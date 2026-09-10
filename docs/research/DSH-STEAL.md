# DSH-STEAL — dsh's orchestration ideas, made Niffler-native

Status: **proposal** (nothing here is implemented). Companion to
[DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md) — read its §4 (guarded tool
pipeline), §8 (subagents) and #12 (agent-team) for the provenance. All dsh
citations below refer to `~/git/deepseek-harness`.

Four steals, selected by one rule: **the wire stays; the topology wins**.
Each design must survive the sieve in §1, and none of them may quietly grow
the frozen conversation prefix — that discipline is the one thing a 30/30
full30 run depends on.

The four:

| # | steal | dsh origin | Niffler host |
|---|---|---|---|
| 1 | Continuable subagents (activation epochs) | continuable background subagents (`subagent/` notes 2026-07-21) | `agent` component |
| 2 | Forked children (seeded from the parent's history) | `subagent-fork-in-process/` | `agent` component |
| 3 | Typed tool declarations **on demand** (tool result, not prompt) | PTC's generated SDK `.d.ts` in the system prompt (`2026-06-15-ptc.md`) | `fabric` component |
| 4 | Team: named teammates + durable mailbox | `experimental/agent-team/` | new `team` component |

Dependency order: 3 and 2 are independent; 1 is the foundation; 4 needs 1.

## 1. The sieve

Every mechanism below is checked against the invariants that already exist
(AGENTS.md). Anything that fails the sieve gets redesigned, not waived.

- **Peers, not frameworks.** New capability = a component process. The `team`
  steal is a new component, not a new mode inside `agent` — identity and
  mailboxes are their own single-writer state, exactly like `store` is.
- **Prompt-cache discipline.** A conversation's request prefix (frozen system
  prompt + frozen direct tool schemas) must stay byte-stable; history only
  grows. Every new contributor to session context states its effect:

  | contributor | effect |
  |---|---|
  | continuation of a subagent (new turn) | append-only history (a new user turn) |
  | fork of a parent transcript | none — it *is* the child's initial history; the child's own prefix rules start at its first turn |
  | `fabric {api: true}` declarations | append-only history (a tool result) |
  | team mail to a **live** teammate | append-only (arrives via the proven steer channel, which the runner already records as an injected user message) |
  | team mail to the lead (`team_inbox`) | append-only (a tool result) |
  | `agent_*` / `team_*` tools themselves | **nothing** — already `onDemand` (progressive discovery); optionally a tools profile freezes them at conversation *start*, which is the sanctioned way |
  | stored fabric programs / the api result | never in the prefix; replayed as stable, cached history |

- **The store is single-writer per record kind.** `team` owns `teammate` and
  `teammsg` records; `agent` keeps its `agentjob` + `sessionmeta`. Nobody
  else writes them.
- **No `asyncdispatch`.** All new handlers are the standard synchronous pump;
  long waits (`agent_wait`, drain) are request/response like today's.
- **Fail-closed where correctness lives, fail-open where convenience lives.**
  Lineage checks (depth, continuation rights) fail closed. Team delivery
  fails open — an absent `team` component costs a delivery, not a turn.
- **The store has no transactions.** Where dsh uses a "mailbox transacted on
  the lead's journal", we use mark-before-publish sequencing and *document
  the residual window* instead of pretending it away (§6).

## 2. Steal 1 — Continuable subagents (activation epochs)

### What dsh does

A durable child accepts *follow-up turns*: the delegation tool returns, the
child's conversation persists, and a later turn can continue it. The
descriptor snapshots **explicit fields** (v3) so "an unrelated extension
value cannot make continuation fail merely because it is not JSON"
(`subagent/src/descriptor.ts:8`); residency is *derived* from quiescence,
"rather than a second state machine" (`continuation.ts:148`).

### What Niffler has today

`agent_run` = `prepareChild` (a fresh `agent-<id>` session: `session_prepare`
→ `ensureRunner`, lineage recorded fail-closed) + **one**
`requestEnvelope("session", ...)` turn (agent/main.nim:289). `agent_spawn` =
the same, backgrounded, tapped into a durable `agentjob` record
(`running → done|failed|stopped`) announced as `ev.agent.done`, reconciled
from the transcript on restart (`resolveStale`). After the terminal record:
nothing. The child conversation *persists* — runners resume from the store,
idle runners retire and are re-ensured on demand (`NIF_RUNNER_IDLE_S`,
`session_prepare` → `ensureRunner` is idempotent) — but no tool can utter a
second turn into it. `agent_steer` only reaches a *live* turn.

The continuable machinery is already 90% built. It's just switched off by
the missing parameter.

### Design

**An activation is one turn.** A subagent's lifetime is a sequence of
activations; the conversation is the continuity. Terminate nothing.

1. `agent_run` and `agent_spawn` gain an optional **`session`** argument.
   - Absent → today's behavior, byte for byte (fresh `prepareChild`).
   - Present → the named child conversation gains a new turn:
     - validate: the conversation exists (`storeGetItem("conversation", …)`),
       the caller may continue it — lineage parent (`sessionmeta.parent ==
       caller`) or, once teams exist (§5), a member of the child's team.
       Fail closed: unknown session, foreign lineage, or unreachable store
       → error, never a silently-fresh child.
     - resolve the runner subject: `core.session_prepare(child)` — this is
       exactly the idempotent re-ensure, so a retired (or never-killed)
       runner costs a process spawn, not a redesign. *This* is the payoff
       of "one conversation = one process, runners are disposable, resume
       from the store": continuation is a property of the store, not of
       process lifetime.
     - run the SAME `requestEnvelope("session", {sessionId, content, …})`
       turn the fresh path runs, then record a new `agentjob` (background)
       or return the reply (sync).
   - Optional **`close: true`** marks the conversation finished — a compact
     hint in `sessionmeta` that suppresses `agent_status` "continuable"
     chatter. Nothing is deleted; the store keeps everything (compare dsh's
     compaction: shadow, never delete — we just don't need to shadow).

2. **Job records: explicit-field, per-activation.** Each activation is its
   own `agentjob` (v2) — the record *stays turn-scoped*, which keeps
   `resolveStale`, the completion tap and `ev.agent.done` untouched:

   ```json
   { "v": 2, "parent": "<caller conv>", "sessionId": "agent-3f2a",
     "activation": 3, "firstActivationAt": 1765400000.0,
     "task": "<this turn's content>", "status": "running",
     "startedAt": …, "budgetMs": …, "timeoutMs": …, "reply": … }
   ```

   Continuity metadata (`activation` counter, `firstActivationAt`) lives in
   `sessionmeta` — one object, explicitly fielded, versioned: the "explicit
   fields, never_bagged extension values" lesson, kept. Everything else
   (full history, who interrupted what) is *derived*: the child transcript
   + the sequence of job records already are the ledger. Derive more, store
   less — exactly dsh's residency rule, inverted onto our stronger store.

3. **Frozen controls are the child conversation's, not the caller's.**
   `model` / `thinking` / `tools` / `maxRounds` / `maxCalls` / `maxTokens`
   were frozen into the child conversation at *its* first turn (core's
   conversation-frozen controls). A continuation therefore accepts only
   `content` (the new task/mail) and `timeoutMs` / `budgetMs`
   (per-activation, like dsh's deliberately-non-durable per-activation
   knobs). The schemas say so: "ignored on continuation — frozen at the
   child's first turn".

4. **Who may continue.** (a) the lineage parent; (b) once §5 lands, any
   member of the child's team (`sessionmeta.team`). Note what this buys:
   today's depth guard (`hasParent` → "subagents cannot spawn subagents")
   blocks a *teammate* from running `agent_run`'s fresh-spawn path — but a
   continuation performs no lineage mutation, so **teammates can wake
   teammates** while the depth-1 rule stays bolted on. Fresh spawns: still
   lead-only, still depth-1.

5. **Cancellation, steering, failures — all unchanged, all per-activation.**
   The two-channel cancel (`llm.cancel.<child>` + steer `__cancel`) and
   `agent_steer` already address the *conversation*, so they keep working
   mid-activation. `resolveStale` keeps its transcript-derived verdicts; one
   new rule: an `interrupted` record (runner died without a final reply)
   is simply continuable — the death cost one turn, not the teammate. The
   replay semantics this needs already ship: "Turn-failure records are
   persisted with `role: "error"` and skipped when replaying history."

6. **Cache effect.** A continuation's prompt = the child's stable prefix
   (system prompt + frozen history) + one appended user turn. That is
   precisely the shape every second-plus turn of every conversation already
   has — provider KV caches warm exactly as they do today. No new
   contributor, no prefix change, no `reset:*` class.

### What we deliberately do not take

- dsh's *settlement-notice message kind* (their "credit the child with words
  it never wrote" fear): our final reply is extracted by the completion tap
  from the child transcript, and steer injections are recorded as their own
  role — attribution is already structural.
- *Activation epochs replacing the durable record.* Our `agentjob`-per-
  activation is strictly simpler and gives `agent_status` a natural history
  for free (dsh needs the descriptor because their children are not
  conversations; ours are).

## 3. Steal 2 — Forked children (seeded from the parent's history)

### What dsh does

`subagent-fork-in-process`: a child seeded from the parent's *completed
history* — the teammate inherits what happened, not a hand-written summary.

### Design

`agent_run` / `agent_spawn` (fresh children only — a fork is a birth, not a
continuation) gain **`fork`**:

- `true` → copy the *entire* persisted parent transcript,
- `{"lastK": 40}` → the last K messages,
- `{"maxChars": 200000}` → the longest tail that fits (whole records; a
  message that busts the budget is dropped, not truncated — the runner's
  context-trim already knows how to shrink what it rebuilds).

Mechanics, all inside the `agent` component:

1. Read: `storeList("message", parentSession & ":")` — the same walk
   `lastTranscript` already does (agent/main.nim:165).
2. Copy: write each record under the **child conversation id** (zero-padded
   seq, the same key order = message order contract), preserving
   `role` / `content` / `createdAt`, dropping per-message `usage` (the
   child's token accounting is its own; the bench timing stream would lie
   twice otherwise). One store, one writer, no sync problem.
3. Persist **provenance before the first turn**:
   `sessionmeta[child] = {parent, fork: {source, uptoId, copied}}` — the
   existing lineage record, one field deeper, fail-closed exactly as the
   depth guard is today (an unrecorded fork would quietly become a fresh
   child; we prefer the error).
4. Then the ordinary fresh-spawn path: preamble + task, one turn.

Two integration points worth naming:

- *Messages before header.* A forked conversation has transcript records
  before its `conversation` header exists. The runner's resume/create path
  must tolerate that ordering (create-or-adopt). It is the only place this
  design touches `core/conversation.nim`.
- *Cache effect: forks are born cold.* The child's first request replays the
  entire copied history uncached — that's the price of judgment inheritance,
  and it's the right trade exactly when the preamble would otherwise have to
  *narrate* that context. (Bulk context transfer with no judgment needed is
  what fabric programs are for — the fork's contract is "the model needs to have
  *read the conversation*, not been told about it".) Continuations of the
  forked child are warm, as ever.

`session_info` gains `fork: {source, uptoId, copied}` next to `parent`, so
the lineage is inspectable from every client.

### What we deliberately do not take

- dsh's rewritten/derived fork views: we copy verbatim and let the runner's
  context-trim policy shrink what it will. Summarized forks = someone's
  informal compaction; if we want that, the research doc's steal #1
  (cache-aware compaction) should exist *first* and then fork gains
  `{"mode": "compacted"}` for free.
- Forks of forks. Depth-1 stays: a forked child is a still-leaf; its
  `agent_spawn` is still denied. Lineage reads stay cheap and provable.

## 4. Steal 3 — fabric declarations on demand (`fabric {api: true}`)

### The constraint (and why the user is right)

dsh's PTC ships the model a generated **`.d.ts`** of the typed tool surface
*inside the system prompt* (`2026-06-15-ptc.md`, "SDK prompt section"). For
Niffler that would be a new contributor to the **frozen prefix** — recurring
bytes in every conversation, `firstPromptBudget` (7000) pressure, and a
cache-discipline decision for a capability most conversations never use. The
right Niffler answer: the declarations are a **tool result** — append-only
history, paid only by conversations that write programs, replayed as
free cache-reads thereafter. (If a future tools profile wants fabric-heavy
conversations, *that* profile may carry a declaration block — sanctioned,
frozen at conversation start. Default: history. Do not do both.)

### Design

`fabric` gains a third call shape (today: `code` XOR `name`):

- `{"api": true, "tools": ["bash", "grep", …]}` → returns, as the tool
  result:
  1. the discipline preamble (~30 lines: import `fabricguest` first;
     VM-clean std imports only; `callTool` returns a JSON *string* —
     `parseJson` first; `finish()`'s value is the only thing that reaches
     the conversation; when-to-use: one command → bash, mechanical →
     program, judgment → `agent_run`, mixed → hybrid),
  2. the helper contract (`finish` / `logg` / `batch` / `stringArg` /
     `stringArg`-backed big payloads; budget limits: `maxCalls ≤ 1000`,
     `timeoutMs ≤ 300000`, 50k-char result spill → artifact),
  3. the **typed declarations for exactly those tools** — the same
     `tools.bash(command = …)`-shaped procs the guest macro mints.

- `{"api": true, "name": "<stored-program>"}` → the stored program's source
  *plus* the declarations for its pinned tool set — the read-then-edit loop
  for the model-curated library, which today forces a second artefact hunt
  through the store.

The load-bearing invariant: **what you saw is what compiles.** The typed
wrappers today are minted at guest-compile time by the runtime-schema macro
(`components/fabric/fabricguest/fabricmeta.nim`) from the pinned, catalog-
snapshot schemas. The renderer must therefore *share the macro's
signature-computation core* (name mangling via `nimName`, arg→`FabricArg[T]`
shaping, JSDoc from schema descriptions, collision handling) and differ only
in emitting text instead of a child AST. `t_fabric` gains the proof: for a
fixture catalog, the rendered declarations are fed to the admission path as
a calling-stub program that `discard`-calls every wrapper — it must compile.

Intended loop, replacing "read `components/fabric/docs/REFERENCE.md` before
writing a program":

```
fabric {api: true, tools: ["bash","grep","read"]}   # once, when the first program is coming
fabric {code: "…"}                                   # identical pin set → skip further api calls
```

Consequences:

- The declarations sit in history; every later turn replays them as stable,
  cache-read context. They never vanish, never reorder — the discipline
  guarantees the prefix they attach to stays byte-identical.
- Cost: ~1.5–3k tokens, once, only where used. Versus dsh's方案: every
  conversation pays, fabric or not.
- Staleness: schemas can drift between the api call and the program's
  admission. The admission error remains the oracle; the api result also
  echoes the catalog digest (`component@version` pin-set), and a mismatched
  digest at admission is *reported in the error* ("decls you hold were
  pinned at 3f2a…; call api again") — the model self-heals from its own
  history.

### What we deliberately do not take

- The prompt-embedded declaration block (see above) — one carve-out: a
  *tools profile* may inline it for dedicated fabric conversations, frozen at
  conversation start. Until someone measures a need: no.
- Python/TS guest backends (dsh's `code-runtime-python`). The Nim-VM guest is
  our isolation story, not a gap to fix; the api steal is deliberately orthogonal to guest language.

## 5. Steal 4 — Team: named teammates + a durable mailbox

### Model

dsh's `experimental/agent-team`: a lead, named teammates, messages and task
state that survive crashes,delivery that queues for the offline. We take
the *identity + mailbox* core and deliberately leave the task board for
phase 2 (§5.6).

Four inversions make it Niffler-simple:

1. **A teammate is a continuable subagent** (§2) with a name. There is no
   second kind of agent, no second runner protocol, no teammate state
   machine — residency stays *derived* (runner alive? = catalog; last
   conversation state? = transcript), courtesy of steal 1's "derive more,
   store less".
2. **The conversation is the lead.** A team belongs to one conversation
   (its id); only it creates teammates. Matches dsh ("only the Lead can
   create/interrupt") and needs no role recording: the lead *is* the
   `team` record's key.
3. **`agent` stays the only turn-runner.** The `team` component owns
   identity + addressing + durable mailboxes — it never prepares a runner,
   never runs a turn. Component-to-component calls (`comp.request`) do the
   rest; the bus makes peers, not frameworks.
4. **Depth-1 stays bolted on.** Teammates wake teammates (continuation — no
   new lineage, §2.4); nobody spawns grandchildren. A teammate's approvals
   route to the original interactive caller, as today; a teammate continued
   by a teammate has that teammate as caller — its approval subject gets the
   broadcast fallback, which is the existing, documented behavior.

### Records (store; `team` is their single writer)

```json
// kind "teammate", id = team(=lead conv) + ":" + name
{ "v": 1, "team": "<lead convId>", "lead": "<lead convId>",
  "name": "reviewer", "sessionId": "agent-8812", "role": "reviewer",
  "workdir": "/abs/dir/inside/harness/root",
  "status": "failed",            // last activation outcome; resurrectable
  "createdAt": 1765400000.0 }

// kind "teammsg", id = team + ":" + to + ":" + zero-padded seq
{ "v": 1, "team": "…", "from": "reviewer", "to": "scout",
  "seq": 7, "body": "found the leak in pool.go:64-88",
  "createdAt": …, "deliveredAt": …, "deliveredVia": "steer|activation|inbox",
  "deliveredTo": "agent-8812:activation-3" }
```

Limits, validated fail-loud at creation (dsh's numbers, kept because they
were validated there): `maxMembers 8` (per team, failed hires keep their
names — never reused, exactly dsh's rule), `maxPendingPerMember 64`,
`maxMessageBytes 65536`, one team per conversation. Seq is monotononic per
`(team, to)`; the *queue* is the pending slice, the *history* is all records
— a 1000-record `storeList` cap is a non-issue at these limits.

### Delivery — three lanes, written before published

The dsh detail worth keeping: **durable order before dispatch** — the record
lands before anything tries to deliver it, so a crashed sender still sent.

| recipient state | lane | exactly/at-most |
|---|---|---|
| **live** (mid-activation) | the teammate's steer subject — the runner already records steer injections as appended user-role history (`[@from] …`), so delivery IS a transcript event | at-most-once; loss window = publish→persist (ms); the activation drain (below) covers anything the next wake finds pending anyway |
| **idle / retired / not yet born** | queued; **the activation drain** — when `agent_run`/`agent_spawn` activates a session whose `sessionmeta.team` is set, it does `comp.request("team", "drain", {member: sessionId})` *before* the turn; the returned mail is prepended to the activation content as `Team mail (n): …` and `deliveredVia: "activation"` | exactly-once per activation, mark-at-drain; residual window (marked, then activation request dies before the runner persists the turn) → the lead sees the activation failure and its retry re-briefs; documented, not pretended away |
| **the lead** (a human conversation) | pull: `team_inbox` returns pending lead-mail as a tool result — append-only history, cache-read thereafter — and marks it | exactly-once |

No auto-wake in v1: a message never *starts* anything; the lead's model
decides, then wakes with `agent_run {session: …}`. (dsh's "a member that is
not loaded receives its messages when it wakes" is the same contract; their
auto-residency is phase 2.) A teammate replies via the same `team_send` —
including `to: "lead"`, which waits in the lead's inbox; the natural reply
path is just the activation's final reply, which only the activation caller
sees — so a teammate woken by teammate B answers `team_send`-wise, and B
reads it via its own next-activation drain. Odd at first, durable at rest.

### Tools (new component `team`; all `onDemand`, zero prefix cost)

- **`team_create {name, role, sessionId?}`** — Hire a named teammate: *reserve
  a unique lowercase name under this conversation's team, create the
  persistent child session (fresh, or forked from this conversation's
  history — the `fork` param of §3, passed straight through), record role and
  the team workdir (this conversation's workspace, resolved from its
  conversation header — so teammates literally share the lead's working
  directory and a reviewer sees the lead's diff). Returns the teammate's
  `sessionId` for `agent_run {session: …}`. Does not run a turn.*
- **`team_send {to, body, wake?}`** — Send a durable, in-order message to a
  teammate (`to: "<name>"`) or to the lead (`to: "lead"`). *Queued
  immediately (survives crashes); if the recipient is mid-turn it also
  arrives live via steer. `wake: true` is advisory — it means "the recipient
  probably has pending work"; the lead still wakes it with `agent_run
  {session: …}`. Messages never wait on the bus: the record is durable
  before any delivery is attempted.*
- **`team_list`** — Roster + residency + pressure. *Names, roles, derived
  status (running = runner in the catalog; idle = otherwise), last
  activation, pending-message counts per member. Use before deciding who to
  wake.*
- **`team_inbox`** — Drain the lead's own pending mail (tool result;
  marks delivered). Teammates never need this — their mail arrives
  transcript-embedded at activation; this tool exists so the human-driven
  conversation loses nothing.

The fabricated team tools enter sessions the way every other capability
does: progressive discovery by default (`discover` + `invoke`; sticky
`invoke` promotion = the documented one-time `reset:tools`), or a tools
profile for team-centric conversations — frozen at conversation start,
which is the sanctioned prefix. Nothing new invents a prefix contributor.

### What we deliberately do not take (phase 2+)

- The **task board**: task DAG, compare-and-set revisions, CAS-advisory write
  scopes. Our mailbox + the lead's judgment covers lead-and-helpers; the
  board earns its `kind` when someone runs three teammates without a lead
  holding the plan. (When it comes: kind `teamtask`, written by `team`,
  read by everyone, CAS via record rev — barrel is single-writer, so CAS is
  a compare-and-put in one component. That's the one place our KV store
  genuinely smiles.)
- Auto-residency / auto-wake; member-side interrupts (lead-only, via
  `agent_stop`, which already works on any teammate's live activation);
  separate workdirs per teammate (dsh also punts on these — good precedent);
  forked teammates *inheritance* beyond §3's `fork` (i.e. no "fork the
  fork"); teammates creating teammates (depth-1).

## 6. Sequencing, effort, tests

| # | deliverable | depends on | effort | contract tests |
|---|---|---|---|---|
| 3 | `fabric {api}` | – | ~1–2 days | `t_fabric`: golden-compile rendered decls; `api` with `name`; unknown-tool error lists known names; digest-mismatch admission hint |
| 1 | continuations | – | ~2–3 days | `t_agent`: continue-after-`done`; kill-then-continue (interrupted→new activation); continuation by non-parent fails closed; frozen controls ignored; `agent_status` shows activation lineage; v1 record lazily coexists |
| 2 | forks | – | ~2 days | `t_agent`: copy→resume proves messages-before-header adoption; `lastK`/`maxChars` budget errors fail closed; provenance in `session_info`; depth-1 unaffected |
| 4 | `team` | 1 (steer lane works today; wake needs 1) | ~1 week | new `t_team`: delivery ordering under two racing sends; drain exactly-once + documented crash window; steer-to-live lane; resurrect-failed-teammate; limits fail-loud; team-component restart keeps queues honest |

Bench: no changes. `expert` component: untouched (its `expert_follow`
precedent is what taught us continuation-cheapness). Docs to touch when, not
before: MANUAL (progressive-discovery note for `team`), REFERENCE.md (the
api-first loop), AGENTS.md (new record kinds, the contributors table).

## 7. Open questions

1. **Concurrent activations.** Two `agent_run {session: X}` at once: the
   runner's pump serializes ("turns never nest"), so the second
   `requestEnvelope` waits — its `timeoutMs` must budget the *first* turn's
   remainder. v1: document it, let the lead's `agent_wait` discipline handle
   it. A later refinement: `agent_run` returns `busy` when the child's
   runner is mid-turn (cheap: one `catalog` probe) — say it in the schema,
   decide at implementation.
2. **Steer-lane duplicates.** A message delivered via steer *and* pending at
   the next drain: today the drain is the mark; a steer-delivered message
   that the live turn *did* record should be visible to `drain` (it can
   check the child transcript's last records) — otherwise the recipient
   reads it twice. Decide: transcript-check (cheap, right) vs "steer marks
   delivered" (lossy). Lean transcript-check.
3. **Teammate → lead, live.** A teammate steering the human conversation
   mid-turn injects into what the human is watching. Feature or noise?
   dsh says feature (any-to-any). Our steer channel is proven; try it, keep
   `team_inbox` as the quiet path.
4. **Fork + team composition** (`team_create {fork: true}` = dsh's "a
   teammate that inherits the lead's completed turns") — works by
   construction once 2 and 4 both land; needs a `t_team` case, nothing more.

## Appendix — what dsh does *not* have that we'd be giving up nothing for

- Process-per-guest and process-per-subagent: fabric's guest runs in a
  rootless, credentialess `fabric-exec` child over framed stdio; a subagent
  is an OS process whose lifetime the supervisor owns. dsh's `run_code`
  trusts a worker thread; our trust boundary is `execve`.
- The stored-program library, artifacts with TTL, the `strings` big-payload
  channel, effect-classified host-side batch scheduling: all shipped, none
  of them stolen back.
- And the honest reverse column: dsh's deny-only monotonic guard stage, its
  spill-policy byte accounting, its Landlock launcher, its cache-aware
  compaction transaction, and its crash-repair closers remain the *better*
  versions of things we either lack or do cruder — those are the earlier
  doc's steals 1–5, unchanged by anything here.
