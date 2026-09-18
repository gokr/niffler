# Worklist slice: Environment variables

From `worklist.tsv` (14 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A024 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: the 87-row table
- CODE: every documented name exists in code (checked name-by-name against `core/ components/ sdk/ ui/ scripts/ tests/ Makefile manifest.yaml .env.example`: zero misses) ✔
- FIX: none — this table is accurate and is the best section in the file.

## A025 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: absent — shell/Makefile-only knobs are not listed anywhere
- CODE: `NIF_BIN_DIR` (`scripts/install.sh:43`), `NIF_LSP_BIN` (`scripts/install-lsp.sh:22`), `NIF_BUILD_LOCK` (`scripts/with-build-lock.sh:22`), `NIF_NATS_CLI` (`components/dialog/dialog.sh:44`), `NIF_STORE_BIN`, `NIF_REPO_ROOT` (test helpers), `NIF_CONF_KEEP`
- FIX: add a third short table "build/script knobs (not read by components)" with those five; today a reader cannot tell them from the runtime set.

## A026 (doc-edit, dup:mechanisms.md §X.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 368 "`.env.example` … is the complete reference: every `NIF_*` variable"
- CODE: `.env.example` omits `NIF_AUTO_CONTINUE`, `NIF_REPOMAP_MIN_CENSUS/_BYTES/_SYMBOLS/_FILES` while the MANUAL table lists them
- FIX: add the five lines to `.env.example`, or soften the sentence to "the reference copy of the documented runtime variables". `[dup]` mechanisms.md §X.

## A262 (doc-edit)
source: `config.md`

- MANUAL: MANUAL:330 `NIF_AUTO_APPROVE` "→ the approval gate (below) is bypassed"
- CODE: core/approval.nim:263 `proc askContinue` returns true when `NIF_AUTO_APPROVE == "1"` **or** `NIF_AUTO_CONTINUE == "1"` — so AUTO_APPROVE also answers every `/limit` keep-going question with yes, which MANUAL:515-516 attributes to AUTO_CONTINUE alone (auto-approve in `proc ask` is :272)
- FIX: append to the AUTO_APPROVE row: "also answers every `/limit` keep-going question with yes (implies `NIF_AUTO_CONTINUE`)"; and in the `/limit` prose: "`NIF_AUTO_CONTINUE=1` (or `NIF_AUTO_APPROVE=1`) answers …"

## A386 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:283` `NIF_OPENAI_CONTEXT` default cell "`models` catalog, then `llm` fallback"; `:108` "its small built-in model table and then a 128K fallback"
- CODE: `main.go:114-153`
- FIX: give the real order — stored provider `context`, then `NIF_OPENAI_CONTEXT`, then the catalog, then the built-in table, then 128000 — and name the built-in entries (`deepseek-chat`/`deepseek-reasoner` 1M, `syn:large:text` 524288, `zai-org/glm-5.3-flash` 524288), flagging that the table is code-resident and needs a source change for a new model.

## A387 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:286` `NIF_LLM_PROVIDERS` "`{nickname: {baseUrl, apiKey, model, context, catalog}}`"
- CODE: `main.go:62-74`, `:292-295`
- FIX: document the full provider object: `protocol` (default `openai-chat`; also `anthropic`, `openai-codex`), `authType` (default `api_key`), `accountId`, and `stripPrefix` — the latter rewrites `alibaba/glm-5.2` to `glm-5.2` for gateways that route on the canonical id (`main.go:508-511`, `:629-634`). Note that a malformed `NIF_LLM_PROVIDERS` JSON and a missing `apiKey` both fail the call explicitly.

## A394 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:308` `NIF_LLM_RETRY_AFTER_CAP_MS` "upper bound honored from a server `retry-after` hint"
- CODE: `main.go:536-578`
- FIX: name the mechanism: `llm` wraps the HTTP client, parses `Retry-After` (seconds or HTTP date), and appends `; retry-after-ms: <n>` to the provider's error message so core can honor the wait without each adapter depending on the same client library. Invalid/absent headers leave the error untouched.

## A398 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:279` `NIF_OPENAI_API_KEY` "Required for any conversation turn"
- CODE: `main.go:296-298`
- FIX: keep, but make the failure explicit: with no key at all the adapter refuses before any HTTP request with `provider "default": no API key (set NIF_OPENAI_API_KEY or NIF_LLM_PROVIDERS apiKey)`, which is a different symptom from the troubleshooting row's HTTP 401/403 (`:2318`, a key that exists but is rejected).

## A408 (code-bug?)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:302` "`NIF_LSP_BIN_DIRS` | extra directories searched for server binaries beyond PATH (tilde-expanded)"
- CODE: `components/lsp/roots.nim:77-82` (splits on `PathSep`, no tilde expansion — a `~/x` entry never matches)
- FIX: either drop "(tilde-expanded)" for "colon-separated **absolute** directories", or add `expandTilde` in `fallbackBinDirs`; the doc-side fix is cheaper and the current claim is wrong.

## A421 (doc-edit)
source: `components/mcp.md`

- MANUAL: MANUAL: 340 `NIF_MCP_PROBE_TIMEOUT_MS` "overrides the 30s default and the call's own `timeoutMs` when higher"
- CODE: any positive value wins unconditionally — `if raw != "" { … timeout = ms }` after the `timeoutMs` branch (`components/mcp/main.go:465-472`), same in the bridge's own probe (`components/mcp-bridge/main.go:437-443`)
- FIX: "timeout for one real-connect probe in `mcp_add`/`mcp_edit`; when set (positive) it wins over both the 30 s default and the server's own `timeoutMs`".

## A440 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :290 `NIF_MODELS_OFFLINE` "`1` disables remote catalog refresh"
- CODE: catalog.go:596-598 returns early only inside `refreshBaseline`; the per-source loop still calls registered plugin tools (catalog.go:552-559, e.g. `llm`'s live-id probe)
- FIX: update — "`1` stops the component downloading models.dev; the cached/seed baseline plus all plugin sources are still used, and source tools are still called. Combine with `NIF_MODELS_REFRESH_INTERVAL=0` for a fully static catalog."

## A441 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :288 `NIF_MODELS_PATH` "pinned local baseline catalog"
- CODE: catalog.go:581-589 — while it is set, `refreshBaseline` never fetches `NIF_MODELS_URL`, and the baseline status is `active` with that file as origin, so `force` cannot refresh it
- FIX: update — "While set, this file *is* the baseline: the component never downloads `NIF_MODELS_URL` (not even with `models_refresh {force:true}`), and changes to the file are picked up on the next refresh. Plugin sources and the override still apply."

## A442 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :292 `NIF_MODELS_CACHE_TTL` "minimum age before refetching the baseline"
- CODE: catalog.go:151-153 (`"0"` → 0) and 636-642 (`cacheTTL <= 0` ⇒ never fresh)
- FIX: update — "…; `0` disables the cache window so every refresh refetches the baseline."

## A453 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing number] What truncation keeps.** `truncateSpool` keeps `min(SPOOL_KEEP = 2 MiB, cap div 2)` bytes (`main.nim:39, 199-217`) and the truncating poll appends `[spool truncated to its tail — the cap was reached]` (`main.nim:404`). MANUAL:1051-1052 says only "truncated to its tail". → state "keeps the last 2 MiB (or half the cap, whichever is smaller)".

