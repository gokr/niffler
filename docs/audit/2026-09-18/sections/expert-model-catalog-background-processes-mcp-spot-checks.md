# Worklist slice: Expert, §Model catalog, §Background processes, §MCP (spot checks)

From `worklist.tsv` (4 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A171 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: mcp tools table lists `mcp_servers`/`mcp_add`/`mcp_edit`/`mcp_remove`/`mcp_refresh`
- CODE: `components/mcp/main.go:148` also registers **`mcp_search`** (registry search; referenced only in prose at MANUAL 1234, "registry search against the mock")
- FIX: add an `mcp_search` row to the tools table.

## A172 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: §Processes table (4 tools)
- CODE: CODE: `components/processes/main.nim:491-530` exactly 4, `process_start`/`process_kill` approval-gated ✔ (but see the approvals-list finding above).

## A173 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: §Model catalog tools table (6 tools)
- CODE: CODE: `components/models/main.go:93,113,136,163,183,204` exactly those 6, all `onDemand` ✔.

## A174 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: §LSP tools table (3 tools incl. `warmup`), §Fetch (1 tool), §Skills ("all eight tools"), §Hooks (env-driven, no tools) all match CODE (`components/lsp/main.nim:1063,1082,1087`; `components/fetch/main.nim:258`; `components/skills/main.nim:256-577`; `components/hooks/main.nim`) ✔.

