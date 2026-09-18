# Worklist slice: Shipped components (

From `worklist.tsv` (5 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A142 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 51 "`store` ... document store over the bus (`put/get/list/del`, rev-based concurrency)"
- CODE: `components/store-sqlite/main.go:112-115` (put/get/list/del), flags at `:264` (put onDemand+sessionId), `:358`/`:404` (get/list onDemand), `:498` (del `hidden`)
- FIX: add "(all four are on-demand; `del` is `hidden` — core-only, never offered to the LLM)".

## A143 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 65 "`builder` ... compiles agent-written Nim/Go source into binaries"
- CODE: `components/builder/main.nim:49` (build: approval always + onDemand), `:203` (info onDemand); MANUAL never names the `info` tool
- FIX: "`builder.build` (approval-gated, on-demand) + hidden-support `builder.info`".

## A144 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 66 `lsp` row lists operations "diagnostics, documentSymbol, workspaceSymbol, goToDefinition, findReferences, goToImplementation, hover"
- CODE: `components/lsp/main.nim:1063-1081` (operations enum also has **`warmup`**; three tools: `lsp`, `lsp_servers`, `lsp_registry` — the latter approval-gated at `:1098`)
- FIX: add `warmup`, mention `lsp_servers`/`lsp_registry` (the row currently implies one `lsp` tool only).

## A145 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: line 67 `git` row: "`git_status`/`git_diff`/`git_log`/`git_show`/`git_blame` ... plus `review_receipt`" — matches CODE `components/git/main.nim:185,215,253,290,319,364` (all onDemand; review_receipt not approval-gated) ✔

## A146 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 68 `agent` row: "subagent sessions: `agent_run` — fresh context, own loop, summary returned"
- CODE: `components/agent/main.nim:1004,1149,1254,1278,1316,1346,1419,1484,1543` = `agent_run`, `agent_spawn`, `agent_status`, `agent_wait`, `agent_stop`, `agent_steer`, `agent_ask`, `agent_notices`, `agent_list` (9 tools)
- FIX: one line naming all nine, or defer to §Fabric and say "nine tools (see Fabric and subagents)".

