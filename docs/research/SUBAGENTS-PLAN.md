# Subagents v2 — implementation plan

Status: **planned, nothing started.** Branch `feat/subagents-v2`, worktree
`~/git/niffler-subagents-v2` (from `main` @ `3ad367c`).

Design rationale and the comparison that produced it:
[SUBAGENTS.md](SUBAGENTS.md) (kept in this branch). Provenance for the two
inherited steals: [DSH-STEAL.md](DSH-STEAL.md) §2 (continuations) and §3
(forks) — this plan supersedes their B1/B2 entries in
[DSH-STEALS-PLAN.md](DSH-STEALS-PLAN.md) with a sharper, code-level design,
and adds three items the DSH study did not cover (the settlement notice, the
`list_agents` roster, the parallel-start footgun).

Companion docs: [FABRIC.md](FABRIC.md) (the agent component's origin),
[CONTEXT-REVIEW.md](CONTEXT-REVIEW.md), [../MANUAL.md](../MANUAL.md) §Fabric
and subagents, [../WIRE.md](../WIRE.md).

## 0. What ships, in one table

Fifteen proposals from SUBAGENTS.md §7, ordered so each phase is independently
mergeable and the cheap wins land first.

| phase | # | deliverable | effort | needs |
|---|---|---|---|---|
| **P0** | 1 | **Settlement notice** — a durable notice to the parent when a child settles | ≤ 1 d | – |
| **P0** | 2 | **`list_agents`** — the durable roster of children | ½ d | – |
| **P1** | 3 | **Continuation** — `session:` on `agent_run`/`agent_spawn` | 2–3 d | P0.1 (notice for continuations) |
| **P1** | 4 | **Fork** — `fork:` on fresh spawns (balanced completed-turn cut) | ~2 d | P1.3 (shared child-prep path) |
| **P2** | 5 | **Parallel start** — schema guidance + safe fan-out | ½–1 d | P1.3 (continuations make fan-out useful) |
| **P2** | 6 | **`NIF_AGENT_MAX_DEPTH`** — depth cap as config (default 1) | ½ d | – |
| **P3** | 7 | Context-sensitive tool descriptions | hours | P1.4 |
| **P3** | 8 | Child-side delegation-scope statement | hours | – |
| **P3** | 9 | `agent_steer` durability (no silent loss to a retired child) | ½ d | P1.3 |
| **P3** | 10 | `agent_ask` — steer *with* a reply | 1 d | P1.3 |
| **P3** | 11 | Fork × compaction note in the docs | hours | P1.4 + compaction merge |
| **P4** | 12 | `session_info` lineage enrichment | hours | P1.4 |
| **P4** | 13 | TUI/UI surfacing of children + notices | 1 d | P0.1, P0.2 |
| **P4** | 14 | Bench: subagent scenarios in `bench/` | 1–2 d | P1.3, P1.4 |

Phases P0–P2 are the substance (the IanTheReal checklist). P3 is judgment and
polish; P4 is observability. **Do not start P3.10 (`agent_ask`) before P1.3
lands** — it is a thin wrapper over a continuation and building it first would
duplicate the turn path.

## 1. Standing rules

Inherited from DSH-STEALS-PLAN.md §Standing rules; restated because they are
the ones reviewers will check.

- Every phase states its **request-prefix effect** in its commit message:
  `frozen prefix` or `append-only history`. **Nothing in this plan adds a
  frozen-prefix contributor** (the one arguable case, P3.8, is a *child's*
  first-life prefix, never a parent's).
- No `asyncdispatch`; the SDK pump stays synchronous. Components never import
  core; core never imports component code.
- **The store is single-writer per record kind**: `agent` owns
  `agentjob`/`sessionmeta`/`agentnotice`; core owns `message`/`conversation`.
  P1.4's fork is `agent` writing `message` records — the one deliberate
  crossing, justified in §6.2 and gated on a store-level check.
- New tool schemas are `onDemand` unless the phase argues otherwise. Doc
  comments are the LLM's only window: all prose lines of the first comment
  block join the description, `- param: text` lines become parameter docs.
- Tests are plain `tests/t_*.nim` bus-contract scripts, picked up
  automatically by `TEST_NIM := tests/smoke.nim $(wildcard tests/t_*.nim)`
  (Makefile:365) — a new `t_*.nim` needs **no Makefile edit** to run in
  `make test`, but does need a line in the docs' test list.
- The bar per phase: `make build && make test` green, plus a live harness run
  for anything touching the turn loop (MANUAL, "Debugging the bus — prove the
  stack without the LLM").
- Update AGENTS.md / MANUAL.md / WIRE.md in the same commit that changes the
  contract they describe.

### Housekeeping before P0

Two docs are currently uncommitted on `main` and exist only in that working
tree. They were copied into this worktree already; commit them as the branch's
first commit:

- `docs/research/SUBAGENTS.md` (the rationale for everything here)
- `docs/research/OPENHANDS.md` (unrelated study; carries along so the index
  entry is not dangling)
- plus the `docs/research/README.md` index rows for both.

Commit message: `docs: subagent vs DSH study (SUBAGENTS.md) + plan branch seed`.

---

## P0.1 — Settlement notice

**Why.** `ev.agent.done` currently reaches only interactive UIs (an activity
line in `ui/frontend/src/App.svelte:316`; nothing in the TUI). The parent
*conversation* learns nothing, so a parent must burn a turn on `agent_wait`
(blocking) or `agent_status` (polling). DSH delivers a manager-owned notice
into the parent's turn stream and wakes an idle parent — "you are told when
one finishes" is in their tool description. This is the cheapest real
capability gap.

**Design.**

1. **Two new records, both owned by `agent`.**

   ```
   kind "agentnotice", id = <parentSession> ":" <zero-padded seq>
     { "v": 1, "parent": "<parentSession>", "jobId": "job-…",
       "child": "agent-…", "status": "done|failed|stopped",
       "summary": "<bounded head, ≤400 chars>", "replyBytes": 12345,
       "fullReplyIn": "agent_status",
       "createdAt": …, "deliveredAt": …, "deliveredVia": "wake|pull" }
   ```

   Zero-padded `seq` per parent keeps store key order = arrival order (the
   message-id convention). The record is **durable before any delivery is
   attempted** — a parent that is down, retired or mid-turn still gets it.

2. **The notice is a pointer, and the pointer names its recourse.** DSH pastes
   the child's final assistant content into the notice; Niffler should not — a
   5 KB child reply re-injected into every subsequent parent request is a
   permanent context tax with no opt-out. But a summary that *loses* the reply
   would be worse than either, so the record must say where the rest lives.

   **The full reply is already durable and requires no new mechanism.** The
   completion tap writes it into the `agentjob` record
   (`components/agent/main.nim:619`: `value["reply"] = %r.args{"reply"}`), and
   `agent_status` / `agent_wait` return the whole record (`:503`). So the
   notice carries:

   - `summary` — a bounded head (~400 chars) of the reply, newline-collapsed;
   - `replyBytes` — how much more there is, so the model can judge whether to
     bother;
   - `fullReplyIn: "agent_status"` — **the recourse named explicitly**, with
     `jobId` already in the notice. A model that does not know to make a second
     call will not make one; this field is what turns a summary from a lossy
     excerpt into a delegating pointer.

   The same shape as the existing spill convention (over-cap content → a path
   plus how to read it), which `bash`/`mcp`/`fetch` already follow — this is a
   Niffler pattern, not an invention.

   **When the reply is large and the parent never had an inline channel**: the
   summary becomes a head/tail split (like the tool-spill helper) rather than a
   mid-truncation, so a 200 KB JSON reply still shows its shape. And note the
   asymmetry that makes this safe: notices only exist on the **background**
   path (`agent_spawn`), where the parent explicitly was not waiting. A
   continuation (`agent_run {session}`, `agent_ask`) returns its reply inline
   and produces no notice at all.

   Remaining routes for the parent that wants more than the reply:
   `agent_status`/`agent_wait` (full reply, `onDemand`, no prefix cost), or the
   child transcript via `discover {component: "store"}` + `store.list {kind:
   "message", idPrefix: "<child>:"}` (the child's full working history, one
   extra round trip). **This is the one place this plan deliberately diverges
   from DSH**; §9 Q1 records it as revisitable.

3. **Delivery is two-lane, and the lanes are chosen by parent state (not by
   notice state).**

   | parent runner state | lane | mechanism |
   |---|---|---|
   | live and mid-turn | **steer** — immediate | `svc.session.<parent>.steer` with a notice payload |
   | live and idle, or retired | **pull** — the notice waits | `agentnotice` record + the next turn's drain |

   The runner does not need to poll the store: `pumpSteer` already drains a
   subscription during a turn, and P0.1 adds a **notice variant of that
   payload** so the injected message is structurally marked rather than
   rendered as a human "Steer: …".

4. **A third path for a truly idle parent (opt-in).** A fixed
   `subagentNotify: "wake" | "pull"` control on the parent conversation. In
   `wake`, `agent` starts the parent's turn after writing the notice
   (one `svc.session.<parent>.steer` plus a "start a turn" signal — see the
   implementation note below). **Default `pull`.** An agent that
   spontaneously writes turns into a human's conversation is a product
   decision, not an implementation default.

   *Implementation note:* an idle runner has no active turn and `pumpSteer`
   only drains in-turn, so "wake" needs the runner to treat a notice payload
   as turn-triggering rather than turn-injecting. Concretely: the runner's
   idle loop (the same loop that implements `NIF_RUNNER_IDLE_S` retirement,
   `core/session.nim:131`) gains a bounded wait on the steer subscription, so
   a notice can start a turn. This is the only piece of P0.1 that touches
   `core/session.nim`, and it is the reason "wake" is a separate sub-step:
   **ship `pull` first, then `wake` behind the control.**

5. **Where the notice is written.** In `components/agent/main.nim` at the two
   existing terminal writers — the completion tap (`comp.tap("_INBOX.agentjob.>")`,
   line 601) and `resolveStale` (line 300) — which between them own all six
   `storePut("agentjob", …)` sites (325, 346, 467, 480, 574, 642). One shared
   `emitNotice(c, parent, jobId, child, status, reply)` proc so the paths
   cannot drift. Emit `ev.agent.notice` alongside (an observe-only event for
   UIs; the durable record is the contract).

6. **The pull drain.** A hidden core-adjacent path is *not* needed: the
   `agent` component owns the records, so `agent_notices {session?}` (a new
   on-demand tool) drains and marks them, returning pending notices as a tool
   result. That is append-only history and needs no core change. **In
   addition**, the parent's next ordinary turn should not have to remember to
   ask: `core/conversation.nim`'s turn preamble (`runTurn`, before the first
   LLM round) can call `agent` for pending notices the same way it folds
   `drainSteer`/`drainAdvisories` — a fourth drain alongside those two. That
   is ~20 lines in core and makes the pull lane invisible to the model.

**Cache effect:** append-only history, both lanes. Nothing in the prefix
moves; a pending notice enters as an appended user-role message with a
structural `notice` field.

**Tests** (`tests/t_agent.nim`, new cases):

- a spawned job that completes while the parent is mid-turn injects a notice
  (assert the parent transcript contains it with `notice.kind ==
  "subagent-settled"`, and that it is **not** a bare `"Steer: "` message);
- a job that completes while the parent is idle leaves exactly one pending
  `agentnotice` record, and the parent's *next* turn folds it (assert exactly
  one injection, and `deliveredAt` set);
- `agent_notices` drains: second call returns none; a notice never
  double-delivers (steer lane + pull drain must not both fire);
- a stopped job with no reply produces a notice with no `summary` rather than
  a fabricated one;
- **the recourse is reachable from the notice alone**: after a notice lands
  with `replyBytes` > 0, `agent_status {jobId}` (taken straight from the
  notice) returns the byte-identical full reply — assert the two agree on
  length, and that a truncated summary's `replyBytes` is the *untruncated*
  length;
- an oversized reply yields a head/tail summary (assert both ends present);
- `subagentNotify: "wake"` starts a parent turn (sub-step 4; separate case).

**Risks.** The double-delivery case in lane selection (a parent that was
mid-turn when the notice was published, and is idle by the time the drain
runs, could get it twice). Mitigation: the notice record carries
`deliveredVia`, and the steer publish is *immediately* followed by a
`deliveredAt`/`deliveredVia: "wake"` write; the drain only takes records whose
`deliveredAt` is unset. Residual window is publish→persist (ms) and is
documented, not pretended away — same posture as DSH-STEAL §5's team mailbox.

---

## P0.2 — `list_agents`

**Why.** The IanTheReal checklist's "list_agents() — check who's doing what".
Today only per-job `agent_status` exists, so a parent cannot enumerate its
children; `session_info` shows `parent` for one known session but nothing
lists a parent's set.

**Design.**

- New on-demand tool `agent_list {scope?: "children"|"descendants"}` on the
  `agent` component.
- **The roster is derived, not stored**: children are sessions whose
  `sessionmeta.parent == caller` (the durable relation), joined with their
  `agentjob` records for status. This is DSH's "derive more, store less" and
  it means P1.3/P1.4 add no new roster state.
- Status vocabulary follows DSH's, because it is the right one and it is
  exactly what a parent needs to choose between verbs:
  - `running` — a live turn (runner present **and** mid-turn);
  - `idle` — runner resident, between turns (steerable / continuable now);
  - `ready` — storage only, no runner (still continuable, costs a process
    start).
  `ready` must never read as terminal — DSH's tool description says so
  explicitly and the wording matters.
- Rows: `{sessionId, status, jobId?, activation?, lastStatus, startedAt,
  label, task}` where `label` is the bounded task text already stored in the
  `agentjob` record.
- **One-shot children are included** (unlike DSH, which omits them because
  they cannot accept `send_message`). Niffler's one-shot children *are*
  conversations with a live status, so hiding them would be wrong; the row
  says `oneShot: true`.
- A child whose records cannot be read yields a **diagnostic row**, never a
  silent omission (DSH's `unavailable`/`corrupt` distinction, collapsed to
  one honest row here since our record shape is simpler).

**Cache effect:** none (read-only; no schema is added to any frozen set — it
is `onDemand`).

**Tests** (`tests/t_agent.nim`): a parent with two children (one running, one
finished) lists both with correct status; `descendants` warns that depth is
bounded at 1 (returns children only, with a note); an `agentjob` whose child
session was deleted yields a diagnostic row; a parent with no children
returns an empty list, not an error.

---

## P1.3 — Continuation

**Why.** The IanTheReal checklist's "follow up with the same agent" and
"optionally keep the conversation going". The child conversation already
persists and its runner re-ensures on demand — only the parameter and the
authorization are missing.

**Design.** (DSH-STEAL §2, restated against the code; the deltas from that
doc are marked ▲.)

1. `agent_run` / `agent_spawn` gain optional **`session`** (string) and
   **`close`** (bool). Absent `session` → today's byte-identical fresh path.
2. Present → a **new activation**:
   - **validate fail-closed**: `storeGetItem("conversation", session)` exists
     (not-found → error, never a silently-fresh child) **and** the caller may
     continue it: `sessionmeta[session].parent == callerSession`. A session
     with *no* `sessionmeta` is a root conversation → refused. Store
     unreachable → refused.
   - ▲ **`sessionmeta.closed == true` is refused too** (a `close: true`
     conversation is done; continuing it is the "silently fresh" failure in a
     different costume). The error names the close.
   - `session_prepare(session)` for the subject — the existing idempotent
     re-ensure (`core/niffler.nim:566`), so a retired runner costs a process
     start, not a redesign.
   - the **same** `childSessArgs` + `requestChildTurn` call the fresh path
     uses, with the continuation content.
3. ▲ **Do not re-send the system prompt on a continuation.** `childSessArgs`
   currently requests `systemprompt` and passes `systemSystemPrompt` on every
   call; for a continuation the child's constitution is *already frozen in
   its header* and `resolveSystemPrompt` will ignore a new one — but sending
   it is a wasted round trip and, worse, invites a future bug where the two
   disagree. Split the helper: `childSessArgs(generate: bool)`.
4. **Frozen controls belong to the child.** On a continuation, `model`,
   `thinking`, `tools`, `maxRounds`, `maxCalls`, `maxTokens` are **ignored**
   (frozen into the child header at its first turn — verified at
   `core/conversation.nim:1305-1335`: every one of them is `if … header is
   unset`-gated). Only `content` and per-activation `timeoutMs`/`budgetMs`
   apply. The schema text must say so, per-parameter, or the model will
   re-specify a model and silently not get it.
5. **Job records v2**: add `activation` (1-based) and `firstActivationAt` to
   each `agentjob`. Each activation is its own job record, so `resolveStale`,
   the completion tap and `ev.agent.done` stay **untouched**; continuity
   metadata (`activation` counter, `firstActivationAt`, `closed`) lives in
   `sessionmeta` — explicit fields, versioned, never a bag.
6. **`interrupted` stays continuable** (runner died without a reply): the
   death cost one turn, not the child.
7. ▲ **Effective-controls readback.** The continuation result should carry the
   child's *actual* frozen controls (`{model, thinking, maxRounds, maxCalls,
   maxTokens, tools}`) so the caller learns what it is talking to instead of
   assuming its ignored arguments took effect. Cheap: they are in the header
   core already has. This is the practical mitigation for point 4.
8. Depth-1 stays bolted on: a continuation mutates no lineage, so it needs no
   depth exception (and that is exactly how teammates will wake teammates
   later, DSH-STEAL §5).

**Cache effect:** one appended user turn onto the child's stable prefix —
identical in shape to any second turn of any conversation. No new contributor,
no `reset:*` class.

**Tests** (`tests/t_agent.nim`):

- continue after `done`: second activation succeeds, reply is the new turn's,
  `agent_status` shows `activation: 2`;
- kill the child runner, then continue: `interrupted` → new activation
  succeeds (`session_prepare` re-ensures);
- continuation by a non-parent fails closed; a root conversation id fails
  closed; a `closed` child fails closed; unreachable store fails closed;
- frozen controls ignored: a continuation carrying `model: "other"` does not
  change the child's model (assert the readback and the header);
- ▲ the system prompt is not re-requested on a continuation (assert the
  sandbox `systemprompt` component was not called for that turn);
- v1 job records (no `activation`) still read correctly.

**Risks.** Two concurrent `agent_run {session: X}` — the runner serializes
turns, so the second waits and its `timeoutMs` must budget the first's
remainder. Resolution in §9 Q2 (return `busy` vs. queue + document). Do not
merge P1.3 without deciding it, because the schema text depends on the answer.

---

## P1.4 — Fork

**Why.** The IanTheReal checklist's `context: fresh | fork` — "forking the
parent's history is useful sometimes". DSH-STEAL §3's design; one correction
found while planning (the toolset snapshot).

**Design.**

- `fork: true | {"lastK": n} | {"maxChars": n}` on the **fresh path only**
  (a fork is a birth, not a continuation).
- **The cut must land on a balanced completed-turn boundary.** DSH: "the
  parent's events up to and including its last `turn/end` — so the seed is
  contiguous-from-0 and the invariants replay accepts it (the in-flight,
  unbalanced turn is excluded)". Niffler's equivalent: scan the parent
  transcript for the last message that *closes a turn* — an assistant message
  with no pending tool calls, or a terminal record — and cut there. Never cut
  mid-tool-round: a child that resumes with a dangling `tool_call_id` is
  exactly the invariant `trimContext` protects, and the child's first request
  would be rejected by a strict provider.
- Read with `storeListAll("message", parent & ":")` (the paging helper —
  a capped `list` silently truncates at 1000, the bug `t_resume_long.nim`
  exists to prevent). Write each record under the child id with the
  zero-padded seq, preserving `role`/`content`/`createdAt`, **dropping
  per-message `usage`** (the child's accounting is its own; copying the
  parent's tokens would lie twice — once to the child's meter, once to the
  bench).
- ▲ **Do not copy `message` records whose role is `summary`/`error`.** A
  `summary` record (from the compaction work) is a *derivation* of records
  that are also being copied — copying both would double-represent that
  range. Copy the raw records and let the child's own context assembly derive
  its view (compaction's replay already splices committed summaries; §9 Q3).
  `error`-role records are audit for the *parent's* turns and are excluded
  from message lists anyway (`loadStoredMessagesEx` skips them).
- ▲ **The toolset snapshot is id-keyed — do not carry it.** `loadToolExposure`
  reads `<sessionId>:tools`, and `core/conversation.nim:1300` reads
  `header{toolAllowlist}`. A fork copies *messages*, so the child starts with
  the parent's frozen direct set re-derived from the **child's own** catalog
  state, and the caller's fresh-path `tools`/`maxRounds`/… arguments apply
  normally (this is a birth: frozen controls are set from *this* call). Copy
  neither the exposure doc nor the header's control fields. Getting this
  wrong would make a child inherit an allowlist it never asked for.
- **Ancillary records are deliberately not copied**: `agentjob` (the child has
  no jobs), `agentnotice` (the child has no children), the parent's
  `conversation:…:tools` doc. Only `message` and the new `sessionmeta`.
- **Header adoption is already safe** — no core change needed for the
  messages-before-header ordering. Verified: `ensureConversationHeader`
  (`core/conversation.nim:255`) returns early if a header exists and never
  clobbers `createdAt`; both the runner boot path (`core/session.nim:124`) and
  the first turn (`core/conversation.nim:1258`) call it, so a forked child
  whose messages were written first simply gets its header created around
  them. **This removes the one core change DSH-STEAL §3 expected** — B2 is
  confined to `components/agent/main.nim`.
- Provenance **before** the first turn, fail-closed:
  `sessionmeta[child] = {parent, fork: {source, uptoId, copied}}`.
- A `lastK`/`maxChars` budget that drops everything **fails closed**, not an
  empty child.
- No fork-of-fork chains: the depth-1 rule means the parent must be a root
  session, which it already is by construction (only a root may spawn).

**Cache effect:** a fork is **born cold** — the child's first request replays
the copied history uncached; warm from the second turn. That is the price of
*judgment* inheritance and the right trade only when the preamble would
otherwise have to *narrate* the context. Bulk context transfer with no
judgment needed is what `fabric` is for; the fork contract is "the model needs
to have **read** the conversation, not been told about it." The tool
description must say this, because the cost is otherwise surprising.

**Tests** (`tests/t_agent.nim`):

- copy → run proves adoption: messages exist before the header, the header is
  created (not clobbered) by the first turn, and the child's first request
  carries the copied history plus the new task;
- the cut is balanced: after a parent turn ending mid-tool-round, the copied
  tail ends at the last *completed* turn (assert the last copied record has no
  pending tool call);
- `lastK`/`maxChars` budget errors fail closed (empty selection → error);
- `usage` is absent from copied records; `summary`/`error` roles are not
  copied;
- ▲ the child does **not** inherit the parent's `toolAllowlist` (spawn with
  `tools: [...]` and assert only those are dispatchable; spawn without and
  assert the full set);
- provenance visible in `session_info`; depth-1 unaffected (`agent_run` from
  the forked child is still denied).

**Risks.** The store-writer crossing (see §1): `agent` writes `message`
records, which core otherwise owns. Justification: it is a *copy*, written
before the child's runner exists, so there is no concurrent writer for that
session id and no lost-update window. Mitigate by (a) a header comment stating
the ownership exception at the write site, and (b) a store-level check in the
test that the child's message ids are dense and start at `:0000000001`.

---

## P2.5 — Parallel start (the footgun)

**Why.** The IanTheReal checklist includes "run things in parallel". Niffler's
delegation tools are `sessionContext: true`, and `isParallelSafeTool`
(`core/dispatch.nim:1272`, exclusion at `:1282`) excludes them — so two
delegations in one assistant message **do not fan out**. Worse (found while
planning): `NestedState.lease` is a **single string** (`core/dispatch.nim:101`),
set on entry and restored on exit (`:1213-1220`), so if two session-context
tools were dispatched concurrently the second's `defer` would restore the
first's lease while the first is still in flight. Today that cannot happen
(the wave scheduler refuses `sessionContext`), so this is a latent hazard
rather than a live bug — but it is the exact thing that must be fixed before
parallel delegation can be allowed.

**Design — two options, pick one; recommendation is A + B.**

- **A. Make the correct pattern explicit (guaranteed, cheap).**
  Schema/prompt guidance: "start independent delegations together in one
  assistant message **as `agent_spawn` calls**; they run concurrently as
  separate child runners." `agent_spawn` already returns immediately and each
  child is its own process, so N spawns in one message *are* parallel
  delegations — they are just not scheduled by the wave processor, they are
  scheduled by the child runners themselves. This is the honest description of
  today's capability and needs no core change beyond wording. Add the DSH
  guidance line to the `agent_spawn` description: "start independent
  delegations together and continue useful work while they run".
- **B. Keyed leases (removes the hazard).** Change `NestedState.lease: string`
  to a set keyed by `callId` (or by the nested call's inbox id), so
  concurrent session-context dispatches cannot clobber each other. Keep
  `isParallelSafeTool` excluding `sessionContext` for now (serial dispatch is
  fine; the children are what run in parallel), but the invariant becomes
  "leases are per-call", which is what any future parallel policy needs.
- **C. `replicas: N` on the `agent` component (only if A+B prove
  insufficient).** Adds 2 replicas to `manifest.yaml` and relies on the queue
  group to distribute starts. Note the interaction: `agent_wait` and
  `agent_run` *block the component pump*, so with replicas a blocked handler
  on one process does not stall another — this is a real throughput win for
  waiting parents, and the completion tap is per-process so each replica would
  only see its own taps. **That last point is a bug generator**: the terminal
  writer assumes it sees the job it started. If C is wanted, the completion
  path must be re-derived (any replica reads the durable record and
  reconciles, i.e. `resolveStale` becomes the norm, not the recovery path).
  Treat C as its own design task, not a config line.

**Cache effect:** none for A/B (schema text is part of the frozen tool set at
conversation start; changing it changes the prefix only for *new*
conversations, as any schema edit does). C changes nothing prompt-facing.

**Tests:** A is a doc/schema test (assert the description text). B is a unit
test in the `t_nested` style: two concurrent session-context dispatches both
succeed and neither loses its lease. C, if attempted, needs the tap/terminal
re-derivation tested with two replicas.

---

## P2.6 — `NIF_AGENT_MAX_DEPTH`

**Why.** Depth is a hard-coded 1 (`x-harness.noSpawn` + the `sessionmeta.parent`
check at `core/dispatch.nim:1245`). DSH defaults `maxDepth: 3` with `0`
forbidding delegation, and — the good part — **the tool stays visible at the
cap**, each start rejecting with an errored result, "so the model learns why".
Niffler already rejects with a clear message rather than hiding the tool, so
only the number needs to become a setting.

**Design.**

- `NIF_AGENT_MAX_DEPTH` (default `1`) read at dispatch, where the lineage check
  already lives.
- Replace the boolean `hasParent` check with a **depth walk**: count
  `sessionmeta.parent` links from `ct.nested.session` to a root. Bounded by
  the cap + 1 reads; fail closed on an unreadable link (today's behavior).
- The error message names the limit and the caller's depth:
  `"subagent depth 1 exceeds NIF_AGENT_MAX_DEPTH=1 (subagents cannot spawn
  subagents)"`.
- `x-harness.noSpawn` stays as the *opt-in marker* on spawn-class tools; the
  numeric cap is separate config so a deployment can raise it without editing
  schemas.
- Keep the default at 1 — raising it is a deliberate act, and DSH-STEAL §5's
  team design assumes 1.

**Cache effect:** none.

**Tests** (`tests/t_agent.nim`): default 1 preserved (a child's spawn is
denied with the new message); `NIF_AGENT_MAX_DEPTH=2` allows one grandchild in
a sandbox core; an unreadable `sessionmeta` link fails closed; a root session
(no `sessionmeta`) is depth 0 and always allowed.

---

## P3.7 — Context-sensitive tool descriptions

**Why.** DSH derives the delegation tool's *wording* from
`provider.inheritsParentContext`: a fresh child gets "it does not see this
conversation", a forked child gets "it does not see the current in-flight
turn" — "so the model never restates or omits context that does not exist".
Once `fork` exists, the current single wording ("It starts with a fresh
context — include everything it needs … not a continuation of this
conversation") becomes actively wrong for a forked child, and the model would
hand a forked child a preamble re-narrating what it just read.

**Design.**

- The `task` parameter's description and the tool description branch on the
  `fork`/`session` arguments. Since the schema is static, the practical form
  is **three sentences covering the three modes**, written so each is
  unambiguous in its own case, e.g.:
  - fresh: "starts with a fresh context — include everything it needs";
  - fork: "sees the completed turns of this conversation, but not the turn in
    flight — state only what is new";
  - continuation: "already has its own history — send only the next task".
- If the schema is ever allowed to vary per conversation this becomes exact,
  but per standing rules a schema edit is a prefix change; keep it static and
  make the static text correct for all three modes.

**Cache effect:** frozen prefix — a schema edit changes the prefix for *new*
conversations only, exactly as every schema change does. Note it in the commit.

**Tests:** assert the description text contains all three mode sentences (a
`t_agent`-adjacent schema check, like `t_approval_manifest.nim`).

---

## P3.8 — Child-side delegation-scope statement

**Why.** DSH writes a `subagent:delegation` statement into every child's
runtime context: the scope was fixed at start, approval-requiring operations
are rejected automatically, and a job needing wider access ends with a
*reported limitation rather than retries*. Niffler's children **can** get
approvals (routed to the parent's human via `__session.caller`), so the
statement must be the accurate Niffler version. The failure mode it closes is
real: a child looping on a denied operation.

**Design.**

- The accurate text: "You are a delegated subagent. Your approvals are
  answered by the human driving the parent conversation; your tool allowlist
  and budgets were fixed when this child was started and cannot be widened
  from inside it. If a request is denied, or a budget is exhausted, report
  the limitation in your reply instead of retrying the denied operation."
- Delivered as part of the child's **first** turn content (the existing
  `taskPreamble` in `components/agent/main.nim`) — not a new prompt
  contributor, and never in the parent. On a *continuation* the statement is
  already in the child's history; do not repeat it (which is also why it must
  not be a per-turn injection).
- Keep it short — it repeats in every child's first turn.

**Cache effect:** the child's first-life prefix only; never the parent's.

**Tests:** a child transcript's first user message contains the statement
(and a continuation does not add a second copy).

---

## P3.9 — `agent_steer` durability

**Why.** `agent_steer` publishes `svc.session.<id>.steer` and returns
`{published: true}`. If the child is not mid-turn — idle between turns, or
retired — `pumpSteer` is not draining (it only runs during a turn) and the
message is **silently lost**. The tool's own doc says "Fire-and-forget:
success means published, not processed", so it is honest, but a parent that
steers a just-finishing child loses the nudge with no signal.

**Design.**

- Check the child's state before publishing (one catalog probe + the durable
  record, both already used by `list_agents`):
  - **mid-turn** → publish as today;
  - **idle/retired** → do not pretend: write the steer into a durable
    `agentnotice`-style pending record (kind reuse or a sibling
    `agentmail`) and return `{queued: true, deliveredVia: "next-turn"}`,
    with the guidance "the child is between turns; this was queued for its
    next continuation (`agent_spawn {session} `)".
- This is deliberately the same shape as the P0.1 pull lane, so one queue
  serves both: **notices (child→parent) and mail (parent→child) are both
  "pending durable messages between adjacent sessions"**. Consider one record
  kind with a `direction` field rather than two kinds — decide at
  implementation; the plan's default is one kind, `agentnotice`, with
  `{direction: "child-settled" | "parent-mail"}`.
- If P1.3 has not landed, "the child's next turn" does not exist yet, so the
  queue would never drain. **Ordering: P3.9 must follow P1.3** (it is listed
  in P3 for that reason).

**Cache effect:** append-only.

**Tests:** steer to a mid-turn child injects immediately (existing behavior);
steer to an idle child queues and returns `queued: true`; the queued mail
drains into the next continuation and is marked delivered; steer to a
nonexistent session returns a clear error rather than `published: true`.

---

## P3.10 — `agent_ask` (steer with a reply)

**Why.** `agent_steer` is fire-and-forget, so a parent can never *ask* a
running child a question and get an answer. DSH's `send_message` returns the
accepted `MessageId`, and the reply arrives as a separate message or as the
activation's final reply — a parent can ask. In Niffler the equivalent is a
continuation whose reply comes back, so this needs P1.3.

**Design.**

- On-demand tool `agent_ask {session, question, timeoutMs?}`:
  `agent_run {session, task: question}` in substance — a continuation that
  returns the child's reply. The value-add over `agent_run {session}` is
  intent and wording (a question, not a re-tasking), a default timeout, and a
  result shape that names it as a reply.
- If the child is **mid-turn**, the question cannot be a new activation (turns
  never nest) → either queue it as mail (P3.9) and return `queued`, or refuse
  with the reason. Recommendation: queue + `queued: true`, since that is what
  a parent asking a working child actually wants.
- Keep the schema tiny; this is a convenience verb, not a new mechanism.

**Cache effect:** append-only (a child turn + the parent's tool result).

**Tests:** ask an idle child → reply returned; ask a mid-turn child → queued,
then delivered on the next turn; ask a `closed` child → refused.

---

## P3.11 — Fork × compaction

**Why.** `feat/compaction` (worktree `~/git/niffler-compaction`, `8f7a49c`)
lands a context identity ledger; a fork copies *store* records, so a forked
child of a compacted parent is **larger** than the parent's live context. That
is correct (the child gets the real history) but surprising, and
CONTEXT-REVIEW.md's read-visibility questions apply: a fork is a reader of
records the parent no longer holds in context.

**Design.**

- Documentation, in `SUBAGENTS.md` §8 and the fork tool description: a forked
  child receives the parent's **raw** transcript (minus `summary`/`error`
  roles), so its first request may exceed the parent's current context usage;
  the child's own compaction will shrink it on its own schedule.
- **Gated on the compaction merge.** §9 Q3 asks whether a forked child should
  inherit the parent's *committed summaries* rather than only the raw records
  (closer to the parent's live view, smaller), and the answer depends on the
  landed compaction contract. Do not guess it here.

**Cache effect:** none (docs).

---

## P4.12 — `session_info` lineage enrichment

**Why.** `session_info` already surfaces `parent` from `sessionmeta`
(`core/dispatch.nim:605-608`). Once P1.3/P1.4 exist, a client needs the rest.

**Design.** Surface, from the `agent`-owned records: `fork: {source, uptoId,
copied}`, `activation` (last/current), `firstActivationAt`, `closed`, and
`children: n` (a count, not the roster — `agent_list` is the roster tool).
Read-only, no new writer.

**Cache effect:** none.

**Tests:** a forked child's `session_info` shows `fork`; a continued child
shows `activation >= 2`; a root session shows neither and does not error.

---

## P4.13 — UI surfacing

**Why.** P0.1's notice and P0.2's roster are agent-facing; the human should
see the same truth. Today the SPA renders `ev.agent.started`/`ev.agent.done`
as activity lines (`ui/frontend/src/App.svelte:313-318`) and the TUI renders
nothing.

**Design.**

- **SPA**: subscribe `ev.agent.notice`; render a child-finished notice in the
  parent's chat as a distinctly styled row (not a user message), reusing the
  existing activity/card components. Optionally a children panel from
  `agent_list`.
- **TUI** (`~/git/niffler-tui`, separate repo): the same two — a status-line
  chip for running children and a notice row. Note the TUI is a plugin repo,
  so this is a follow-up PR there, not in this branch.
- Keep both read-only clients of the bus; no new subjects beyond
  `ev.agent.notice`.

**Cache effect:** none (clients).

**Tests:** the SPA's unit tests cover the notice rendering (plain node, no
NATS — the existing `npm test` pattern); the TUI's tests live in its repo.

---

## P4.14 — Bench scenarios

**Why.** The IanTheReal caveat is exact: "kinda hard to benchmark this fairly
tho — each model gets different amounts of training for its own subagent
setup. Claude and Kimi seem pretty good at it, so you're testing the model +
harness combo as much as the harness itself." The honest response is a
subagent bench that measures the *harness* mechanics, not model affinity.

**Design.**

- Add a bench lane (`bench/adapters/niffler.mjs`-adjacent) with scenarios that
  are mechanism checks, each scored on bus-observable facts rather than prose:
  1. **delegate-and-collect**: spawn 3 independent children, wait for all,
     assert 3 replies — measures parallel delegation and the notice lane.
  2. **follow-up**: continue a child twice, assert activation 2 and 3 and that
     the child did not re-read context it already had (token delta should be
     the new task, not the history) — measures continuation.
  3. **fork**: fork a parent with N completed turns, assert the child's first
     request carries the history and that the child's *reply* references it
     without the task restating it — measures fork.
  4. **interrupt-and-resume**: stop a running child, then continue it —
     measures `agent_stop` + continuation composing.
- Report per-scenario *harness* metrics (children spawned, activations,
  notices delivered, cache-hit ratio on continuations) alongside the usual
  tokens/time, so a reader can separate harness correctness from model skill.
- Do **not** compare cross-harness on these numbers without the caveat above;
  the scenarios exist to catch Niffler regressions, and the DSH comparison is
  already argued qualitatively in SUBAGENTS.md.

**Effort:** 1–2 days. Depends on P1.3/P1.4.

---

## 5. Cross-phase: documentation and validation

- **AGENTS.md** — the new record kinds (`agentnotice`) and the store-writer
  exception for fork (with its justification); `NIF_AGENT_MAX_DEPTH`; the
  `session`/`fork` tool arguments as part of the tool-surface description.
- **docs/MANUAL.md** — §Fabric and subagents gains: continuation (the
  `session` argument, frozen controls, the readback), fork (the balanced cut,
  born-cold cost), the settlement notice (the two lanes, `subagentNotify`),
  `agent_list`, `NIF_AGENT_MAX_DEPTH`. The env-var table gains the new knobs.
- **docs/WIRE.md** — `ev.agent.notice`; the `agentnotice` record shape; the
  `agentjob` v2 fields (`activation`, `firstActivationAt`); the notice variant
  of the steer payload (a new allowed payload shape on an existing subject).
- **docs/research/SUBAGENTS.md** — flip §7's effort table to shipped state as
  phases land (it is the provenance doc; keep it honest).
- **DSH-STEAL.md / DSH-STEALS-PLAN.md** — add a status line pointing here for
  B1/B2 (they are superseded, not wrong).
- **Validation per phase** (the manual's live-harness recipe):
  - P0: lead spawns a child, does other work, is *told* when it finishes
    (mid-turn and idle cases);
  - P1: lead runs a child, re-tasks it, forks it, and the transcript shows the
    expected history;
  - P2: three spawns in one message all run concurrently (watch `ev.agent.*`
    timestamps overlap).
- **`make build && make test`** green before each PR; the branch may hold all
  phases as commits and split into PRs before review (P0 alone is a very
  reviewable first PR).

## 6. Notes for the reviewer

### 6.1 The one place this plan contradicts DSH

P0.1 point 2: DSH's settlement notice carries the child's **final assistant
content**; this plan carries a **bounded summary + the child id**. Reason: the
child's reply is already durably retrievable (`agent_status` returns it, the
transcript is addressable), and a large child reply pasted into every
subsequent parent request is a permanent context tax with no way to opt out.
If the live run shows parents constantly reading the child's reply anyway, add
it — behind a size cap. Recorded as §9 Q1.

### 6.2 The one standing-rule exception

P1.4: `agent` writes `message` records (core's kind). Justified because it is
a copy written before the child's runner exists (no concurrent writer for that
id, no lost-update window), and gated on a density assertion in the test. The
alternative — core exposes a `fork` core-tool — puts conversation-shape
knowledge in core for a component's feature, which is worse.

### 6.3 What is deliberately not in this plan

- The DSH named-provider registry (ACP/Codex/Claude Code children), in-process
  children, approvals-pinned-to-`never` — SUBAGENTS.md §6 explains each.
- `team` (DSH-STEAL §5): it depends on P1.3 and deserves its own branch. This
  plan leaves the seams it needs (continuation, adjacent messaging, the
  pending-mail queue).
- Fabric `{api: true}` (DSH-STEALS-PLAN phase C): unrelated to subagents, gated
  on the compiled-Nim merge, tracked there.
- Compaction itself: `feat/compaction`, its own worktree.

## 7. Effort summary

| phase | deliverables | effort | cumulative |
|---|---|---|---|
| P0 | notice + roster | 1.5 d | 1.5 d |
| P1 | continuation + fork | 4–5 d | 5.5–6.5 d |
| P2 | parallel + depth config | 1–1.5 d | 6.5–8 d |
| P3 | descriptions, child statement, steer durability, ask, fork×compaction | 2 d | 8.5–10 d |
| P4 | session_info, UI, bench | 2–3 d | 10.5–13 d |

P0+P1 is the reviewable core (the IanTheReal checklist minus parallel
scheduling). P2 completes the checklist. P3/P4 are quality and observability.

## 8. Suggested commit sequence

```
docs: subagent vs DSH study + plan branch seed
agent: settlement notices to the parent (durable, two-lane delivery)
agent: agent_list — the durable child roster
agent: continuation — session: on agent_run/agent_spawn
agent: fork — children seeded from the parent's completed turns
core: keyed nested-call leases; document parallel delegation
core: NIF_AGENT_MAX_DEPTH (default 1, walk-based check)
agent: context-sensitive delegation descriptions
agent: the child-side delegation-scope statement
agent: agent_steer queues to an idle child instead of dropping the message
agent: agent_ask — a continuation that answers a question
docs: fork × compaction note
core: session_info lineage (fork, activation, closed, child count)
ui: render ev.agent.notice; agent_list panel
bench: subagent scenarios (delegate/follow-up/fork/interrupt)
```

## 9. Open questions (decide at implementation)

1. **Notice content.** Bounded summary vs. full final reply. **Settled in
   P0.1 point 2**: the notice carries a bounded `summary` + `replyBytes` +
   `fullReplyIn: "agent_status"`, because the full reply is *already durable*
   in the `agentjob` record (`agent/main.nim:619`) and `agent_status` returns it
   for free. A summary would be a loss only if the recourse were unnamed —
   hence the explicit pointer field. Revisit only if the live run shows parents
   reading the reply on essentially every notice anyway (at which point carry
   it behind a size cap, §6.1).
2. **Concurrent activations.** Two `agent_run {session: X}` at once: return
   `busy` from a cheap catalog probe, or queue and document the timeout
   arithmetic (DSH-STEAL §7.1's v1 answer)? The **schema text depends on the
   answer**, so decide before P1.3 ships. Recommendation: `busy` for
   `agent_run` (it promises a result *now*), queue for `agent_spawn` (it
   promises work *happens*).
3. **Fork + compaction.** Should a forked child inherit the parent's committed
   `summary` records (closer to the parent's live view, smaller) or only the
   raw records (complete, larger)? Recommendation: raw only, until compaction
   lands and its contract says otherwise (P3.11).
4. **One notice kind or two.** `agentnotice` with a `direction` field for both
   child→parent notices and parent→child mail (P3.9), or two kinds?
   Recommendation: one kind with `direction`; fewer kinds, one queue
   discipline.
5. **`subagentNotify: "wake"` scope.** Per conversation (this plan) or a
   harness-wide default? Per conversation, because it changes what a
   conversation does to a human's attention.
6. **`agent` replicas.** If P2.5's B is insufficient, replicas require the
   terminal-writer re-derivation described in P2.5 C. Only if measurements
   justify it.
