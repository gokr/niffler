# DeepSeek Harness (dsh) — research notes

Studied 2026-07-15 via four Niffler subagents (one structural survey + three
slice deep-reads) against `~/git/deepseek-harness` (~170k LOC TypeScript, 265
workspace packages). All findings below carry the agents' file:line citations;
I spot-checked five load-bearing quotes across five files — all exact.
Unverified: cordis runtime waterfall semantics (taken from docs + code reads),
e2b remote sandbox, the inspector's CDP bridge (15.6k lines, skimmed only).

## What it is

DeepSeek's open-source agent harness (`dsh`, npm `@deepseek-ai/dsh`):
"everything-is-a-plugin" on the Cordis DI framework — model adapter, tool
registry, session log, agent loop are all replaceable plugins composed at boot
from **profiles** (web/headless/sdk/acp/sdk-minimal) stacking **bundles** and
patch files. React client (`packages/client`, 73k LOC — the single biggest
package is the UI), Python SDK, a Landlock sandbox launcher in raw C. House
style: every seam JSDocuments its failure modes; validation is fail-loud,
never silent-clamp.

## Positioning: three granularities of "replaceable"

- **Pi** bets on minimality: a core you can read in an afternoon, in-process
  TS extensions, JSONL sessions (see `CODEWHALE.md`).
- **Niffler** bets on topology: one wire protocol (JSON envelopes over NATS),
  every capability a peer process, core blind to component code. Extension =
  write source → `builder.build` → `core.spawn`.
- **dsh** bets on typed composition: a DI container where every capability
  seam is a *waterfall*, plugins layer via patch files, and correctness is
  enforced by validation at the seams.

Same destination, different isolation granularities: OS processes (Niffler),
none (Pi), vm-realms + validated seams (dsh).

## The techniques

### 1. The Surface — event-sourced conversation with provable deletions
Every session is an append-only, seq-contiguous event log; all model history,
UI, persistence, and stats are **projections** folded from it. Message-producing
events must carry a `surfaceOp` (`append` or `replace{start,end,sourceEventSeqs}`)
— "the sole source of derived model history"
(`packages/core/session/src/index.ts:675`). Compaction never deletes; it
*shadows*. A replace must cite every node it shadows or be rejected
(`surface.ts:254`); a tool-result replace may change *only content* — everything
else is deep-compared and must be identical (`surface.ts:308`) — an
anti-context-injection rule baked into the log itself.
*Niffler*: store keeps the transcript, derived context is rebuilt on trim — no
formal contract between "what happened" and "what the model sees". *Pi*: JSONL
log + /compact rewriting the working set; no shadow proof.

### 2. Compaction as a durable, locked, cache-aware transaction
`compaction/start` appended *before* async summarization — the marker IS the
lock (`compaction-basic/src/region.ts:298`). Commit = summary event + surface
replace; hard gate `summary is not smaller than the shadowed content` throws
(`region.ts:385`); failures leave exactly one `compaction/end` with
`errorChain`. The summarizer call reuses the live request's exact system
prompt, tool schemas, and shadowed messages, appending only the instruction —
"the call is a genuine prefix of the conversation and reuses the provider's KV
cache" (`region.ts:499`). Two-tier trigger: pressure each pre-step + recovery
on provider `CONTEXT_WINDOW_EXCEEDED` with bounded retries.
*Niffler*: `reset:trim` is a full cache miss — the exact pain of the GLM
525k-token overflow. Most transferable idea in the repo. *Pi*: /compact
summarizes without the lock/monotonicity/cache-replay machinery.

### 3. Spill — oversized tool results become artifacts with byte-exact budgets
A `tools/post-execute` waterfall: full text → spill store; model sees
head/tail preview + locator. The notice's own byte cost is reserved *inside*
the cap before sizing the preview (`spill-policy/src/index.ts:166`); if the
notice alone exceeds the cap the spill is abandoned. `read` is exempt
model-facing ("avoid a read → spill → read again loop") but bounded in the
durable log. Best-effort — a spill failure never converts success into error.
Children inherit locators without re-owning.
*Niffler/Pi*: nothing; a 200KB tool result enters history raw in both.

### 4. Guarded tool pipeline — deny-only monotonic guards
`tools/pre-execute` (policy, ordering-dependent) → *guards* that can only veto,
inserted after the policy stage so "listener ordering cannot turn a denial back
into permission" (`core/tools/src/index.ts:697`) → execute (timeout/retry) →
`tools/post-execute` that can block/replace even a *successful* result →
registry stamps canonical results (`WeakMap` tokens); wrapper-authored results
are re-normalized through the owning tool's schema (`index.ts:1775`). Under
PTC (`run_code`) mode, direct calls to other tools are denied *before* the
policy pipeline — approval can never bless a call that can only fail — and the
same `collapses()` predicate drives the prompt text, "so the prompt cannot
state a rule the registry does not enforce".
*Niffler*: one approval gate + `x-harness.effect` scheduling. *Pi*: extension
filters. The deny-only monotonic stage is a crisp answer to "who wins" in
plugin security.

### 5. Landlock sandboxing, done honestly
`native/landlock-run`: raw syscalls 444–446, `PR_SET_NO_NEW_PRIVS`; the
launcher installs the ruleset *on itself* then `exec`s — confinement inherits
across `execve`, invoker stays free; fail-closed exit 125 without exec; the
probe is functional, not version-gated — "actually restricting is the only
honest signal" (`main.c:273`). Above it: per-OS runner chains (bwrap/landlock,
seatbelt, windows-ACL) with per-runner stderr "denial dialects" so failures
classify as policy denials surfaced to the model
(`sandbox-local/src/index.ts:201`); escalation is one shared fail-closed
sequence for bash+fs (`sandbox/src/escalation.ts:8`); `sandbox_permissions`
exists in the tool schema *only when* confinement is active — capability
advertisement by shape (`tool-bash/src/index.ts:258`). Windows ACL honestly
reports `partial`.
*Niffler*: bash is raw, no sandbox anywhere. *Pi*: none either. Maps cleanly
onto a Niffler `sandbox` component wrapping the launcher.

### 6. Extension composition — waterfalls, patches, seams
Every capability is a `ctx.<key>` service; middleware short-circuits by
yielding (`llm/stream` is a waterfall, so retry/routing/replay are just
listeners, `llm/llm/src/index.ts:1122`); patch rows replace whole config,
last-write-wins, env-reactive via `!!js`; dynamic plugins run in a `node:vm`
realm with teaching-error traps — honest caveat: "not containment:
host-realm helper functions remain an escape route"
(`cordis-host-runner/src/sandbox.ts:84`).
*Niffler*: the bus gives OS-process isolation by default and zero framework
ceremony; dsh buys in-process composability and pays in WeakMaps and frozen
snapshots everywhere. *Pi* is dsh's model at ~1/50th the rigor.

### 7. LLM layer discipline
- Adapter throws normalize to frozen `LlmFailure` facts at the boundary —
  consumers never see stack traces (`llm/llm/src/index.ts:1112`).
- `ReplayEnvelope`: adapter-private lossless replay state, stripped when the
  route is owned by a different adapter — replay never crosses
  implementations (`types.ts:356`, `index.ts:958`).
- Atomic registry swaps: validate the whole candidate set, commit "in one
  synchronous section, so no request can observe a gap" (`index.ts:293`);
  prepared calls are generation-bound so HMR cannot mix adapters.
- Retry policy is provider-owned data, resolved at registration; the retry
  counter lives in a **session projection** — retries survive process
  restarts (`llm-retry/src/index.ts:125`); each wait is two log events
  (`llm/retry` before the delay, `llm/retry-started` after). Retry-After
  honored but capped; exceeding the cap in normal mode = give up.
- Token meter: trust provider usage only when ≥ a full route-priced heuristic
  anchor — "signed deltas remain conservative" (`token-meter/src/index.ts:160`);
  image pricing reproduces the adapter's deterministic image projection so
  estimates match the wire (`llm-deepseek/src/request-pricing.ts`).
*Niffler*: `retry.nim` in core, no durable ledger, no meter. *Pi*: pi-ai has
the clean typed vocabulary but a simpler lifecycle.

### 8. Subagents — convergence, with one idea to steal
dsh: child = one durable session + at most one activation epoch; residency
*derived* from quiescence + owned-child set ("rather than a second state
machine", `subagent/src/continuation.ts:148`); the durable descriptor
snapshots *explicit fields* (v3) — "an unrelated extension value cannot make
continuation fail merely because it is not JSON" (`descriptor.ts:8`);
per-activation knobs deliberately non-durable; out-of-process children declare
ZERO capabilities — "never accepted-then-ignored" (`out-of-process.ts:51`);
settlement notices are a distinct message kind so a transcript can't "credit
the child with words it never wrote" (`continuation.ts:74`).
*Niffler's agent component converged independently* (fresh sessions, durable
job records, steer subject, `noSpawn`, budgets). Steal: explicit-field
descriptor versioning; derive more, store less.

### 9. Approvals as durable, turn-enclosed audit events
Every ask logs `approval/asked` + `approval/decided` around the answerer
waterfall; must be "turn-enclosed (a bare event between turns is crash-tail
garbage on reload)" (`interaction/user-approval/src/index.ts:212`); `'never'`
is resolved *before* any listener because "a listener-shaped gate cannot keep
the documented promise"; mid-session policy switches append an injected notice
instead of touching the prompt prefix.
*Niffler*: approval routes to the caller's private UI subject with broadcast
fallback; not logged as conversation events.

### 10. Runtime context as self-superseding user messages
Dynamic facts (time, cwd, git status) materialize as user-role snapshot
messages appended only when content differs; a later surface replace flips the
projection to an explicit CLEARED message — "Current runtime context: none.
Earlier runtime-context snapshots no longer apply."
(`agent-loop/src/runtime-context.ts:13`). *Niffler* reaches the same
frozen-prefix conclusion by forbidding volatile facts in the head; dsh gives
each volatile fact a tombstone.

### 11. Crash repair that teaches the model
On restore, open turns get synthetic closers whose text differs by failure
class — unknown-outcome tool calls get "retry only if the operation is
read-only or idempotent; if it may have side effects, first verify external
state" (`session/src/repair.ts:100`); timestamps reuse the last real event
("never invents a 'future' time").
*Niffler*: a killed runner loses only the in-flight turn; resume just
continues — no synthetic guidance.

### 12. Small delights
- Session-format migrations validated at *compile time* — missing/duplicate/
  non-adjacent steps rejected ("Session migration v0->v1 is missing",
  `session-format/src/chain.ts:67`); each persisted format is an immutable
  generation file with torn-tail truncation as the crash boundary.
- 279-line NDJSON JSON-RPC transport framed by shape, shared by TS + Python
  SDKs; abort = forgetting (no state for a response that may never come).
- One muxed WebSocket including *reverse* events: client listeners run host
  waterfalls, so the UI can intercept approval prompts; live Agent/AbortSignal
  stripped before the wire, re-injected on arrival (`api/gateway`).
- Agent-team (experimental): durable mailbox transacted on the lead's journal,
  dispatch registered before releasing the transaction so concurrent senders
  queue in durable order; membership derived, not stored; task DAG with
  compare-and-set revisions and *advisory* write scopes (warnings, not
  enforcement).
- Client store: flush `'sync'` default "controlled inputs need same-tick
  echo"; hand-rolled persistence because zustand's persist middleware
  "explodes primitive state (a persisted string draft becomes {0:'h',1:'e',…})".

## What Niffler should steal (prioritized)

1. **Cache-aware compaction transaction** (#2) — `reset:trim` throws away the
   whole KV cache; a prefix-shaped summarizer keeps it. Direct mitigation for
   the long-conversation overflow class.
2. **Spill** (#3) — a post-execute hook in the session runner; days of work,
   permanent context savings.
3. **Landlock sandbox component** (#5) — bash spawns commands under the
   launcher; approvals could auto-clear for confined runs.
4. **Synthetic crash closers** (#11) — class-specific text, idempotency
   guidance on resume.
5. **Conservative token anchoring** (#7) — a token-meter component folding the
   store log.
6. **Deny-only guards** (#4) — if Niffler ever grows plugin-side tool policies.

## Where Niffler and Pi win

- **Footprint**: Niffler core is 10 Nim files; dsh is ~170k LOC TS plus 73k of
  client. Niffler's entire source is a rounding error next to dsh's *client*.
  The bus replaces the framework: OS processes are the isolation dsh
  approximates with WeakMaps and frozen snapshots.
- **Readability**: Pi and Niffler optimize for harness-as-a-weekend-read;
  dsh's rigor is admirable and unreadable.
- **Wire simplicity**: one JSON envelope protocol vs dsh's capability-seam +
  waterfall + patch-YAML stack. When something breaks in Niffler you read the
  bus; in dsh you read the DI graph.
