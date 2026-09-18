# Worklist slice: Minimal boot profile

From `worklist.tsv` (2 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A013 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 84-99 "filters the manifest boot set to exactly three service components … Persisted components … are deliberately not restored … Minimal mode is only a boot profile, not a policy boundary — a caller can still use `core.spawn`"
- CODE: `core/niffler.nim:25` (`minimalComponents = ["store","bash","llm"]`), `:473` (skip non-minimal autostart), `:593-594` ("minimal mode — persisted spawned components stay stopped") ✔
- FIX: none.

## A014 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 100-108 "neither `provider` nor `models` is present … `llm` uses its small built-in model table and then a 128K fallback"
- CODE: `components/llm/main.go:91-96` (`knownContext` = deepseek-chat/deepseek-reasoner/syn:large:text/zai-org/glm-5.3-flash), `:146` lookup then conservative fallback ✔ — but the two DeepSeek ids are **retired upstream** (docs/research/DEEPSEEK.md §3)
- FIX: keep the mechanics; add "`NIF_OPENAI_CONTEXT` is the only correct answer on DeepSeek today — the built-in table still lists the discontinued `deepseek-chat`/`deepseek-reasoner` ids".

