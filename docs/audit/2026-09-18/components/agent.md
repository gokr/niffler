# Audit: `components/agent/` (Nim, 1744 lines, one file)

Component: `components/agent/main.nim` — `newComponent("agent", "0.1.0")` (:41).
Manifest: `manifest.yaml:219-225` (autostart `true`, `required: false`,
`restart: on-failure`). All 9 tools are `onDemand` ⇒ **discover-only**, never in
the frozen direct set (MANUAL's shipped policy already says so: MANUAL:1476).

## 1. What it offers

The subagent runtime: it turns a conversation into a *parent* that delegates
work to **child sessions that are ordinary Niffler sessions** — own runner
process, own transcript, own frozen controls, resumed from the store (:3-5).
Two drivers on one primitive: `agent_run` blocks and returns the child's final
reply (`session_prepare` → lineage → child turn → reply, :7-9, :1004-1116);
`agent_spawn` records a durable `agentjob`, publishes the child turn to a
private reply inbox and returns `{jobId, sessionId}` immediately (:10-14,
:1149-1247). Around those: a background-job lifecycle (`agent_status`,
`agent_wait`, `agent_stop`), live/queued message injection (`agent_steer`,
`agent_ask`), a durable child roster (`agent_list`), and **settlement notices**
that reach the parent conversation without polling (`agent_notices`, :60-186).
Restart recovery reconciles non-terminal jobs lazily against the live catalog
and the child transcript (:25-29, :906-967). Delegation depth is capped and
children cannot spawn children (`x-harness.noSpawn`, :1001, :1146, :1416;
core/dispatch.nim:1607-1621).

## 2. Tools (9, all registered on `svc.agent.call`)

Signature = tool schema; flags = `x-harness` block verbatim.

| Tool | Where | Purpose (from the schema description) | `x-harness` |
|---|---|---|---|
| `agent_run {task, session?, close?, fork?, model?, modelTier?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | :974-1116 | Run a task in a subagent session and return only its final reply; fresh child or one more turn of an existing child | `{approval: "always", timeoutMs: 900000, sessionContext: true, noSpawn: true, onDemand: true}` (:1001-1003) |
| `agent_spawn {task, session?, close?, fork?, model?, modelTier?, thinking?, tools?, maxRounds?, maxCalls?, maxTokens?, timeoutMs?}` | :1119-1247 | Start a task in the background, return `{jobId, sessionId}` immediately; `session` **queues** a turn | `{approval: "always", timeoutMs: 60000, sessionContext: true, noSpawn: true, onDemand: true}` (:1146-1148) |
| `agent_status {jobId}` | :1249-1268 | Non-blocking durable job lookup (`running/done/failed/stopped/stopping` + reply or error) | `{onDemand: true}` (:1253) |
| `agent_wait {jobId, timeoutMs?}` | :1271-1310 | Block until the job is terminal (`stopping` is not terminal); late waits read the durable record | `{timeoutMs: 900000, onDemand: true}` (:1277) |
| `agent_stop {jobId}` | :1311-1337 | Cancel a running job for real (aborts the in-flight LLM request, ends the turn between rounds); terminal record says `stopped` | `{onDemand: true}` (:1315) |
| `agent_steer {session_id, message}` | :1338-1404 | Send a message to your subagent: injected now if mid-turn, otherwise queued durably for its next continuation | `{onDemand: true, sessionId: true}` (:1345) |
| `agent_ask {session, question, timeoutMs?}` | :1407-1476 | Ask a child a question: on an idle child a continuation returning the answer; on a mid-turn child queued as mail | `{approval: "always", timeoutMs: 900000, sessionContext: true, noSpawn: true, onDemand: true}` (:1416-1418) |
| `agent_notices {session?, peek?}` | :1477-1512 | Drain this conversation's pending settlement notices (`peek` looks without consuming) | `{onDemand: true, sessionId: true}` (:1483) |
| `agent_list {scope?, sessionId?}` | :1535-1582 | The caller's subagent roster from the durable lineage; `scope: children` (default) or `descendants` | `{onDemand: true, sessionId: true}` (:1542) |

Notes on the roster contract (:1613-1637): each row carries `sessionId`,
`parent`, `depth`, and when a job exists `jobId`, `lastStatus`, `task`,
`startedAt`, `error`; `status` is derived as `running` (in `liveTurns` or
`lastStatus in running/stopping`) → `idle` (runner resident, sanitized id in the
one-shot catalog read `liveRunnerSet`, :1520-1533) → `ready` (storage only,
"resumable, NOT finished", :1630-1636). Stale job records are reconciled before
a status is derived (:1596-1604), so `lastStatus` cannot read `running` forever.

Results worth naming: `agent_run` returns `{sessionId, reply, model, modelTier?,
fork?}` and, on a continuation, `continued: true, activation: N, effective:
{...}` read back from the child's header (:1088-1116, `effectiveControls`
:778-805); `agent_spawn` returns `{jobId, sessionId, steer: "svc.session.<child>.steer"}` plus `fork?`/`close?` (:1240-1247).

## 3. Configuration

**Env vars** (all read by this component; core reads `NIF_AGENT_MAX_DEPTH` too):
- `NIF_AGENT_MAX_DEPTH` — delegation depth cap, default `1`, negative/unreadable
  falls back to 1 (main.nim:505-515; core mirror core/dispatch.nim:1483-1489).
  Enforced twice: core at dispatch from `x-harness.noSpawn`
  (core/dispatch.nim:1607-1621) and component-side in `prepareChild`
  (`lineageDepth` walking `sessionmeta.parent`, fail-closed → `cap+1`,
  main.nim:518-552).
- `NIF_AGENT_MODEL_WEAK` / `_MEDIUM` / `_STRONG` — exact model ids per tier
  (main.nim:604-608); `NIF_AGENT_DEFAULT_TIER` — tier ceiling for an unknown
  parent model, default `strong` (:610-614). A fresh child resolves
  `model` xor `modelTier` (both ⇒ error, :638-640), tier clamped to the parent's
  effective tier (:658-666), and the child otherwise inherits the parent's
  persisted `modelOverride`/`model` (:643-656). Continuations never call this.
- Indirect: `NIF_MAX_TURN_ROUNDS` bounds `maxRounds` (schema text :986, :1131);
  `NIF_RUNNER_IDLE_S` retires idle child runners, which re-ensure on demand
  (component doc :34-35; MANUAL:347).

**Store kinds owned/used:**
- `agentjob` `<jobId>` — durable background job: `{sessionId, parent, status,
  task, startedAt, budgetMs?, continued?, activation?, close?}` written before
  the fire-and-forget publish (:1218-1230); the `_INBOX.agentjob.>` tap is the
  **single writer** of the terminal state, preserving spawn fields and turning
  `stopping` into `stopped` (:1587-1651).
- `agentnotice` `<parentSession>:<seq>` — settlement notices and parent-mail
  (queued steer/questions), both drained by core at turn top
  (core/conversation.nim:1035-1060); flags `deliveredAt`/`deliveredVia`
  (`wake` | `pull`).
- `sessionmeta` `<sessionId>` — lineage `{parent}` written **before** the child
  turn (fail-closed, :324-331), plus `fork?` provenance (:326-328) and, on
  continuation, `activations`/`firstActivationAt` and `closed` (:738-748,
  :1109-1117).

**Notice mechanism** (`emitNotice` :153-186, the only writer): a durable record
first, delivery second. Two lanes by *parent* state — parent mid-turn ⇒ publish
to `svc.session.<parent>.steer` with `{notice: {kind: "subagent-settled", ...}}`
and mark `deliveredVia: "wake"` (:128-151); otherwise leave pending for the
pull lane (`agent_notices` marks `deliveredVia: "pull"`, :1496-1501). The
payload is a **pointer**: `summary` (400-byte head/tail split, :76-103),
`replyBytes`, `fullReplyIn: "agent_status"` (:76-82). Best-effort throughout —
a store failure costs a notice, never a turn (:157-159, :185).
**Event subjects:** `ev.agent.started` (:1238), `ev.agent.done` (completion tap
:1656, and lazy recovery :966), `ev.agent.notice` (:184-186 — observe-side
counterpart of the record). Taps/subscriptions: `ev.session.turn`
(`liveTurns`, :1717-1735), `_INBOX.agentjob.>` (:1587), `cancel.agent`
(:203-240). Cancel is two-channel: `llm.cancel.<child>` + `__cancel` on
`svc.session.<child>.steer` (:187-197).

## 4. MANUAL placement

**Existing home: MANUAL:1974 `## Fabric and subagents`**, sub-sections
`### Settlement notices` (1997), `### Continuation (sessions with memory)`
(2015), `### Delegation depth` (2040), `### Fork (a child that has read the
discussion)` (2051). The tool table is MANUAL:1986-1995; `agentjob`/
`agentnotice`/`sessionmeta` rows are in `## The store` (MANUAL:2185-2187);
env vars in `## Environment variables` (MANUAL:284-285, 335, 347); "the long
tail is on demand … Orchestration: `fabric`, the `agent_*` tools"
(MANUAL:1476).

Split by audience — this is right as it stands:
- **MANUAL keeps**: the tool table with signatures and refusal semantics, the
  four sub-sections (notice lanes, continuation, depth, fork), the store kinds,
  the `NIF_AGENT_*` rows. All of it is operability/contract, not technique.
- **`docs/FABRIC_GUIDE.md` keeps**: nudge phrasing, worked hybrid example 6
  ("mechanical program + judgment subagent", FABRIC_GUIDE:220-258), budgets
  narrative (:249-256), the `ev.agent.started`/`ev.agent.done` row in its
  "after a run" table (:353). MANUAL should **point at** it (it already does,
  MANUAL:1983) and not duplicate examples; `docs/WIRE.md` "Subagent
  continuation"/"Subagent fork" keep the bus-level contract MANUAL cites.
- **Add to MANUAL only** the deltas below (missing tool, missing flags,
  incomplete rows) — no new section is needed.

## 5. DELTA list

- `- MANUAL:1986-1995 (table rows: agent_run…agent_notices) | CODE: components/agent/main.nim:1419 (registered), schema :1407-1418 | FIX: add` — **`agent_ask` is entirely undocumented** (absent from MANUAL and FABRIC_GUIDE; grep for `agent_ask` in docs/ ⇒ 0 hits). Suggested row: `| `agent_ask {session, question, timeoutMs?}` | Ask one of your subagents a question and get its answer. On an idle child this is a continuation returning the reply; on a MID-TURN child the question is queued as mail (`queued: true`, `deliveredVia: "next-turn"`) and answered with the child's next continuation. Approval-gated; same lineage authorization as `agent_run`. |`
- `- MANUAL:1993 | CODE: main.nim:1367-1402 (queue path), :1345 (`x-harness.sessionId`) | FIX: update` — the `agent_steer` row says only "injected into a running turn (drained between LLM rounds)". Code also has the between-turns lane: the message is written durably as an `agentnotice` record with `direction: "parent-mail"` and the reply is `{queued: true, deliveredVia: "next-turn"}`; only the parent conversation may steer (lineage check :1358-1366), the lane check is `sessionId in liveTurns` after `refreshTurns()` (:1367-1372).
- `- MANUAL:1988-1989 | CODE: main.nim:978, :1125 (`modelTier` in both schemas) | FIX: update` — both signature rows omit `modelTier`; add it and one clause: "`modelTier` (`weak`/`medium`/`strong`) selects from `NIF_AGENT_MODEL_*` for a FRESH child and is clamped to the parent's tier; `model` and `modelTier` are mutually exclusive."
- `- MANUAL:1990 | CODE: main.nim:1249-1252, :1300-1305, :1306-1310 | FIX: update` — `agent_status` also returns `stopping` (a non-terminal "stop requested" state); `agent_wait` explicitly keeps waiting on `stopping` and on its own timeout returns `code: "timeout"` with `{jobId, status}` rather than the record.
- `- MANUAL:1994 | CODE: components/agent/main.nim:1535-1541, :1613-1637 | FIX: update` — the roster row lists only `sessionId`, `jobId`, `task`, `status`. Add: rows also carry `parent`, `depth`, `lastStatus` (last activation's outcome), `startedAt` and `error`; the signature is `{scope?, sessionId?}` (`sessionId` is the read-only UI override); and drop/reword "`scope: "descendants"` walks the whole tree (depth 1 today)" — `descendants` recurses through `sessionmeta.parent` (:1550, :1575-1585) while `children` is depth 1; "depth 1 today" is the delegation cap (`NIF_AGENT_MAX_DEPTH`), not the scope.
- `- MANUAL:2020-2021 | CODE: main.nim:707-708 (`"cannot continue yourself"`) | FIX: add` — the continuation refusal list omits the self case. Full set: self (`child == caller`), unknown session, root conversation (`parent` empty), foreign child (`parent != caller`), closed child, store unreachable — all explicit errors, never a silent fresh child (:707-737).
- `- MANUAL:2034-2036 | CODE: main.nim:738-742, :324-331 | FIX: clarify` — `activations` counts every turn the child accepted *including its birth turn* (`meta["activations"].getInt(1) + 1`), so a child continued once reports `activation = 2`; `firstActivationAt` is stamped at the child's **first continuation**, not at birth (birth writes only `{parent}`/`{fork}`).
- `- MANUAL:2057-2059 | CODE: main.nim:326-328; core/dispatch.nim:657-659 | FIX: add` — provenance claim is correct, but the durable home is `sessionmeta.fork = {source, uptoId, copied}`; MANUAL:2187's `sessionmeta` row should list `fork` alongside `parent`/`activations`/`firstActivationAt`/`closed`.
- `- MANUAL:2051-2106 (fork section) | CODE: main.nim:452-462 (comment), AGENTS.md "Fork is the one store-ownership exception" | FIX: add one line` — the fork's **store-write exception** is documented in code and AGENTS.md but not in MANUAL: `agent` writes `message` records (which core otherwise owns) in `forkHistory`, safe because it is a one-time copy written after `forkBlocks`/`balancedPrefixLen` selection and **before** the child's runner exists (no concurrent writer), with the child's `seqNo` continuing after the copied ids.
- `- MANUAL:1986-1995 (table) + 2092 | CODE: main.nim:1001, :1146, :1416 (`approval: "always"`), :1002/:1147/:1417 (`sessionContext: true`), :1003/:1148/:1418 (`noSpawn: true`) | FIX: add` — the subagent section never states that `agent_run`/`agent_spawn`/`agent_ask` are **approval-gated** (a human y/N prompt per call) and that `noSpawn`/`sessionContext` are what make them delegation tools; `noSpawn` is only mentioned in the fabric "Guards" bullet (MANUAL:2092). Suggested: one sentence under the table.
- `- MANUAL:1991 (agent_wait row) | CODE: main.nim:1288-1290 (`c.pumpTaps`, serialized pump) | FIX: add (optional)` — a wait blocks on the component's serialized pump, so other `agent_*` calls queue behind it; `agent_spawn`/`agent_status` exist partly for that reason. Also worth one line: non-terminal records are reconciled lazily (boot `reconcileAll` :963, and on every status/wait/roster read), so a completed turn whose tap was missed synthesizes `done` from the transcript and a dead runner becomes `failed` with `"interrupted — child runner gone before completion"` (:906-967).
- `- MANUAL:1997-2013 (Settlement notices) | CODE: main.nim:171-183, :1499-1508, :184-186 | FIX: add (small)` — the record shape/id (`<parentSession>:<seq>`, zero-padded seq) and `deliveredVia: "wake" | "pull"` are described only in the store table (MANUAL:2186); `ev.agent.notice` (the observe-side event, :184) and `ev.agent.started` (:1238) are not named in the section, while FABRIC_GUIDE:353 already lists `ev.agent.started`/`ev.agent.done`.
- `- MANUAL:1988 ("exhaustion ends the turn as a budget-exhausted failure") | CODE: core/conversation.nim:1802-1806; MANUAL:512-514, 552-556 | FIX: none` — verified: job-scoped budgets stay hard, exhaustion is a budget-exhausted error surfaced as a failure. Cite-free, no change needed.
- `- MANUAL:2040-2049 (Delegation depth) | CODE: main.nim:538-552; core/dispatch.nim:1607-1621 | FIX: none` — verified accurate, including "the spawn tools stay visible at the cap" and the error naming limit + caller's depth.
- `- MANUAL:2051-2106 (fork) | CODE: main.nim:330-503 | FIX: none` — verified: `fork` + `session` refused (:1035-1039), balanced contiguous-from-0 cut (:365-404), budgets cut on turn boundaries (`forkBlocks` :406) and "nothing to fork"/"selection excluded every record" fail closed (:444, :500), usage/summary/error/toolset not copied.

Finding count: **15** bullets (12 deltas + 3 verified-unchanged: budgets, depth, fork semantics).

## 6. Not user-facing

Nothing here should be hidden: all 9 tools are the model's own delegation
surface and already on-demand, so a user only sees them through `discover`
hints and the approval prompt. Two things are *internal* and MANUAL should not
document them as user features: the `cancel.agent` side-channel subscription
and the 30-second cancel freshness window (main.nim:198-240), and the
`_INBOX.agentjob.<jobId>` reply-inbox tap (:1587). The component registers no
UI/service surface of its own (`newComponent("agent", "0.1.0")`, :41;
`autostart: true` in manifest.yaml:221) — it is a pure LLM-facing tool peer,
plus three store kinds that belong in the store table (already there,
MANUAL:2185-2187).
