# Wire protocol — mini Niffler

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
  "error": {"code": "...", "message": "..."}  // error only
}
```

Rules:

- `call` → `result` (or `error`), matched by `id`. One reply per call.
- `args`/`payload` are JSON values (objects, or anything JSON — array, string).
- Missing fields are omitted, never null. Unknown fields ignored (forward compat).
- Errors: `code` is a stable machine string (`timeout`, `no-tool`, `boom`),
  `message` is human text.
- Streaming: a caller may send `call` frames, each carrying a chunk, and a
  final `result` frame with `done: true` (custom field). `ev.*` streams
  (LLM tokens) are chunked events on a dedicated subject instead.

## Subjects

```
reg.publish            # component announces itself on connect
                       #   {name, version, pid, tools: [ {name, schema} ]}
reg.depart             # same shape, graceful shutdown
svc.<component>.call   # queue-grouped request/reply (one replica handles each call)
ev.<topic>             # session.*, catalog.updated, sys.drain, sys.shutdown, log.*
```

Session subjects (core emits during `svc.core.call` session turns — UIs
subscribe `ev.session.>` and render live):

```
ev.session.assistant   # {sessionId, content}   model text as it completes
                       #   (chunked streaming comes later)
ev.session.toolcall    # {sessionId, tool, args, result | error}
ev.session.done        # {sessionId, reply} or {sessionId, error}
```

`svc.core.call` is core's own service surface, served by core itself
(queue "core"): tools `session` (hidden from the LLM), `spawn`, `catalog`,
`kill`, `remove`.

- Presence = connection; component death detected by core via NATS disconnect
  plus `reg.depart` (graceful) vs silence (crash).
- Tool names are unique across the whole catalog — enforced by core at
  registration, rejected with an error envelope. The LLM only ever sees tool
  names; core maps tool → component at dispatch.
- `ev.sys.drain` (core → component): stop taking new calls, finish in-flight,
  then exit. `ev.sys.shutdown` (component → core): I'm leaving.

## Lifecycle

1. Core boots: spawn NATS if no `NATS_URL` → read `manifest.yaml` → build cache
   check → spawn children (no ordering; ordering emerges from the bus).
2. Component connects, publishes `reg.publish` with its tool schemas.
3. Core converges when the required set (llm, bash, builder) has registered;
   every new registration is announced as `ev.catalog.updated` with the full
   tool list (the LLM tools parameter is rebuilt per request anyway).
4. Teardown = exit; the OS is the disposer. Core drains children in reverse
   registration order: `ev.sys.drain` → grace period → SIGTERM → SIGKILL.

## Cancellation

No transport-native cancellation in NATS. Components that care subscribe to
`ev.cancel.<call-id>` on call start and check it between output chunks.
Core publishes it on user cancel. ~10 lines in the SDK.

## Conventions

- Component names: lowercase, hyphens (`llm-openai`). Tool names: lowercase,
  letters/digits/underscore (LLM function-calling grammar).
- Big payloads (tool output > ~64KB): reference, never inline —
  `{"ref": "store://bucket/key"}`; JetStream Object Store later, filesystem
  under `var/store/` for milestone 1.
- One message = one envelope. NDJSON for stdio streams (pipewrap) — same
  codec, line-delimited.
