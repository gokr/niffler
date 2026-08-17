# Reboot — mini Niffler

A design summary for a minimal, self-extending agent harness, distilled from a
design conversation (2026-08) covering the DeepSeek Harness, the Cordis plugin
framework (cordiverse/cordis) and its paper, and comparisons with Pi, NATS, and
ConnectRPC.

End goal: **a harness that builds itself out during a conversation** — adding
tools, swapping components in and out — while conversation state and context
survive intact.

## Design goals

- **Minimalism** (Pi-style: one-way flow, few primitives, ~nothing in core)
- **Self-extension**: the agent writes, compiles, and launches its own new
  components mid-conversation
- **Crash isolation**: the component author is an LLM that writes buggy code;
  a component must never corrupt the agent's own mind
- **Persistence of shape**: capabilities the agent adds must survive restarts
- **Language freedom**: components in Nim, Go, or anything else

## What we learned from Cordis

Cordis is the plugin framework (vendored) beneath DeepSeek Harness. Its paper
(*A Programming Paradigm for Spatiotemporal Composability*) names the two
dimensions any self-modifying system must solve:

- **Temporal composability**: every side effect of a component reverts on
  unload (in Cordis: tracked inverses, LIFO disposers; correctness is an
  author obligation, observational equivalence, not byte-perfect restore).
- **Spatial composability**: dependencies are declared and reactively managed
  (`inject`-style specs; providers identified by *fiber identity*, not value;
  in-place overwrite of a binding does not propagate — withdraw + reinstall
  does). Lifecycle transitions are *inertial* (a reload/unload completes before
  reacting to new changes).

Note: the paper's formal core is effects/coeffects/context/fibers — the
`emit`/`waterfall`/`parallel`/`serial` event vocabulary is the *harness
dialect* on top, not the theory. Case study is Koishi (4000+ plugins);
agent harnesses are named as the future direction — which DeepSeek Harness is.

Key paper insight for language choice (§6.4): temporal composability needs
closures; native languages get runtime composability via `dlopen`/`dlclose`
(or, our choice, **processes**). Spatial composability needs dependency
injection + access mediation; compile-time metaprogramming (Rust proc macros,
Zig comptime) is listed as an alternative to runtime proxies — this is the Nim
macro route.

## The core decision: processes, not plugins

We skip in-process composition entirely (no dlopen, no ABI/type-border
issues, no image-based self-modification à la Smalltalk/Lisp). The unit of
composition is the **process**:

- Teardown = `exit()`; the OS is the perfect disposer. Stronger than anything
  Cordis can guarantee in-process.
- Crash of a component ≠ crash of the harness.
- Lineage: essentially **Erlang/OTP for agent harnesses** (processes as
  components, supervision, monitors as dependency notification).
- Latency cost (~100µs/call vs ~50ns in-process) is noise at harness
  timescales — LLM calls take seconds.

Rejected alternatives:

- **Smalltalk/Lisp image**: seductive immediacy (eval a tool into the live
  system), but (1) the author is an LLM whose bad code would run with full
  memory access, and (2) *removal* is the classic unsolved weakness of images
  (image rot; Emacs has no unload story after 40 years). A dynamic language
  (Janet/Lua/nimscript) may live *inside one component* as a fast, live-codable
  chamber for pure-logic tools — Smalltalk inside a cell, Unix between cells.
- **Cordis itself**: its in-process machinery earns its complexity at
  hot-reload/millisecond latencies; we steal only the *disciplinary* ideas
  (provider identity, drain-before-stop ordering, contracts-as-artifacts).

## Architecture

```
┌─ mini Niffler core ──────────────────────────────┐
│ conversation loop, supervisor (spawn/drain/kill),│
│ catalog (JetStream KV or DB), NATS connection    │
└───────────────────────┬──────────────────────────┘
                        │ NATS (spawned locally if no external URL)
      ┌─────────────────┼──────────────────┬───────────────┐
   ┌──▼───┐       ┌─────▼────┐       ┌──────▼────┐    ┌─────▼─────┐
   │ bash │       │ builder  │       │ llm-openai│    │ your tool │
   │ (Nim)│       │  (Nim)   │       │   (Go)    │    │ (any lang)│
   └──────┘       └──────────┘       └───────────┘    └───────────┘
   every box = a small binary using its language's component SDK
```

- **Building is itself a tool call.** The `builder` component receives
  `build(lang, source) → binary`. "The agent adds a capability" = write source
  → call builder → supervisor spawns → component registers → catalog updated →
  LLM sees the new tool on the next request.
- **Self-extension persists**: the manifest lives in the DB. The agent's final
  step when adding a tool is inserting a component row; next boot, the harness
  comes up with its new body already attached.
- **Manifest format** (YAML bootstraps fresh systems; DB is authoritative):

  ```yaml
  components:
    - name: bash
      build: {lang: nim, src: components/bash/main.nim}
      autostart: true
      restart: on-failure   # never | on-failure | always
  ```

- **Boot sequence**: spawn NATS (if embedded mode) → open catalog → resolve
  manifest to binaries (build cache keyed by source hash; `builder` itself is
  a bootstrap component the supervisor compiles directly) → spawn children
  (no ordering; ordering emerges from the bus) → converge when the required set
  (llm adapter, core tools) has registered.
- **Core stays nearly empty**: NATS + supervisor + conversation loop reading
  the catalog. Prompt assembly, approvals, token metering are components too
  where feasible.

## NATS as the single backbone

Core speaks exactly one protocol. Chosen capabilities relevant here:

- **Queue groups**: N replicas of a component, one gets each request —
  load balancing + rolling cutover (v2 spawns, v1 drains) for free.
- **Request/reply**: blocking API over an async wire
  (`nats.Request(subject, args, timeout)`); many concurrent in-flight calls on
  one connection. **"No responders"** (NATS 2.2+ headers) distinguishes
  "tool gone" from "tool slow" — spawn-or-rebuild vs wait-or-kill.
- **Wildcards**: `ev.tools.>` — observe everything without enumeration;
  `nats sub '>'` = watch the harness think.
- **Presence = connection**; server death detection is the transport.
- **JetStream KV**: the catalog/manifest home, with watches.
- **JetStream Object Store**: builder publishes compiled *binaries*;
  artifact distribution through the same auth/topology.
- **Leaf nodes/gateways**: multi-machine federation later, if ever wanted.

Trade-offs accepted (vs ConnectRPC, which we evaluated seriously):
- No native **cancellation propagation** (Connect/gRPC has `ctx.Done()`
  transport-native). We ship it in the component SDK: subscribe
  `cancel.<callid>` on call start, check between output chunks. ~10 lines.
- No schema enforcement at the seam (proto/codegen) — accepted: tool schemas
  are *runtime data* (the LLM needs JSON schemas anyway), so a newly built
  component can announce a schema the core has never seen. Strictness at the
  wire would fight the design.
- Idempotency: every call carries a call-id; dedupe at the worker.

## The component SDK (the real product)

Small enough to port in an afternoon (~200 lines/语言); the envelope spec is
the artifact, SDKs follow. Surface, Pi-minimal:

```
Component(name, version, {tools: [schemas]})
  .tool(schema, handler(argsJson) -> resultJson | error)
  .on(subject, handler)               # passive events
  .emit(subject, payload)             # fire-and-forget
  .request(subject, payload, timeout) # RPC to another component
  .run()                              # blocks; drain → SIGTERM → exit
```

Envelope (versioned, boring,identical on every transport):

```json
{"v": 1, "id": "...", "kind": "call|result|event|error",
 "tool": "...", "args": {...}, "payload": ..., "error": {...}}
```

Subject convention (tiny):

```
reg.publish           # {name, version, tools:[schema], pid} on connect
svc.<name>.call       # queue-grouped request/reply
ev.<topic>            # session.updated, tool.called, sys.drain, ...
ev.sys.shutdown
```

Streaming (tool output, LLM tokens): chunk frames to the reply subject,
final frame marks completion. No separate channel.

## Payload serialization

**JSON everywhere by default.** The envelope and seams are already JSON by
design (tool args/schemas are JSON in the LLM prompt; schemas-as-runtime-data
is a core decision), so the only question is per-seam codec upgrades — never
a global format.

| Format | Verdict |
|---|---|
| **JSON** | Default. Universal, debuggable, curl-able, schemaless-evolution-friendly |
| **MessagePack** | The practical binary upgrade path (JSON-like, ~2-3× smaller/faster, no schema) |
| **CBOR** | Cleaner spec than msgpack, self-describing; niche |
| **Protobuf** | Rejected: Nim support is the weak link, and codegen fights schema-as-runtime-data — the Connect discipline we declined at the bus level shouldn't return through the serializer |

Mechanisms that make this safe:

- **Codec negotiation via NATS headers** (per-message, opt-in):

  ```
  NATS/1.0
  Content-Type: application/json
  ```

  All subjects default to JSON; a component may send `application/msgpack`
  on a hot stream (token chunks, big output). Old consumers keep parsing
  JSON; upgrades don't fork the subject space.
- **References, not blobs.** Keep messages small (KB range). Large tool
  output rides as `store://...` references to JetStream Object Store / DB,
  never in-band. This matters more than any codec choice.
- **NDJSON for streams** (NATS chunked streams *and* the `pipewrap` stdio
  path): same JSON codec, line-delimited — no second serializer, scripts
  stay bit-compatible with the bus.
- **Compress instead of encode** if size ever bites: gzip/zstd on JSON beats
  switching formats; identical in Go, Nim, Python.

## Contracts: JSON Schema (2020-12)

One JSON Schema artifact serves three roles no other mechanism covers
simultaneously:

1. **Bus contract** — catalog validates envelopes/args before dispatch;
   components validate the calls they receive.
2. **LLM tool contract** — the announced schema *is* the function-calling
   contract handed to the model; descriptions/examples are prompt
   engineering, not decoration.
3. **Runtime-authored contract** — the agent or a new component writes or
   extends schemas at runtime; no build step, no regeneration. (This is what
   protobuf and Zod-type-codegen cannot give a multi-language system;
   DSH's Typert = the TS-only variant of this idea.)

Discipline:

- **Two tiers, declared up front.** Tool schemas (LLM-facing) stay in the
  restricted tool-calling subset (no cross-file `$ref`; enforced by the
  catalog at registration); internal message schemas may use full 2020-12.
- **One enforcement point.** Validate in the core/catalog (Go or Nim,
  whichever hosts it); SDK-side validation is a debug aid, not the
  enforcement layer — Nim's jsonschema packages are thinnest, and that's
  acceptable precisely because components don't need to enforce.
- **Conformance in CI.** Implementations disagree on edge cases (`format` is
  annotation-only by default; `default` semantics vary). Standardize on
  draft 2020-12 and pin behavior with a conformance corpus.
- **Policy rides the schema** via `x-` extensions — one artifact carries
  contract + permission metadata + docs, no parallel registries:

  ```json
  {
    "type": "object",
    "properties": { "path": {"type": "string"} },
    "required": ["path"],
    "x-harness": { "approval": "always", "sandbox": "read-only", "timeoutMs": 30000 }
  }
  ```

- **Graduation path:** an HTTP gateway / web UI later can generate OpenAPI
  *from* the catalog (OpenAPI reuses JSON Schema); optional per-seam codegen
  (quicktype-style) for compile-time stubs — convenience, never the
  discipline.

## Unix fallback path: stdio behind pipewrap

Unix philosophy taken seriously (Pi's `--mode rpc`, MCP, LSP) suggests
stdio/NDJSON as the maximal-simplicity transport — debuggable with `tee`,
shell scripts as components. Accepted, but **never in the core**: a generic
`pipewrap` component bridges stdio-speaking scripts onto NATS:

```bash
pipewrap --name weather -- python3 weather.py
```

Duties: spawn+supervise the script (death → departure event; wrapper death →
script gets EOF and exits), relay registration, correlate by envelope id,
forward stderr to `ev.log`, bounded buffers + kill-on-drain-timeout. Constraint
on itself: framing and supervision only — the moment it grows retries or
routing logic, it's a framework.

Rule: high-frequency streaming components (LLM adapter, PTY) are native NATS
speakers; anything request/reply can live behind `pipewrap`.

## What Niffler contributes

- `natswrapper` (cnats) — Nim NATS client, proven
- `types/tools.nim` — ToolCall/ToolResult JSON shapes ≈ the envelope
- `core/agent_manager.nim` — self-spawning logic = supervisor seed
- DB-backed conversation persistence — externalized state is *why*
  mid-conversation tool swaps are safe
- Multi-agent NATS experience (subjects, JetStream KV presence)

Not ported: the `ToolKind` enum/object-variant tool registry — a tool is now
just a queue-grouped subject; compile-time dispatch is exactly what we're
escaping. Niffler is client-only re: NATS (no embedding in code; only roadmap
docs discuss it) — mini Niffler adds the spawn-if-missing fallback (3 lines of
`startProcess` on a random loopback port).

## Open threads

- Approval/policy: keep synchronous and central (interceptor on the dispatch
  path in core/router) — don't replicate multi-hop middleware chains over a bus.
- LLM-side care when the advertised tool set changes mid-conversation: rebuild
  the tools parameter per request; keep schema *names* stable across swaps to
  protect prompt caches.
- Dynamic-language component (Janet/Lua) for instant, compile-free tools.
- NATS spawn fallback: `NATS_URL` set → use it; else spawn `nats-server` on a
  random loopback port.

## First milestone

Wire-protocol spec (one page: envelope + subjects + lifecycle), Nim SDK,
supervisor, `bash` and `builder` components. The agent adds itself a trivial
tool end-to-end — architecture validated when that works.
