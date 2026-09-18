# Worklist slice: Fetch

From `worklist.tsv` (22 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A052 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 909-933 (one tool, methods, `convertToText`, trafilatura within 30 s, 10 MiB/50 MiB caps, 200 KB spill, `ok:false` errors, "Read-only network access — no approval gate")
- CODE: `components/fetch/main.nim:27-31` (`DefaultMaxSize`, `MaxSizeLimit`, `MaxInlineBytes = 200_000`, `TrafilaturaTimeoutMs = 30_000`), `:258-292` (methods + `maxSize` validation 1024..52428800), `:177` (`NIF_FETCH_ALLOW_PRIVATE`), no `x-harness.approval` anywhere in the file ✔
- FIX: none.

## A053 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 926 "content over 200 KB after processing is written to a file under `$NIF_FETCH_DIR`"
- CODE: `MaxInlineBytes = 200_000` is applied to the extracted text (`components/fetch/main.nim:29`, spill at `:137`) ✔
- FIX: none.

## A346 (wrong)
source: `components/fetch.md`

- MANUAL: `extractWithTrafilatura` → `extractionMethod="trafilatura"` (`components/fetch/main.nim:83-134`, `346-350`); it feeds the already downloaded HTML through a temp dir with `--input-dir/--output-dir --parallel 1` to avoid pipe deadlocks (`:94-104`). Missing executable, non-zero exit, timeout, or empty output → fallback (`:87-88`, `112-120`, `125-126`).

## A347 (doc-edit)
source: `components/fetch.md`

- MANUAL: built-in `htmlToText` (`htmlparser` walk: drops script/style/noscript/iframe/object/embed `SkipTags`, newline at block tags, collapses whitespace) → `"htmlparser"` (`components/fetch/main.nim:45-74`, `34-37`, `351-357`).

## A348 (doc-edit)
source: `components/fetch.md`

- MANUAL: empty walk result → raw body, `extractionMethod="raw-fallback"` (`components/fetch/main.nim:358`).

## A349 (doc-edit)
source: `components/fetch.md`

- MANUAL: never attempted (non-`text/html`, or `convertToText=false`) → `extractionMethod="none"`, `convertedToText=false` (`:344`, `345`).

## A350 (doc-edit)
source: `components/fetch.md`

- MANUAL: **`:932` mislabels the tool as read-only.** No `x-harness.effect` is declared (`components/fetch/main.nim:257`), so fabric classifies `fetch` as `write` and serializes it (`components/fabric/fabric.nim:226-228`, `309`); MANUAL should either say so or the component should declare `"effect": "read"`.

## A351 (doc-edit)
source: `components/fetch.md`

- MANUAL: **§Fetch never says the tool is discover-only.** `onDemand: true` (`components/fetch/main.nim:257`); the fact appears only in the shipped-policy list (`docs/MANUAL.md:1477`) and discovery examples (`:1361-1443`).

## A352 (doc-edit)
source: `components/fetch.md`

- MANUAL: **The SSRF/private-destination rule and its exact messages are missing from §Fetch**, living only in the env table (`docs/MANUAL.md:295`). Add the rule (all resolved addresses checked, fail-closed DNS, hop-by-hop re-validation, ≤5 redirects) and the message strings (`components/fetch/main.nim:189-211`).

## A353 (doc-edit)
source: `components/fetch.md`

- MANUAL: **`timeout` default 30000 / max 120000 missing** from the tool table; `:916` says only "enforces caps" (`components/fetch/main.nim:260`, `26`, `290-291`).

## A354 (doc-edit)
source: `components/fetch.md`

- MANUAL: **`maxSize` lower bound 1024 missing** beside the documented 10 MiB / 50 MiB (`components/fetch/main.nim:292-293`).

## A355 (doc-edit)
source: `components/fetch.md`

- MANUAL: **Exact spill message and file naming undocumented**: `fetch_<rand>.txt` under `$NIF_FETCH_DIR` with `"Content saved to file (over 200000 bytes after processing): <path>"` (`components/fetch/main.nim:140`, `363-367`).

## A356 (doc-edit)
source: `components/fetch.md`

- MANUAL: **Result fields undocumented**: `finalUrl`, `extractionMethod` (`none|trafilatura|htmlparser|raw-fallback`), `contentLength`, `savedToFile`, `filePath` (`components/fetch/main.nim:344-358`, `368-372`).

## A357 (doc-edit)
source: `components/fetch.md`

- MANUAL: **Error contract partly undocumented**: 500-byte snippet cap, `extra.status` on HTTP errors, and oversize being an `ok:false` error rather than a spill (`components/fetch/main.nim:30`, `320-333`, `334-337`).

## A358 (doc-edit)
source: `components/fetch.md`

- MANUAL: **Redirect policy undocumented**: ≤5 hops, per-hop re-validation, 301/302/303 → GET + body/header drop, 307/308 preserved, non-http(s) target refused (`components/fetch/main.nim:226-255`).

## A359 (doc-edit)
source: `components/fetch.md`

- MANUAL: **Request-shape guards undocumented**: http(s)-only, 2048-char URL cap, credential URLs refused, caller headers overriding default UA/Accept/Accept-Language (`components/fetch/main.nim:189-193`, `282-283`, `299-305`).

## A360 (doc-edit)
source: `components/fetch.md`

- MANUAL: **`NIF_FETCH_ALLOW_PRIVATE` also accepts `true`/`yes`**, not just `1` (`components/fetch/main.nim:177` vs `docs/MANUAL.md:295`); likewise `NIF_TRAFILATURA` disables on `0|false|none` as well as `off` (`components/fetch/main.nim:79` vs `docs/MANUAL.md:303`).

## A361 (doc-edit)
source: `components/fetch.md`

- MANUAL: **Conversion triggers only for `text/html`** (`components/fetch/main.nim:345`) while the request advertises `application/xhtml+xml` (`:301`): XHTML pages come back raw. One caveat line belongs in §Fetch; the JSON-verbatim claim itself holds.

## A362 (doc-edit)
source: `components/fetch.md`

- MANUAL: **Extraction ladder wording is loose**: `:920-924` omits the third rung (`"raw-fallback"`) and the fact that a non-zero trafilatura exit, timeout or empty output silently falls back (`components/fetch/main.nim:112-126`, `358`).

## A363 (doc-edit)
source: `components/fetch.md`

- MANUAL: **`NIF_FETCH_DIR` also hosts trafilatura temp work dirs**, created on demand and cleaned up afterwards (`components/fetch/main.nim:94`, `127-133`); the env table (`docs/MANUAL.md:294`) already hints at this, §Fetch does not.

## A364 (doc-edit)
source: `components/fetch.md`

- MANUAL: **No cleanup/reaping of spilled files**: nothing prunes `fetch_*.txt`, so the dir grows without bound (`components/fetch/main.nim:136-143`) — worth an operator note.

## A365 (doc-edit)
source: `components/fetch.md`

- MANUAL: **Verified correct, no change**: the "port of the old niffler `fetch` tool" provenance note (`docs/MANUAL.md:911-912` vs `components/fetch/main.nim:3-4`) and the "one tool" framing (`:912` vs the single registration at `:257`).

