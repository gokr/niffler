# Worklist slice: component: mcp

From `worklist.tsv` (7 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A419 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1203-1209 tools table has five rows, no `mcp_search`
- CODE: `mcp_search` is a registered on-demand read tool (`components/mcp/main.go:148-158`); it only appears in prose at 1233
- FIX: add row — "| `mcp_search` | keyword search of the official MCP Registry; returns `installable` entries with ready `name`/`type`/`command`/`args`/`url` for `mcp_add`, others with the reason (`limit` default 10, max 20) |". Also rename the table's `Effect` column to `Purpose` (its cells are purposes, not `read`/`write`).

## A421 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 340 `NIF_MCP_PROBE_TIMEOUT_MS` "overrides the 30s default and the call's own `timeoutMs` when higher"
- CODE: any positive value wins unconditionally — `if raw != "" { … timeout = ms }` after the `timeoutMs` branch (`components/mcp/main.go:465-472`), same in the bridge's own probe (`components/mcp-bridge/main.go:437-443`)
- FIX: "timeout for one real-connect probe in `mcp_add`/`mcp_edit`; when set (positive) it wins over both the 30 s default and the server's own `timeoutMs`".

## A426 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1152-1154 spill path "readable with niffler_edit, niffler_grep or bash"
- CODE: shipped tool names are `read`, `grep`, `bash`; `niffler_edit`/`niffler_grep` are the `plugins` package names, not tool names
- FIX: "readable with `read`, `grep` or `bash`". Same wording issue elsewhere in MANUAL (grep `niffler_edit`) if the audit of `edit`/`grep` lands the same call.

## A428 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1099-1105 Shape says the bridge is one supervised process per server
- CODE: the bridge itself re-reads the store record at boot, returns **0** immediately when `enabled: false`, and exits 1 on identity mismatch or unreadable record (`components/mcp-bridge/main.go:483-506`; `enabled()` at `:60`)
- FIX: add one sentence — "The bridge carries no config on its argv: it re-reads the `mcp` record named by `--server` at startup (so the record is the single source of truth) and exits immediately if that record is disabled."

## A430 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: absent (no mention of the manager's live-state lookup anywhere; `mcp_servers` at 1205 only promises "live bridge state")
- CODE: live state comes from one `catalog {op: snapshot}` plus a per-server 1 s `bridge_status` call capped at 8 concurrent calls (`components/mcp/main.go:242-258`); a catalog outage yields `live: false` rather than an error (`:171-176`)
- FIX: add to the `mcp_servers` row — "a stalled bridge never blocks the listing (1 s status timeout, 8 concurrent); if the catalog is unreachable the row reports `live: false` instead of failing."

## A431 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 80 shipped-component row lists `mcp_servers`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh` in parentheses
- CODE: `mcp_search` is also a component tool (`components/mcp/main.go:148`)
- FIX: add `mcp_search` to that enumeration (keeps it consistent with the corrected table).

## A432 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1167-1194 record example
- CODE: CODE: field set matches `serverConfig` exactly (`components/mcp/types.go:14-31`), including `prompts`; the example's `"enabled": true` is correct as default-true (`components/mcp-bridge/main.go:60`)
- FIX: OK — no change. (Noted so the record schema is not "fixed" by mistake.)

