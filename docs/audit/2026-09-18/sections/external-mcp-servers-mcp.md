# Worklist slice: External MCP servers (mcp)

From `worklist.tsv` (12 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A063 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1116-1122 name rule "≤32 chars, `bridge` reserved; **≤100 servers per harness**; tool names … capped at 64 chars"
- CODE: `components/mcp/types.go:54-55` (32-char pattern, bridge reserved at `main.go:398`), `types.go:87` (64-char tool names); **no server-count cap was found** (`grep -rn 'maxServers\|serverLimit' components/mcp/*.go` → nothing; the manager reads up to 1000 records at `main.go:170`)
- FIX: **remove** "≤100 servers per harness" — it is enforced nowhere (see (X) item 5); if a cap is wanted, say so in the code first.

## A064 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1173-1183 record example (`idleMs` 5 min, `timeoutMs` 120 s)
- CODE: `main.go:92-93` (timeout 0 ⇒ 120 s, idle default 300000), `:440` (both clamped 0..86400000 = 24 h) ✔
- FIX: none.

## A065 (doc-edit, dup:mechanisms.md for)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1199-1207 tools table (5 rows: `mcp_servers`/`add`/`edit`/`remove`/`refresh`)
- CODE: a sixth tool `mcp_search` exists (`components/mcp/main.go:148`), and the bridge also registers per-server `mcp_<server>_resources` (`mcp-bridge/operations.go:379`) and `mcp_<server>_prompt` (hidden)
- FIX: add `mcp_search` to the table and a "per-server tools appear after `mcp_add`" note. `[dup]` mechanisms.md for `mcp_search`.

## A066 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1210-1213 "Adding an MCP server therefore asks for approval twice by design: once for the `mcp_add` itself, once for the `core.spawn` it triggers"
- CODE: `main.go:98,123,134` (the three write gates) plus core's own spawn gate (`core/dispatch.nim:273-276`) ✔
- FIX: none.

## A067 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1188-1196 "MCP results ≤64 KiB are returned inline; larger results are spilled to `$NIF_ROOT/var/mcp-results/result-*.json`"
- CODE: `mcp-bridge/operations.go:19` (`inlineLimit = 64 * 1024`), `:152` (`var/mcp-results`), `:180` (`spill` + `truncated`) ✔
- FIX: none.

## A068 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1136-1150 (name collision rejection, `[mcp:<server>]` provenance prefix, onDemand default, `expose: direct` + `NIF_MCP_DIRECT_THRESHOLD`)
- CODE: `mcp-bridge/operations.go:322` (threshold), `main.go:90` (expose enum), `types.go:111-122` (≤32 prompts / ≤16 args) ✔
- FIX: none.

## A418 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1201 `"All on the `mcp` component, all on-demand; writes are approval-gated:"`
- CODE: `mcp_refresh` declares only `{"onDemand": true}` (`components/mcp/main.go:145`), and `mcp_servers`/`mcp_search` are reads
- FIX: update — "All on the `mcp` component, all on-demand. `mcp_add`, `mcp_edit` and `mcp_remove` are approval-gated (as is the `core.spawn`/`core.remove` they issue); `mcp_refresh`, `mcp_servers` and `mcp_search` are not — refreshing only re-lists an already-approved server."

## A422 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1117-1122 Exposure says `"expose": "direct"` puts a server's tools into new conversations
- CODE: the bridge defers the **whole server** back to on-demand when it has more than `NIF_MCP_DIRECT_THRESHOLD` (default 10) cached tools (`components/mcp-bridge/operations.go:329-331`, `:321-327`)
- FIX: append "— unless the server publishes more than `NIF_MCP_DIRECT_THRESHOLD` tools (default 10), in which case the bridge defers the entire server to on-demand. The threshold is read by the bridge process at startup, so it is fixed for that child's lifetime (change it and restart the bridge)."

## A424 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1217-1219 "Each server prompt is registered as a hidden catalog tool `mcp_<server>_prompt`" reads as one tool per server
- CODE: two distinct hidden names exist — the generic renderer `mcp_<server>_prompt` (`components/mcp-bridge/operations.go:380`) **and** one `mcp_<server>_prompt_<promptname>` per prompt (`:401-409`), the latter being the slash command's `Tool`
- FIX: "Each server prompt is registered as a hidden catalog tool `mcp_<server>_prompt_<promptname>` plus a slash command `mcp-<server>-<promptname>`; a second hidden generic tool `mcp_<server>_prompt` lets clients render any prompt by name. Both are invisible to the LLM (`x-harness.hidden`)."

## A425 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1228-1229 "`{op: "list"}` or `{op: "read", uri: ...}`"
- CODE: the op enum is `list | templates | read`, and `templates` returns URI templates (`components/mcp-bridge/operations.go:379`, `:268-317`)
- FIX: "`{op: "list"}`, `{op: "templates"}` (URI templates) or `{op: "read", uri: ...}`".

## A427 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1102 Shape block shows `binary: var/bin/mcp-bridge`
- CODE: the path is `NIF_MCP_BRIDGE_BIN` when set, else `<NIF_ROOT>/var/bin/mcp-bridge` (`components/mcp/main.go:57-61`; documented only in the env table at 298)
- FIX: append one line under the diagram — "`mcp-bridge` is only ever started this way (or by the probe with `--probe`); the path is `NIF_MCP_BRIDGE_BIN`, default `<root>/var/bin/mcp-bridge`, and the manager re-spawns the child after a crash or drift."

## A433 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 1211-1213 "asks for approval twice by design"
- CODE: CODE: confirmed — the `mcp_add` gate (`components/mcp/main.go:98`) plus core's `core.spawn` gate; `mcp_edit` adds a third for the respawn, and `mcp_remove` gates `mcp_remove` + `core.remove`
- FIX: FIX (optional, for completeness): "`mcp_edit` likewise asks twice (edit + respawn) and `mcp_remove` twice (remove + `core.remove`)."

