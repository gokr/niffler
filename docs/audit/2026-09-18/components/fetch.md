# Audit — `components/fetch/` (Nim, `main.nim`, 376 lines, component v0.1.0)

Scope: `components/fetch/main.nim` (one file; no README, no `niffler.json`
inside the component dir) vs. `docs/MANUAL.md`. Read-only audit.

## 1. What it offers

- One component, `fetch` v0.1.0 (`components/fetch/main.nim:23`), the agent's
  HTTP(S) reader: fetch a URL and return its content.
- HTML → readable text, preferring an installed `trafilatura` CLI, with a pure
  Nim `htmlparser` walk as the always-available fallback
  (`components/fetch/main.nim:9-10`, `77-134`, `45-74`).
- Fail-closed egress guard: private/loopback/link-local/CGNAT/multicast/
  unspecified addresses, private hostname suffixes and credential-bearing URLs
  are refused, and every redirect hop is re-validated
  (`components/fetch/main.nim:6-8`, `145-212`).
- Request timeout + size caps; content over 200 KB *after processing* spills to
  a file the agent reads with its own file tools
  (`components/fetch/main.nim:11-14`, `29`, `362-367`).
- A fresh `HttpClient` per call, deliberately: a stale pooled connection hangs
  the next read forever (`components/fetch/main.nim:15-16`, `296-298`).

## 2. Tools

- Exactly one tool, `fetch` — a single `comp.tool` registration
  (`components/fetch/main.nim:257`; grep shows one occurrence).
- Purpose (doc comment `components/fetch/main.nim:262-272`): "Fetch a web page
  or API endpoint over HTTP(S) and return its content… Prefer this over
  bash+curl for reading pages"; "Use for documentation, articles, APIs, raw text
  files, feeds and similar"; "the result never blows the conversation".
- Signature/defaults `fetch {url, method="GET", headers={}, body="",
  timeout=30000, maxSize=10485760, convertToText=true}`; param docs at
  `components/fetch/main.nim:273-279` for timeout/maxSize/convertToText.
- `x-harness` flags: **only** `{"onDemand": true}`
  (`components/fetch/main.nim:257`). No `approval`, no `timeoutMs`, no `effect`,
  no `parallel`, no `hidden`, no `sessionContext`.
- **Discover-only, not direct**: as an `onDemand` tool, `fetch` is kept out of a
  conversation's frozen direct toolset and is reached via `discover` →
  `invoke`. MANUAL's shipped-policy list agrees (`docs/MANUAL.md:1477`), and
  `fetch` is the sample component in the discovery examples
  (`docs/MANUAL.md:1361`, `1373`, `1381-1390`, `1409`, `1443`).
- Consequence of the *missing* `effect` flag: the fabric batch host classifies
  any tool without `x-harness.effect` as `"write"` and schedules it exclusively
  (`components/fabric/fabric.nim:226-228`, `309`, `327`), unlike genuinely
  read-only peers that declare `"effect": "read"`
  (`components/repomap/main.nim:255`, `components/processes/main.nim:514`).

## 3. Configuration

### Environment variables (every one the component reads)

| Var | Where read | Default / accepted | Notes |
|---|---|---|---|
| `NIF_FETCH_DIR` | `components/fetch/main.nim:40-43` | unset → `rootVarDir("fetch")` = `$NIF_ROOT/var/fetch` (`sdk/subjects.nim:38-41`) | Holds spilled results **and** the trafilatura temp work dir (created at `:94`, removed in `finally` at `:127-133`). |
| `NIF_FETCH_ALLOW_PRIVATE` | `components/fetch/main.nim:176-177` | `""` (blocked); truthy set `"1"`, `"true"`, `"yes"` | Short-circuits the entire destination check (`:194`). MANUAL/env table documents only `1` (`docs/MANUAL.md:295`). |
| `NIF_TRAFILATURA` | `components/fetch/main.nim:77-81` | unset → `findExe("trafilatura")` | Disable values `"0"`, `"false"`, `"off"`, `"none"` (`:79`); otherwise treated as an executable path/name. MANUAL mentions only `off` (`docs/MANUAL.md:924`, `303`). |

No other env var is read: timeouts, size caps and headers are per-call arguments.
Already in MANUAL's env table — `docs/MANUAL.md:294` (`NIF_FETCH_DIR`),
`:295` (`NIF_FETCH_ALLOW_PRIVATE`), `:303` (`NIF_TRAFILATURA`).

### Size caps and spill

- `maxSize` default `DefaultMaxSize = 10_485_760` (10 MiB), absolute
  `MaxSizeLimit = 52_428_800` (50 MiB), accepted range 1024..52428800, else
  `"maxSize must be 1024..52428800 bytes"`
  (`components/fetch/main.nim:27-28`, `260`, `292-293`).
- A response over `maxSize` is an **error, not a spill**: `"response is N bytes,
  over the M byte cap"` with `extra.status` (`components/fetch/main.nim:334-337`).
- Spill threshold applies to *post-processing* content length:
  `MaxInlineBytes = 200_000` (200 KB) (`components/fetch/main.nim:29`, `362`).
- Spill path: `saveToFile` → `createTempFile("fetch_", ".txt", fetchDir())`, i.e.
  a unique `<NIF_FETCH_DIR>/fetch_<rand>.txt` per call so repeated fetches never
  overwrite a path already handed to another call
  (`components/fetch/main.nim:136-143`, `140`).
- Exact caller-visible text: `"Content saved to file (over 200000 bytes after
  processing): <path>\nOriginal URL: <url>"`, with `savedToFile=true` and
  `filePath=<path>` (`components/fetch/main.nim:363-367`, `371-372`); the doc
  comment tells the model to read it "with the read tool"
  (`components/fetch/main.nim:268-270`).

### Private / loopback rejection rule and exact messages

`validateFetchUrl` (`components/fetch/main.nim:179-212`) plus `blockedAddress`
(`:145-175`) rejecting 0/8, 10/8, 127/8, 100.64/10, 169.254/16, 172.16/12,
192.168/16, ≥224/4, IPv6 `::`, `fc00::/7`, `fe80::/10`, `ff00::/8`, with
IPv4-mapped IPv6 normalized to the IPv4 rules (`:150-157`, `:159-173`):

- non-http(s) or missing hostname: `"url must be http(s) with a hostname"`
  (`components/fetch/main.nim:189-191`); unparseable: `"invalid URL"` (`:188`)
- embedded credentials: `"URL credentials are not allowed"` (`:192-193`)
- suffixes `localhost`, `.localhost`, `.local`, `.internal`:
  `"refusing private hostname: <hostname>"` (`:195-198`)
- literal private IP: `"refusing private address: <host>"` (`:199-202`)
- **any** resolved address private: `"hostname resolves to a private address:
  <host>"` (`:207-209`); empty resolution: `"hostname has no addresses: <host>"`
  (`:205-206`)
- DNS failure, fail-closed on purpose ("otherwise a typo or a transient resolver
  failure could bypass the destination policy", `:180-183`):
  `"cannot validate hostname <host>: <msg>"` (`:210-211`)
- URL longer than 2048 chars: `"url is too long"` (`:282-283`); every
  validation error is returned as `<error>: <url>` (`:284-286`).

### Timeouts

- `timeout` argument: default 30000 ms, hard max `MaxTimeoutMs = 120_000`, lower
  bound 1, else `"timeout must be 1..120000 ms"`; passed straight to
  `newHttpClient(…, timeout = timeout)` (`components/fetch/main.nim:26`, `260`,
  `290-291`, `296-297`). Not stated anywhere in MANUAL §Fetch.
- Trafilatura subprocess: bounded to `TrafilaturaTimeoutMs = 30_000`, then
  `terminate()` → `kill()` and fallback (`components/fetch/main.nim:31`,
  `106-117`).

### Extraction performed and fallback ladder

Conversion runs only when `convertToText` and the content type contains
`text/html` (`components/fetch/main.nim:345`); then:

1. `extractWithTrafilatura` → `extractionMethod="trafilatura"`
   (`components/fetch/main.nim:83-134`, `346-350`); it feeds the already
   downloaded HTML through a temp dir with
   `--input-dir/--output-dir --parallel 1` to avoid pipe deadlocks (`:94-104`).
   Missing executable, non-zero exit, timeout, or empty output → fallback
   (`:87-88`, `112-120`, `125-126`).
2. built-in `htmlToText` (`htmlparser` walk: drops
   script/style/noscript/iframe/object/embed `SkipTags`, newline at block tags,
   collapses whitespace) → `"htmlparser"`
   (`components/fetch/main.nim:45-74`, `34-37`, `351-357`).
3. empty walk result → raw body, `extractionMethod="raw-fallback"`
   (`components/fetch/main.nim:358`).
4. never attempted (non-`text/html`, or `convertToText=false`) →
   `extractionMethod="none"`, `convertedToText=false` (`:344`, `345`).

`convertToText` defaults to true (`components/fetch/main.nim:262`). JSON comes
back verbatim simply because its content type is not `text/html` — consistent
with `docs/MANUAL.md:918-919`.

### Requests, redirects, headers, result shape

- Methods: GET/POST/PUT/DELETE/HEAD/OPTIONS/PATCH via `AllowedMethods`, else
  `"method must be one of: GET, POST, …"`; body is sent only for
  POST/PUT/PATCH (`components/fetch/main.nim:32-33`, `288-289`, `306-314`,
  `230-233`).
- `newHttpClient("niffler-fetch/0.1", maxRedirects = 0, …)`: redirects are
  followed manually over ≤6 hops, each hop re-validated by `validateFetchUrl`;
  301/302/303 downgrade to GET and drop body plus
  Content-Length/Content-Type/Transfer-Encoding, 307/308 keep method+body; a
  missing `Location`, a non-http(s) target, or too many hops raise
  (`components/fetch/main.nim:226-255`, `296`).
- Default headers `User-Agent: niffler-fetch/0.1`, an HTML-ish `Accept`,
  `Accept-Language: en-US,en;q=0.5`; caller `headers` override them, non-string
  values become `""` (`components/fetch/main.nim:299-305`).
- Non-2xx → `ok:false`, message `"HTTP <code> <reason> — <snippet>"` with
  `extra.status`; snippet = first `MaxErrorSnippet = 500` bytes of the stripped
  body (`components/fetch/main.nim:30`, `320-333`).
- Success payload: `url`, `status`, `content`, `contentType`, `contentLength`
  (raw body bytes), `convertedToText`, `extractionMethod`, `savedToFile`,
  `filePath`, `finalUrl` (URL after redirects)
  (`components/fetch/main.nim:368-372`) — none of these field names appear in
  MANUAL §Fetch.
- Any other failure → `"fetch failed: <msg>"` (`components/fetch/main.nim:374`).

## 4. MANUAL placement

Already present, correctly placed — extend it, do not add a section:

- `## Fetch` at **`docs/MANUAL.md:909`** (between `## Hooks` at `:884` and
  `## Language servers (lsp)` at `:934`), body `:909-932`, Contents entry
  `docs/MANUAL.md:18`. It covers the tool table `:914-916`, `convertToText` +
  JSON verbatim `:918-919`, trafilatura bound/fallback/`NIF_TRAFILATURA`
  `:920-924`, `maxSize` caps + 200 KB spill + `$NIF_FETCH_DIR` `:925-929`, error
  shape `:930-931`, "no approval gate" `:932`.
- Other fetch facts already live at: layout table `docs/MANUAL.md:64`, `var/`
  state listing `:244`, env table `:294-295`, `:303`, shipped on-demand policy
  `:1477`, discovery examples `:1361-1443`.
- Proposed edits, all inside the existing section: fix `:932` (see DELTA 1), add
  a "Discover-only" line after `:916`, and add tolerance/SSRF/redirect bullets
  before `:930`.

## 5. DELTA list

1. **`:932` mislabels the tool as read-only.** No `x-harness.effect` is declared
   (`components/fetch/main.nim:257`), so fabric classifies `fetch` as `write`
   and serializes it (`components/fabric/fabric.nim:226-228`, `309`); MANUAL
   should either say so or the component should declare `"effect": "read"`.
2. **§Fetch never says the tool is discover-only.** `onDemand: true`
   (`components/fetch/main.nim:257`); the fact appears only in the shipped-policy
   list (`docs/MANUAL.md:1477`) and discovery examples (`:1361-1443`).
3. **The SSRF/private-destination rule and its exact messages are missing from
   §Fetch**, living only in the env table (`docs/MANUAL.md:295`). Add the rule
   (all resolved addresses checked, fail-closed DNS, hop-by-hop re-validation,
   ≤5 redirects) and the message strings (`components/fetch/main.nim:189-211`).
4. **`timeout` default 30000 / max 120000 missing** from the tool table; `:916`
   says only "enforces caps" (`components/fetch/main.nim:260`, `26`, `290-291`).
5. **`maxSize` lower bound 1024 missing** beside the documented 10 MiB / 50 MiB
   (`components/fetch/main.nim:292-293`).
6. **Exact spill message and file naming undocumented**: `fetch_<rand>.txt` under
   `$NIF_FETCH_DIR` with `"Content saved to file (over 200000 bytes after
   processing): <path>"` (`components/fetch/main.nim:140`, `363-367`).
7. **Result fields undocumented**: `finalUrl`, `extractionMethod`
   (`none|trafilatura|htmlparser|raw-fallback`), `contentLength`, `savedToFile`,
   `filePath` (`components/fetch/main.nim:344-358`, `368-372`).
8. **Error contract partly undocumented**: 500-byte snippet cap, `extra.status`
   on HTTP errors, and oversize being an `ok:false` error rather than a spill
   (`components/fetch/main.nim:30`, `320-333`, `334-337`).
9. **Redirect policy undocumented**: ≤5 hops, per-hop re-validation, 301/302/303
   → GET + body/header drop, 307/308 preserved, non-http(s) target refused
   (`components/fetch/main.nim:226-255`).
10. **Request-shape guards undocumented**: http(s)-only, 2048-char URL cap,
    credential URLs refused, caller headers overriding default
    UA/Accept/Accept-Language (`components/fetch/main.nim:189-193`, `282-283`,
    `299-305`).
11. **`NIF_FETCH_ALLOW_PRIVATE` also accepts `true`/`yes`**, not just `1`
    (`components/fetch/main.nim:177` vs `docs/MANUAL.md:295`); likewise
    `NIF_TRAFILATURA` disables on `0|false|none` as well as `off`
    (`components/fetch/main.nim:79` vs `docs/MANUAL.md:303`).
12. **Conversion triggers only for `text/html`** (`components/fetch/main.nim:345`)
    while the request advertises `application/xhtml+xml` (`:301`): XHTML pages
    come back raw. One caveat line belongs in §Fetch; the JSON-verbatim claim
    itself holds.
13. **Extraction ladder wording is loose**: `:920-924` omits the third rung
    (`"raw-fallback"`) and the fact that a non-zero trafilatura exit, timeout or
    empty output silently falls back (`components/fetch/main.nim:112-126`,
    `358`).
14. **`NIF_FETCH_DIR` also hosts trafilatura temp work dirs**, created on demand
    and cleaned up afterwards (`components/fetch/main.nim:94`, `127-133`); the
    env table (`docs/MANUAL.md:294`) already hints at this, §Fetch does not.
15. **No cleanup/reaping of spilled files**: nothing prunes `fetch_*.txt`, so the
    dir grows without bound (`components/fetch/main.nim:136-143`) — worth an
    operator note.
16. **Verified correct, no change**: the "port of the old niffler `fetch` tool"
    provenance note (`docs/MANUAL.md:911-912` vs `components/fetch/main.nim:3-4`)
    and the "one tool" framing (`:912` vs the single registration at `:257`).

Finding summary: 16 findings — 1 inaccurate MANUAL claim (#1), 2 missing but
load-bearing facts (#2, #3), 12 documentation gaps (#4-#15), 1 verified-correct
(#16). MANUAL coverage is otherwise sound: heading, env-table rows, layout table,
`var/` listing and discovery examples all exist and match the source.

## 6. Not user-facing

Nothing here is hidden from the LLM (`x-harness.hidden` is unused) and the
component registers no status/service tools, so no "not user-facing" caveat is
warranted. Keep out of the MANUAL as implementation detail: the
`SkipTags`/`BlockTags` lists and whitespace `multiReplace`
(`components/fetch/main.nim:34-37`, `72-73`), `responseCode` parsing (`:214-216`),
`requestSafe`'s exception plumbing beyond the redirect policy (`:218-255`), the
trafilatura temp-dir/`--parallel 1` mechanics beyond the documented bound
(`:94-104`), and the `fetch_` temp-file naming internals — except where the DELTA
list asks for the caller-visible symptom (spill message, method list, error text).
