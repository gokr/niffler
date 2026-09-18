# Audit: `components/mcp` (MCP client manager)

Scope: `components/mcp/` (6 Go files, 1499 lines incl. tests) + the children it
owns, `components/mcp-bridge/` (1778 lines). Read-only audit; MANUAL checked at
working-tree revision.

## 1. What it offers

`mcp` is the **client/host side of the Model Context Protocol**: it keeps a
store-backed registry of external MCP servers and makes each server's tools
ordinary catalog tools (`mcp_<server>_<tool>`) that participate in progressive
discovery, approval and cancellation like any component tool
(`components/mcp/main.go:1-19`). Storage is one `mcp` store document per server
(`components/mcp/types.go:12`); execution is one supervised child process per
server, `var/bin/mcp-bridge --server <name>` spawned as component
`mcp-<name>` (`components/mcp/main.go:517-522`, `components/mcp-bridge/main.go:483`).
Transports: `stdio`, `http` (streamable HTTP), `sse`
(`components/mcp/main.go:449-457`; `components/mcp-bridge/transport.go`).
The bridge reads its own record at boot (`components/mcp-bridge/main.go:489-506`),
caches the server's tool/prompt listing in that record, and lazily opens the real
MCP session on the first tool call (`components/mcp-bridge/main.go:227-235`).
Optional component (MANUAL:80 `docs/MANUAL.md:80`).

## 2. Tools (component `mcp`, `components/mcp/main.go:66-158`)

| Tool | One-line purpose (doc comment / schema description) | `x-harness` | Exposure |
|---|---|---|---|
| `mcp_servers` | list configured servers with transport, cached tool count, live bridge state (env/header values never echoed) | `onDemand`, `effect: read` (main.go:72) | discover-only |
| `mcp_add` | add a server: real-connect validation, store record + cached listing, spawn bridge | `onDemand`, `approval: always` (main.go:98) | discover-only, **approval** |
| `mcp_edit` | merge provided fields, re-validate, respawn (or stop when disabling) | `onDemand`, `approval: always` (main.go:123) | discover-only, **approval** |
| `mcp_remove` | kill the bridge + delete the record (tools vanish from discovery) | `onDemand`, `approval: always` (main.go:134) | discover-only, **approval** |
| `mcp_refresh` | force a bridge to drop its session, reconnect and re-list now | `onDemand` only (main.go:145) | discover-only, **no approval** |
| `mcp_search` | keyword search of the official MCP Registry, returns ready `mcp_add` args | `onDemand`, `effect: read` (main.go:158) | discover-only |

Per-server tools registered by the **bridge** (not the manager), all carrying
`sessionId` + `timeoutMs`, `onDemand` unless the server is `expose: direct`:
`mcp_<server>_<tool>`, `mcp_<server>_resources` (also `effect: read`),
`mcp_<server>_prompt` (**hidden**, generic renderer) and one hidden
`mcp_<server>_prompt_<promptname>` per prompt plus slash command
`mcp-<server>-<promptname>`; `mcp_<server>_bridge_status` is **hidden**
(manager-only helper) (`components/mcp-bridge/operations.go:329-411`).

## 3. Configuration

- **Store kind**: `mcp`, id = server name, one doc per server
  (`components/mcp/types.go:12`); read by the bridge at boot
  (`components/mcp-bridge/main.go:489`) and rewritten (tools/prompts cache only)
  on drift (`components/mcp-bridge/main.go:277-320`). Listing caps at 1000 docs
  (`components/mcp/main.go:170`), 100 servers (`components/mcp/validation.go:76`).
- **No config file.** There is no `mcp.json`-style file anywhere; the record is
  the configuration and the manager owns every field except `tools`/`prompts`
  (`components/mcp/types.go:14-31`, `components/mcp/main.go:692-724`).
- **Env knobs**: `NIF_MCP_BRIDGE_BIN` (default `<NIF_ROOT>/var/bin/mcp-bridge`,
  `components/mcp/main.go:57-61`), `NIF_MCP_PROBE_TIMEOUT_MS`
  (`components/mcp/main.go:466-472`, also honored inside the bridge probe
  `components/mcp-bridge/main.go:437`), `NIF_MCP_REGISTRY_URL`
  (`components/mcp/main.go:300-302`), `NIF_MCP_DIRECT_THRESHOLD` — read **by the
  bridge process** at registration (`components/mcp-bridge/operations.go:322-331`),
  so it is fixed for that child's lifetime, `<1`/unparseable ⇒ 10.
- **Transports**: `stdio` (default; `command`+`args`+`env`/`cwd`), `http`
  (streamable HTTP), `sse`; url must be http(s), no userinfo/fragment
  (`components/mcp/main.go:424-457`).
- **Child bridges**: `core.spawn {name: "mcp-"+name, binary: bridgeBin,
  args: ["--server", name]}` (`components/mcp/main.go:517-522`), idempotent when
  already supervised, then a 15 s catalog poll; failure ⇒
  `"bridge did not register within 15s; inspect var/logs/mcp-<name>.log"`
  (`components/mcp/main.go:525-544`). Stopped with `core.kill`; `mcp_remove`
  uses `core.remove` so boot does not resurrect it (`components/mcp/main.go:548-560`,
  `:743-747`). Child argv + record survive reboots (persisted component record).
- **Timeouts**: probe 30 s, extended to `timeoutMs` when that is higher, then
  overridden by `NIF_MCP_PROBE_TIMEOUT_MS` (if >0) — **unconditionally**, not
  "when higher" (`components/mcp/main.go:465-472`); probe stdout capped 1 MiB,
  stderr 64 KiB with the last 400 bytes surfaced
  (`components/mcp/validation.go:16-30`, `components/mcp/main.go:483-500`).
  Per-call `timeoutMs` default 120 s, `idleMs` default 5 min, both ≤86 400 000
  (`components/mcp/main.go:438-441`, `components/mcp-bridge/main.go:67-77`).
  `mcp_refresh` uses a 65 s bridge timeout (`components/mcp/main.go:766`),
  `mcp_servers` polls bridge status with 1 s timeout, 8-way concurrent
  (`components/mcp/main.go:242-258`).
- **Error surfacing**: probe stderr tail with env/header values redacted
  (`components/mcp/validation.go:32-40`, `components/mcp/main.go:486-490`);
  partial successes return `{"ok": true, "warning": "stored but bridge did not
  start/restart…"}` and `mcp_remove` keeps the record when the bridge cannot be
  stopped (`components/mcp/main.go:608`, `:676-679`, `:747`);
  `mcp_servers` attaches live `bridge` status incl. last error
  (`components/mcp/main.go:244-256`).
- **Contract drift**: fresh session + `notifications/tools/list_changed` +
  `notifications/prompt_list_changed` re-list tools *and* prompts; a changed
  contract is persisted (3 rev-retries, and never overwrites an edited config)
  and the bridge exits **3** (`driftExitCode`, `components/mcp-bridge/main.go:22`)
  for a supervisor restart with 0.5–8 s backoff (`core/supervisor.nim:34-39`,
  `:205-209`). If persistence fails it **fails closed** into a `retiring` state
  instead of crash-looping: status carries `"contract drift could not be
  persisted; edit/refresh to recover: …"` and `refresh` refuses while calls are
  active (`components/mcp-bridge/main.go:249-272`,
  `components/mcp-bridge/operations.go:397-413`).
- **Model-facing limits**: server name `^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$`, ≤32
  chars, `bridge` reserved (`components/mcp/types.go:50-58`,
  `components/mcp/main.go:397-399`); generated tool names ≤64 and collision-checked
  against other servers **and** the live catalog
  (`components/mcp/types.go:79-125`, `components/mcp/validation.go:42-100`);
  ≤32 prompts/server, ≤16 args each, `__session` argument name reserved
  (`components/mcp/types.go:126-138`); results >64 KiB spill to
  `$NIF_ROOT/var/mcp-results/result-*.json` with a 16 KiB preview
  (`components/mcp-bridge/operations.go:19`, `:140-180`).

## 4. MANUAL placement

Already present and correct in section order: **`## External MCP servers (`mcp`)`
— `docs/MANUAL.md:1085`**, with `### Shape` (1096), `### The record` (1165),
`### Tools` (1199), `### Prompts, resources, registry` (1215),
`### Verification` (1245); env rows at 297, 298, 339, 340; shipped-component row
at 80; TOC entry at 19. **`components/mcp-bridge` does not need its own
section** — it is never user-spawned, and its guard/flag surface is already
covered in the Sandboxing bullet (1140-1143). Recommendation: keep it a pointer,
but add one sentence to `### Shape` stating that `mcp-bridge` is only started by
the manager (`core.spawn`) or by the probe, never by hand, and that the manager
re-spawns it after drift/crash — that is the only sub-topic a reader currently
has to infer. If a pointer is preferred over prose, `docs/MANUAL.md:50`'s
Shipped-components table is the right home (the `mcp` row at line 80 does not
name `mcp-bridge` at all).

## 5. DELTA list

- MANUAL: 1201 `"All on the `mcp` component, all on-demand; writes are approval-gated:"` | CODE: `mcp_refresh` declares only `{"onDemand": true}` (`components/mcp/main.go:145`), and `mcp_servers`/`mcp_search` are reads | FIX: update — "All on the `mcp` component, all on-demand. `mcp_add`, `mcp_edit` and `mcp_remove` are approval-gated (as is the `core.spawn`/`core.remove` they issue); `mcp_refresh`, `mcp_servers` and `mcp_search` are not — refreshing only re-lists an already-approved server."
- MANUAL: 1203-1209 tools table has five rows, no `mcp_search` | CODE: `mcp_search` is a registered on-demand read tool (`components/mcp/main.go:148-158`); it only appears in prose at 1233 | FIX: add row — "| `mcp_search` | keyword search of the official MCP Registry; returns `installable` entries with ready `name`/`type`/`command`/`args`/`url` for `mcp_add`, others with the reason (`limit` default 10, max 20) |". Also rename the table's `Effect` column to `Purpose` (its cells are purposes, not `read`/`write`).
- MANUAL: 1206 `mcp_add` row mentions only the validate→store→spawn happy path | CODE: `enabled: false` stores a parked config with *no probe, no spawn* (`components/mcp/main.go:563-583`); a spawn that never registers returns `{"ok": true, "warning": "stored but bridge did not start: …"}` and the record is kept (`components/mcp/main.go:606-608`, `:525-544`) | FIX: extend — "`enabled: false` stores a parked config without connecting or spawning (`mcp_edit {enabled: true}` activates it later). If the bridge does not register within 15s the record is still stored and the call returns `ok` plus a `warning` naming `var/logs/mcp-<server>.log`; re-run `mcp_refresh` or `mcp_edit` after fixing the server."
- MANUAL: 340 `NIF_MCP_PROBE_TIMEOUT_MS` "overrides the 30s default and the call's own `timeoutMs` when higher" | CODE: any positive value wins unconditionally — `if raw != "" { … timeout = ms }` after the `timeoutMs` branch (`components/mcp/main.go:465-472`), same in the bridge's own probe (`components/mcp-bridge/main.go:437-443`) | FIX: "timeout for one real-connect probe in `mcp_add`/`mcp_edit`; when set (positive) it wins over both the 30 s default and the server's own `timeoutMs`".
- MANUAL: 1117-1122 Exposure says `"expose": "direct"` puts a server's tools into new conversations | CODE: the bridge defers the **whole server** back to on-demand when it has more than `NIF_MCP_DIRECT_THRESHOLD` (default 10) cached tools (`components/mcp-bridge/operations.go:329-331`, `:321-327`) | FIX: append "— unless the server publishes more than `NIF_MCP_DIRECT_THRESHOLD` tools (default 10), in which case the bridge defers the entire server to on-demand. The threshold is read by the bridge process at startup, so it is fixed for that child's lifetime (change it and restart the bridge)."
- MANUAL: 1155-1159 Drift describes persist-and-exit-3 as best effort | CODE: on persist failure after 3 rev-retries the bridge does **not** exit — it enters a fail-closed `retiring` state, surfaces `"contract drift could not be persisted; edit/refresh to recover: …"` in `bridge_status`, and refuses `refresh` while calls are in flight (`components/mcp-bridge/main.go:249-272`, `components/mcp-bridge/operations.go:397-413`) | FIX: append "If the refresh cannot be persisted the bridge fails closed in a *retiring* state instead of crash-looping: `mcp_servers` shows the error and the server needs `mcp_refresh` (after active calls finish) or `mcp_edit` to recover."
- MANUAL: 1217-1219 "Each server prompt is registered as a hidden catalog tool `mcp_<server>_prompt`" reads as one tool per server | CODE: two distinct hidden names exist — the generic renderer `mcp_<server>_prompt` (`components/mcp-bridge/operations.go:380`) **and** one `mcp_<server>_prompt_<promptname>` per prompt (`:401-409`), the latter being the slash command's `Tool` | FIX: "Each server prompt is registered as a hidden catalog tool `mcp_<server>_prompt_<promptname>` plus a slash command `mcp-<server>-<promptname>`; a second hidden generic tool `mcp_<server>_prompt` lets clients render any prompt by name. Both are invisible to the LLM (`x-harness.hidden`)."
- MANUAL: 1228-1229 "`{op: "list"}` or `{op: "read", uri: ...}`" | CODE: the op enum is `list | templates | read`, and `templates` returns URI templates (`components/mcp-bridge/operations.go:379`, `:268-317`) | FIX: "`{op: "list"}`, `{op: "templates"}` (URI templates) or `{op: "read", uri: ...}`".
- MANUAL: 1152-1154 spill path "readable with niffler_edit, niffler_grep or bash" | CODE: shipped tool names are `read`, `grep`, `bash`; `niffler_edit`/`niffler_grep` are the `plugins` package names, not tool names | FIX: "readable with `read`, `grep` or `bash`". Same wording issue elsewhere in MANUAL (grep `niffler_edit`) if the audit of `edit`/`grep` lands the same call.
- MANUAL: 1102 Shape block shows `binary: var/bin/mcp-bridge` | CODE: the path is `NIF_MCP_BRIDGE_BIN` when set, else `<NIF_ROOT>/var/bin/mcp-bridge` (`components/mcp/main.go:57-61`; documented only in the env table at 298) | FIX: append one line under the diagram — "`mcp-bridge` is only ever started this way (or by the probe with `--probe`); the path is `NIF_MCP_BRIDGE_BIN`, default `<root>/var/bin/mcp-bridge`, and the manager re-spawns the child after a crash or drift."
- MANUAL: 1099-1105 Shape says the bridge is one supervised process per server | CODE: the bridge itself re-reads the store record at boot, returns **0** immediately when `enabled: false`, and exits 1 on identity mismatch or unreadable record (`components/mcp-bridge/main.go:483-506`; `enabled()` at `:60`) | FIX: add one sentence — "The bridge carries no config on its argv: it re-reads the `mcp` record named by `--server` at startup (so the record is the single source of truth) and exits immediately if that record is disabled."
- MANUAL: 1233-1240 Registry bullet describes `mcp_search` behavior but not its failure modes | CODE: 10 s HTTP timeout, 4 MiB response cap, non-200 ⇒ `registry returned status N`, unreachable ⇒ `registry unreachable: …` (`components/mcp/main.go:296-320`) | FIX: append "Failures are reported verbatim (`registry unreachable: …`, `registry returned status N`, `bad registry payload`); browsing never mutates anything — nothing installs until the returned args are passed to `mcp_add`."
- MANUAL: absent (no mention of the manager's live-state lookup anywhere; `mcp_servers` at 1205 only promises "live bridge state") | CODE: live state comes from one `catalog {op: snapshot}` plus a per-server 1 s `bridge_status` call capped at 8 concurrent calls (`components/mcp/main.go:242-258`); a catalog outage yields `live: false` rather than an error (`:171-176`) | FIX: add to the `mcp_servers` row — "a stalled bridge never blocks the listing (1 s status timeout, 8 concurrent); if the catalog is unreachable the row reports `live: false` instead of failing."
- MANUAL: 80 shipped-component row lists `mcp_servers`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh` in parentheses | CODE: `mcp_search` is also a component tool (`components/mcp/main.go:148`) | FIX: add `mcp_search` to that enumeration (keeps it consistent with the corrected table).
- MANUAL: 1167-1194 record example | CODE: field set matches `serverConfig` exactly (`components/mcp/types.go:14-31`), including `prompts`; the example's `"enabled": true` is correct as default-true (`components/mcp-bridge/main.go:60`) | OK — no change. (Noted so the record schema is not "fixed" by mistake.)
- MANUAL: 1211-1213 "asks for approval twice by design" | CODE: confirmed — the `mcp_add` gate (`components/mcp/main.go:98`) plus core's `core.spawn` gate; `mcp_edit` adds a third for the respawn, and `mcp_remove` gates `mcp_remove` + `core.remove` | FIX (optional, for completeness): "`mcp_edit` likewise asks twice (edit + respawn) and `mcp_remove` twice (remove + `core.remove`)."

## 6. Not user-facing

Nothing here needs a caveat of the "operator-only" kind: every tool is documented
and every knob is an env var. Two items are deliberately *internal* and should
**stay** out of the MANUAL beyond a parenthetical: the hidden helper
`mcp_<server>_bridge_status` (`components/mcp-bridge/operations.go:411`, called by
`mcp_servers`/`mcp_refresh` at `components/mcp/main.go:775-779`) and the
`--probe`/`--stdio-guard` argv of `mcp-bridge`
(`components/mcp-bridge/main.go:454-466`) — the latter is already correctly
described as an implementation detail inside the Sandboxing bullet.

## Summary

MANUAL coverage of `mcp` is already strong and structurally correct (section
placement, store kind, transport list, sandboxing, spill, drift, registry are all
accurate). The 15 deltas above are refinements: one missing tool row
(`mcp_search`), one wrong approval generalization, three incomplete failure paths
(parked `enabled: false`, spawn-failure `warning`, drift persist-failure
fail-closed), two timeout/threshold semantics (`NIF_MCP_PROBE_TIMEOUT_MS` override
direction, `NIF_MCP_DIRECT_THRESHOLD` read by the bridge), one naming collision
in the prompt tools, two missing ops/fields (`resources.templates`, bridge
re-reads its record), plus naming/link touch-ups.
