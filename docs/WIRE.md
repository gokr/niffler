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
                       #   tool "session" {sessionId, content?, model?, thinking?};
                       #   content runs a turn; model-only calls persist/resolve
                       #   selection without inference; model present + empty clears
                       #   the conversation override. thinking (low|medium|high,
                       #   empty clears) persists a per-conversation thinking-effort
                       #   selection forwarded to the LLM as reasoning_effort
                       #   (provider-dependent; providers without support never see it)
svc.session.<id>.steer # fire-and-forget event envelope {content} injected into the
                       #   running turn as a user message ("Steer: ..."); folded in
                       #   before the next LLM round or before done (no reply)
svc.session.<id>.advise # turn-bound advisory request/reply (the expert peer,
                        #   EXPERT.md): {sessionId, turnId, source, content, ...};
                        #   answered {accepted, reason?} — accepted only while
                        #   that exact turn is live (stale-turn, no-active-turn,
                        #   advisory-limit, duplicate, ...); never queued past it
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

Session subjects (core emits during `svc.core.call` session turns — UIs
subscribe `ev.session.>` and render live):

```
ev.session.turn        # {sessionId, turnId, phase: start|done, content?, error?}
                       #   turn lifecycle; content (the user request) on start.
                       #   turnId identifies the turn — advisory delivery binds
                       #   to it and every session event carries it
ev.session.assistant   # {sessionId, turnId?, content, provider?, model?,
                       #   context?, usage?}
                       #   complete model text + actual backend metadata per LLM round
ev.session.status      # {sessionId, turnId?, provider?, providerSource?, model?,
                       #   catalog?, context?, contextSource?, promptTokens?,
                       #   usedTokens?}
                       #   resolved turn config and live context occupancy.
                       #   Also emitted by model-only session calls (no inference)
ev.session.token       # {sessionId, turnId?, content, reasoning} live token deltas
                       #   (streamed while the model generates)
ev.session.toolcall    # {sessionId, turnId?, callId?, phase: start|done,
                       #   tool, args, result? | error?, errorCode?}
                       #   start fires before dispatch, done after the result
                       #   (error keeps its legacy string shape; errorCode is
                       #   the stable machine code when known)
ev.session.steer       # {sessionId, turnId?, content} a steer message was folded in
ev.session.advice      # {sessionId, turnId?, source, content, reason?} an
                       #   advisory message (svc.session.<id>.advise) was folded in
ev.session.context     # {sessionId, turnId?, promptTokens, usedTokens, context,
                       #   warning?|trimmed?}; context-window pressure
                       #   (75% warn, 90% trim)
ev.session.done        # {sessionId, turnId?, reply} or {sessionId, turnId?, error}
```

LLM streaming (adapter → core → UI): the `llm` component emits
`ev.llm.token {sessionId, content, reasoning}` deltas while generating;
core forwards matching deltas for the active turn as `ev.session.token`
and heals any last-frame race with the final assistant event (which
always carries the complete content). Cancellation: publish an envelope
to `llm.cancel.<sessionId>` to abort an in-flight streaming call.

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

`svc.core.call` is core's own service surface, served by core itself
(queue "core"): tools `session` (hidden from the LLM), `spawn`, `catalog`,
`kill`, `remove`. `catalog` ops: `list` (the name-sorted *direct*
projection — tools without `x-harness.onDemand`/`x-harness.hidden`),
`components` (component→tools view over the full catalog for bus clients
that missed the registrations — the cli seeds its catalog from it) and
`snapshot` (full registration payloads incl. schemas — session runners
seed their catalog from it at startup, then follow `reg.>` live).
The LLM-facing core tools also include `discover` (hint/schema lookup
over the non-hidden catalog) and `invoke` (generic gateway into any live
non-hidden tool, preserving its approval/timeout policy) — see
docs/MANUAL.md, section "Progressive tool discovery".

Core stays responsive while a turn dispatch is in flight: tool calls from
components that land on `svc.core.call` mid-turn (e.g. `plugin_install`
calling `core.spawn`) are served from the dispatch's idle slot, and
concurrent `session` requests are stashed and answered when the turn
ends — turns never nest.

- Presence = connection; component death detected by core via NATS disconnect
  plus `reg.depart` (graceful) vs silence (crash).
- Tool names are unique across the whole catalog — enforced by core at
  registration, rejected with an error envelope. The LLM only ever sees tool
  names; core maps tool → component at dispatch. The namespace is deliberately
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

No transport-native cancellation in NATS. Components that care subscribe to
`ev.cancel.<call-id>` on call start and check it between output chunks.
Core publishes it on user cancel. ~10 lines in the SDK.

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

## x-harness schema extensions

Tool schemas may carry an `x-harness` object (docs/research/REBOOT.md,
"policy rides the schema") that the session runner honors at dispatch. Known
keys:

- `approval`: `"always"` gates the call on a human (see Approvals).
- `timeoutMs`: per-tool request timeout (default 120s).
- `hidden`: tool invisible to the LLM catalog (e.g. `chat`, `session`).
- `onDemand`: kept out of a conversation's frozen direct toolset; reachable
  via `discover` + `invoke` (docs/MANUAL.md, "Progressive tool discovery").
- `sessionContext`: the call runs in the live conversation (fabric, agent);
  the runner injects `__session` context and a nested-call lease.
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

## Conventions

- Component names: lowercase, hyphens (`hashline-edit`). Tool names: lowercase,
  letters/digits/underscore (LLM function-calling grammar).
- Big payloads (tool output > ~64KB): reference, never inline —
  `{"ref": "store://bucket/key"}`; JetStream Object Store later, filesystem
  under `var/store/` for milestone 1.
- One message = one envelope. NDJSON for stdio streams (pipewrap) — same
  codec, line-delimited.
