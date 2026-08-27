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
reg.publish            # component announces itself on connect
                       #   {name, version, pid, tools: [ {name, schema} ], client?}
reg.depart             # same shape (name suffices), graceful shutdown
svc.<component>.call   # queue-grouped request/reply (one replica handles each call)
svc.session.<id>.call  # session runner for conversation <id> (queue "session"):
                       #   tool "session" {sessionId, content?, model?}; content runs a turn
                       #   model-only calls persist/resolve selection without inference;
                       #   model present + empty clears the conversation override
svc.session.<id>.steer # fire-and-forget event envelope {content} injected into the
                       #   running turn as a user message ("Steer: ..."); folded in
                       #   before the next LLM round or before done (no reply)
ev.<topic>             # session.*, catalog.updated, sys.drain, sys.shutdown, log.*
                       # models.updated reports effective model-catalog refreshes
                       # provider.switch selects the global backend; provider.changed
                       # invalidates redacted provider/runtime views
ev.log.<component>     # {component, level, msg, ctx?, at}; SDK log threshold applies
```

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
ev.session.assistant   # {sessionId, content, provider?, model?, context?, usage?}
                       #   complete model text + actual backend metadata per LLM round
ev.session.status      # {sessionId, provider?, providerSource?, model?, catalog?,
                       #   context?, contextSource?, promptTokens?, usedTokens?}
                       #   resolved turn config and live context occupancy.
                       #   Also emitted by model-only session calls (no inference)
ev.session.token       # {sessionId, content, reasoning}   live token deltas
                       #   (streamed while the model generates)
ev.session.toolcall    # {sessionId, tool, args, result | error}
ev.session.steer       # {sessionId, content} a steer message was folded in
ev.session.context     # {sessionId, promptTokens, usedTokens, context,
                       #   warning?|trimmed?}; context-window pressure
                       #   (75% warn, 90% trim)
ev.session.done        # {sessionId, reply} or {sessionId, error}
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
[DISCOVER.md](DISCOVER.md).

Core stays responsive while a turn dispatch is in flight: tool calls from
components that land on `svc.core.call` mid-turn (e.g. `plugin_install`
calling `core.spawn`) are served from the dispatch's idle slot, and
concurrent `session` requests are stashed and answered when the turn
ends — turns never nest.

- Presence = connection; component death detected by core via NATS disconnect
  plus `reg.depart` (graceful) vs silence (crash).
- Tool names are unique across the whole catalog — enforced by core at
  registration, rejected with an error envelope. The LLM only ever sees tool
  names; core maps tool → component at dispatch.
- `ev.sys.drain` (core → component): stop taking new calls, finish in-flight,
  then exit. `ev.sys.shutdown` (component → core): I'm leaving.

## Lifecycle

1. Core boots: spawn NATS if no `NIF_NATS_URL` → read `manifest.yaml` → select
   the boot profile → spawn children (no ordering; ordering emerges from the
   bus). Normal mode uses the manifest; `--minimal` filters it to `store`,
   `bash`, and `llm` and skips restoration of persisted spawned components.
2. Component connects, publishes `reg.publish` with its tool schemas.
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

Dispatch honors `x-harness.approval` on the tool schema (docs/REBOOT.md,
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

## Conventions

- Component names: lowercase, hyphens (`hashline-edit`). Tool names: lowercase,
  letters/digits/underscore (LLM function-calling grammar).
- Big payloads (tool output > ~64KB): reference, never inline —
  `{"ref": "store://bucket/key"}`; JetStream Object Store later, filesystem
  under `var/store/` for milestone 1.
- One message = one envelope. NDJSON for stdio streams (pipewrap) — same
  codec, line-delimited.
