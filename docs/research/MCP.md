# MCP support — plan

> Research note — an unshipped plan. Status: not implemented.
>
> How Niffler gains Model Context Protocol support as a *client*: external MCP
> servers (stdio) contribute tools that appear as ordinary bus tools, gated by
> the same discover/invoke and approval machinery as everything else.
> Prior art: `~/git/niffler-old/src/mcp/` (protocol.nim, manager.nim, tools.nim,
> mcp.nim, ~1.4k lines) and its docs (`doc/MCP_SETUP.md`, `doc/research/MCP.md`).
> This plan ports the *idea*, not the code: the old implementation was
> thread-and-lock based, kept an in-process tool registry, and configured
> servers in `config.yaml` — all three are explicitly outside the new
> architecture (docs/research/REBOOT.md, docs/ARCHITECTURE.md).

## Goal

Phase 1 target: a configured MCP server's tools become live Niffler tools —
discoverable, invokable, approval/timeout-gated — with server lifecycle
managed as supervised child processes of one new component.

Non-goals for v1 (kept from the old implementation, which also ignored them):

- MCP **resources** and **prompts** — tools only. The registry is tool-shaped.
- Remote/streamable-HTTP transports — stdio only (phase 2 extension).
- Niffler acting as an **MCP server** for external clients (phase 3).

## Architecture fit

MCP slots into the existing architecture without new primitives:

| Old Niffler mechanism | New equivalent |
|---|---|
| MCP worker thread + locks | the `mcp` **component process**; bus surface single-threaded on the SDK poll loop, blocking stdio I/O on internal worker threads (see "Internal threading model") |
| in-process tool registry | `reg.publish` tools array; catalog owns routing + uniqueness |
| `config.yaml` servers section | store docs, kind `mcp` — persistence of shape |
| `/mcp status` slash command | `mcp_status` / `mcp_list` tools (onDemand) |
| OpenAI tool-definition conversion | schema passes through `normalizeToolSchema` unchanged (MCP `inputSchema` *is* JSON Schema) |
| confirmation for edit_/create_ tools | `x-harness.approval` / `x-harness.timeoutMs` on generated schemas |

Key decisions, one by one:

### 1. One component, many servers, one tool namespace

- A single `mcp` component (like `plugins`/`skills`) supervises all configured
  MCP server processes. Its handler routes each tool call to the owning
  server — the component's internal routing table is the analogue of old
  `tools.nim`'s `mcpTools` table, except calls arrive over the bus.
- Tool names are **globally unique** (docs/WIRE.md); raw MCP tool names
  (`read`, `list_directory`) collide with shipped tools. Registered name:
  `mcp_<server>_<tool>`, sanitized to `[a-z0-9_-]`. The original name is kept
  in the schema description (`"… (MCP tool <tool> of server <server>)"`) so
  the LLM still sees the server's own description verbatim.
- Per-server config may override the prefix (e.g. a trusted server can drop
  to `mcp_<tool>`) — not v1.

### 2. Exposure: onDemand, not direct

Every MCP tool schema gets `x-harness: {"onDemand": true}`. Rationale:

- Servers can expose dozens of tools (github server: ~15); flooding a
  conversation's *frozen direct toolset* burns prompt budget and dilutes tool
  selection. `onDemand` keeps them out of the direct snapshot but fully
  reachable: `discover {component: "mcp"}` returns hints (direct/onDemand
  buckets already exist), `discover {component: "mcp", tools: [...]}` returns
  full schemas, `invoke` calls them with approval/timeout preserved.
- The system prompt already teaches discover-first for exactly this pattern
  (plugins, skills). One sentence is added to `discover`'s description:
  "the mcp component exposes tools of configured external MCP servers."

### 3. Registration model: tools known at connect, re-announce for changes

The SDK announces `reg.publish` once in `run()`. The mcp component therefore
starts all enabled servers, performs initialize + `tools/list` at boot, and
registers the merged toolset at connect. Config changes (add/remove/enable a
server) are applied by restarting the component — `core.kill` + `core.spawn`
is already the harness's hot-change idiom, or the management tool does it via
a self-restart (component re-execs itself).

Supporting change in **core/catalog.nim**: `handle` currently replaces a
component's reg on `reg.publish` but does not remove the previous toolIndex
entries — a re-announce with fewer tools would leave stale routes. Fix:
when a re-publish for a known component arrives, drop its old toolIndex /
slashIndex entries before applying the new reg. Small, and makes hot-reload
of any component's toolset well-defined.

### 4. Server processes are the mcp component's children

Not the core supervisor's — the supervisor owns Niffler components; MCP
servers are third-party executables the component manages (same shape as
`plugins` running git, `builder` running nim). Per server:

- spawn with `poUsePath`, cwd = `workingDir` (default NIF_ROOT), env =
  inherited + configured overrides (secrets never logged; `mcp_status`
  redacts env values).
- stderr is **logging**, stdout is protocol: keep them separate (old code got
  this right); stderr goes to the component's stderr → `var/logs/mcp.log`
  via the supervisor, never into JSON parsing.
- restart policy `on-failure` with backoff and an error counter per server
  (old `manager.nim` had this); a dead server's tools answer a clear
  "server <name> not running" error instead of timing out.
- `ev.sys.drain` → send `shutdown` JSON-RPC, close pipes, kill after grace.
- Health: `tools/list` ping in the idle loop (SDK's onIdle / timer), marking
  last-activity per server for `mcp_status`.

### 5. Internal threading model

A component may be multithreaded internally — the architecture boundary is the
bus (subscribe, answer on the reply subject, register/depart), not how a
component computes. The Nim SDK itself stays callback-free: the main thread
owns the NATS surface (poll loop, replies, catalog announces, drain), and
**one worker thread per server** owns that server's stdio pipes. Rationale:

- Blocking `readLine`/pipe reads are the natural implementation for stdio
  JSON-RPC; a worker thread per server means a slow or hung server can never
  stall the main poll loop or the other servers (the old code's dedicated
  MCP worker thread made the same call).
- The main thread publishes requests into the worker's queue and drains
  completed results from a locked table in its idle slot, then answers the
  call's NATS inbox — replies always leave from the main thread, keeping the
  envelope flow single-owner and testable.
- Threads are optional, not structural: v1 may ship with a single worker
  thread (or even fully synchronous, blocking the main loop per call) and
  graduate to per-server workers when a slow server actually bites. The
  serialized main-thread version is the reference behavior for tests.

### 6. Framing: support both MCP wire generations

Old code assumed newline-delimited JSON (protocol 2024-11-05). Current
servers mostly speak 2025-03-26+ framing:

- **Content-Length framing**: `Content-Length: N\r\n\r\n<body>` per message.
- **Newline fallback**: parse a bare JSON line as one message (2024-11-05).
- The client offers the server's reported `protocolVersion` in initialize,
  accepts whatever comes back, and picks framing by first bytes.
- Requests are strictly one-in-flight per server (JSON-RPC correlation is by
  id anyway): the worker sends `{jsonrpc, id, method, params}`, then reads
  frames until the response with the matching id arrives — **draining**
  interleaved notifications (progress, logging) and rejecting server→client
  requests (v1: method-not-found, we advertise no client capabilities).

Handshake: `initialize` {protocolVersion, capabilities: {}, clientInfo:
{niffler, <ver>}} → `notifications/initialized` → `tools/list` →
optionally subscribe `notifications/tools/list_changed` (v1: ignore; a
server change surfaces on next component restart).

### 7. Result mapping

MCP `tools/call` result: `{content: [{type: text|image|resource, text?, data?,
mimeType?}], isError?}`. Map to the envelope result:

```json
{"ok": true, "content": "<joined text blocks>",
 "blocks": [ ...full content array... ]}
```

- `isError: true` → `{"ok": false, "error": "<joined text>"}` so the LLM sees
  it as a failed tool call (conversation loop renders `$toolResult`).
- JSON-RPC error → `{"ok": false, "error": "<code>: <message>"}`.
- Timeouts (per-server `timeoutMs`, default 120s): a pipe read has no
  portable deadline, so on expiry the component **kills the server process**
  — EOF unblocks the worker thread — and returns a `timeout` error; the
  restart policy (on-failure) brings the server back for the next call.
  This is also the old manager's recovery shape.

## Config in the store

Kind `mcp`, id = server name:

```json
{"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem",
                              "/allowed/path"],
 "env": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"},
 "workingDir": ".", "enabled": true, "timeoutMs": 30000}
```

- `${VAR}` interpolation from the harness environment at spawn time
  (old config.yaml behavior; secrets live in `.env`, never in the store doc).
- The mcp component loads these at boot; `mcp_add` writes them via the store
  (put is hidden — component calls it like core does, that is the established
  pattern), `mcp_remove` deletes.

## Component surface (`components/mcp/main.nim`)

Tools (management tools `x-harness.onDemand`):

| Tool | Description | Gate |
|---|---|---|
| `mcp_list` | configured servers: name, command, enabled, running, errors, restarts, last activity, tool count | — |
| `mcp_status` | same + per-tool table (registered name → original name) | — |
| `mcp_add` | add/update a server config; restarts the affected server | approval: always |
| `mcp_remove` | remove config + stop server | approval: always |
| `mcp_restart` | restart one server (e.g. after list_changed) | — |
| `mcp_<server>_<tool>` ×N | proxied MCP tools, schemas normalized + namespaced | per-server timeoutMs |

`mcp_add`/`mcp_remove` are approval-gated because they run arbitrary
executables (same policy as plugin install). Individual MCP tool calls get
`x-harness.approval: "always"` only if the server config asks for it
(per-server `approveTools: true`) — default off, matching shipped tools.

## LLM flow

```
"list files" → discover {component: "mcp"}            # hints: mcp_filesystem_*
             → discover {component: "mcp", tools: ["mcp_filesystem_list_directory"]}
             → invoke {tool: "mcp_filesystem_list_directory",
                       arguments: {"path": "/x"}}
```

`invoke`'s dispatch keeps the tool's approval/timeout policy (docs/MANUAL.md, "Progressive tool discovery").
Calls to different servers proceed independently (per-server worker threads);
within one server, calls serialize in the order the bus delivers them.

## Testing (`tests/t_mcp.nim`, new Makefile target `test-mcp`)

Fixture: `tests/fixtures/mcp_server.py` (or a tiny Nim binary compiled by the
test, like `ctxtest`) — a real stdio MCP server speaking Content-Length
framing with 3 scripted tools: `echo_tool` (returns text), `fail_tool`
(isError result), `slow_tool` (sleeps past timeoutMs), plus one server
notification mid-call to exercise the drain logic.

Bus-contract assertions:

1. `mcp_add` with the fixture → component starts it, handshake ok →
   `discover {component: "mcp"}` lists the namespaced tools; schemas carry
   `x-harness.onDemand` and valid `type: object`.
2. `invoke`/direct call of `mcp_fixture_echo_tool` → text result roundtrip.
3. `mcp_fixture_fail_tool` → `ok: false` with the server's message.
4. `slow_tool` → timeout error (proves the poll-loop deadline).
5. Kill the server process → tools answer "server not running"; restart
   policy brings it back; tool works again.
6. Concurrency: `slow_tool` (pending) does not block `echo_tool` — both
   complete/cancel independently (asserts the worker-thread isolation).
7. `mcp_remove` → config gone, process stopped, tools unregistered after
   re-announce (catalog fix from §3).
8. Approval: `mcp_add` on a bus without NIF_AUTO_APPROVE is denied.
9. `ev.sys.drain` → server child receives shutdown and exits.

## Phases

**Phase 1 — stdio client (this plan).**
catalog re-announce fix; `components/mcp` (protocol framing, handshake,
supervision, registration, dispatch, management tools); `t_mcp`; README/
MANUAL note. Dogfood target: configure the reference filesystem server and
use it from a conversation.

**Phase 2 — transport + dynamics.**
Streamable-HTTP adapter behind the same routing table; `tools/list_changed`
hot reload (re-announce via the catalog fix); per-server exposure toggle
(direct vs onDemand); health-check tuning; UI: MCP section in the Live
components view (catalog snapshot already carries the tool schemas).

**Phase 3 — Niffler as an MCP server (outbound).**
A `mcp_gateway` component (or `niffler mcp serve`) exposing the live catalog
to external MCP clients (Claude Desktop, IDEs): envelope ↔ JSON-RPC mapping
is mechanical (both are JSON, id-correlated request/reply); session turns map
to `tools/call` with `sessionId` context; approval surfaces through MCP
elicitation or a local prompt. This is the mirror of pipewrap's direction and
is what makes a *pair* of Niffler harnesses composable over MCP.

## Open questions

1. Naming: `mcp_<server>_<tool>` vs `mcp.<server>.<tool>` (the latter reads
   better in transcripts; invoke tolerates dotted spellings already, but the
   flat namespace makes dots decorative — recommend underscores, matching
   `plugin_*`/`skill_*`).
2. Per-conversation server selection (only expose some servers to some
   sessions) — the exposure doc (`<sessionId>:tools`) is the natural place;
   defer until a real need.
3. Direct-tool promotion for a "trusted" server (drop onDemand) — config
   flag, phase 2.
