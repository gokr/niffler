# DSH steals — implementation plan

Status: **planned, nothing started.** Execution order for the three steals
selected out of [DSH-STEAL.md](DSH-STEAL.md) (orchestration) and
[DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md) (techniques). Those two stay the
design rationale and provenance; this is the runbook.

Baseline `fea84d6`. Branch `feat/dsh-steals`, worktree
`~/git/niffler-dsh-steals`.

## Order and why

| phase | steal | depends on | effort | lands as |
|---|---|---|---|---|
| **A** | context layer: post-execute spill + compaction transaction | – | 3–4 d | `feat/ctx-compaction` |
| **B** | continuable subagents + forked children | – | 3–4 d | `feat/agent-continuation` |
| **C** | fabric declarations on demand (`{api: true}`) | **compiled-Nim merge** | 1–2 d | `feat/fabric-api` |

A and B are independent — either can start first, and they can run in parallel
worktrees. **C is gated**: `feature/fabric-compiled-nim` rewrites
`components/fabric/fabricguest/fabricmeta.nim` (the signature core C must
share), `REFERENCE.md`, the examples and the guest API, and already ships
`fabric_help` — the discovery half of C's motivation. Sequence: merge the
compiled branch → re-measure t30 → render declarations. Do not build C on
main's VM-era fabric.

This branch can hold all three as phase commits, then split into three PRs
before review. If the phases stay small and self-contained, one PR is fine.

## Standing rules

Every phase states, in its commit message, its effect on the request prefix:
**frozen prefix** or **append-only history**. Nothing in this plan adds a
frozen-prefix contributor.

- No `asyncdispatch`; the SDK pump stays synchronous. No core import of
  component code, and components never import core.
- The store is single-writer per record kind: `core` owns `message`, `agent`
  owns `agentjob`/`sessionmeta`. New writers need their own kind.
- New tool schemas are `onDemand` unless a phase argues otherwise. Doc
  comments are the LLM's only window: all prose lines of the first comment
  block become the description, `- param: text` lines become parameter docs.
- Tests are plain `tests/t_*.nim` bus-contract scripts, wired into the
  Makefile and the `make test` list. The bar is a green
  `make build && make test`, plus a live harness run for turn-loop changes
  (MANUAL, "Debugging the bus — prove the stack without the LLM").
- Update AGENTS.md / MANUAL.md / WIRE.md in the same PR that changes the
  contract they describe.

---

## Phase A — context layer

### A1. Post-execute spill (generic, at the dispatch/history seam)

**Why, and the deviation from the doc.** DSH-STEAL and
DEEPSEEK-HARNESS.md #3 propose a *pruner* that rewrites history (replace an
oversized tool result with head/tail). Bash already does better: it caps what
enters history at 12 KB and spills the full capture to
`var/toolout/<session>/`, which the model pages with `read`
(`components/bash/main.nim`). That is **append-only** — the record written to
the store is already the short one, so replay is exact and no original is
lost — and it needs no history rewriting, no store revision tricks and no
pressure trigger. Making it generic is ~20 lines at the single point where a
tool result becomes a message. The other tools that can return unbounded
output (`grep` notably) get it for free.

**Design.**

- In `core/conversation.nim:717` (`runTurn`'s tool-result projection), before
  building `toolMsg`: if `content.len > spillCapBytes` (default 16384,
  `NIF_TOOL_SPILL_BYTES`), write the full text to
  `var/toolout/<sessionId>/<pid>-<ts>-<n>.out` and replace `content` with
  head + middle marker + tail + the path, telling the model it can `read` the
  file with offset/limit.
- Move bash's `spillOutput` into a shared helper
  (`sdk/niffler/toolout.nim`, used by core and by bash). Bash keeps its own
  12 KB cap — same policy, one step earlier, and it keeps a 2 MB capture off
  the bus.
- Exempt `read` (never spill a spill-page). 1-hour TTL sweep, shared helper.

**Cache effect:** append-only history, and history gets *cheaper*. No prefix
change.

**Tests:** `tests/t_toolspill.nim` — a stub tool returning 100 KB yields a
capped persisted message plus a spill file holding the full text, and `read`
on that path returns slices; under-cap results are untouched;
`NIF_TOOL_SPILL_BYTES` override honored. Extend `tests/t_bash.nim` to prove
its own spill still works through the shared helper.

**Effort:** 1 day. **Risk:** low.

### A2. Compaction transaction (durable, cache-aware, monotonic)

**Why.** `core/conversation.nim:473 trimContext` drops whole turns and
inserts a one-line marker; `checkContext` reports `reset:trim` and the next
request rebuilds the provider prompt cache from scratch — on the one path
where a long conversation needs help. The store keeps the transcript, but the
model cannot recall what was dropped. This is the measured `reset:trim` class
(the GLM 525k overflow) and it is engine-wide: every conversation, every
component, the bench, the UI.

**Design.**

- **Trigger:** the existing pressure check in `checkContext`
  (`trimThreshold`, `ctxTrimRatio`, `NIF_CTX_RESERVE`), plus recovery: when
  the provider reports `CONTEXT_WINDOW_EXCEEDED`, compact and retry the round
  once (bounded).
- **Summarizer request = a genuine prefix of the request that just ran:**
  `[frozen system prompt] + [frozen tool schemas] + [the shadowed messages] +
  [the summary instruction]`. The provider's KV cache therefore hits for
  everything but the instruction; the summary costs instruction + output.
- **Monotonic gate:** refuse to commit a summary whose token estimate is ≥
  the shadowed content (dsh `region.ts:385`). Keep `minKeepTurns`.
- **Durable commit, before it is used:** a `message` record with
  `role: "summary"` and `shadows: {fromId, toId, count}` (message ids are
  zero-padded, so the shadowed range is a key range). Raw records stay; the
  store is never asked to delete anything. `core` stays the writer.
- **Replay** (`core/conversation.nim:215`): after loading the
  `convId:`-prefixed messages, drop the shadowed range and splice the summary
  in at index 1. A resumed runner therefore replays the *committed*
  compaction — no re-summarizing, byte-identical.
- **Event:** `reset:trim` becomes `reset:compact` with
  `{shadowed, shadowedTokens, summaryTokens, cacheHitTokens}`. Check
  `ui/frontend` (and `bench/report.mjs`) for `reset:trim` consumers before
  deciding whether to keep an alias.
- **Knobs:** `NIF_COMPACT` (off/auto), `NIF_COMPACT_MODEL` (default: the
  session's model — a different model cannot reuse the prefix cache).
- **Failure is never fatal:** provider error, gate refused or a failed store
  write → fall back to today's drop-with-marker and say so in the event.
  Compaction must not turn a working turn into a failed one.

**Cache effect:** the compaction itself is the sanctioned full miss (the
prefix legitimately changes once, and smaller); the summarizer call is a
prefix hit; after commit the derived prefix is stable again. Document it in
AGENTS.md's cache-discipline section next to `reset:trim`.

**Tests** (`tests/t_compact.nim`; bus-level with `tests/mock_llm.nim`
extended to script usage numbers and summary replies, pure helpers unit-tested
in the `t_ctx_accounting` style):

- pure: shadow-range arithmetic, monotonic gate, summary-record round-trip,
  replay drops exactly the range and inserts at index 1;
- bus: a session forced over the threshold compacts once; the next request
  carries system + summary + kept turns; the store holds the full transcript
  plus exactly one summary record; a second turn does not re-summarize;
- **the cache claim is tested:** the summarizer request's message list is a
  prefix of the previous request's (assert on what `mock_llm` received);
- fail-closed: provider error → marker fallback, turn still completes.

**Effort:** 2–3 days. **Risk:** medium — it touches `runTurn`'s hot path and
the replay contract. Do not merge without a live long-conversation run.

---

## Phase B — continuable subagents and forks

### B1. Continuations (`session:` on `agent_run` / `agent_spawn`)

**Why.** `components/agent/main.nim:183 prepareChild` always mints a fresh
`agent-<id>`; a child runs one turn and is unreachable forever. But
continuation *is* the architecture: the conversation persists in the store,
`core.session_prepare` → `ensureRunner` is idempotent
(`components/agent/main.nim:196`), runners are disposable. dsh needs a
descriptor plus derived residency; Niffler needs a parameter.

**Design.**

- Add optional `session` (string) and `close` (bool) to both schemas.
- `session` present → **validate fail-closed**: the conversation exists
  (`storeGetItem("conversation", …)`) and the caller may continue it
  (`sessionmeta[session].parent == callerSession`; teams extend this later).
  Unknown session, foreign lineage or unreachable store → error, never a
  silently fresh child.
- Reuse the existing turn path: `comp.request("core","session_prepare",
  {sessionId})` for the subject (idempotent re-ensure), then the same
  `childSessArgs` + `requestChildTurn` call the fresh path uses.
- **Frozen controls belong to the child.** On a continuation `model` /
  `thinking` / `tools` / `maxRounds` / `maxCalls` / `maxTokens` are ignored
  (frozen into the child conversation at its first turn); only the new
  `task`/content and `timeoutMs`/`budgetMs` apply. The schema text says so.
- **Job records v2:** add `activation` (1-based) and `firstActivationAt`;
  each activation is its own `agentjob`, so `resolveStale`, the completion tap
  and `ev.agent.done` stay untouched. Continuity metadata lives in
  `sessionmeta` — explicit fields, never a bag.
- `close: true` writes `closed: true` into `sessionmeta`; `agent_status`
  stops advertising the child as continuable. Nothing is deleted.
- `interrupted` (runner died without a reply) stays continuable: the death
  cost one turn, not the child.
- Depth-1 stays bolted on: a continuation mutates no lineage, so it needs no
  depth exception (later, this is how teammates wake teammates).

**Cache effect:** one appended user turn onto the child's stable prefix —
exactly the shape of any second turn. No new contributor.

**Tests** (`tests/t_agent.nim`): continue after `done`; kill the runner then
continue (interrupted → new activation); continuation by a non-parent fails
closed; `session` naming a root conversation fails closed; frozen controls
ignored (a continuation carrying `model` does not change the child's model);
`agent_status` shows the activation lineage; v1 records still read.

### B2. Forked children (`fork:` on fresh spawns)

**Why.** A child that inherits what happened instead of being told about it —
the same code path as B1, one step further.

**Design.**

- `fork: true | {"lastK": n} | {"maxChars": n}` on the *fresh* path only (a
  fork is a birth, not a continuation).
- Read the parent transcript (`storeListItems("message", parent & ":")`),
  write each record under the child id preserving role/content/createdAt and
  dropping `usage` (the child's accounting is its own), then record
  `sessionmeta[child] = {parent, fork: {source, uptoId, copied}}` **before**
  the first turn.
- **Create-or-adopt:** a forked conversation has message records before its
  `conversation` header exists. The resume path in `core/conversation.nim`
  must tolerate that ordering (the header is created on the first turn,
  adopting the existing records). This is B2's only core change.
- `session_info` gains `fork: {source, uptoId, copied}`.
- A `lastK`/`maxChars` budget that drops everything fails closed, not an
  empty child.

**Cache effect:** forks are born cold (the first request replays the copied
history uncached) and warm from the second turn. That is the price of
inheritance — say so in the tool docs.

**Tests** (`tests/t_agent.nim`): copy → resume proves the
messages-before-header adoption; `lastK`/`maxChars` budget errors fail
closed; provenance visible in `session_info`; depth-1 unaffected; no
fork-of-fork chains.

**Effort:** B1 2 days, B2 1–2 days. **Risk:** low-medium; lineage checks and
header adoption are the sharp edges.

---

## Phase C — fabric declarations on demand (`fabric {api: true}`)

**Gate.** Do not start before `feature/fabric-compiled-nim` is merged (see
Order and why). Then merge it into `feat/dsh-steals` as well, so C builds on
the native executor.

**Why.** The one place Niffler measurably loses to pi (t30: `29 calls /
383.8s / $0.0297` vs pi `5 / 36.1s / $0.00196`), and the cost is authoring +
selection, not execution. Today the model must read
`components/fabric/docs/REFERENCE.md` before it can write a program; the
declarations should come to it, pinned to the exact catalog snapshot its
program will compile against.

**Design.**

- `fabric {api: true, tools: [...]}` returns, as the tool result: (1) the
  ~30-line discipline preamble (import `fabricguest` first, `callTool`
  returns a JSON *string* so `parseJson` first, `finish()`'s value is the only
  thing that reaches the conversation, when-to-use: one command → bash,
  mechanical → program, judgment → `agent_run`, mixed → hybrid); (2) the
  helper contract (`finish` / `logg` / `batch` / `stringArg`, budgets
  `maxCalls ≤ 1000`, `timeoutMs ≤ 300000`); (3) the **typed declarations for
  exactly those tools**.
- `fabric {api: true, name: "<stored-program>"}` → the program source *plus*
  the declarations for its pinned tool set (kills the second artefact hunt).
- **Requirement: share the signature core.** The renderer and
  `fabricmeta.nim`'s runtime-schema macro must compute names and types from
  one implementation (`nimName`, `scalarType` / `FabricArg[T]` shaping, JSDoc
  from schema descriptions, collision handling) — the macro emits an AST, the
  renderer emits text. The proof test: feed the rendered declarations to the
  admission path as a stub program that `discard`-calls every wrapper; it must
  compile. "What you saw is what compiles."
- The result echoes the pin digest (`component@version` set); a mismatch at
  admission is *reported in the error* ("declarations were pinned at 3f2a…;
  call `fabric {api:true}` again") so the model self-heals from its history.
- **No prefix contributor:** the declarations are a tool result (append-only
  history, replayed as cache reads thereafter). The prompt-embedded variant
  (dsh's `.d.ts` in the system prompt) stays rejected; a tools profile may
  inline it for dedicated fabric conversations, frozen at conversation start —
  not now.

**Cache effect:** append-only history, paid once per conversation that writes
programs. Never the frozen prefix.

**Tests** (`tests/t_fabric.nim` plus the compiled branch's native test):
rendered declarations for a fixture catalog compile via the admission path;
`api` with `name`; unknown tool → error listing the known names; digest
mismatch admission hint; the emitted text is byte-stable for the same catalog
(that is what makes it cache).

**Effort:** 1–2 days after the merge. **Risk:** low, but it must not drift
from the macro — the shared-core requirement is the whole point.

---

## Cross-phase: documentation and validation

- **AGENTS.md** — cache-discipline entry for `reset:compact`; the new record
  fields (`message.shadows`, `sessionmeta.activation`, `agentjob.v2`,
  `sessionmeta.fork`).
- **docs/MANUAL.md** — `NIF_TOOL_SPILL_BYTES`, `NIF_COMPACT*`; agent
  continuation and fork semantics; the api-first fabric loop.
- **docs/WIRE.md** — the `summary` message role + `shadows`; `ev.session.
  context` `reset:compact`; agentjob v2 and the `session`/`fork` tool args.
- **Tests** — each phase adds its target to the Makefile and the `make test`
  list; `make build && make test` green before each PR.
- **Live validation** — A: drive a conversation past the threshold, watch
  `cacheHitRatio` stay high and exactly one `reset:compact`; B: a lead runs a
  child, re-tasks it, forks it; C: a t30 rerun comparing model-facing calls
  before/after.
- **Bench** — none of the three changes the bench. The full30 numbers from
  the `full30-deepseek-v4.1-flash-*` run are the baseline to re-check after
  A (cache read should rise, `reset:trim` should disappear).

## Open questions (decide at implementation)

1. **Summary message role.** `role: "summary"` must be accepted by the llm
   component and its provider adapters; otherwise persist as `role: "user"`
   with an explicit `[compacted history]` wrapper. Check the adapters first.
2. **Concurrent activations (B1).** Two `agent_run {session: X}` at once: the
   runner serializes turns, so the second waits and its timeout must budget
   the first turn's remainder. v1: document it; optionally return `busy` from
   a cheap catalog probe.
3. **Fork + compaction composition.** A forked child of a compacted parent
   should copy the raw records *plus* the parent's summary record, so the
   child inherits the same derivation — not a flattened view.
4. **`reset:trim` alias.** Keep emitting it for one release if the UI or
   `bench/report.mjs` parses it.
