# Worklist slice: Language servers (lsp)

From `worklist.tsv` (7 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A054 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 949-961 ("all three tools are on-demand", `lsp` read-only/approval-free, `lsp_registry` approval-gated)
- CODE: `components/lsp/main.nim:1085` (lsp: onDemand, `effect: read`), `:1090` (lsp_servers), `:1098` (lsp_registry: onDemand + `approval: always`) ✔
- FIX: none.

## A055 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 994-996 "the component runs a bounded extension census (stops at 5 000 files or a 2 s budget) and pre-starts servers for the most prevalent languages"
- CODE: `WARM_MAX_FILES = 5000`, `WARM_BUDGET_SECS = 2.0`, **`WARM_MAX_SERVERS = 2`** (`components/lsp/main.nim:741-743,792`)
- FIX: add "at most two servers per workspace (`WARM_MAX_SERVERS`)" — the missing number is what makes a warmup look partial.

## A056 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 968-970 "results are capped (100 locations / 16 KB)"
- CODE: `MAX_LOCATIONS = 100` (`:40`) and "result caps (100 locations / 16000 chars)" (`:25`) — 16 000 **chars**, not 16 KiB
- FIX: say "100 locations / ~16 000 characters".

## A057 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 1031 "The registry is re-read on every call, so edits take effect immediately"
- CODE: accurate — `loadRegistry()` is called on every operation path (`components/lsp/main.nim:783,872,952,984,1225`)
- FIX: none.

## A058 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 1021-1024 "Built-in defaults — gopls, nimtortoise, typescript-language-server, pyright, rust-analyzer, clangd, bash-language-server, jdtls, csharp-ls"
- CODE: `components/lsp/main.nim:76-92` lists exactly gopls, nimtortoise, typescript-language-server, pyright (as `pyright-langserver --stdio`), rust-analyzer, clangd, bash-language-server, jdtls, csharp-ls ✔
- FIX: none.

## A373 (doc-edit)
source: `components/git.md`

- MANUAL: **`review_receipt` writes without approval and is not named in the approvals chapter** (MANUAL:455-470; its schema has neither `approval` nor `effect`, `main.nim:364`). Say so instead of letting "read-only, approval-free" (MANUAL:67) cover the write.

## A405 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:948` "| `lsp {operation, path, line?, character?}` |"
- CODE: `components/lsp/main.nim:1063-1078`
- FIX: update signature to `lsp {operation, path, query?, line?, character?, workspaceRoot?}` and add one clause: "`workspaceRoot` pins the server root; without it the root is derived from the file's nearest module marker (`go.mod`, `Cargo.toml`, `tsconfig.json`/`package.json`, `pyproject.toml`, `*.nimble`, …), falling back to the workspace."

