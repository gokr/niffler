# Worklist slice: component: models

From `worklist.tsv` (4 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A439 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1671-1679 "only reports which credential environment names a provider uses and whether one is set"
- CODE: catalog.go:837-859 also marks a provider configured when `NIF_OPENAI_API_KEY` is set for `deepseek`, and when the provider id appears as a nickname in `NIF_LLM_PROVIDERS`; the flag is attached to `models_providers`, `models_list` and `models_get` results (catalog.go:917-957 (providers), 960-1013 (models), 1059-1071 (get))
- FIX: update — "Configured means: one of the provider's `env` names is set, or the id appears in `NIF_LLM_PROVIDERS`, or (for `deepseek`) the shipped `NIF_OPENAI_API_KEY` is set. The flag is computed at call time and appears on provider and model results; values are never returned."

## A440 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :290 `NIF_MODELS_OFFLINE` "`1` disables remote catalog refresh"
- CODE: catalog.go:596-598 returns early only inside `refreshBaseline`; the per-source loop still calls registered plugin tools (catalog.go:552-559, e.g. `llm`'s live-id probe)
- FIX: update — "`1` stops the component downloading models.dev; the cached/seed baseline plus all plugin sources are still used, and source tools are still called. Combine with `NIF_MODELS_REFRESH_INTERVAL=0` for a fully static catalog."

## A443 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1546 "refreshes at startup and hourly"
- CODE: main.go:217 (interval from `NIF_MODELS_REFRESH_INTERVAL`, default 1h, `0` disables the ticker) plus main.go:70-88, 281 (startup, every `reg.publish`/`reg.depart`, every `ev.catalog.updated`)
- FIX: update — "The component refreshes at startup, whenever the component catalog changes (registration or departure), and then on `NIF_MODELS_REFRESH_INTERVAL` (default one hour; `0` disables the periodic tick)."

## A448 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1536-1547 documents the merge layers but not what a patch may touch or that `id`/`name` are synthesized
- CODE: catalog.go:290-310 (RFC 7396 object merge, arrays/scalars replace, `null` deletes), :312-344 (`normalizeCatalog` fills a missing `id`/`name` from the map key and drops non-object providers/models), tests/t_models.nim:111-124 (a patch can add a whole provider)
- FIX: add — "A patch may add an entire provider, add models under an existing one, or change any field, because the full models.dev shape is preserved; `null` deletes a key (including a whole model). A provider or model that omits `id`/`name` has them filled from its map key, and non-object entries are dropped during normalization."

