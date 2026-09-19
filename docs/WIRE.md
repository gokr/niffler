# Wire protocol — Niffler

One page. Versioned, boring, identical on every transport (NATS, stdio/NDJSON
behind pipewrap, future HTTP gateway). JSON everywhere by default; codec
upgrades are per-seam via NATS headers, never a global format.

## Envelope

```json
{
  "v": 1,
  "id": "01J...",          // uuid, every message
  "kind": "call",          // call | result | event | error
  "tool": "bash",          // tool name (call/result/error)
  "args": {"cmd": "ls"},   // tool arguments (call only)
  "payload": {...},        // event payload (event only)
  "error": {"code": "...", "message": "..."},  // error only
  "caller": "tui"          // component name of the call originator (call only;
                            // self-declared routing hint, not an auth claim)
}
```

Rules:

- `call` → `result` (or `error`), matched by `id`. One reply per call.
- `args`/`payload` are JSON values (objects, or anything JSON — array, string).
- Missing fields are omitted, never null. Unknown fields ignored (forward compat).
- Errors: `code` is a stable machine string (`timeout`, `no-tool`, `boom`),
  `message` is human text.
- A request carrying malformed JSON or a non-`call` envelope receives a
  `bad-envelope` error when it has a reply subject. Decodable inputs preserve
  their envelope id in that reply.
- Interactive frontends (UIs) register with `"client": true` in reg.publish.
  A core spawned with `NIF_AUTOSTART=1` (the SDK's `ensureHarness`) exits
  when the last interactive client departs; a manually started core never
  self-terminates.
- Streaming: a caller may send `call` frames, each carrying a chunk, and a
  final `result` frame with `done: true` (custom field). `ev.*` streams
  (LLM tokens) are chunked events on a dedicated subject instead.

## Subjects

```
reg.publish            # component process announces itself on connect
                       #   {name, version, pid, tools: [ {name, schema} ], client?,
                       #    slash?: [SlashCommand]}; repeated logical name +
                       #    identical contract joins its replica group
reg.depart             # {name, pid, ...}, graceful process departure; the logical
                       #   component remains while another replica PID is live
svc.<component>.call   # queue-grouped request/reply (one replica handles each call)
svc.session.<id>.call  # session runner for conversation <id> (queue "session"):
                       #   tool "session" {sessionId, content?, model?, thinking?,
                       #   title?, cwd?, profile?, discovery?, tools?, maxRounds?,
                       #   maxCalls?, maxTokens?, approvals?, limits?, compact?,
                       #   export?, wake?};
                       #   content runs a turn; model-only calls persist/resolve
                       #   selection without inference; model present + empty clears
                       #   the conversation override. thinking (low|medium|high|max,
                       #   empty clears) persists a per-conversation thinking-effort
                       #   selection forwarded to the LLM as reasoning_effort
                       #   (provider-dependent; providers without support never see it).
                       #   approvals?/limits? are the human's mutable conversation
                       #   controls; compact? runs the compactor now (no turn);
                       #   export? returns the exact provider request (no turn);
                       #   wake? runs a notice-only turn — see "Autonomous wake".
                       #   profile names a stored tool profile resolved into the
                       #   direct toolset once, at the first call (unknown names
                       #   fail the call; resumes ignore the argument — the
                       #   snapshot is byte-stable). discovery {…} is an explicit
                       #   client discovery: it runs `discover`, appends the
                       #   schemas as a user message and records them, with no
                       #   LLM turn. tools/maxRounds/maxCalls/maxTokens are frozen per-session
                       #   controls (first call wins, then the conversation header
                       #   carries them across runner resumes): a tool allowlist,
                       #   LLM rounds per turn (1-NIF_MAX_TURN_ROUNDS when explicitly set;
                       #   default 1000), total tool dispatches per
                       #   turn (1-500), and cumulative tokens per turn — budget
                       #   exhaustion ends the turn as a budget-exhausted error.
                       #   approvals/limits are the human's conversation controls
                       #   (see "Conversation controls"): mutable per conversation,
                       #   persisted in the same header — a gate mode (ask|auto) and
                       #   SOFT turn limits (rounds/tokens/seconds) that ask the human
                       #   instead of ending the turn
svc.session.<id>.steer # fire-and-forget event envelope {content} injected into the
                       #   running turn as a user message ("Steer: ..."); folded in
                       #   before the next LLM round or before done (no reply)
svc.session.<id>.advise # turn-bound advisory request/reply (the expert peer,
                        #   research/EXPERT.md): {sessionId, turnId, source, content, ...};
                        #   answered {accepted, reason?} — accepted only while
                        #   that exact turn is live (stale-turn, no-active-turn,
                        #   advisory-limit, duplicate, ...); never queued past it
cancel.<component>     # turn-cancel side-channel (see "Cancellation"): a runner
                        #   publishes an event envelope {sessionId, tool, ts} when
                        #   it abandons an in-flight dispatch; components opt in
                        #   by subscribing and matching sessionId (bash kills the
                        #   command's process group; others drop it)
ev.<topic>             # session.*, catalog.updated, sys.drain, sys.shutdown, log.*
                       # models.updated reports effective model-catalog refreshes
                       # provider.switch selects the global backend; provider.changed
                       # invalidates redacted provider/runtime views
ev.log.<component>     # {component, level, msg, ctx?, at}; SDK log threshold applies
```

## Slash commands (declarative UI surface)

Components declare how interactive UIs (TUIs, web) expose them as slash
commands. The spec is pure data — a UI renders it with its own widgets and
never executes component-supplied code:

```json
SlashCommand = {
  "name": "deploy",          // command word; globally unique like tool names
  "description": "...",      // one line for /help and completion
  "tool": "deploy_run",      // optional; target tool (defaults to name) —
                             //   must be a tool this same component registered
  "params": [                // command-line surface, positional order
    {"name": "env", "kind": "enum",     // kind: string|bool|int|enum (default string)
     "source": {"tool": "deploy.envs", "args": {}},  // value candidates for
                             //   completion; the UI calls this tool lazily on Tab
                             //   (resolved server-side via core.invoke)
     "description": "target environment"},
    {"name": "force", "kind": "bool", "default": false},
    {"name": "mode", "kind": "enum", "values": ["fast", "safe"]}  // inline
                             //   candidates for small enums (no roundtrip)
  ]
}
```

Invocation contract for UIs: parse the command line against `params`
(positional values in order; `name=value` named; bool flags bare or
`=on|off`), then issue a regular `svc.<component>.call` to `tool` with the
resulting arguments object — result/error rendering is the UI's business.

Core validates at registration (bad entries are rejected with a warning and
skipped): command names are `[a-z0-9_-]` and unique across the catalog, the
target tool must be registered by the same component, at most 32 commands
per component and 16 params per command. `source.tool` may live in another
component and is not resolved at registration time.

**Naming convention: namespace by the registering package.** Because the
namespace is global and duplicates are rejected, a package prefixes its
commands with its own component or package name — the MCP bridge registers
`mcp-<server>-<prompt>`, the `synthetic` plugin registers `/synthetic`,
`/synthetic-models` and `/synthetic-search`. A generic verb (`/install`,
`/models`, `/search`) would collide with another installed package's
command and the later registration is silently dropped, so keep the prefix
root equal to the package name.

Checkpoint: on every catalog change core persists the merged table
*first* (store kind `slash`, id `slash`: `{updatedAt, commands: [{name,
description, component, tool, params}]}`), then publishes `ev.catalog.updated`.
UIs read the store first for the last-known table and follow
`ev.catalog.updated` live; the live catalog (`catalog` op `snapshot`, which
now carries each component's `slash` array) remains authoritative. Built-in
UI commands (e.g. `/help`) shadow registered ones with the same name.

Session runners: one conversation = one process. The system harness
(`svc.core.call`, tool `session`) ensures a runner for the session id
(spawns `var/bin/session <id>` if none is alive — presence of component
`session-<id>` in the catalog is the readiness signal) and forwards the
turn to `svc.session.<id>.call`. Clients keep a single stable address
(`svc.core.call`); runners are ephemeral — history lives in the store,
a fresh runner resumes the conversation on the next call.

Session subjects (the runner emits during a turn as
`ev.session.<sessionId>.<kind>` — one subject hierarchy per conversation,
so a client watching one conversation subscribes `ev.session.<id>.>` and
receives only its frames, while observers subscribe `ev.session.>` for
everything — UIs render live from the narrow subscription):

```
ev.session.<id>.turn        # {sessionId, turnId, phase: start|done, content?, error?}
                       #   turn lifecycle; content (the user request) on start.
                       #   turnId identifies the turn — advisory delivery binds
                       #   to it and every session event carries it
ev.session.<id>.assistant   # {sessionId, turnId?, content, provider?, model?,
                       #   context?, usage?}
                       #   complete model text + actual backend metadata per LLM round
ev.session.<id>.status      # {sessionId, turnId?, provider?, providerSource?, model?,
                       #   catalog?, context?, contextSource?, promptTokens?,
                       #   usedTokens?, cache?: {prompt, read, hitRate}}
                       #   resolved turn config and live context occupancy.
                       #   cache reports cumulative provider-reported
                       #   prompt-cache reads (A3; present when the provider
                       #   sends prompt_tokens_details). Also emitted by
                       #   model-only session calls (no inference)
ev.session.<id>.context     # {sessionId, turnId?, promptTokens, usedTokens, context,
                       #   warning?|trimmed?}; context-window pressure
                       #   (75% warn, 90% trim)
ev.session.<id>.retry       # {sessionId, turnId, attempt, maxRetries, delayMs, error}
                       #   a transient LLM failure is being retried after delayMs
                       #   (exponential backoff; NIF_LLM_MAX_RETRIES, default 2).
                       #   Auth/quota/bad-request failures never retry
ev.session.<id>.token       # {sessionId, turnId?, content, reasoning} live token deltas
                       #   (streamed while the model generates)
ev.session.<id>.toolcall    # {sessionId, turnId?, callId?, phase: start|done,
                       #   tool, args, result? | error?, errorCode?}
                       #   start fires before dispatch, done after the result
                       #   (error keeps its legacy string shape; errorCode is
                       #   the stable machine code when known)
ev.session.<id>.steer       # {sessionId, turnId?, content} a steer message was folded in
ev.session.<id>.advice      # {sessionId, turnId?, source, content, reason?} an
                       #   advisory message (svc.session.<id>.advise) was folded in
ev.session.<id>.notice      # {sessionId, turnId?, kind?, content?, jobId?, child?,
                       #   status?} a settlement notice, background process exit,
                       #   or the opening of an autonomous wake turn was folded in;
                       #   `content` is the rendered text UIs show (the durable
                       #   `agentnotice` record carries the summary and the recourse
                       #   to the full reply; see "Settlement notices")
ev.session.<id>.done        # {sessionId, turnId?, reply} or {sessionId, turnId?, error}
```

Wildcards compose: `ev.session.>` observes every conversation's frames,
`ev.session.<id>.>` one conversation, `ev.session.*.token` every token
stream. The payload keeps `sessionId` for clients that subscribe wide.

LLM streaming (adapter → core → UI): the `llm` component emits
`ev.llm.token {sessionId, content, reasoning}` deltas while generating;
core forwards matching deltas for the active turn as
`ev.session.<id>.token` and heals any last-frame race with the final
assistant event (which always carries the complete content). Cancellation:
publish an envelope to `llm.cancel.<sessionId>` to abort an in-flight
streaming call.

Approval subjects (human gate for `x-harness.approval: "always"` tools):

```
svc.approval.<name>.request  # directed request to the interactive component
                             #   that drove the current turn: {id, tool, args,
                             #   sessionId, caller}. Core derives <name> from
                             #   the call envelope's caller field — component
                             #   names are never hardcoded.
ev.approval.request    # broadcast fallback: {id, tool, args, sessionId,
                       #   caller?, fallback: true} — used for direct
                       #   (non-session) calls, or when the driver did not
                       #   ack a directed request within ~1.5s
                       #   (terminal harness prompts instead)
ev.approval.reply      # UI → core: {id, ack: true} when a directed request
                       #   is taken (modal shown), then {id, ok} — the
                       #   decision. Broadcast/direct requests need no ack.
ev.approval.resolved   # core → UIs: {id, ok} gate verdict; clients dismiss
                       #   stale modals for id
```

The `ui` tool (hidden) is the interactive-client registry: `register` /
`renew` / `release` / `claim` / `release_session` / `owner`. Core assigns
monotonic display numbers ("Niffler 1", …) and brokers conversation
ownership between cooperating UIs; an ~20s lease is the liveness signal. A
caller name is self-declared, so this is coordination, not authentication.
The TUIs register unique `tui-<hex>` component names (their approval caller);
the web UI mints one identity per browser tab (`ui-<hex>`) and stamps it as
the `caller` of that tab's session turns, so directed approvals stay per tab
(ui/README.md).

`svc.core.call` is core's own service surface, served by core itself
(queue "core"): tools `session` (hidden from the LLM), `spawn`, `catalog`,
`kill`, `remove`. `catalog` ops: `list` (the name-sorted *direct*
projection — tools without `x-harness.onDemand`/`x-harness.hidden`),
`components` (component→tools view over the full catalog for bus clients
— the CLI reads this authoritative snapshot for catalog, tool lookup, and
registration/install verification; raw `reg.publish` is not acceptance) and
`snapshot` (full registration payloads incl. schemas — session runners
seed their catalog from it at startup, then follow `reg.>` live).
The LLM-facing core tools also include `discover` (hint/schema lookup
over the non-hidden catalog) and `invoke` (generic gateway into any live
non-hidden tool, preserving its approval/timeout policy; `sticky: true`
appends a successful target's schema to the persisted direct toolset —
one durable prefix change, capped by `NIF_MAX_DIRECT_TOKENS`). `profile`
(onDemand) manages the named tool profiles a new conversation resolves
its direct toolset from — see docs/MANUAL.md, section
"Progressive tool discovery".

Core stays responsive while a turn dispatch is in flight: tool calls from
components that land on `svc.core.call` mid-turn (e.g. `plugin_install`
calling `core.spawn`) are served from the dispatch's idle slot, and
concurrent `session` requests are stashed and answered when the turn
ends — turns never nest.

- Presence = connection; component death detected by core via NATS disconnect
  plus `reg.depart` (graceful) vs silence (crash).
- Tool names are unique across the whole catalog — enforced by core at
  registration; conflicting registrations are refused in full. The LLM only
  sees tool names; core maps tool → component at dispatch. The namespace is deliberately
  **flat**, not `component.tool`-qualified: flat names are the LLM's call
  vocabulary (no `edit.edit` noise), and dot-names would break Anthropic-style
  providers that restrict tool names to `[a-zA-Z0-9_-]`. Clash avoidance is by
  convention: **shipped core components own their semantic names** (`read`,
  `edit`, `bash`, ...); **plugin/third-party components prefix every tool with
  the component name** (`stocks_quote`, `weather_current`, `git_status`) so
  independently published packages never collide. Core rejects a clashing
  registration instead of letting two components share a name.
- `ev.sys.drain` (core → component): stop taking new calls, finish in-flight,
  then exit. `ev.sys.shutdown` (component → core): I'm leaving.

## Lifecycle

1. Core boots: spawn NATS if no `NIF_NATS_URL` → read `manifest.yaml` → select
   the boot profile → spawn children (no ordering; ordering emerges from the
   bus). A stateless entry may set `replicas: N` (1–16; default 1), producing N
   queue-group subscribers under one logical component name. Normal mode uses
   the manifest; `--minimal` filters it to `store`, `bash`, and `llm` and skips
   restoration of persisted spawned components.
2. Each component process connects and publishes `reg.publish` with its tool
   schemas. Core tracks all live PIDs for an identical logical registration;
   `catalog {op: snapshot}` exposes `pids` and `replicas`, while `core.status`
   also exposes `runningReplicas`.
3. Core converges when the selected profile's required set has registered
   (normally the manifest's required entries; `store`, `bash`, and `llm` in
   minimal mode). Every new registration is announced as
   `ev.catalog.updated` with the direct projection (same shape as
   `catalog {op: list}`). Each conversation freezes its direct toolset at
   first turn — late registrations reach an existing conversation through
   `discover` + `invoke`, not schema churn.
4. Teardown = exit; the OS is the disposer. Core drains children in reverse
   registration order: `ev.sys.drain` → grace period → SIGTERM → SIGKILL.

## Cancellation

No transport-native cancellation in NATS. Two implemented cancel paths:

- `llm.cancel.<sessionId>` — aborts that session's in-flight provider
  request (see `components/llm/main.go`).
- `cancel.<component>` — published by a session runner when a turn cancel
  lands while a tool dispatch is in flight (event envelope
  `{sessionId, tool, ts}`). Components opt in by subscribing their own
  subject and matching `sessionId` against the injected `__session.session`
  private context (`x-harness.sessionId`); bash kills the running command's
  process group (exit 130), mcp-bridge aborts the in-flight MCP call —
  the MCP server's `notifications/cancelled`-equivalent (its per-call
  context) fires immediately. fabric subscribes `cancel.>`: a fabric
  program's bridge calls are dispatched for it by the session runner, so a
  stop that lands while a NESTED call is in flight arrives on that call's
  component subject — the fabric run still terminates its guest
  (`fabric-exec`), reports a cancelled outcome, and dispatches nothing
  further. agent cancels the child of an in-flight `agent_run` whose parent
  turn was stopped. Direct callers (CLI scripts) see
  `""` for `__session.session` and cannot spoof a session id. Components
  without a subscription drop the message and run to completion or deadline —
  request/reply callers that stop waiting only abandon the reply; the target
  work is not stopped. A generic `ev.cancel.<call-id>` subject remains a
  possible future addition.

## Settlement notices

A background subagent (`agent_spawn`) that reaches a terminal state writes a
durable `agentnotice` record and delivers it to its **parent conversation** —
not just to UIs (`ev.agent.done` is observe-only). Rationale and design:
docs/research/SUBAGENTS-PLAN.md P0.1.

**Background processes use the same lane** (components/processes): a tracked
child that exits publishes a notice with `kind: "process-exited"` — and
delivers it on exactly the same subject, so the runner folds it in as
append-only history and nothing new is subscribed. It is a pointer too: the
process id, its status, how long it ran and how many bytes of output exist;
the output itself stays in the spool for `process_poll`, and the command text
never travels. It exists because *nothing reaped a child except a tool call*:
an exit was invisible until someone happened to poll, so finished background
work sat unnoticed. The reap is now periodic (the SDK's `onIdle`), which is
what makes the notice possible — and stops `process_list` from reporting a
finished child as running.

The one asymmetry with the agent's notice: no durable record backs it (the
process entry itself is the record). A process whose owning conversation has
no live runner, or whose runner is gone by the time it exits, is announced to
nobody — the entry stays pollable, so the fallback is asking.

Record (store kind `agentnotice`, id `<parentSession>:<zero-padded seq>`):

```json
{ "v": 1, "parent": "conv-…", "jobId": "job-…", "child": "agent-…",
  "status": "done|failed|stopped",
  "summary": "<bounded head of the reply, ≤400 chars; absent when the job
                produced no reply>",
  "replyBytes": 12345,
  "fullReplyIn": "agent_status",
  "createdAt": 1765400000.0,
  "deliveredAt": 1765400001.0, "deliveredVia": "wake|pull" }
```

The notice is a **pointer, not the reply**: `replyBytes` counts the
untruncated reply and `fullReplyIn` names the tool that returns it, because
the full reply is already durable in the `agentjob` record (`agent_status`
returns it). A model told only "your subagent finished" does not know to make
a second call; the pointer is what makes the summary a delegation rather
than a loss. Same convention as the tool-spill paths (`bash`, `mcp`, `fetch`).

Delivery is two-lane by **parent state**, and the durable record is written
before either is attempted:

- **parent runner mid-turn** → the steer subject
  (`svc.session.<parent>.steer`) with a `notice` payload object instead of a
  `content` string. The runner queues it separately from user steer and
  folds it in as a structurally marked user message — it is runtime
  machinery about a subagent, never something the human typed.
- **otherwise** (idle, retired, or no runner) → **the agent component wakes
  the parent** (below); if that is declined the notice stays pending and the
  parent's next turn pulls every pending notice at the top of the turn
  (alongside steer and advisories), marking it `deliveredVia: "pull"`.

Taking the pushed lane first is what prevents double delivery. Notices are
best-effort throughout: a store or agent-component failure costs a notice,
never a turn, and a completed job is never turned into a failed call.
`agent_notices {session?, peek?}` drains manually (on demand) for callers
that want to look without waiting for a turn.

### Busy-parent inbox (a turn cannot close over a settlement)

A settlement that lands while the parent's turn is live takes the steer lane
and is folded at the next step — and the would-stop point drains notices the
same way it drains steer and advisories, so a child that finished during the
model's final response keeps the turn alive for one more step instead of
waiting for the human to come back. Every notice waiting in the two lanes
folds in **one** drain: a burst of N settlements costs one extra step, not
N. `NIF_AGENT_NOTICE_HOLD=0` disables only this hold — the notices then stay
pending for the next turn's opening drain (the scripted bus-contract suites
pin it off for deterministic round counts; `tests/t_agentwake.nim` pins the
default behavior with a stub that injects the notice mid-answer).

### Autonomous wake

An **idle** parent must not wait for the human to ask. When a child settles
while its parent has no live turn, the agent component wakes the parent:
it publishes a `session` call with `{sessionId: <parent>, wake: true,
content: "[wake] …"}` and a dropped reply (fire-and-forget — a wake turn
runs as long as any turn, and the component must keep serving tool calls
while it does). Core ensures the parent's runner exactly as for a UI call.

The runner admits a wake only when all of these hold, and **persists nothing
on a decline**:

- `NIF_AGENT_WAKES` is non-zero (0 disables wakes);
- pending notices exist (`agent_notices {peek: true}` count is non-zero) —
  a wake with nothing to fold is `wake: "skipped"`;
- the **consecutive-wake budget** has room: at most `NIF_AGENT_WAKES`
  (default 3) trailing wake turns since the last real user message. The
  budget is derived from stored history (a wake turn persists a user message
  marked `notice.kind: "wake"`; machinery messages neither count nor reset
  it), so it survives runner restarts with no counter to lose. A declined
  wake returns `{wake: "declined", reason: "budget"|"wakes disabled"|
  "notices unreachable"}`.

An admitted wake runs a normal turn whose user message is structurally
marked:

```json
{ "role": "user", "content": "[wake] background subagent settled…",
  "notice": { "kind": "wake" } }
```

so rendering, trimming and compaction treat it as runtime machinery, and the
request prefix is untouched (append-only history). The turn's opening drain
folds the pending notices, the model answers, and the conversation has
visibly moved on — without a human message. A declined or skipped wake
leaves the notice pending for the next real turn (never lost); the human's
next message resets the budget.

The process-exited lane has no waker (a process notice is announced on the
same subject but nothing wakes for it): its fallback remains the next turn's
pull drain.

## Subagent continuation (`agent_run`/`agent_spawn {session}`)

Both drivers accept `session`: a previously returned `sessionId` gives that
EXISTING child another turn instead of minting a fresh one. Design and
testing: docs/research/SUBAGENTS-PLAN.md P1.3.

- **Authorization is the durable lineage relation**: the child's
  `sessionmeta.parent` must equal the caller's session. Unknown sessions,
  root conversations (a lineage record with no `parent`), foreign children,
  closed children and an unreachable store all refuse with distinct errors —
  fail-closed, never a silently fresh child.
- **Frozen controls**: model, thinking, tool allowlist and budgets were
  frozen into the child's conversation header at its first turn. A
  continuation sends content only (no preamble, no system prompt) — the
  caller's model/thinking/tools/budget arguments are ignored by
  construction, and the synchronous result carries the child's `effective`
  controls as a readback. This keeps the child's cached request prefix
  stable (append-only history).
- **Busy semantics by promise**: `agent_run {session}` promises a result
  now, so a mid-turn child is refused with `code: "busy"` (naming
  `agent_spawn` to queue or `agent_wait`/`agent_status` for the current
  turn). `agent_spawn {session}` promises the work happens, so it queues —
  the child's runner serializes turns. The busy check runs AFTER
  authorization, because the caller itself is always "mid-turn" while its
  own `agent_run` executes.
- **Activation ledger**: each accepted turn advances
  `sessionmeta.activations` (1-based; the first turn counts as 1) and sets
  `firstActivationAt` once. Background continuations stamp `continued` and
  `activation` on their `agentjob` record (the completion tap preserves
  them when it terminalizes the record).
- **Close**: `close: true` marks the child retired (`sessionmeta.closed`)
  AFTER its turn — synchronously in `agent_run`, via the job's completion
  tap in `agent_spawn`. Nothing is deleted (record + transcript survive for
  forensics); only further continuation refuses.

## Subagent fork (`fork: true | {lastK} | {maxChars}`)

On fresh spawns only — a fork is a birth, not a continuation (`fork` +
`session` is refused). The child's message log is seeded with the CALLER's
completed turns before its first request, so the child has READ the
conversation instead of being told about it. Design and testing:
docs/research/SUBAGENTS-PLAN.md P1.4 (DSH-STEAL §3).

- **The seed is contiguous-from-0 and replay-valid**: `balancedPrefixLen`
  walks the transcript with a pending-tool_calls count and stops at the
  first record that breaks the provider invariants (a user message over
  unanswered calls, an orphaned tool record, a closing assistant over
  unanswered calls); a tail ending with pending calls is cut before the
  dangling assistant. Blocks within that prefix open at a user message and
  close at an assistant with no `tool_calls` — a steered turn's extra user
  messages fold into the same block. The fork copies whole blocks only, so
  the child's first request can never carry a dangling `tool_call_id`.
- **The one store-ownership exception**: this is the documented case where
  `agent` writes `message` records (core otherwise owns that kind). Safe
  because it is a one-time COPY written before the child's runner exists —
  no concurrent writer for that session id, no lost-update window — and the
  child's `seqNo` continues AFTER the copied ids (`loadStoredMessagesEx`
  derives it from the highest stored id). The copy site in
  `components/agent/main.nim` carries the ownership comment.
- **Not copied**: per-message `usage` (the child's meters are its own —
  born cold), `summary`/`error` roles (a summary is a derivation of records
  copied raw; errors are the parent's audit), the `<session>:tools` toolset
  snapshot, and the header's control fields. The forked child's frozen
  controls come from THIS call (a birth), not from the source conversation.
- **Fork × compaction** (the gate is satisfied — compaction landed): a
  forked child receives the parent's **raw transcript**, which may be
  LARGER than the parent's current live context — compaction's projections
  are checkpoint nodes (`<convId>#ck<gen>`, outside the message kind) and
  are never copied, and the child's ledger is rebuilt from the copied
  records on its first resume. The child's own compaction then shrinks it
  on its own schedule. Read-visibility framing: a fork is a reader of
  records the parent may no longer hold in context — that is the point
  (the child gets the real history, not the parent's summary of it).
- **Provenance before the first turn, fail-closed**:
  `sessionmeta[child] = {parent, fork: {source, uptoId, copied}}`, surfaced
  by `session_info` as `fork`. A budget (`lastK`/`maxChars`) that drops
  everything fails closed — never an empty child.
- **Cache effect**: born cold (the first request replays the history
  uncached; warm from the second turn). The tool descriptions say this,
  because the cost is otherwise surprising — and point bulk mechanical
  transfer at `fabric`.

## Delegation depth (`NIF_AGENT_MAX_DEPTH`)

Delegation depth is capped by `NIF_AGENT_MAX_DEPTH` (default **1** —
subagents cannot spawn subagents). The cap is evaluated at dispatch time
(`core/dispatch.nim`, where the session-context gate lives) by a **depth
walk** over `sessionmeta.parent` links from the calling session to a root:
a root is depth 0, children 1, grandchildren 2 — a spawn is denied when
`depth >= cap`. `0` forbids delegation entirely (even a root may not
spawn). The walk is bounded by the cap + 2 reads (a corrupt lineage cycle
exceeds the cap and is denied) and fails closed when the lineage store is
unverifiable.

The spawn-class tool stays **visible at the cap** — each start rejects
with an errored result naming the limit and the caller's depth
(`subagent depth 1 exceeds NIF_AGENT_MAX_DEPTH=1 (subagents cannot spawn
subagents)`), so the model learns why instead of finding a hidden tool.
The component enforces the same rule a second time at its own trust
boundary (defense in depth; core's dispatch gate is the primary).

**Raising the cap above 1** changes the trust shape and needs the nested
synchronous path to work: a child's synchronous `agent_run` arrives at the
agent component while the parent's synchronous `agent_run` holds the
component's pump — so `requestChildTurn` serves queued calls re-entrantly
(`pumpCallsReentrant` in the SDK), depth-bounded by the same cap. Each
level blocks in its own downstream wait; handler state is per-call.

## Nested-call leases (keyed)

The nested-call proxy validates requests against the lease a
session-context dispatch granted. Leases are **keyed by id** — each
session-context dispatch registers its own lease (with its own deadline)
and removes exactly that key on exit:

- two overlapping session-context dispatches can neither clobber nor
  prematurely restore one another (the old single-string lease was the
  latent hazard that made parallel session-context dispatch unsafe);
- a lease's validity window gates everything else: an expired outer call
  is denied (`expired`) before tool resolution or argument validation;
- an unknown, stale or empty lease reads `bad-lease`; no live turn reads
  `no-session`;
- a completed dispatch's lease is dead immediately, and leases never
  outlive their turn (cleared at turn end).

The wave scheduler still refuses `sessionContext` tools — serial dispatch
is fine (children are what run in parallel) — but the invariant "leases
are per-call" now holds regardless of future dispatch policy.

## Approvals

Dispatch honors `x-harness.approval` on the tool schema (docs/research/REBOOT.md,
"policy rides the schema"): a tool marked `"always"` is held until a human
answers. Terminal harness: y/N prompt on stdin. Service mode: the request
is routed to the interactive component that drove the current turn — its
private subject `svc.approval.<name>.request` (name from the envelope's
self-declared `caller`, never hardcoded). The driver acks on
`ev.approval.reply` (a human is being asked) and answers `{id, ok}`.
When the driver does not ack within ~1.5s (crashed, or not interactive)
the request is rebroadcast on `ev.approval.request` with `fallback: true`
so any attached interactive client can step in; direct (non-session) calls
broadcast immediately. The gate verdict is published on
`ev.approval.resolved` so other clients dismiss stale modals. Timeout →
denied. No human reachable → deny. `NIF_AUTO_APPROVE=1` bypasses.

## Conversation controls (`/approvals`, `/limit`, `/compact`)

Per-conversation controls belong to the human, never to the model, and ride
the ordinary session call (`svc.session.<id>.call`, tool `session`):

```json
{"sessionId": "conv-…", "approvals": "auto"}
{"sessionId": "conv-…", "limits": {"rounds": 20, "tokens": 50000, "seconds": 600}}
{"sessionId": "conv-…", "compact": true}   // run the compactor now, no turn
{"sessionId": "conv-…"}                    // status readback, runs no turn
```

- **`approvals`** is this conversation's gate mode: `""`/`"ask"` (the
default) gates every `x-harness.approval` tool as described above; `"auto"`
grants them without asking any client, loudly (`core: approval auto-granted
for <tool>`) — a silent grant is exactly what the gate exists to prevent.
It applies from the NEXT turn on and, unlike the frozen scoping arguments,
may be changed at any point in a conversation's life.
- **`limits`** are SOFT budgets: `rounds` (LLM rounds per turn, 1–200),
`tokens` (cumulative per turn) and `seconds` (wall clock per turn, checked
before every dispatch as well as at round boundaries — one bash call can
outlast a whole round). Each key is optional and independent; an empty
object clears all three. Job-scoped budgets — `maxRounds`/`maxCalls`/
`maxTokens` (what the `agent` component freezes into a child's header) and
`NIF_MAX_TURN_ROUNDS` — remain HARD: they end the turn and never ask, because
a subagent must not be able to negotiate its own budget.
- **`compact`** runs the same replaceable-compactor rung the automatic ladder
runs at pressure, explicitly: the compaction component proposes a checkpoint
over a permitted cut, core validates and installs it atomically, and the
usual `reset:compact` context event follows — with no LLM turn and no user
message. The reply is `{ok, compacted: true, beforeTokens, afterTokens,
generation}` or `{ok, compacted: false, reason}` (no compaction component
configured / compactor declined / no permitted cut). A decline is explicit —
it never silently degrades to lossy trim.
- **Reaching a soft limit asks the human.** The question travels the approval
transport on the same routing (directed to the driver, then broadcast), with
`tool: "turn-limit"`, `purpose: "continue"` and
`args: {dimension, detail}` — `dimension` is `rounds`/`tokens`/`seconds`,
`detail` is a human-readable "3 LLM rounds (limit 2)". The answer is the
existing `ev.approval.reply` (with the usual `{id, ack: true}` first):
`ok: true` extends THAT limit by one more step and the turn continues;
`false`, no answer or no reachable human ends the turn with a distinct error
record (`error: "limit-<dimension>"`) naming the limit and the command that
raises it. `NIF_AUTO_CONTINUE=1` (or `NIF_AUTO_APPROVE=1`) answers yes
without a human, for headless automation.
- The `approvals` and `limits` settings are persisted in the conversation
header (`approvals`, `limits`), so a resumed runner re-applies exactly what
the human last chose, and both are echoed by the status readback and the turn
result (`approvals`, `limits`) for UIs. Invalid values are refused with a
clear error (unknown mode, unknown limit key, out-of-range value).

### Session calls during a turn

The runner is single-threaded and a turn must never nest, so a session call
that arrives while a turn is running is refused **immediately** with
`{code: "busy"}`, message `the conversation is mid-turn — retry when the turn
finishes`. It used to stay silent until the turn ended, which made any client
with a deadline report a generic timeout ten seconds in (`/export` waits 10s
and looked like a hang).

The refusal is answered by whichever layer the caller reaches, and the two
layers split by what losing the call would cost:

- **`svc.core.call` (what UIs use)** — core is mid-dispatch for the running
turn, so its idle-slot pump (`pumpCoreWhileBusy`) sees the call first. A
**content-less** session call (the status readback, `/export`, a control
change) is refused `busy` on the spot: it is cheap to retry, and stashing it
only produces the client-side timeout. A **turn-starting** call (content
present) is still *stashed* and drained once the turn ends, because a user's
message must never be dropped, and the runner would refuse it anyway.
- **`svc.session.<id>.call` (a client addressing the runner directly)** — the
runner's own idle-slot pump (`pumpBusyCall`, `ct.callSub`) refuses everything
it sees mid-turn with the same `busy`, since serving any of it would mean
re-entering the session handler while the running turn owns the context.

Both pumps answer within milliseconds; a caller that ignores `busy` and keeps
waiting will still hit its own deadline. `agent_run`'s refusal of a mid-turn
child uses the same `busy` contract.

## x-harness schema extensions

Tool schemas may carry an `x-harness` object (docs/research/REBOOT.md,
"policy rides the schema") that the session runner honors at dispatch. Known
keys:

- `approval`: `"always"` gates the call on a human (see Approvals).
- `timeoutMs`: per-tool request timeout (default 120s).
- `hidden`: tool invisible to the LLM catalog (e.g. `chat`, `session`).
- `onDemand`: kept out of a conversation's frozen direct toolset; reachable
  via `discover` + `invoke` (docs/MANUAL.md, "Progressive tool discovery").
- `runner`: when `true` on a `hidden` tool, exempts internal runner machinery
  from a conversation's frozen tool allowlist. This is how replaceable
  `chat`, model-resolution, compaction, and recall tools remain available to
  restricted subagent sessions without hardcoding their names in core.
  `runner` does not expose the tool and is ignored unless `hidden` is also
  true.
- `sessionContext`: the call runs in the live conversation (fabric, agent);
  the runner injects `__session` context and a nested-call lease.
- `sessionId`: the runner injects `__session.session` (the live session id,
  `""` for non-session callers) so the component can match
  `cancel.<component>` events against its in-flight work (see Cancellation).
  Carries no lease and does not fail closed, so a read-only tool may also use
  it purely to learn its caller (`agent_list`, `agent_notices` do); core
  overwrites any client-supplied `__session` for such tools at
  dispatch — the key is core-owned private context, never caller data.
- `effect`: `"read"` or `"write"` (default) — how the fabric batch host
  schedules items (reads fill the concurrency cap together, writes run
  exclusively).
- `workspace`: path-shaped arguments are resolved against the conversation
  workspace at dispatch. Such tools also receive core-owned private context
  `__workspace = {root, roots}` — the conversation's **workspace set**: the
  primary workspace plus its linked git worktrees (`git worktree list`) and
  sibling checkouts of the same `remote.origin.url` (core/workspace.nim;
  bounded by `maxWorkspaceRoots`, currently 8). It exists
  so a component can recognize work in another tree of the same project
  instead of treating it as "outside the workspace" — `lsp` indexes a file in
  a declared root as *that* tree. Like `__session`, it is injected after the
  model's message is written and never rendered into the frozen system prompt
  or a tool schema: worktree awareness must not cost a cache miss, and a
  worktree appearing mid-conversation is picked up on the next dispatch.
- `noSpawn`: a subagent (a session with a parent lineage record) may not call
  this tool (depth guard enforced at dispatch).
- `parallel`: `true` marks the tool safe to dispatch **concurrently** with
  other `parallel`-marked tools in the same assistant message. The runner
  fans out the batch over the bus and reassembles results in call order.
  Default (absent/`false`) is strictly serial — which is also enforced for
  any tool carrying `approval: "always"` or `sessionContext: true`, whatever
  `parallel` says. `parallel` is a *runner-side* scheduling hint: it does not
  by itself make one process execute two handlers concurrently. Server-side
  execution is an independent, explicit component choice: stateless services
  can use process replicas; audited Go handlers can register with
  `ToolConcurrent`; a Nim component may own native workers even though the
  default SDK pump remains serial. The NATS queue group on
  `svc.<component>.call` distributes one call per process subscriber.

## Self tests (`selftest`) and `/doctor`

Every component may register a hidden tool **`selftest`** (SDK: `selfTest()`,
both SDKs) — a component checking its own wiring, on core's behalf:

- input: `{deep: bool, default false}` — quick mode must stay cheap (no
  spawns, under ~10s: configuration, binary resolution, own-store sanity);
  `deep` runs live end-to-end probes and may spawn real processes (e.g. the
  lsp component boots every configured language server against fixtures).
  Callers pick the timeout: `deep` legitimately takes minutes.
- result: `{ok: bool, summary: string, checks: [{name, ok, detail, ms}]}` —
  one entry per check, `ms` the per-check duration; `ok` is false when any
  check failed. The canonical `{ok, error}` envelope conventions still apply
  for transport-level failures.

Components without a selftest tool are not broken — the mechanism is
opt-in; `/doctor` reports them as not implementing one.

Catalog note: tool names are unique across the harness (discover/invoke
dispatch by bare name), but `selftest` is deliberately exempt — it exists
on every implementing component by design, is hidden, and is addressed
per subject (`svc.<component>.call`) by `/doctor`, never by bare name.

**`/doctor`** (core tool `doctor`, also a declarative slash command) is the
user entry point: core's own read-only probes (bus, store, llm/provider,
systemprompt, catalog size, conversations) plus a **self-test fan-out** —
a `selftest` request to every registered component that implements one
(skipping core itself and UI clients), results collected under
`selftest: [{component, ok, summary, checks}]`. The fan-out is sequential
(core serves one call at a time) with a per-component timeout (10s quick /
120s deep); a timeout or transport error is a failed check, never a crash.

## Store contract (`svc.store.call`)

The store's bus contract is the artifact; every engine implements exactly
these tools (docs/MANUAL.md "Store engines"). `put` / `get` / `del` carry
`{kind, id, value?, expectRev?}`; docs are opaque JSON, ids sort
lexicographically, and `expectRev` gives optimistic concurrency
(`rev-conflict` on mismatch).

`list` takes `{kind, idPrefix?, limit?, after?}` and returns
`{ok, items: [{id, rev, value}], hasMore, nextAfter?}`.

**`list` is a page, not a complete view.** `limit` is capped at 1000. When
more documents follow, the reply carries `hasMore: true` and `nextAfter`
(the last returned id); pass it back as `after` to continue. `after` is a
strictly exclusive cursor — the id equal to `after` is never returned — and
it advances by *key*, so a page whose documents are all tombstoned still
moves forward rather than stranding the caller. A caller that needs the
whole kind loops until `hasMore` is false or `nextAfter` is absent.

Core's own full-kind reads (session resume, `session_info`,
`conversation_delete`) use `storeListAll` (core/dispatch.nim; the SDK
exposes the same helper) rather than a single call, because a capped read
silently truncated a resumed transcript at 1000 messages and the next
write then targeted an existing id.

## Conventions

- Component names: lowercase, hyphens (`hashline-edit`). Tool names: lowercase,
  letters/digits/underscore (LLM function-calling grammar).
- Tool results are JSON values. A result object carrying a string `text`
  field is the LLM-facing rendering: session runners put `text` verbatim
  into the tool message (`role: "tool"`), and nothing else from the result
  reaches the transcript. Every other field is machine data for bus
  consumers — fabric programs, tests, UIs, plugins — and must stay stable
  even when the `text` wording changes. Text-oriented tools follow the
  `(exit N)` status-line convention as the first line of `text` (non-zero =
  failure) and repeat the same facts in structured fields (`exit_code`,
  `cancelled`, `spill`, ...). A bare-string result is rendered as-is; a
  result without `text` is serialized into the transcript unchanged.
  One `userMessage` convention rides the same machine-data rule: a result
  object carrying `userMessage` (string) asks the *client UI* to render
  that string as a user-authored message (MCP prompt templates, e.g.
  `mcp-<server>-<prompt>` slash commands) — it never enters the transcript
  as system or assistant content, and it is not required for the result to
  carry `text` alongside.
- Big payloads (tool output > ~64KB): reference, never inline —
  `{"ref": "store://bucket/key"}`; JetStream Object Store later, filesystem
  under `var/store/` for milestone 1.
- One message = one envelope. NDJSON for stdio streams (pipewrap) — same
  codec, line-delimited.
- One envelope still has to fit the NATS `max_payload`. Core spawns the
  bundled `components/nats` build with `--max_payload 8388608` (8MiB — a
  Niffler flag extension; the official binary only accepts it via config
  file) because an `llm` `chat` request carries the whole conversation. A
  PATH `nats-server` fallback (hand-compiled dev runs) gets the same 8MiB
  via a generated config file — verified against the official binary; a
  stock 1MiB cap makes oversized publishes time out instead of failing
  loudly. Core also checks the connected bus's cap at boot and warns when
  it is below the harness's 8MiB. A publish over the cap fails and
  reports the size against the server's `max_payload`.
