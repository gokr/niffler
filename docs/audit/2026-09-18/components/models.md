# Audit — `components/models` (Go, catalog.go 1189 / main.go 285 lines)

MANUAL anchor: `## Model catalog (`models`)` at **docs/MANUAL.md:1518**, subsections
`### Merge order` 1536, `### Tools` 1562, `### Source plugins` 1599,
`### Configuration` 1669. Env rows docs/MANUAL.md:287-293; shipped-component row
:60; contents entry :22; `var/` cache row :244; `ev.models.updated` :400.

## 1. What it offers

`models` is the replaceable provider/model metadata plane: it answers which
providers and models exist, how they are addressed, what they support, and
their limits/prices — never the inference wire protocol (components/models/main.go:1,
catalog.go:1-30). The effective catalog is `models.dev` baseline (or
`NIF_MODELS_PATH` file, or the embedded DeepSeek-only seed) + every registered
`x-models-source` plugin patch (ascending priority) + `NIF_MODELS_OVERRIDE`
last (catalog.go:346-393, 161-198). It caches the baseline atomically in
`var/models/api.json` and each source's last-known-good patch in
`var/models/sources/<component>--<tool>.json` (catalog.go:110, 779-781, 783-810),
refreshes at startup, on registration change, and on an interval, and never
exposes credential values (redaction at catalog.go:861-905, 907-915).

## 2. Tools

All six are registered with `"x-harness": {"onDemand": true}` and no `hidden`
(main.go:93/100, 113/126, 136/144, 163/171, 183/189, 204/208) → **discover-only**
for the LLM (omitted from a conversation's frozen direct set; reachable via
`discover` + `invoke`, docs/MANUAL.md:1283-1285), but directly callable by
components and by `cli call` (tests/t_models.nim:44).

| Tool | file:line | doc-comment purpose | args |
|---|---|---|---|
| `models_providers` | main.go:93 | List known LLM providers and their connection metadata without exposing credentials | `query`, `configured` |
| `models_list` | main.go:113 | Search the effective model catalog after models.dev, plugin corrections, and local overrides are merged | `provider`, `query`, `status`, `input`, `reasoning`, `toolCall`, `configured`, `limit` (default 50, max 500 — main.go:124, catalog.go:961-965) |
| `models_get` | main.go:136 | Get one exact provider/model descriptor (connection metadata, capabilities, limits, pricing) | `provider`+`model` (required) |
| `models_resolve` | main.go:163 | Resolve an exact provider/model reference without silently choosing among ambiguous providers | `reference` (required), `provider` |
| `models_refresh` | main.go:183 | Queue a refresh of models.dev and every registered model-source plugin, retaining each last-known-good result on failure | `force` |
| `models_sources` | main.go:204 | Show catalog provenance and health: baseline, plugin patches, stale fallbacks, local override | none |

Result shapes (all undocumented in the MANUAL): list-style results are
`{<key>, count, total, truncated?}`, halved until they fit 900 KiB
(main.go:30-47); a single oversized `models_get` descriptor errors instead
(main.go:146-148). `models_get`/`resolve` return
`{provider, model, reference, configured, updatedAt}` (catalog.go:1059-1071);
`models_refresh` returns the *pre-refresh* report plus `queued`/`force`
(main.go:197-200) — the refresh itself happens asynchronously after a 150 ms
coalescing window (main.go:237-249). `models_list {status:"active"}` treats a
missing status as active and missing `tool_call` as true
(catalog.go:1015-1032). Filtering/search detail is at catalog.go:960-1056.

## 3. Configuration

Env vars (code site → default; MANUAL row):

| Var | code | default | meaning |
|---|---|---|---|
| `NIF_MODELS_URL` | catalog.go:98-105 | `https://models.dev/api.json` (catalog.go:25) | base URL; `/api.json` appended only when the last path segment has no `.json` |
| `NIF_MODELS_PATH` | catalog.go:112 | unset | local baseline file; when set the remote URL is **never** fetched (catalog.go:581-583) |
| `NIF_MODELS_OVERRIDE` | catalog.go:113 | unset | JSON file, RFC 7396 merge patch applied last (catalog.go:365-393) |
| `NIF_MODELS_OFFLINE` | catalog.go:114 (`envBool`) | false | skips only the models.dev download (catalog.go:596-598) |
| `NIF_MODELS_CACHE_DIR` | catalog.go:94-97 | `$NIF_ROOT/var/models` | baseline cache + `sources/` subdir |
| `NIF_MODELS_CACHE_TTL` | catalog.go:115 | `5m` | baseline cache freshness; `0` ⇒ never fresh (catalog.go:151-153, 636-642) |
| `NIF_MODELS_REFRESH_INTERVAL` | main.go:217 | `1h` | periodic tick; `0` disables it (main.go:221-225) |

Also read for the `configured` flag: the provider's `env` names, the DeepSeek
special case `NIF_OPENAI_API_KEY`, and `NIF_LLM_PROVIDERS` nicknames
(catalog.go:837-859).

- **Cache/seed**: baseline `var/models/api.json` written atomically
  (catalog.go:110, 783-810); per-source patches
  `var/models/sources/<component>--<tool>.json` with non-`[A-Za-z0-9-_.]` chars
  mapped to `_` (catalog.go:748-756, 779-781). Embedded `seed.json`
  (`//go:embed`, catalog.go:31-34) contains exactly one provider (DeepSeek,
  2 models: `deepseek-chat`, `deepseek-reasoner`) so a first offline boot
  keeps the shipped setup; provenance in components/models/NOTICE.md:1-8.
- **Merge order**: baseline → sources sorted by `priority` ascending, ties by
  `component/tool` (catalog.go:347-360) → override. `normalizeCatalog`
  synthesizes a missing provider/model `id` and `name` from the map key
  (catalog.go:312-344), so a patch may omit them.
- **Registration contract** (`x-models-source`): read from `reg.publish` and
  from core's `catalog {op: snapshot}` (catalog.go:439-453, 483-527; snapshot
  request 3 s timeout). `version` must be exactly `1` or the tool is ignored
  (catalog.go:421-425); `priority` defaults to `100` (catalog.go:26, 426-429).
  The tool is called with `{"version": 1}` under a 30 s timeout and must return
  `{"patch": {…}}`; an absent/`null` patch is an error that falls back to the
  cached patch (catalog.go:690-746). A `hidden` flag is convention, not the
  registration mechanism.
- **Patch scope**: any provider/model key — add providers, correct
  `limit.context`, add ids, or delete with `null` (catalog.go:290-310,
  tests/t_models.nim:76-130). Redaction happens on the way out
  (catalog.go:861-915), so a patch cannot leak a secret; `configured` is
  computed, never stored.
- **Refresh rules**: startup + interval + every `reg.publish`/`reg.depart`/
  `ev.catalog.updated` (main.go:70-88, 281); baseline skipped while the cache
  is younger than the TTL and the fetch is forced only by `models_refresh
  {force:true}` (catalog.go:599-601, main.go:189); HTTP bounded (12 s client
  timeout catalog.go:116, 3 attempts with 200/400 ms backoff, 16 MiB cap,
  fail-fast on non-5xx/429, empty catalog rejected — catalog.go:232-263,
  644-688); a failed refresh retries after `min(30s, interval)`
  (main.go:246-249); `ev.models.updated` is emitted on success
  (catalog.go:567-571); sources that depart lose their patch immediately
  (catalog.go:455-475). `NIF_MODELS_PATH` also short-circuits
  `refreshBaseline` (catalog.go:581-589).

## 4. MANUAL placement

Existing: `docs/MANUAL.md:1518` heading, `### Merge order` :1536, `### Tools`
:1562, `### Source plugins` :1599, `### Configuration` :1669; env rows :287-293.
Proposed: keep the heading; append (a) an exposure/args paragraph after the
tools table (~:1571), (b) a "Local corrections" paragraph with a worked
`NIF_MODELS_OVERRIDE` example before `### Source plugins`, (c) two contract
bullet lines in `### Source plugins`, and (d) a `#### Verification` subsection
after `### Configuration` (the section is currently the only larger component
section without one; compare `### Verification` at :1245, :1506, :1961).

## 5. DELTA list (17)

- MANUAL: :1562-1571 lists the six tools but never says they are on-demand | CODE: components/models/main.go:100,126,144,171,189,208 (`"x-harness":{"onDemand":true}` on all six), contrast lsp/git rows :70-71 "On-demand tools" | FIX: add — "All six tools are `onDemand`: they are absent from a conversation's frozen direct toolset, so the model reaches them through `discover` + `invoke` (docs/MANUAL.md:1283). Components and `cli call` address them directly by name. Nothing here is `hidden`, so `/discover tool=models_sources` shows them."
- MANUAL: :1566-1571 gives no arguments or result shape | CODE: main.go:96-98,116-124,139-141,166-168,186-187,1025-1047; result envelopes main.go:30-47 (900 KiB, halving, `truncated`), catalog.go:1059-1071 | FIX: add one compact line per tool listing args and defaults (`limit` default 50 / max 500; `models_get` requires `provider`+`model`) and a sentence — "List-style results are `{models|providers, count, total}` and are trimmed with `truncated: true` when they would exceed the bus payload limit; one oversized `models_get` descriptor errors instead of timing out."
- MANUAL: :1569 "strict `provider/model` or globally unique bare-id resolution" | CODE: catalog.go:1088-1151 — success is `{found:true, provider, model, reference, configured, updatedAt}`; ambiguity returns `{found:false, error:"model id is ambiguous; use provider/model", matches:[…]}` (:1130-1136); a miss returns `{found:false, error:"model not found", suggestions:[…]}` (:1144-1151); the `provider/` prefix is split off only when it names a *known* provider (:1090-1096), otherwise the whole string is looked up as a bare id | FIX: add — "`models_resolve` never guesses: a bare id that exists under several providers comes back `found:false` with `matches`, and an unknown reference comes back `found:false` with up to ten `suggestions`. A `provider/model` string whose prefix is not a known provider id is treated as a literal bare id, so a typo'd provider looks like a missing model. On success the answer carries the selected `provider`, `model`, `reference`, `configured` and the catalog `updatedAt`."
- MANUAL: :1570 "queue a refresh" | CODE: main.go:190-200 returns the previous report with `queued:true`/`force`; the work happens on the worker after a 150 ms coalescing window (main.go:237-249) and reports through `models_sources` / `ev.models.updated` (catalog.go:567-571) | FIX: add — "`models_refresh` returns immediately with the *current* provenance report plus `queued` and `force`; the refresh runs asynchronously (registration bursts are coalesced over 150 ms), so read `models_sources` again — or wait for `ev.models.updated` — to see the outcome. `force: true` bypasses the cache TTL."
- MANUAL: :287-293 / :1543 name `NIF_MODELS_OVERRIDE` but the correction path is not actionable — :1669-1681 (`### Configuration`) only points at the env table, and no example file, path convention, or restart requirement appears anywhere | CODE: catalog.go:113, 365-393 (file read on every rebuild, previous patch kept if unreadable mid-rewrite → `stale`), docs/MANUAL.md:240 (env read once at boot; a change is `core.kill` + `core.spawn`) | FIX: add a "Local corrections" paragraph — "The cheapest way to fix or add metadata is a JSON Merge Patch file: `{ "deepseek": { "models": { "deepseek-chat": { "limit": { "context": 131072 } } } } }`, pointed at by `NIF_MODELS_OVERRIDE=/abs/path/override.json` (env only, so restart the component with `core.kill` + `core.spawn` after changing it). It is re-read on every rebuild, merges after all plugin patches, and `null` deletes a key. A file that is unreadable mid-rewrite keeps the previous patch and is reported as `stale` by `models_sources`." (Keep the plugin path documented as the durable, shareable option.)
- MANUAL: :1671-1679 "only reports which credential environment names a provider uses and whether one is set" | CODE: catalog.go:837-859 also marks a provider configured when `NIF_OPENAI_API_KEY` is set for `deepseek`, and when the provider id appears as a nickname in `NIF_LLM_PROVIDERS`; the flag is attached to `models_providers`, `models_list` and `models_get` results (catalog.go:917-957 (providers), 960-1013 (models), 1059-1071 (get)) | FIX: update — "Configured means: one of the provider's `env` names is set, or the id appears in `NIF_LLM_PROVIDERS`, or (for `deepseek`) the shipped `NIF_OPENAI_API_KEY` is set. The flag is computed at call time and appears on provider and model results; values are never returned."
- MANUAL: :290 `NIF_MODELS_OFFLINE` "`1` disables remote catalog refresh" | CODE: catalog.go:596-598 returns early only inside `refreshBaseline`; the per-source loop still calls registered plugin tools (catalog.go:552-559, e.g. `llm`'s live-id probe) | FIX: update — "`1` stops the component downloading models.dev; the cached/seed baseline plus all plugin sources are still used, and source tools are still called. Combine with `NIF_MODELS_REFRESH_INTERVAL=0` for a fully static catalog."
- MANUAL: :288 `NIF_MODELS_PATH` "pinned local baseline catalog" | CODE: catalog.go:581-589 — while it is set, `refreshBaseline` never fetches `NIF_MODELS_URL`, and the baseline status is `active` with that file as origin, so `force` cannot refresh it | FIX: update — "While set, this file *is* the baseline: the component never downloads `NIF_MODELS_URL` (not even with `models_refresh {force:true}`), and changes to the file are picked up on the next refresh. Plugin sources and the override still apply."
- MANUAL: :292 `NIF_MODELS_CACHE_TTL` "minimum age before refetching the baseline" | CODE: catalog.go:151-153 (`"0"` → 0) and 636-642 (`cacheTTL <= 0` ⇒ never fresh) | FIX: update — "…; `0` disables the cache window so every refresh refetches the baseline."
- MANUAL: :1546 "refreshes at startup and hourly" | CODE: main.go:217 (interval from `NIF_MODELS_REFRESH_INTERVAL`, default 1h, `0` disables the ticker) plus main.go:70-88, 281 (startup, every `reg.publish`/`reg.depart`, every `ev.catalog.updated`) | FIX: update — "The component refreshes at startup, whenever the component catalog changes (registration or departure), and then on `NIF_MODELS_REFRESH_INTERVAL` (default one hour; `0` disables the periodic tick)."
- MANUAL: :1599-1630 example shows `{"version": 1, "priority": 200}` but not what is enforced | CODE: catalog.go:421-425 (version must equal 1, otherwise the tool is ignored), :426-429 (`priority` default 100), :350-355 (equal priorities ordered by `component/tool`), :691-693 (called with `{"version":1}`, 30 s timeout), :698-703 (no `patch` object ⇒ error, cached patch kept) | FIX: add — "The contract: the `x-harness.hidden` flag is convention, the `x-models-source` extension is what registers the tool; `version` must be exactly 1 or the tool is skipped; `priority` defaults to 100 and equal priorities are ordered by `component/tool`; the tool is called with `{"version": 1}` and a 30 s deadline, and a result without a `patch` object counts as a failure that keeps the last-known-good patch."
- MANUAL: :1553-1557 says each source has a last-known-good patch "under `var/models/sources/`" but not the file naming or that it is dropped on departure | CODE: catalog.go:779-781 (`<component>--<tool>.json`, unsafe chars → `_` via :748-756), :455-475 (departure removes registration, status and patch), tests/t_models.nim:157-170 | FIX: add — "The file is named `<component>--<tool>.json` (anything outside `A-Za-z0-9-_.` becomes `_`). Removing the component deletes its registration, status and cached patch in one step, so a departed source cannot keep influencing the catalog."
- MANUAL: :1531-1532 "A small embedded seed makes a first offline boot useful" | CODE: components/models/seed.json:2-81 — exactly one provider (`deepseek`, :2) with two models (`deepseek-chat` :12, `deepseek-reasoner` :43); NOTICE.md:1-8 records the models.dev provenance | FIX: update — "The embedded seed is deliberately tiny: the shipped DeepSeek provider with `deepseek-chat` and `deepseek-reasoner` only, so a first offline boot keeps the configured default working. Every other provider/model appears once the baseline is fetched or a source/override supplies it."
- MANUAL: :1546-1550 "bounded, retried, validated" without numbers | CODE: catalog.go:116 (12 s HTTP client timeout), :644-688 (3 attempts, 200/400 ms backoff, 16 MiB cap, fail fast on non-5xx/429), :232-263 (a catalog with no usable model entries is rejected so it cannot replace the last-known-good cache) | FIX: update — "Downloads are bounded (16 MiB, 12 s per request), retried up to three times with 200/400 ms backoff, fail fast on client errors, and are rejected outright when they contain no usable model entries — a bad response can never replace the last-known-good `var/models/api.json`."
- MANUAL: :1536-1547 documents the merge layers but not what a patch may touch or that `id`/`name` are synthesized | CODE: catalog.go:290-310 (RFC 7396 object merge, arrays/scalars replace, `null` deletes), :312-344 (`normalizeCatalog` fills a missing `id`/`name` from the map key and drops non-object providers/models), tests/t_models.nim:111-124 (a patch can add a whole provider) | FIX: add — "A patch may add an entire provider, add models under an existing one, or change any field, because the full models.dev shape is preserved; `null` deletes a key (including a whole model). A provider or model that omits `id`/`name` has them filled from its map key, and non-object entries are dropped during normalization."
- MANUAL: :1669-1681 (end of the section) has no `#### Verification` | CODE: Makefile:503 (`make test-models`, builds a source plugin through `builder` + `core.spawn` and proves the patch appears and reverts), tests/t_models.nim:16-30 (private bus + `NIF_MODELS_PATH` fixture) | FIX: add — "`make test-models` boots a private harness with a local fixture catalog and proves registration, strict resolution, and that a built source plugin's patch appears on spawn and disappears on removal. Against a live harness, `./var/bin/cli call models_sources '{}'` prints provenance and `./var/bin/cli call models_get '{\"provider\":\"deepseek\",\"model\":\"deepseek-chat\"}'` one descriptor."
- MANUAL: :1591 "`llm` asks `models_get` for the selected model's context window" and :1573-1576 status/trimming/redaction claims | CODE: verified correct — components/llm/main.go:130,160; catalog.go:1015-1032 (missing status ⇒ active, missing `tool_call` ⇒ true), main.go:34-47, catalog.go:861-915 | FIX: none (keep as-is).

## 6. Not user-facing

Nothing here is a UI surface: the component has no client-facing tool, no
approval-gated write, and no store records — it is env-configured, read-only
to callers, and all six tools are on-demand for the LLM
(components/models/main.go:93-209). Its only cross-component contracts are
`models_get` (consumed by `llm`, components/llm/main.go:130,160), the
`x-models-source` tool call (catalog.go:690-746), and the
`ev.models.updated` notification (catalog.go:567-571, documented at
docs/MANUAL.md:400). Consequently the MANUAL work is prose and one JSON
example — no new tool documentation beyond the existing table.
