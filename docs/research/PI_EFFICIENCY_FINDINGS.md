# Pi Efficiency Findings

> Research note — what pi (github.com/earendil-works/pi, `@earendil-works`) does that
> Niffler does not, focused on **token consumption** and **wall-clock execution
> time** on tasks, plus a deep-dive on concurrency (Nim threading vs. NATS
> fan-out). Operating decisions live in
> [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) (same directory).
>
> Basis: pi at `96317e50b` (pulled 2026-08), Niffler at `45ba045`, both read in
> full where it matters. Every claim below is grounded in a file path; nothing
> here is inferred from documentation alone.

## 0. How pi and Niffler differ at the seams

| Axis | pi | Niffler |
|---|---|---|
| Unit of execution | one big Node process (`AgentSession`), everything in-thread | many small processes on a NATS bus; core is a thin orchestrator |
| Tool call parallelism | parallel by default, per-file mutation serialization | strictly serial (`for tc in toolCalls`) |
| Context overflow | LLM **compaction** (structured summaries, iterative update) | whole-turn **trim** (drops history, no summary) |
| Token accounting | model-reported usage + cache buckets, persisted, drives decisions | chars/4 fallback + blunt 90% threshold |
| Prompt cache | measured (`cache-stats`), cache-retention policy per call | forwarded `sessionId`, `cached_tokens` read back, no measurement |
| LLM failure | classified retryable vs not, exponential backoff | error returned to caller, no auto-retry |
| Long output | bounded tail + full-output temp file | head+tail cap in memory |
| Sessions | tree with branch summaries, forks | linear conversation (+ subagents) |
| Images | read + auto-resize ≤2000px, normalized on entry | text-only reads |

Niffler already matches pi on several things worth *not* copying: `read`
pagination with offset/limit + continuation hints (`components/edit/main.nim`
`hRead`), skills as a compact catalog with on-demand `skill_load` (more
token-economical than pi's full catalog in the prompt), Pi-style ancestor
context-file walk with worktree shadowing (`components/systemprompt/`),
steering/follow-up message queues (`drainSteer`/`drainAdvisories` in
`core/conversation.nim`).

---

## 1. Concurrency: the question, answered precisely

> Correction (2026-08): an earlier draft claimed NATS fan-out alone gives
> "true OS-level parallelism". That is only true **across** components. For
> **same-component** concurrency (four `bash` calls, four `edit` reads) the
> runner fan-out changes nothing — the component still serializes. The three
> mechanisms below are orthogonal; the plan now splits them (B1a runner
> fan-out, B1b SDK worker threads, B2 scale-out).

### 1.0 The three mechanisms — one mental model

| Mechanism | Where the concurrency is | Gives you | Needs |
|---|---|---|---|
| **Runner fan-out** (B1a) | across components: `read` (edit) ∥ `grep` (grep) ∥ `git_status` (git) | cross-component parallelism; removes runner-side serialization | async request/reply in the runner (no threads, no asyncdispatch) |
| **Worker threads in the component** (B1b) | inside one component: 4 `bash` calls ∥ 4 `edit` reads | same-component parallelism — the real bash/edit win | `--threads:on` + a worker pool in the SDK (your preference) |
| **Replicas / scale-out** | N copies of the component process, one per call via the NATS queue group | same-component parallelism with **zero threads**, works for Go too | spawn N replicas; queue group already distributes |

**Why bash cannot "fork and return early" to get concurrency:** the WIRE
contract is one reply per call. `bash` spawns a child shell process per command
(the handler blocks on it), but the component can only accept the *next* call
after the handler returns. A detached background process would need a second
reply on the reply subject — a protocol change (pi's deferred responses
`fetchDeferred` are exactly this). So in-process concurrency for a blocking
handler means threads.

### 1.1 Today Niffler is serial twice over

**Within a component** (`sdk/niffler/sdk.nim` `run*`): a single main thread
polls every subscription with `natsSubscription_NextMsg` (1ms timeout) and
`handleMsg` finds the tool handler and calls it **synchronously**, then
publishes the reply. One call at a time, per process. A long handler (bash with
a 60s timeout) blocks that component's *entire* pump — every other tool *and*
every event/tap handler it owns.

**Across components** (`core/conversation.nim`):
`for tc in toolCalls:` runs each tool call to completion
(`ct.dispatchToolCall(name, args)` is a blocking request/reply) before the
next. So even though the model emits 5 independent calls, the wall clock is the
**sum** of their latencies.

The AGENTS.md invariant ("Nim SDK has no callbacks and no threads … the
`{.gcsafe.}` dance must not be copied here") is about the SDK's base design —
it does **not** forbid a component from running handlers on a worker pool. But
it tells us the default must stay simple and serial.

### 1.2 B1a — Runner fan-out: cross-component parallelism (no threads)

`dispatchToolCall` becomes a fan-out that fires all N calls (distinct reply
subjects) and polls N reply subscriptions round-robin, reassembling results in
original order. It is pure event-driven async in the runner and touches **zero**
component code — but it only parallelizes calls to **different** components.

**Why it is not free:** not every call may run concurrently.
- **Approvals** (`core/approval.nim`) are a synchronous human-in-the-loop prompt;
  4 approvals in flight would interleave badly. Approval-gated tools must be
  serialized (or batched).
- **Session-context tools** (`fabric`, `agent`, `session_*`) carry a live
  lease/lineage (`ct.nested`, `pumpNested`); the child runner is itself a
  blocking loop. These must stay sequential.
- **Mutations** to the same file must serialize (pi: `file-mutation-queue.ts` +
  `executionMode: "sequential"`); independent-file mutations can go parallel.
- Tool **timeoutMs** and cancellation (`llm.cancel.<sessionId>`) must map to a
  per-call deadline when calls are in flight.

So fan-out needs a **parallel-safe classification** per tool, exactly pi's
`executionMode` — and it is **not** a substitute for in-component
concurrency. Same-component calls still serialize at the component.

### 1.3 B1b — Worker threads in the component: same-component parallelism (your preference)

For 4 `bash` calls (or 4 `edit` reads) to actually run concurrently, the
component itself must execute handlers on more than one thread. Design:
- Keep the NATS pump single-threaded (delivery stays serial → no subscription
  races, approvals stay on the main thread).
- On a call envelope, capture `{tool, args, reply subject}` and hand it to a
  worker pool, then keep polling.
- The worker runs the handler and publishes the reply (`natsConnection_Publish`
  is thread-safe; only the pump reads subscriptions). For `bash` each worker
  blocks on its own child shell process — natural; for `edit` each worker does
  its own file read — natural; same-file mutations need a per-file queue.
- Handlers become `{.gcsafe.}` and the argument payload is isolated.

Nim 2.2.10 offers two mechanisms:

**Old: `std/threadpool`** (`lib/pure/concurrency/threadpool.nim`) — mature,
high-level: `spawn` a proc → `FlowVar[T]`, wait with `sync`/`blockUntil`/
`awaitAny`/`awaitAnyAnd`, `parallel` sections, bounded worker threads. Uses a
**shared heap** with `--threads:on`; the handler must be `{.gcsafe.}` and the
payload must not be aliased across threads (ref objects like `JsonNode` must be
owned by exactly one thread or the whole payload isolated).

**New: `std/tasks`** (`lib/std/tasks.nim`) — the modern primitive, built on
`std/isolation` (`isolate`/`extract`), so ownership is explicit: a `Task` is
"owned by a single thread, cannot be shared". In 2.2.10 it is a **lower-level**
building block (`toTask` + `invoke` + result pointer; the ergonomic
`await`/`awaitAll`/`awaitAny` layer is newer). Cleaner semantics, more manual.

### 1.4 B2 — Replicas / scale-out (no threads, works for any language)

Because the call subject is a NATS queue group, spawning N copies of a
component process distributes N concurrent calls one per replica. Zero
threading; the simplest mechanism for a non-Nim component (Go `store`/`llm` is
single-writer and can't replicate, but `bash`/`fetch`/`grep` can). Costs: N
processes, and any per-process state is duplicated.

### 1.5 Recommendation

Runner fan-out (B1a) **and** SDK worker threads (B1b) together give full
parallelism: the runner fires across components; parallel-safe components
(`bash`, `edit`, `grep`, `fetch`) run their own calls on threads. B2
(replicas) is a fallback for non-Nim components. Build B1a first (small, no
threads, needed regardless); then B1b opt-in worker pools per component.
Do not retrofit the whole SDK at once.

---

## 2. Token consumption — pi features Niffler lacks

### 2.1 LLM-backed compaction (A1) — highest value
Pi `core/compaction/compaction.ts`:
- structured checkpoint summary (`## Goal`, `## Progress` Done/In Progress/
  Blocked, `## Key Decisions`, `## Next Steps`, `## Critical Context`),
- **iterative update**: feeds the previous summary back (`UPDATE_…_PROMPT`)
  instead of regenerating,
- **mid-turn split**: when the cut lands mid-turn, a separate
  `TURN_PREFIX_SUMMARIZATION_PROMPT` covers just the dropped prefix,
- **file-op tracking**: `<read-files>/<modified-files>` appended to the summary
  so nothing is silently lost,
- triggers on **reported usage** vs `contextWindow − reserveTokens`,
- can run **before** the next LLM call (`prepareNextTurn` hook in
  `agent-session.ts` `_compactBeforeNextAssistantResponse`), not only on
  overflow.

Niffler `core/conversation.nim` `trimContext()` drops whole turns and inserts
`"[context trimmed: dropped N earlier messages…]"` — the work product
(decisions, constraints, next steps) is *lost*. Long tasks degrade.

### 2.2 Usage-accurate context accounting (A2)
Pi `estimateTokens` counts text + thinking + toolCall args + tool results;
`estimateContextTokens` uses the **model-reported** usage
(`input+output+cacheRead+cacheWrite`) of the last assistant message, persisted
across resume, with the remainder estimated. Niffler's fallback is
`content.len div 4` (ignores thinking, tool-call args, tool-result bulk) and a
blunt 90%-of-window threshold with `minKeepTurns=2`.

### 2.3 Prompt-cache discipline + measurement (A3)
Pi `core/cache-stats.ts` computes per-turn **cache-miss waste**
(`missedTokens`/`missedCost`/`missCount`) from usage data, distinguishing
cache-read-only providers (OpenAI-style) from providers that never report
caching; it sets `cacheRetention: "none"` on one-off summarization calls so
they don't pollute the cache; it forwards `sessionId` for session-affinity
headers; it keeps system prompt + tool schemas byte-stable per turn (rebuild
only on tool-set change). Niffler freezes the system prompt per conversation
✓, forwards `sessionId` ✓ (for token routing/cancellation), reads
`cached_tokens` back ✓ — but has no cache-retention policy for one-off calls
and no cache-waste measurement, so cache-breaking regressions (model switch
mid-session, tool-schema drift) are invisible.

### 2.4 Bash/command output: bounded tail + full-output temp file (A4)
Pi `tools/output-accumulator.ts` keeps a rolling **tail window** in memory,
spills the **full** output to a temp file once limits are exceeded, and returns
the truncated tail **with the temp-file path** (`Full output: …`), so the model
reads only what it needs and can `read` the rest on demand. Niffler
`capBytes` (head+tail) keeps the marker but no path — a huge build/test log
can't be selectively re-read without re-running the command.

### 2.5 Grep/find hygiene (A5)
Pi `tools/grep.ts` defaults to 100 matches, **kills `rg` as soon as the limit is
hit** (`child.kill()` — saves wall-clock), truncates long match lines to 500
chars, and appends actionable notices (`Use limit=2N…`, `Use read tool to see
full lines`). Niffler `components/grep/main.nim` caps at 200 lines but buffers
all of rg's output before capping and doesn't early-kill.

### 2.6 Image reading + auto-resize (A6)
Pi `read` opens images (jpg/png/gif/webp/bmp), **resizes to ≤2000×2000** before
sending (`image-process.ts`), and `afterToolCall` normalizes any image blocks
from extension tools (`utils/tool-result-images.ts`) so oversized payloads
never enter history (huge token cost per image). Niffler `edit`'s read is
**text-only** — images rejected as `[E_NOT_TEXT] … looks binary`. No vision path
at all.

### 2.7 Strict tool-call sampling (A7)
Pi tools can request `constrainedSampling` (`json_schema` strict mode) so the
provider emits well-formed tool calls — fewer malformed-argument round-trips.
Niffler neutralizes bad JSON in-loop but can't *prevent* it.

---

## 3. Wall-clock execution time — pi features Niffler lacks

### 3.1 Parallel tool execution (B1) — biggest wall-clock win
See §1.2. pi `agent-loop.ts` `executeToolCallsParallel` (default
`toolExecution: "parallel"`), serializing only same-file mutations via
`file-mutation-queue.ts`. Niffler executes strictly serially.

### 3.2 Auto-retry of transient LLM failures (B2)
Pi `ai/src/utils/retry.ts` classifies failures — retryable (`429`, `5xx`,
`overloaded`, connection drops, `reset before headers`, …) vs fail-fast
(quota/billing exhaustion) — and auto-retries with exponential backoff +
jitter, emitting retry events; also wraps compaction/branch summaries
(`completeSummarization`). Niffler returns the error to the caller on the first
transient failure — recovery costs a full human re-prompt.

### 3.3 Length-stop / truncated-tool-call policy (B3)
Pi: on `stopReason === "length"`, the loop **fails every tool call in the
batch** (`failToolCallsFromTruncatedMessage`) — truncated args may be silently
borked — and asks the model to re-issue; it also compacts pre-turn so overflow
doesn't nuke a response. Niffler handles malformed JSON but has no length-stop
policy.

### 3.4 Auto-download of rg/fd (B4)
Pi `utils/tools-manager.ts` `ensureTool` downloads static ripgrep/fd binaries
when missing. Niffler's grep errors out (`127`) and falls back to bash
`grep -rn`, dramatically slower on large repos.

### 3.5 Process-tree kill on timeout/abort (B5)
Pi `killProcessTree` on abort/timeout so detached grandchildren can't linger
and hold locks. Niffler kills the immediate child; process-group kills are
safer (see the `var/barrel-db.lock` class of problems).

---

## 4. Complex-task capability (drives efficiency indirectly)

### 4.1 Session tree + branch summarization (C1)
Pi `session-manager.ts` is a **tree** (entries with `parentId`); forking a
session and exploring produces a `branch-summarization.ts` LLM pass that
summarizes the branch you leave (with file-op tracking), so exploration doesn't
cost a linear-context blow-up or a re-do. Niffler has linear conversations +
subagents (`agent` component) but no in-session branching.

### 4.2 Scoped/cheap models per phase (C2)
Pi `model-resolver.ts` + scoped-models selector route cheap/fast models for
mechanical phases and set **thinking level per model**
(`off|low|medium|high`), burning tokens only where reasoning earns it. Niffler
has per-session `model` override + `reasoning_effort` passthrough but no
per-phase routing policy.

---

## 5. Already-parity (do not copy)

- `read` pagination + continuation notices (`components/edit/main.nim`) — pi-style, present.
- Skills catalog + on-demand load — Niffler is *more* token-economical than pi here.
- Ancestor context-file walk + worktree shadowing (`components/systemprompt/`).
- Steering/follow-up queues, persistent history in a store, subagents with depth guard.

## 6. Ground-truth index

| Claim | pi evidence | Niffler evidence |
|---|---|---|
| Parallel tool exec | `packages/agent/src/agent-loop.ts` (`executeToolCallsParallel`, `toolExecution: "parallel"`) | `core/conversation.nim` (`for tc in toolCalls`) |
| Per-file mutation serialization | `core/tools/file-mutation-queue.ts` | — |
| LLM compaction | `core/compaction/compaction.ts` + `compaction/utils.ts` + `branch-summarization.ts` | `core/conversation.nim` `trimContext`/`checkContext` |
| Cache measurement | `core/cache-stats.ts`; `cacheRetention:"none"` in `compaction.ts` `completeSummarization` | `components/llm/main.go` (forwards `sessionId`, reads `cached_tokens`) |
| Retry classification | `packages/ai/src/utils/retry.ts` | — |
| Tail+temp-file output | `core/tools/output-accumulator.ts`, `truncate.ts` | `sdk/niffler/procutil.nim` `capBytes` |
| Grep early-kill | `core/tools/grep.ts` (`child.kill()`, `truncateLine`) | `components/grep/main.nim` |
| Image resize | `utils/image-process.ts`, `utils/tool-result-images.ts` | `components/edit/main.nim` (text-only read) |
| rg/fd download | `utils/tools-manager.ts` `ensureTool` | `components/grep/main.nim` (`findExe("rg")`) |
| Session tree | `core/session-manager.ts`, `core/compaction/branch-summarization.ts` | store: linear `kind=message` sequence |
| Scoped models / thinking | `core/model-resolver.ts` | `components/llm/main.go` `reasoning_effort` |
| Serial SDK pump | — | `sdk/niffler/sdk.nim` `run*`/`handleMsg` |
