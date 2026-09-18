# Worklist slice: Model catalog (models)

From `worklist.tsv` (12 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A078 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1543-1548 merge order ("registered `x-models-source` plugins, ascending by `priority` and then by `component/tool`. **A larger priority therefore wins**")
- CODE: `components/models/catalog.go:345-362` sorts ascending by priority then key and applies patches in that order (`:358-364`, second copy `:545-556`) ✔
- FIX: none.

## A079 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1550-1564 ("refreshes at startup and hourly", "skipped while its cache is younger than five minutes", atomic rename into `var/models/api.json`, `var/models/sources/` last-known-good, retry "30s or the configured interval, whichever is sooner", `ev.sys.drain` cancels work)
- CODE: `components/models/main.go:217` (1 h default), `:238-247` (retry delay = 30 s, or the interval when shorter — exactly the claim), `catalog.go:110-115` (`api.json`, `cacheTTL` 5 m), `:780` (`<cacheDir>/sources/<component>--<tool>.json` = `var/models/sources/`) ✔
- FIX: none.

## A080 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1602-1606 "the `llm` component registers an `x-models-source` plugin (**priority 150**) … (probed in the background after chats, **10-minute TTL**)"
- CODE: `components/llm/main.go:1114,1121` (`llm_models_source`, `priority: 150`), `components/llm/models_source.go:33-35,114-117` (`liveProbeTTL = 10 * time.Minute`, probe out of band) ✔
- FIX: none.

## A081 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1566-1596 tools table (6 tools, all onDemand per `mechanisms.md`)
- CODE: `components/models/main.go:93,113,136,163,183,204` ✔
- FIX: none.

## A082 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1577-1580 "`models_list {status: \"active\"}` also matches models whose status field is absent … List results are trimmed when they would exceed the bus payload limit … Descriptor metadata is recursively redacted: secret-like keys … never reach a caller, at provider or model level."
- CODE: `components/models/catalog.go:886-911` (recursive `redactMetadata`), `:1005,1072` (applied at provider and model level); trimming is `maxResultBytes` under the NATS payload limit (`components/models/main.go:28-33`) and an oversized single descriptor errors with "model descriptor exceeds the result size limit" (`:158`) ✔
- FIX: none.

## A436 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1569 "strict `provider/model` or globally unique bare-id resolution"
- CODE: catalog.go:1088-1151 — success is `{found:true, provider, model, reference, configured, updatedAt}`; ambiguity returns `{found:false, error:"model id is ambiguous; use provider/model", matches:[…]}` (:1130-1136); a miss returns `{found:false, error:"model not found", suggestions:[…]}` (:1144-1151); the `provider/` prefix is split off only when it names a *known* provider (:1090-1096), otherwise the whole string is looked up as a bare id
- FIX: add — "`models_resolve` never guesses: a bare id that exists under several providers comes back `found:false` with `matches`, and an unknown reference comes back `found:false` with up to ten `suggestions`. A `provider/model` string whose prefix is not a known provider id is treated as a literal bare id, so a typo'd provider looks like a missing model. On success the answer carries the selected `provider`, `model`, `reference`, `configured` and the catalog `updatedAt`."

## A443 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1546 "refreshes at startup and hourly"
- CODE: main.go:217 (interval from `NIF_MODELS_REFRESH_INTERVAL`, default 1h, `0` disables the ticker) plus main.go:70-88, 281 (startup, every `reg.publish`/`reg.depart`, every `ev.catalog.updated`)
- FIX: update — "The component refreshes at startup, whenever the component catalog changes (registration or departure), and then on `NIF_MODELS_REFRESH_INTERVAL` (default one hour; `0` disables the periodic tick)."

## A444 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1599-1630 example shows `{"version": 1, "priority": 200}` but not what is enforced
- CODE: catalog.go:421-425 (version must equal 1, otherwise the tool is ignored), :426-429 (`priority` default 100), :350-355 (equal priorities ordered by `component/tool`), :691-693 (called with `{"version":1}`, 30 s timeout), :698-703 (no `patch` object ⇒ error, cached patch kept)
- FIX: add — "The contract: the `x-harness.hidden` flag is convention, the `x-models-source` extension is what registers the tool; `version` must be exactly 1 or the tool is skipped; `priority` defaults to 100 and equal priorities are ordered by `component/tool`; the tool is called with `{"version": 1}` and a 30 s deadline, and a result without a `patch` object counts as a failure that keeps the last-known-good patch."

## A445 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1553-1557 says each source has a last-known-good patch "under `var/models/sources/`" but not the file naming or that it is dropped on departure
- CODE: catalog.go:779-781 (`<component>--<tool>.json`, unsafe chars → `_` via :748-756), :455-475 (departure removes registration, status and patch), tests/t_models.nim:157-170
- FIX: add — "The file is named `<component>--<tool>.json` (anything outside `A-Za-z0-9-_.` becomes `_`). Removing the component deletes its registration, status and cached patch in one step, so a departed source cannot keep influencing the catalog."

## A446 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1531-1532 "A small embedded seed makes a first offline boot useful"
- CODE: components/models/seed.json:2-81 — exactly one provider (`deepseek`, :2) with two models (`deepseek-chat` :12, `deepseek-reasoner` :43); NOTICE.md:1-8 records the models.dev provenance
- FIX: update — "The embedded seed is deliberately tiny: the shipped DeepSeek provider with `deepseek-chat` and `deepseek-reasoner` only, so a first offline boot keeps the configured default working. Every other provider/model appears once the baseline is fetched or a source/override supplies it."

## A447 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1546-1550 "bounded, retried, validated" without numbers
- CODE: catalog.go:116 (12 s HTTP client timeout), :644-688 (3 attempts, 200/400 ms backoff, 16 MiB cap, fail fast on non-5xx/429), :232-263 (a catalog with no usable model entries is rejected so it cannot replace the last-known-good cache)
- FIX: update — "Downloads are bounded (16 MiB, 12 s per request), retried up to three times with 200/400 ms backoff, fail fast on client errors, and are rejected outright when they contain no usable model entries — a bad response can never replace the last-known-good `var/models/api.json`."

## A450 (doc-edit)
source: `components/models.md`

- MANUAL: MANUAL: :1591 "`llm` asks `models_get` for the selected model's context window" and :1573-1576 status/trimming/redaction claims
- CODE: verified correct — components/llm/main.go:130,160; catalog.go:1015-1032 (missing status ⇒ active, missing `tool_call` ⇒ true), main.go:34-47, catalog.go:861-915
- FIX: none (keep as-is).

