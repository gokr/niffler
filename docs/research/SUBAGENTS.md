# Subagents — Niffler vs DSH, and the fork/resume baseline

> Historical research note (2026-09-14). The gap analysis below was written
> before subagents-v2 landed. Current continuation, fork, roster and settlement
> notice contracts are in [MANUAL.md](../MANUAL.md#fabric-and-subagents).
>
> Scope deliberately narrow: **compare Niffler's
> `agent` component with DSH's subagent subsystem**, then decide what
> "spawn / send_message / wait / list / interrupt, with fork and resume" (the
> IanTheReal baseline) actually costs Niffler.
>
> Basis: `~/git/niffler` at `6be9748` (main; `feat/compaction` at `8f7a49c`
> landing the context ledger), `~/git/harnesses/deepseek-harness` at
> `c291e7961a`. Companion docs: [DSH-STEAL.md](DSH-STEAL.md) — the 2026-09
> proposal whose steals 1 (continuations) and 2 (forks) this note re-derives
> against the now-shipped code — [DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md) §8,
> [FABRIC.md](FABRIC.md), [CONTEXT-REVIEW.md](CONTEXT-REVIEW.md),
> [../MANUAL.md](../MANUAL.md) §Fabric and subagents.
>
> Pi is out of scope by agreement: its agents are a plugin, not a mechanism.

## 0. The verdict in one paragraph

Niffler's `agent` component is **better than DSH at the hard parts nobody
enumerates** — durable job records, lazy restart reconciliation, two-channel
cancellation that actually kills an in-flight command, depth-1 lineage, graceful
degradation when the store is down — and now ships the baseline's continuation,
fork, child roster and parent settlement notice. The remaining differences are
listed below as research rather than current implementation gaps. All landed
subagent additions are **append-only** with respect to the frozen prompt prefix.

## 1. The two designs side by side

### 1.1 What each layer does

| Layer | DSH | Niffler |
|---|---|---|
| **Delegation seam** | `ctx.subagents` service + **named provider registry** (`spawn`, `fork`, `acp`, `codex`, `claude-code`, `dsh-sdk`) | One `agent` component; the child is literally a Niffler session runner |
| **Child identity** | A durable Session + at most one process-local **Activation** (residency epoch); `subagent/descriptor` session event is the durable identity | A session (`agent-<id>`) + a `sessionmeta` lineage record; `agentjob` records are per-activation |
| **Child transport** | In-process (shared agent factory/LLM/tools) or out-of-process (ACP/Codex/Claude Code) | **Always out-of-process on the bus** — the child is a full session runner process |
| **One-shot shape** | `SubagentRun` handle: `result` promise + `dispose()`; ownership transfers at publication | `agent_run` (synchronous `requestEnvelope`) / `agent_spawn` (fire-and-forget publish + a reply-inbox tap) |
| **Continuable shape** | Durable child, FIFO inbox, multiple turns per Activation, cold resume | **Shipped.** `agent_run` refuses a busy child; `agent_spawn` queues another turn |
| **Fork** | `fork` provider: child seeded with the parent's *balanced completed-turn prefix* | **Shipped.** Fresh children can inherit a replay-valid completed-turn prefix |
| **Messaging** | `send_message` (adjacent-only: direct child, or direct parent from a resident child), Steer scheduling fixed | `agent_steer` (into a live turn only, fire-and-forget, no reply) |
| **Interrupt** | `interrupt_agent`: cancels the current turn, **keeps inbox + descendants + availability** | `agent_stop`: two-channel cancel (`llm.cancel.<child>` + steer `__cancel`), keeps the conversation |
| **Listing** | `list_agents` (children/descendants, durable ids, labels, status from the live registry) | `agent_list` (children/descendants, derived status) plus `agent_status` for one job |
| **Completion signal** | Manager-owned **settlement notice** delivered into the parent's turn stream (parent woken if idle) | **Shipped.** Durable `agentnotice` pointers are delivered during a live turn or drained before the next one |
| **Depth limit** | `maxDepth` config (default 3; `0` forbids delegation), absolute cap, provider capability advertised | Hard-coded **depth 1** (`x-harness.noSpawn` + `sessionmeta.parent` check at dispatch) |
| **Policy per child** | `persona` (scoped shadow), `toolFilter` (one live visibility rule), `agentOptions` (provider/model/effort) | `model`, `thinking`, `tools` allowlist, `maxRounds`/`maxCalls`/`maxTokens` — **frozen into the child conversation at its first turn** |
| **Approvals in children** | Pinned `approvalPolicy: 'never'` + a child-visible "your scope was fixed at start" statement | Child approvals **route to the original interactive caller** via `__session.caller` (strictly more capable) |
| **Authority** | Exact live sender (`exec.agent`); parent↔direct-child only; stale/sibling/self rejected | Depth-1 lineage at dispatch; no messaging authority model (steer is fire-and-forget) |

### 1.2 Where Niffler is genuinely ahead (and should not regress)

These are not consolation prizes — they are load-bearing:

- **Cancellation that reaches the bottom.** `agent_stop` publishes
  `llm.cancel.<child>` (aborts an in-flight streaming request) *and*
  `svc.session.<id>.steer {__cancel: true}` (ends the turn between rounds), and
  the runner's `cancel.<component>` side-channel kills an in-flight bash process
  group. DSH's `interrupt()` issues `Agent.cancel(cause, {keepInbox: true})`
  and explicitly "returns without awaiting quiescence"; whether a child's
  in-flight tool dies is the tool's business.
- **Durability of the job record, verified.** `agentjob` is written *before*
  the fire-and-forget publish; the completion tap is the single terminal
  writer; `resolveStale` reconciles non-terminal records on boot and on every
  status/wait against the live catalog **and the child transcript** — so a job
  whose tap was missed while the component was down is synthesized as
  `done` (with the reply), and a child whose runner died is honestly recorded
  `failed`/`stopped` rather than lying "running". DSH's equivalent honesty
  problem (`No replay of accepted-but-unlogged messages`, `Wake gap during
  cancellation convergence`) is listed as a known limitation.
- **Fail-closed lineage and the process boundary.** Lineage is written before
  the turn and reads fail closed; depth is enforced at *dispatch* (core), not
  just in the component. The child is an OS process with its own runner — the
  supervisor owns its lifetime, PDEATHSIG prevents orphans, and idle runners
  retire. DSH's in-process children share the parent's process, LLM and tool
  services.
- **Approvals route to a human.** DSH *removed* the child's ability to ask
  (pinned `never`) because "a permission-blocked child was indistinguishable
  from a working one" and the heavier fix was disproportionate. Niffler's
  `__session.caller` injection means a child's `bash` approval reaches the
  person driving the parent conversation. This matters exactly because
  Niffler's children are *more* capable (real shell, real files) than an
  in-process DSH child.
- **Budget discipline.** Per-child `maxRounds`/`maxCalls`/`maxTokens` and a
  per-job `budgetMs` enforced lazily on observation (`resolveStale` cancels an
  over-budget running job). DSH has `max-tokens` as a stop reason but nothing
  like the three-axis turn budget.

### 1.3 Where the drift is real

The headline gaps in this comparison are now closed: Niffler has continuation,
fork, `agent_list` and parent settlement notices. Remaining asymmetries worth
keeping in view are:

1. **Depth is 1, not N.** DSH defaults `maxDepth: 3`; Niffler deliberately
   keeps depth-1 lineage. A configurable cap remains a possible future change.
2. **`agent_steer` is fire-and-forget.** A parent can continue a child with
   `agent_run`/`agent_spawn`, but steer itself does not return a reply.
3. **The APIs differ.** Niffler's roster and notice records are bus-native and
   derived from `sessionmeta`/`agentjob`; they are not DSH's provider registry
   or in-process activation model.

## 2. The baseline, checked against Niffler tool by tool

IanTheReal's five-tool sketch, mapped:

| Baseline | DSH | Niffler today | Verdict |
|---|---|---|---|
| `spawn_agent(task, context: fresh\|fork)` | `subagent` tool, provider `spawn`/`fork`, `run_in_background` | `agent_run` / `agent_spawn`, fresh or `fork` | **present** |
| `send_message(id, message)` | `send_message` (Steer, fixed; returns `MessageId`) | `agent_steer` plus `agent_run`/`agent_spawn` continuation | **present, different API** |
| `wait_agent(id)` | `subagent` foreground (awaits result) or one-shot `job_output` | `agent_wait` (polls the durable record; **blocks the component pump**) | present, blocked-pump caveat |
| `list_agents()` | `list_agents` (children/descendants, live status), one-shot children omitted | `agent_list` (children or descendants, derived from lineage) | **present, different API** |
| `interrupt_agent(id)` | `interrupt_agent` (keeps inbox/descendants) | `agent_stop` (keeps conversation) | present, better cancellation |
| background notify | settlement notice into the parent's turn stream | durable `agentnotice` delivered to the parent | **present** |

Agreement with the chat: **fork and resume, with context and history persisted,
was the right first scope.** Niffler's persistence was already the strongest
part of its story; the missing verbs were subsequently added without changing
the store ownership model.

## 3. Steal 1 — continuation (the foundation)

This restates DSH-STEAL §2 as a historical design record. The continuation
contract described here has landed; see the manual for the authoritative
schema and authorization rules.

**The insight: continuation was already latent in the runner model.**
`session_prepare` is the idempotent re-ensure ("prepare the runner directly
(core's session tool would stash mid-turn)"); a runner that retired resumes from
the store; the conversation header carries the frozen controls. A second turn
is `requestEnvelope("session", {sessionId: child, content: …})` — the *same*
call the fresh path makes, now authorized and exposed by `agent_run`/`agent_spawn`.

Design (unchanged from DSH-STEAL §2.1–§2.6, reiterated compactly):

1. `agent_run` / `agent_spawn` gain optional **`session`**. Absent → today's
   byte-identical fresh path. Present → a new activation of a named child:
   validate existence + authorization (lineage parent — and later team
   membership) **fail closed**; `session_prepare(child)`; run the ordinary
   turn; record a new `agentjob` (which stays turn-scoped, so `resolveStale`,
   the completion tap and `ev.agent.done` are untouched).
2. `agentjob` gains `activation: n` + `firstActivationAt`; continuity metadata
   lives in `sessionmeta` (explicit, versioned fields). Everything else is
   derived from the child transcript + the job sequence.
3. Frozen controls are the **child conversation's**, not the caller's: a
   continuation accepts only `content` and per-activation `timeoutMs`/`budgetMs`.
   The schema must say "ignored on continuation — frozen at the child's first
   turn", or the model will try to re-specify a model and silently not get it.
4. Who may continue: the lineage parent; teammates later. Because a
   continuation mutates no lineage, **teammates can wake teammates while the
   depth-1 rule stays bolted on** — the payoff that makes the `team` steal
   (DSH-STEAL §5) cheap.

**Cache effect: none.** A continuation's prompt is the child's stable prefix +
one appended user turn — the shape every second turn already has. No
`reset:*` class, no new prefix contributor.

**The one real design question** (raised in DSH-STEAL §7.1, now sharper because
turns run in per-conversation runner *processes*): two concurrent
`agent_run {session: X}` calls. The runner's pump serializes turns ("turns
never nest"), so the second request queues behind the first and its `timeoutMs`
must budget the first's remainder. Recommendation: make `agent_run` return a
`busy` error when the child's runner reports a live turn (one cheap catalog
probe), and let `agent_spawn` accept the queue (a background activation *should*
queue). That difference is worth writing into the schemas: it is the difference
between "you asked for a result now" and "you asked for work to happen".

## 4. Steal 2 — fork (the context verb)

DSH-STEAL §3's design holds. Restated with what the store now gives:

- `fork` on a **fresh** spawn only (a fork is a birth, not a continuation):
  `true` (whole transcript), `{"lastK": 40}`, `{"maxChars": 200000}`.
- Read via `storeList("message", parent & ":")` — the walk `lastTranscript`
  already does; write each record under the child conversation id with the
  zero-padded seq (store key order = message order), preserving
  `role`/`content`/`createdAt`, **dropping per-message `usage`** (the child's
  accounting is its own; keeping the parent's tokens would lie twice).
- Provenance before the first turn, fail-closed:
  `sessionmeta[child] = {parent, fork: {source, uptoId, copied}}`.
- Two integration points: **messages before header** (the resumed child has
  transcript records before its `conversation` header — the resume path must
  create-or-adopt; this is the only place it touches `core/conversation.nim`),
  and `session_info` should surface `fork` next to `parent`.
- **Cache effect: forks are born cold** — the child's first request replays the
  whole copied history uncached. That is the price of *judgment* inheritance and
  the right trade only when the preamble would otherwise have to *narrate* the
  context. Bulk context transfer with no judgment needed is what `fabric` is
  for; the fork contract is "the model needs to have **read** the conversation,
  not been told about it."

DSH's boundary is instructive and Niffler should match it: the seed is the
parent's **balanced completed-turn prefix** ("up to and including its last
`turn/end`"), because "the in-flight, unbalanced turn is excluded" so the seed
replays clean. Niffler's per-message records make the equivalent trivially
checkable: cut at the last `user` message whose turn has a terminal assistant
reply, never mid-tool-round. Getting this wrong produces a child that resumes
with a dangling `tool_call_id` — exactly the invariant `trimContext` protects.

## 5. Steal 3 — the settlement notice — shipped

The design below is the pre-implementation reasoning. The landed record and
current delivery rules are in [WIRE.md](../WIRE.md#settlement-notices-subagents)
and the manual.

This is not in DSH-STEAL.md and is the cheapest of the three.

**What DSH does.** When a resident Activation settles, "the manager delivers one
notice to the child's durable direct parent describing how that epoch ended and
carrying its final assistant content", *before* releasing ownership so the
parent cannot be judged settled first, reaching a resident parent "through the
same waking Agent delivery as an Agent message". Crucially the notice has its own
provenance kind — `SubagentSettledMessageSource {kind: 'subagent-settled', form:
'notice', summary, senderSessionId}` — deliberately *different* from
`AgentMessageSource`, with the reasoning stated verbatim: "an Agent message is
content the sender chose, while this message is the manager stating what became
of the child, and a transcript that merged them would credit the child with words
it never wrote."

**What Niffler has now.** In addition to `ev.agent.done` for clients, the
agent component writes a durable `agentnotice` pointer and delivers it to the
parent's live turn or drains it before the parent's next turn. The notice
carries status, summary and a pointer to the byte-identical full reply in
`agent_status`; it never pastes the full child reply into parent history.

**Why Niffler can do better than DSH here.** The parent is a live session runner
with a proven, *recorded* injection channel: `svc.session.<id>.steer`. The
runner folds steer payloads in as `role: "user"` messages prefixed `"Steer: "`
(`drainSteer`, `core/conversation.nim:607`) and persists them, emitting
`ev.session.steer`. A settlement notice rides the same channel and lands as
append-only history — the exact cache shape DSH describes ("the notice follows
its reusable request prefix").

**Landed design (the bullets below record the reasoning):**

- `resolveStale`/the completion tap already know the terminal facts. After
  writing the record, publish the notice to the **parent** session:
  `svc.session.<parent>.steer` with a structured payload.
- The runner must **not** render it as a user-authored steer. Today `drainSteer`
  takes a bare string and hardcodes `"Steer: "`. Add a second, typed path:
  `drainNotices`, writing e.g.
  `%*{"role": "user", "content": "[subagent <childId> " & status & "] " & summary,
       "notice": {"kind": "subagent-settled", "sessionId": child, "status": …,
                  "reply": …}}` — **structural provenance on the message record,
  not a text convention.** (`core/dispatch.nim` already has the distinct
  `advice` path with its own event; this is the same idea.)
- **The notice is not the reply.** DSH keeps the child's final content *in* the
  notice; that is right for a continuable child whose output has nowhere else to
  go, but Niffler's child transcript is readable and `agent_status` returns the
  reply. Recommendation: carry a bounded summary (truncated, with the session id
  for the full read) — the notice's job is to make the parent *aware*, not to
  re-inject the child's whole output into the parent's context. A 5 KB child
  reply pasted into every parent turn is a silent context tax.
- **Wake semantics.** If the parent's runner is idle, the steer publishes into
  the void — the runner is not running a turn, and Niffler's steer subscription
  is drained *during* a turn (`pumpSteer` in dispatch's idle slot). So the
  notice needs a **durable pending record** and a wake: either (a) `agent`
  writes the notice into a `agentnotice` record and the parent's next turn
  drains it (the `team_inbox` pull shape), or (b) `agent` calls core's session
  surface to start the parent's turn. Option (a) is the honest Niffler answer
  today — no auto-wake, the pull is a tool result — and it composes with the
  eventual `team` mailbox. Option (b) is a real feature ("the parent starts
  thinking when its child finishes") and should be a **conversation-level opt-in**
  (`sessionmeta.autoWake` or a session control), never a default: an agent that
  spontaneously writes turns into a human's conversation is a product decision,
  not an implementation detail.
- DSH's own warning applies: the notice must not be *mistaken for the child's
  words*. Keep the marker structural and the wording clearly runtime-authored.

**Cache effect: append-only.** The notice is one appended user message in the
parent; nothing in the prefix moves. If the pull shape is chosen, it is a tool
result — also append-only.

**Effort: hours** for the tap→notice path plus a `t_agent` case; **1–2 days** if
the durable-pending + wake option (b) is included.

## 6. What else is worth taking, and what is not

### Take (small)

- **`list_agents`.** A read-only tool over `storeList("agentjob")` filtered by
  `parent == caller` (and optionally every session whose `sessionmeta.parent ==
  caller`, which is the durable roster rather than the job roster). Add the
  Activation notion once steal 1 lands: `running` / `idle` / `ready` is a better
  vocabulary than `agentjob.status`, because it distinguishes "resident between
  turns" from "storage only, resumable" — the exact distinction a parent needs
  to decide between `agent_steer` and `agent_run {session}`.
- **Depth as configuration.** `NIF_AGENT_MAX_DEPTH` (default 1), enforced at
  dispatch in core where the lineage check already lives. DSH's "the tool stays
  visible at the cap — each attempted start checks the calling agent's current
  depth and rejects with an errored result" is the right model-facing behavior:
  the model learns why, instead of a tool silently vanishing. (Niffler's
  `noSpawn` already rejects with a clear error rather than hiding the tool, so
  this is only about making the number a setting.)
- **Context-sensitive tool descriptions.** DSH derives the delegation tool's
  *wording* from `provider.inheritsParentContext`: a fresh child gets "it does
  not see this conversation", a forked child gets "it does not see the current
  in-flight turn" — "so the model never restates or omits context that does not
  exist". Niffler's `task` description currently says only the fresh wording.
  Once `fork` exists, the description must branch, or the model will hand a
  forked child a preamble that re-narrates what it just read.

### Consider (medium)

- **Child-side policy statement.** DSH writes a `subagent:delegation` statement
  into each child's runtime context: "your permission scope was fixed when you
  were started and cannot be widened from inside this session — operations that
  require approval are rejected automatically … state the limitation in your
  reply so the delegating agent can handle it." Niffler's children *can* get
  approvals (routed to the parent's caller), so the statement must be the
  accurate Niffler version: "your approvals are answered by the human driving
  the parent conversation; if the request is denied, report the limitation
  rather than retrying." Cheap, and it closes a real failure mode (a child
  looping on a denied operation). Note this rides the child's **first** turn —
  a prefix contribution for the child, never for the parent.
- **`persona` / `toolFilter` per child.** Niffler has `tools` (an allowlist
  frozen at the child's first turn) but no persona and no way to *filter* the
  inherited globals rather than replace them. DSH's `ToolRuntime.restrict()` is
  "one live global-view rule" — the same result applies to schemas, lookup,
  execution and PTC generation, so "visibility equals authority" and there is no
  second place to get it wrong. Niffler's equivalent is the conversation's
  `tools` allowlist, which already refuses to *dispatch* outside it; the missing
  half is that the child's *prompt* shows the filtered set rather than the full
  catalog. Worth doing only if child tool costs show up in the bench.

### Do not take

- **The named-provider registry with out-of-process backends (ACP/Codex/Claude
  Code).** It is DSH's way of reaching "other agents" because its child is
  in-process. Niffler's child is *already* a separate process on a bus, and the
  bus is how you reach another harness if you ever want to (`NIF_NATS_URL`,
  REMOTE.md). A provider registry would be a second, weaker seam over the one we
  have.
- **In-process children.** DSH's in-process provider exists to make delegation
  cheap. Niffler's process-per-conversation is the isolation story: a child
  crash cannot corrupt the parent, and the supervisor owns lifetimes. Do not
  trade that for latency.
- **Pinning child approvals to `never`.** DSH did it because blocked children
  were invisible. Niffler routes child approvals to a human; the right response
  to "blocked children are invisible" is to make the *pending approval* visible
  (the UI already has the modal and `ev.approval.*`), not to remove the
  capability.
- **`send_message` to non-adjacent agents, siblings, or the whole tree.**
  Adjacent-only (parent ↔ direct child) is DSH's *stronger* rule and Niffler
  should keep it: depth-1 lineage plus adjacency is a policy that can be stated
  in one sentence.
- **Replacing `agentjob` with activation epochs.** DSH-STEAL §2's "what we
  deliberately do not take" stands: our per-activation durable record gives
  `agent_status` a free history that DSH needs a descriptor to reconstruct.

## 7. Sequencing, effort, tests

| # | deliverable | depends on | effort | contract tests (`t_agent`) |
|---|---|---|---|---|
| 1 | **Settlement notice** (§5) | – | hours–1 day | tap→notice on spawn completion; notice is a *structural* record and not a bare steer; notice reaches an idle parent (pull shape) and a mid-turn parent (steer shape); no notice for a stopped-without-reply job beyond the status line |
| 2 | **Continuation** (§3) | – | 2–3 days | continue-after-`done`; kill-then-continue (interrupted → new activation); non-parent continuation fails closed; frozen controls ignored on continuation; `agent_status` shows activation lineage; v1 records coexist; `agent_run {session}` on a busy child returns `busy` while `agent_spawn` queues |
| 3 | **Fork** (§4) | – | ~2 days | copy→resume proves messages-before-header adoption; `lastK`/`maxChars` fail closed on bad budgets; the cut lands on a balanced turn boundary (no dangling `tool_call_id`); provenance visible in `session_info`; `usage` dropped from copied records; depth-1 unaffected |
| 4 | **`list_agents`** (§6) | 2 (for the status vocabulary) | ~half day | direct children only by default; descendants optional; `ready` means storage-only-resumable, not terminal; a corrupt/unreachable candidate is a diagnostic, not a silent omission |
| 5 | **Depth config** (§6) | – | hours | default 1 preserved; an over-depth start errors with a clear message and the tool stays visible |

Bench: no changes. `expert`: untouched. Docs when the code lands, not before:
MANUAL §Fabric and subagents (continuation + fork + notice), AGENTS.md (new
`agentjob` field, the notice record kind), WIRE.md (any new subject), and
DSH-STEAL.md's status line if these supersede it.

## 8. Open questions

1. **Notice vs. reply.** Does the notice carry the child's full final reply, a
   bounded summary, or a pointer? DSH carries the content. Recommendation:
   bounded summary + session id (see §5); decide with a measurement of how often
   a parent actually wants the whole thing.
2. **Auto-wake.** Should a settled child *start* the parent's turn? DSH says yes
   implicitly (the notice reaches an idle parent and wakes it). Recommendation:
   per-conversation opt-in, default off, because it makes an agent write turns
   into a human's conversation unprompted.
3. **Notice for `agent_run` children too?** A synchronous `agent_run` returns the
   reply, so a notice would be a duplicate. But a `agent_run` whose *caller turn*
   was cancelled leaves a child running to completion — for that child a notice
   is the only delivery. Recommendation: notice on terminal settlement for any
   child whose terminal state was not delivered by the tool result that started
   it.
4. **Does continuation need the `busy` error?** Alternative: let it queue and
   document the timeout arithmetic (DSH-STEAL §7.1's v1 answer). The `busy`
   error is more honest but makes two calls behave differently under load;
   decide by how often the bench shows a parent issuing overlapping
   continuations.
5. **Fork + compaction interaction.** `feat/compaction` is landing a context
   identity ledger (`CtxNode`, `canonicalSeq`, digest). A fork copies *store*
   records, so it copies the pre-compaction originals — which is correct (the
   child gets the real history) but means a forked child of a compacted parent
   is *larger* than the parent's live context. CONTEXT-REVIEW.md's
   read-visibility questions apply: a fork is a reader of records the parent no
   longer has in context. Worth one paragraph in the fork implementation notes.

## 9. One-line summary for the chat

Niffler's child persistence, cancellation and job durability are ahead of DSH;
what it lacks is **verbs, not storage** — continuation (add `session` to
`agent_run`/`agent_spawn`), fork (copy the balanced transcript prefix at birth),
and a **settlement notice into the parent's turn stream** (which DSH has and we
do not; cheap because the parent is a live runner with a recorded injection
channel). `list_agents` and a configurable depth cap are the small completions.
Do not take the provider registry, in-process children, or DSH's
approvals-pinned-to-never.
