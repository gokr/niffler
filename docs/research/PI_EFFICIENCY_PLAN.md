# Pi Efficiency Plan

> Operating plan derived from [PI_EFFICIENCY_FINDINGS.md](PI_EFFICIENCY_FINDINGS.md)
> (same directory). Ordered by **impact ÷ effort**, split into phases. Each item
> names the wire/spec implications where they exist, because Niffler's core
> speaks exactly one protocol (JSON envelopes over NATS, `docs/WIRE.md`) and any
> change that alters message shapes or tool semantics must be specced first.
>
> Status markers: ☐ not started, ◐ in progress, ☑ shipped.

## The one architectural principle

**Concurrency is explicit at each layer:** the session runner fans calls out
over NATS; stateless logical components can scale through queue-group process
replicas; and an audited component may own native concurrency. Never use Nim
`asyncdispatch`. The default Nim SDK pump remains threadless and serial, while
`std/threads` + `std/locks` is the preferred general model for component-owned
shared-state workers (`taskpools` fits genuinely isolated jobs). Go tools are
serialized unless explicitly registered concurrency-safe.

---

## Phase 1 — Concurrency + cheap wins (this branch)

### B1a. Runner fan-out: cross-component parallelism *(no threads)* ☑
- **What:** replace `for tc in toolCalls:` in `core/conversation.nim` with a
  fan-out: publish all N call envelopes with distinct reply subjects, poll N
  reply subscriptions round-robin (pure event-driven async — no asyncdispatch,
  no threads), reassemble results in original order. Parallelizes calls to
  *different* components (`read` ∥ `grep` ∥ `git_status`). Calls to one logical
  component need queue-group replicas (B2) or a worker-aware component to overlap.
- **Guard rails (design work, not just async):** per-tool `parallel: bool`
  classification. Default **serial** for: approval-gated tools
  (`core/approval.nim` — human in the loop), session-context tools (`fabric`,
  `agent`, `session_*` — live lease/lineage), and same-target mutations.
  Default **parallel** for pure, side-effect-light tools (`read`, `grep`,
  `files`, `git_*`, `skill_*`, `logfile` reads, `fetch` GETs).
- **Spec:** add `"parallel": true` to the catalog's `x-harness` extension
  (`docs/WIRE.md`); core's `dispatch.nim` already carries the tool schema +
  x-harness, so this is a per-tool flag, default-off → no surprise behavior.
- **Effort:** medium. ~1–2 days. Required regardless of the scale-out mechanism.

### B1b. Worker-aware Nim component pump — deferred
- **Investigation:** compared `std/threadpool`, `std/tasks`, `taskpools` 0.2.1,
  and a fixed `std/threads` + `std/locks` pool on Nim 2.2.10. `taskpools`
  correctly rejects an aliased shared `Component` ref, but remains suitable for
  isolated jobs. A fixed `std/threads` + `std/locks` pool is the preferred
  general component model.
- **Decision:** keep `Component.run()` serial for now. A future opt-in pump must
  define encoded/isolated job ownership, bounded admission, gcsafe handlers,
  exclusive barriers for serial tools/events, completion publication, and
  shutdown. This is primarily needed for mixed stateful components such as
  parallel `read` plus serialized `edit`; it is not a session reply-consumer
  bottleneck. See
  [PI_EFFICIENCY_B1B_THREADS.md](PI_EFFICIENCY_B1B_THREADS.md).

### B1c. Concurrent-safe Go tool handlers ☑
- **What:** `ToolConcurrent` hands a call from nats.go's serial subscription
  callback to a bounded goroutine (default 16; `ConcurrentLimit` configures
  it). An RW-lock lets concurrent tools overlap while ordinary tools, events,
  and taps remain exclusive barriers; shutdown waits for detached handlers.
- **First use:** audited `llm.chat`, `llm_resolve`, and `llm-openai.chat`,
  removing accidental serialization across independent sessions/subagents.
- **Verification:** bus-level overlap/exclusion tests and `go test -race` for
  the SDK and both LLM adapters.

### B2. Replicas / scale-out *(no threads, any language)* ☑
- **What:** because the call subject is a NATS queue group, spawning N copies
  of a component process distributes concurrent calls one per replica while
  preserving process crash isolation and the serial SDK pump.
- **Shipped:** optional `replicas: N` (1–16, default 1) in `manifest.yaml` and
  `core.spawn`; persisted replica count; replica-aware catalog PIDs/status;
  group lifecycle; four stateless `grep` replicas; same-component timing and
  ordered-result coverage in `tests/t_parallel.nim`.
- **Constraint:** only stateless or externally coordinated components may be
  replicated. `store` and the current mixed read/mutation `edit` component may
  not be.

### B3. Auto-retry of transient LLM failures ☑
- **What:** the session runner's chat call retries transient errors (429,
  5xx, `overloaded`, timeout, connection drop — pi `ai/src/utils/retry.ts`
  classification) with exponential backoff + jitter, up to
  `NIF_LLM_MAX_RETRIES` (default 2, 0 disables). Auth/quota/bad-request fail
  fast. Each retry announces `ev.session.retry {attempt, maxRetries,
  delayMs, error}` so UIs can show the wait.
- **Spec:** event documented in docs/WIRE.md. Classification/backoff live in
  `core/retry.nim` (unit-tested in `tests/t_retry_unit.nim`); the
  end-to-end recovery path is proven in `tests/t_parallel.nim` (retry
  scenario: two mocked 503s, then success).
- **Effort:** small. Saves a human round-trip on every transient provider
  hiccup.

### B4. Length-stop / truncated-tool-call policy
- **What:** when the provider reports a length finish on a message that
  contains `tool_calls`, neutralize the whole batch with a re-issue notice
  (pi `failToolCallsFromTruncatedMessage`) instead of executing partially-valid
  args. Wire the finish-reason through `components/llm/main.go` (today it is
  not surfaced to the runner).
- **Effort:** small–medium (needs the llm adapter to return the stop reason).

### B5. Auto-download of rg/fd (grep/files)
- **What:** `components/grep/main.nim` — when `rg`/`fd` is missing, download a
  static binary (pi does this in `utils/tools-manager.ts`), cache under
  `var/tools/`, before falling back to bash `grep -rn`.
- **Effort:** small. Removes the slow fallback path entirely.

### A3. Cache-waste reporting
- **What:** from the existing per-assistant `usage` (`components/llm/main.go`
  already returns `cached_tokens`), compute per-turn cache misses
  (`promptTokens − cacheRead` vs previous request, model-change flag — mirror
  `cache-stats.ts`), emit on the session `status` event and persist in the
  conversation header. Also set a no-cache policy on one-off calls (none exist
  yet in Niffler — this becomes meaningful once compaction lands).
- **Effort:** small. Makes efficiency *measurable*, which is the precondition
  for trusting every later change.

### A2. Usage-accurate context accounting
- **What:** in `core/conversation.nim`, drive the trim/compact decision off the
  persisted model-reported usage (`input+output+cacheRead+cacheWrite`) instead
  of the chars/4 fallback; add a token **reserve** for output (e.g. compact at
  `window − 16K`, pi's default) rather than a single 90% ratio; include
  thinking + tool-call args + tool-result bulk in the estimate.
- **Effort:** small–medium. Prerequisite for A1's compaction trigger to be
  reliable.

---

## Phase 2 — Token-efficiency core (the big one)

### A1. LLM-backed compaction
- **What:** replace `trimContext`'s silent drop with a `compact` pass that:
  1. cuts at the newest whole-turn boundary that fits the keep budget,
  2. calls the llm component with a **serialized conversation + structured
     checkpoint prompt** (`## Goal / Progress / Key Decisions / Next Steps /
     Critical Context` — port pi `compaction.ts` + `utils.ts`
     `serializeConversation`, truncated tool results to 2K chars),
  3. **iteratively updates** the previous summary instead of regenerating
     (feeds prior summary back),
  4. appends `<read-files>/<modified-files>` tracked from tool calls,
  5. injects a `compactionSummary`-style system message in place of the dropped
     turns (new message role per `docs/WIRE.md`).
- **Spec:** new role/kind in the store (`kind=compaction` entry), a
  `compaction` tool or a runner-internal LLM call (reuse `svc.llm` `chat` with
  a small model — cheap), and the summarization prompt living where prompts
  live today (systemprompt component or baked const).
- **Effort:** large (the design record above is the pattern; port it, don't
  invent). Defer the mid-turn split and pre-turn trigger until the basic
  path works.
- **Why first-class:** this is the single biggest token + capability win on
  long tasks; Phase-1 A2/A3 make its trigger and its cost visible.

### A4. Bash full-output temp file
- **What:** on truncation, spill the full output to `var/logs/<conv>/…` and
  include the path + a read hint in the result (pi `output-accumulator.ts`).
- **Effort:** small. Real token savings on build/test-heavy tasks; pairs with
  `edit`'s read for selective re-reads.

### A5. Grep early-kill + line truncation
- **What:** in `components/grep/main.nim`, kill rg as soon as `max_results` is
  hit; truncate long match lines to ~500 chars with a `Use read tool to see
  full lines` notice.
- **Effort:** small. Saves wall-clock on noisy repos.

### A6. Image reading + auto-resize
- **What:** extend `edit`'s read to detect image MIME, resize to ≤2000×2000
  (small helper; `sips`/ImageMagick or a Nim image lib), and send as an OpenAI
  `image_url` content block through `components/llm/main.go` (needs to accept
  image content parts). Unlocks vision tasks (screenshots, diagrams, UI bugs).
- **Effort:** medium; touches the llm adapter's message shape → **spec it**
  (`docs/WIRE.md` message content schema).

### A7. Strict tool-call sampling (experimental)
- **What:** optional strict JSON-schema tool-call mode through the llm adapter
  when the provider supports it (gate behind `NIF_EXPERIMENTAL`-style flag).
- **Effort:** small. Reduces malformed-argument round-trips.

---

## Phase 3 — Capability (strategic)

### C1. Session tree + branch summarization
- **What:** model session history as entries with `parentId` (the store already
  has revisioned docs — `kind=session` tree), add fork + branch-summary pass
  (reuse A1's summarization machinery: `serializeConversation`, file-op
  tracking, checkpoint prompt). Lets the agent explore alternatives and return
  without linear-context blow-up or re-do.
- **Effort:** large. Most of A1's machinery transfers.

### C2. Scoped/cheap models per phase
- **What:** a session-level routing rule (mechanical tool batches → cheap
  model/low thinking; main reasoning → strong model) surfaced as an llm
  `model`/`reasoning_effort` hint. Niffler's plumbing already carries both
  overrides; this is policy, not transport.
- **Effort:** small once Phase 1 lands (the parallel fan-out needs the same
  classification list).

---

## Suggested order (impact ÷ effort)

| # | Item | Effort | Payoff |
|---|---|---|---|
| 1 | **B1a** runner fan-out (cross-component) | medium | concurrent dispatch; prerequisite for useful replicas/workers |
| 2 | **B2** process replicas (same-component) | small | concurrent stateless calls without weakening process isolation |
| 3 | **B1c** concurrent Go handlers | small | independent sessions/subagents no longer queue behind one LLM request |
| 4 | **A1** LLM compaction (basic path) | large | biggest token + capability win on long tasks |
| 5 | **B3** LLM auto-retry | small | saves human round-trips constantly |
| 6 | **A2** usage-accurate accounting | small–med | makes compaction reliable |
| 7 | **A3** cache-waste reporting | small | makes efficiency measurable |
| 8 | **A4/B5/B4** bash temp-file, rg download, length-stop | small | everyday wins |
| 9 | **C1** session tree + branch summaries | large | strategic; reuses A1 machinery |
| 10 | **B1b** worker-aware Nim pump | large/deferred | parallel reads in mixed stateful components |

B1a, B2, and B1c are shipped. Continue with **A1**; implement B1b when a
mixed stateful component needs call-level concurrency that replicas cannot
safely provide. Wire implications are marked per item — nail the compaction
message role before coding A1.
