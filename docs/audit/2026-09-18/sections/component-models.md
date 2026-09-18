# Worklist slice: component: models

From `worklist.tsv` (7 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A434 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1562-1571 lists the six tools but never says they are on-demand
- CODE: components/models/main.go:100,126,144,171,189,208 (`"x-harness":{"onDemand":true}` on all six), contrast lsp/git rows :70-71 "On-demand tools"
- FIX: add — "All six tools are `onDemand`: they are absent from a conversation's frozen direct toolset, so the model reaches them through `discover` + `invoke` (docs/MANUAL.md:1283). Components and `cli call` address them directly by name. Nothing here is `hidden`, so `/discover tool=models_sources` shows them."

## A435 (trim)
source: `components/models.md`

- MANUAL: MANUAL: :1566-1571 gives no arguments or result shape
- CODE: main.go:96-98,116-124,139-141,166-168,186-187,1025-1047; result envelopes main.go:30-47 (900 KiB, halving, `truncated`), catalog.go:1059-1071
- FIX: add one compact line per tool listing args and defaults (`limit` default 50 / max 500; `models_get` requires `provider`+`model`) and a sentence — "List-style results are `{models|providers, count, total}` and are trimmed with `truncated: true` when they would exceed the bus payload limit; one oversized `models_get` descriptor errors instead of timing out."

## A437 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1570 "queue a refresh"
- CODE: main.go:190-200 returns the previous report with `queued:true`/`force`; the work happens on the worker after a 150 ms coalescing window (main.go:237-249) and reports through `models_sources` / `ev.models.updated` (catalog.go:567-571)
- FIX: add — "`models_refresh` returns immediately with the *current* provenance report plus `queued` and `force`; the refresh runs asynchronously (registration bursts are coalesced over 150 ms), so read `models_sources` again — or wait for `ev.models.updated` — to see the outcome. `force: true` bypasses the cache TTL."

## A438 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :287-293 / :1543 name `NIF_MODELS_OVERRIDE` but the correction path is not actionable — :1669-1681 (`### Configuration`) only points at the env table, and no example file, path convention, or restart requirement appears anywhere
- CODE: catalog.go:113, 365-393 (file read on every rebuild, previous patch kept if unreadable mid-rewrite → `stale`), docs/MANUAL.md:240 (env read once at boot; a change is `core.kill` + `core.spawn`)
- FIX: add a "Local corrections" paragraph — "The cheapest way to fix or add metadata is a JSON Merge Patch file: `{ "deepseek": { "models": { "deepseek-chat": { "limit": { "context": 131072 } } } } }`, pointed at by `NIF_MODELS_OVERRIDE=/abs/path/override.json` (env only, so restart the component with `core.kill` + `core.spawn` after changing it). It is re-read on every rebuild, merges after all plugin patches, and `null` deletes a key. A file that is unreadable mid-rewrite keeps the previous patch and is reported as `stale` by `models_sources`." (Keep the plugin path documented as the durable, shareable option.)

## A439 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1671-1679 "only reports which credential environment names a provider uses and whether one is set"
- CODE: catalog.go:837-859 also marks a provider configured when `NIF_OPENAI_API_KEY` is set for `deepseek`, and when the provider id appears as a nickname in `NIF_LLM_PROVIDERS`; the flag is attached to `models_providers`, `models_list` and `models_get` results (catalog.go:917-957 (providers), 960-1013 (models), 1059-1071 (get))
- FIX: update — "Configured means: one of the provider's `env` names is set, or the id appears in `NIF_LLM_PROVIDERS`, or (for `deepseek`) the shipped `NIF_OPENAI_API_KEY` is set. The flag is computed at call time and appears on provider and model results; values are never returned."

## A448 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1536-1547 documents the merge layers but not what a patch may touch or that `id`/`name` are synthesized
- CODE: catalog.go:290-310 (RFC 7396 object merge, arrays/scalars replace, `null` deletes), :312-344 (`normalizeCatalog` fills a missing `id`/`name` from the map key and drops non-object providers/models), tests/t_models.nim:111-124 (a patch can add a whole provider)
- FIX: add — "A patch may add an entire provider, add models under an existing one, or change any field, because the full models.dev shape is preserved; `null` deletes a key (including a whole model). A provider or model that omits `id`/`name` has them filled from its map key, and non-object entries are dropped during normalization."

## A449 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1669-1681 (end of the section) has no `#### Verification`
- CODE: Makefile:503 (`make test-models`, builds a source plugin through `builder` + `core.spawn` and proves the patch appears and reverts), tests/t_models.nim:16-30 (private bus + `NIF_MODELS_PATH` fixture)
- FIX: add — "`make test-models` boots a private harness with a local fixture catalog and proves registration, strict resolution, and that a built source plugin's patch appears on spawn and disappears on removal. Against a live harness, `./var/bin/cli call models_sources '{}'` prints provenance and `./var/bin/cli call models_get '{\"provider\":\"deepseek\",\"model\":\"deepseek-chat\"}'` one descriptor."

