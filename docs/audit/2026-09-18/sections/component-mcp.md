# Worklist slice: component: mcp

From `worklist.tsv` (9 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A419 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1203-1209 tools table has five rows, no `mcp_search`
- CODE: `mcp_search` is a registered on-demand read tool (`components/mcp/main.go:148-158`); it only appears in prose at 1233
- FIX: add row — "| `mcp_search` | keyword search of the official MCP Registry; returns `installable` entries with ready `name`/`type`/`command`/`args`/`url` for `mcp_add`, others with the reason (`limit` default 10, max 20) |". Also rename the table's `Effect` column to `Purpose` (its cells are purposes, not `read`/`write`).

## A420 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1206 `mcp_add` row mentions only the validate→store→spawn happy path
- CODE: `enabled: false` stores a parked config with *no probe, no spawn* (`components/mcp/main.go:563-583`); a spawn that never registers returns `{"ok": true, "warning": "stored but bridge did not start: …"}` and the record is kept (`components/mcp/main.go:606-608`, `:525-544`)
- FIX: extend — "`enabled: false` stores a parked config without connecting or spawning (`mcp_edit {enabled: true}` activates it later). If the bridge does not register within 15s the record is still stored and the call returns `ok` plus a `warning` naming `var/logs/mcp-<server>.log`; re-run `mcp_refresh` or `mcp_edit` after fixing the server."

## A423 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1155-1159 Drift describes persist-and-exit-3 as best effort
- CODE: on persist failure after 3 rev-retries the bridge does **not** exit — it enters a fail-closed `retiring` state, surfaces `"contract drift could not be persisted; edit/refresh to recover: …"` in `bridge_status`, and refuses `refresh` while calls are in flight (`components/mcp-bridge/main.go:249-272`, `components/mcp-bridge/operations.go:397-413`)
- FIX: append "If the refresh cannot be persisted the bridge fails closed in a *retiring* state instead of crash-looping: `mcp_servers` shows the error and the server needs `mcp_refresh` (after active calls finish) or `mcp_edit` to recover."

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

## A429 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1233-1240 Registry bullet describes `mcp_search` behavior but not its failure modes
- CODE: 10 s HTTP timeout, 4 MiB response cap, non-200 ⇒ `registry returned status N`, unreachable ⇒ `registry unreachable: …` (`components/mcp/main.go:296-320`)
- FIX: append "Failures are reported verbatim (`registry unreachable: …`, `registry returned status N`, `bad registry payload`); browsing never mutates anything — nothing installs until the returned args are passed to `mcp_add`."

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

