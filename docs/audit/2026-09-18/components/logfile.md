# Audit — `components/logfile/` (Nim, `main.nim`, 493 lines, component v0.1.0)

Scope: `components/logfile/main.nim` (the only file; no README),
`manifest.yaml:205-210`, `sdk/niffler/sdk.nim:198-204` (`errResult`) and
`:268-284` (`configInt`), `tests/t_logfile.nim` (374 lines), `Makefile:514`
(`test-logfile`), and `docs/MANUAL.md` — the section
`### `logfile`: rotating JSONL persistence` inside `## Observation and logs`,
the shipped row, the seven `NIF_LOGFILE_*` env rows, the `var/` state row and
the shipped-policy tail. Read-only audit: no builds, no source or MANUAL edits.

> **Line-number drift:** the numbers below are `docs/MANUAL.md` as it stood
> while this report was written (2850 lines); the concurrent consolidation pass
> kept editing it (3072 lines by the end, the logfile subsection
> ≈2279→2430, the `NIF_LOGFILE_*` env rows ≈417→452, the `var/` state row
> ≈330→365). The quotes are the durable anchor — every row's quote was
> re-verified against the file — so re-resolve a number by searching its quote.

## 1. What it offers

- A **durable-ish JSONL sink** for bus events, one file per emitting component,
  with rotation: `appendEntry` opens/appends/flushes/closes per record
  (`main.nim:153-176`), and rotates when `current size + record size` would
  exceed `NIF_LOGFILE_MAX_BYTES` (`main.nim:163-166`; `rotate`, `:105-120`).
- Best-effort, deliberately: the header says so and the MANUAL repeats it —
  core NATS is at-most-once, so anything published while the component is down
  is lost (`main.nim:1-7`).
- **Publishes nothing and calls nothing.** No `comp.emit`/`publishEnvelope`, no
  store access, no idle seam (`grep -n 'emit\|publish\|storePut\|onIdle'
  components/logfile/main.nim` → only an `emittedAt` field read at `:406-407`).
  It is a pure consumer, which is why `replicas` would be meaningless here.
- Two read tools over the sink: `logfile_search` (bounded search of persisted
  history) and `logfile_paths` (directory listing plus sink health), both
  `onDemand` (`main.nim:292`, `:448`).
- Whole-file leniency on input: a record whose subject is a *valid* component
  name becomes `<component>.jsonl`; everything else (non-log traffic, a
  whole-bus `>` tap, spoofed component names, and any component beyond the file
  cap) goes to one `bus.jsonl` so dynamic inbox subjects cannot exhaust inodes
  (`main.nim:91-99`, `:53-59`).
- Lossless retention of bytes it cannot decode: invalid UTF-8 is stored as
  `rawBase64` + `encoding` + `bytes` + `decodeError`; valid-UTF-8 non-JSON is
  stored as `raw` + `decodeError` (`main.nim:138-151`).
- Restart hygiene: every boot prunes rotation generations above the configured
  `keep` (`main.nim:122-136`, called at `:194`) and re-seeds the component-file
  registry from the `.jsonl` files already on disk (`main.nim:195-201`), so the
  file cap counts files that predate this process life.
- Fail-loud configuration: all five numeric knobs go through `configInt`, which
  raises `ValueError` on an unparsable or out-of-range value (`main.nim:37-45`;
  `sdk/niffler/sdk.nim:268-284`), and an invalid `NIF_LOGFILE_SUBJECTS` raises
  before `comp.run()` (`main.nim:212-221`) — the process exits non-zero instead
  of substituting a default.

## 2. Tools

| Tool | Registered at | Purpose (doc-comment text) | `x-harness` flags verbatim |
|---|---|---|---|
| `logfile_search` | `main.nim:292-446` | "Search persisted JSONL history. Structured ev.log.\* records expose component/level/msg/ctx; raw bus records expose their original JSON message (or raw + decodeError). Results are newest first by sink receivedAt. The bounded scan reports truncated when it hits its byte or candidate limit." (`main.nim:296-300`) | `{"onDemand": true}` (`main.nim:292`) — **no** `approval`, **no** `effect`, **no** `timeoutMs`, **no** `parallel` |
| `logfile_paths` | `main.nim:448-491` | "Report the configured directory, retained JSONL files, and sink health. A non-empty lastError means writes were lost; inspect stderr and fix the filesystem before relying on subsequent records." (`main.nim:450-452`) | `{"onDemand": true}` (`main.nim:448`) — **no** `approval`, **no** `effect`, **no** `timeoutMs`, **no** `parallel` |

- Both are discover-only. The MANUAL reflects that in prose ("the observe/logfile
  diagnostics" in the on-demand tail) but has no tools table for this component,
  unlike `observe`.
- Neither declares `x-harness.effect`; the fabric batch host classifies an
  undeclared tool as `"write"` and schedules it exclusively
  (`components/fabric/fabric.nim:226-228`, `:309`, `:327`) even though both are
  read-only. The MANUAL states this exact consequence for `bash` and `fetch` but
  not here.
- Without `x-harness.timeoutMs`, core's dispatch default of 120 000 ms applies
  (`core/dispatch.nim:173`, `:1638-1641`) — a `logfile_search` over a large
  `NIF_LOGFILE_SCAN_BYTES` budget can hold a call for up to two minutes.

Parameters (`main.nim:293-295`, docs at `:301-306`):

- `logfile_search {component="", level="", regex="", since=0.0, until=0.0, limit=100}`
  — `component` is `ev.log.<component>` (max 64 chars, `:307-308`); `level` is
  one of `debug|info|warn|error` (`:29`, `:309-310`); `regex` ≤1024 bytes
  (`:27`, `:311-312`); `since > until` is refused (`:313-314`); an invalid regex
  is refused (`:321-322`); `limit` is clamped to 1..500 (`:323`) although the doc
  says "cap 500" (`:306`). `since`/`until` are epoch **seconds** compared against
  the sink's own `receivedAt`, never the emitter's `at` (`:381-384`; emitter time
  is only echoed as `emittedAt`, `:406-407`).
- Search machinery: candidate files are enumerated by `walkDir` up to
  `maxDirectoryEntries` (`:330-335`), sorted newest-mtime first (`:336-338`),
  each read from its **tail** under a shared `maxScanBytes` budget
  (`readTail`, `:254-290`), matched newest-line-first, candidates capped at
  `MaxSearchItems = 5000` (`:21`, `:371-374`), then sorted by `receivedAt`
  newest-first (`:428-430`) and emitted under a 55 904-byte encoded response
  budget (`:22-23`, `:433-440`).
- `logfile_paths {}` — lists `{name, size, mtime}` sorted by name, capped at
  `MaxPathItems = 500` items and the same response budget (`:24`, `:463-482`),
  and returns the sink-health metadata `dir`, `writeErrors`, `lastError`,
  `lastErrorAt`, `maxBytes`, `keep`, `maxComponentFiles`, `componentFiles`
  (a count), `subjects`, `totalFiles`, `truncated`, `directoryTruncated`,
  `maxDirectoryEntries`, `responseBytes` (`:483-491`).
- **Error convention differs from `observe`**: invalid `logfile_search`
  arguments return a *successful* result containing `{"error": ...}` (`main.nim:308`,
  `:310`, `:312`, `:314`, `:322`) instead of the SDK's `errResult` shape
  (`sdk/niffler/sdk.nim:198-204`) that `observe` uses, because the tool server
  wraps any returned node in a result envelope and only a raised exception
  becomes an error (`sdk/niffler/sdk.nim:723-727`). A model must inspect the
  payload for `error`, not the call status.
- No `selftest` tool (`grep -c selftest components/logfile/main.nim` → 0).

## 3. Configuration

### Event subjects it consumes

- One tap, either on the single configured pattern (default `ev.log.>`) or — when
  more than one pattern is configured, or the list contains `>` — on `>` with
  local filtering (`main.nim:204-227`). Because the multi-pattern case taps `>`,
  the component then *sees* every bus message, including `_INBOX.*` replies, and
  writes the ones that match a pattern into `bus.jsonl`.
- Subject → file mapping (`pathFor`, `main.nim:91-99`): `ev.log.<name>` with
  `<name>` matching `[a-z0-9-]{1,64}` → `logDir/<name>.jsonl`; anything else
  (including a component beyond `NIF_LOGFILE_MAX_FILES`) → `logDir/bus.jsonl`.
- `NIF_LOGFILE_SUBJECTS` validation is fatal at boot: a malformed/oversized
  pattern, more than 64 unique patterns, or an empty result raises
  (`main.nim:212-221`; `MaxPatterns = 64` `:25`, `MaxPatternBytes = 512` `:26`).

### Retention/rotation knobs (every `NIF_*` variable the component reads)

| Var | Where | Default | Accepted range (fatal outside it) |
|---|---|---|---|
| `NIF_LOGFILE_DIR` | `main.nim:32-36` | `$NIF_ROOT/var/logs` | absolute → used as-is; relative → `$NIF_ROOT/<value>`; `rootDir()` is `NIF_ROOT` |
| `NIF_LOGFILE_MAX_BYTES` | `main.nim:37-38` | `10_485_760` (`:16`) | 256 … 104 857 600 (`:20`) |
| `NIF_LOGFILE_KEEP` | `main.nim:39` | `5` (`:17`) | 0 … 100; `0` = no rotated generation kept (`:108-110`) |
| `NIF_LOGFILE_MAX_FILES` | `main.nim:40-41` | `64` (`:18`) | 1 … 1024; counts *component* files only (`bus.jsonl` is exempt, `:199`) |
| `NIF_LOGFILE_SCAN_BYTES` | `main.nim:42-43` | `16_777_216` (`:19`) | 1024 … 104 857 600; shared across all files of one search (`:350-360`) |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | `main.nim:44-45` | `10_000` (`:28`) | 100 … 100 000; applies to both tools (`:332`, `:458`) |
| `NIF_LOGFILE_SUBJECTS` | `main.nim:204-221` | `ev.log.>` | validated, not numeric; fatal on bad input |

Hardcoded (not env): rotation generation naming `<file>.1..N` (`main.nim:111-120`),
the boot prune (`:122-136`, `:194`), `MaxSearchItems = 5000` (`:21`),
`MaxResponseBytes = 60_000` / `ResponseItemBudget = 55_904` (`:22-23`),
`MaxPathItems = 500` (`:24`), `MaxRegexBytes = 1024` (`:27`), the allowed
levels (`:29`), per-record append/flush/close, and the directory/file
permissions (0700 at `:156`, 0600 at `:174`).

### Where output lands

`$NIF_ROOT/var/logs/` by default: `<component>.jsonl` plus `<file>.1 … <file>.N`
rotations per component, and `bus.jsonl` for everything else. One JSON object
per line: `{receivedAt, subject, message}` for decodable input, plus
`rawBase64`/`encoding`/`bytes`/`decodeError` or `raw`/`decodeError` for the
undecodable cases (`rawEntry`, `main.nim:138-151`). The `var/` state row already
names `logs/` for "bus JSONL + child logs" but says nothing about the rotations.

## 4. How `docs/MANUAL.md` covers it today

The section **exists** as a subsection — `### `logfile`: rotating JSONL
persistence` inside `## Observation and logs` (MANUAL:2220/2279 in the revision
read) — and it is unusually complete: most of the behaviour above is stated, and
it is *correct*. The deltas are missing numbers and flags, not false claims.
Exact current text (quotes anchor; numbers are the revision read):

- **MANUAL:2281-2283** — "`logfile` is best-effort process-local persistence, not
  an audit log. Core NATS is at-most-once: records emitted before startup or
  during a restart are lost. Guaranteed replay would require an explicit
  JetStream design."
- **MANUAL:2285** — "Default input is `ev.log.>`. A valid component name gets one
  file:" followed by the `var/logs/bash.jsonl` / `bash.jsonl.1` block.
- **MANUAL:2293-2298** — "`NIF_LOGFILE_SUBJECTS` can select other subjects.
  Non-log traffic, including whole-bus `>`, goes to a single `bus.jsonl`; dynamic
  inbox subjects therefore do not create unbounded file descriptors or filenames.
  The number of component log files is capped, and excess/spoofed component
  subjects also fall back to `bus.jsonl`. Multiple configured patterns are
  treated as one locally filtered union, so overlapping patterns persist each
  matching publication exactly once."
- **MANUAL:2300-2304** — the record example
  `{"receivedAt": 1780000000.25, "subject": "ev.log.bash", "message": {...}}`.
- **MANUAL:2306-2312** — "Malformed UTF-8 input uses lossless `rawBase64`;
  textual malformed input uses `raw` and `decodeError`. The sink opens, appends,
  flushes, and closes each record. Rotation compares `current size + record size`
  before renaming closed files, so exact-boundary writes cannot leave a stale
  file handle. A single record larger than the configured file size is retained
  as the active file and rotated before the next record. `NIF_LOGFILE_KEEP=0`
  retains no rotated generation."
- **MANUAL:2314-2323** — "`logfile_search` reads only a bounded tail from the
  retained files, sorts matching records by `receivedAt` newest-first, and reports
  `truncated`, `scannedBytes`, malformed line counts, and read errors. Results
  also have an encoded response-byte budget. Structured log records expose
  `component`, `level`, `msg`, `ctx`, and optional emitter time; raw bus records
  expose the preserved message. Search never trusts an emitter-supplied timestamp
  for `since`/`until` windows. Directory enumeration is capped by
  `NIF_LOGFILE_DIRECTORY_ENTRIES` and reports `directoryTruncated` when more files
  exist; searches still inspect the bounded subset."
- **MANUAL:2325-2328** — "`logfile_paths` reports a bounded retained-file list
  plus `writeErrors`, `lastError`, and `lastErrorAt`. Filesystem failures also go
  to stderr. Capture directories are user-only where the platform permits; active
  symlink targets are rejected."

Verified against the code (no change needed): the at-most-once framing
(`main.nim:1-7`); one file per valid component name plus the `bus.jsonl` fallback
(`main.nim:91-99`); the file cap and spoofed-name fallback (`main.nim:41-50`,
`:95-96`); the multi-pattern local union and exactly-once persistence
(`main.nim:187-191`, `:224-227`); the record shape (`main.nim:138-151`); the
rotation arithmetic and the oversize-record rule (`main.nim:163-166`, `:105-120`);
`KEEP=0` (`main.nim:108-110`); bounded-tail search, `receivedAt` sorting,
`truncated`/`scannedBytes`/`parseErrors`/`readErrors` (`main.nim:340-446`); the
response budget (`main.nim:433-440`); the `since`/`until` rule
(`main.nim:381-384`, `:406-407`); `DIRECTORY_ENTRIES` + `directoryTruncated`
(`main.nim:330-335`, `:458-460`); the health fields and stderr on write failure
(`main.nim:178-185`, `:483-491`); the symlink refusal (`main.nim:160-161`); and
all seven env rows.

**Explicitly absent**: the two tools' flags (on-demand, no `effect`, no
`timeoutMs`); `logfile_search`'s parameters and caps; the
`{"error": …}`-inside-a-successful-result convention; the fatal validation of
`NIF_LOGFILE_SUBJECTS` and the accepted *ranges* of the five numeric knobs; the
boot-time prune of generations above `keep` and the re-seeding of the
component-file registry; the rotation generation naming and the 0700/0600 modes;
`NIF_LOGFILE_DIR`'s absolute-vs-root-relative rule; and the fact that the two
read-only diagnostics are classified as writes by the fabric batch host.

## 5. DELTA list

Rows are the findings in the audit's machine-parsed shape, grouped by the current
MANUAL section they land in. `[class]` marks the ledger class; `FIX` starts with
the verb, and the proposed wording/evidence is in the row. §1–§4 hold the
long-form reasoning.

## Observation and logs

- MANUAL: "`logfile_search` reads only a bounded tail from the retained files, sorts" | CODE: components/logfile/main.nim:292-295,307-323,433-446; sdk/niffler/sdk.nim:198-204,723-727 | FIX: add — [missing] after that sentence: "It is `onDemand` and declares no `x-harness.effect`, so the fabric batch host schedules it as a write. Arguments are `{component?, level? (debug|info|warn|error), regex? (≤1024 bytes), since?, until? (epoch seconds, `since ≤ until`), limit? (default 100, cap 500)}`; an invalid argument comes back as `{"error": …}` inside a *successful* result rather than as an error envelope, and with no `timeoutMs` on the schema the call runs under core's 120 s default deadline."
- MANUAL: "`logfile_paths` reports a bounded retained-file list plus `writeErrors`," | CODE: components/logfile/main.nim:448,463-491,156,174 | FIX: update — [doc-edit] "`logfile_paths` (`onDemand`, no `x-harness.effect`) reports up to 500 retained files plus `writeErrors`, `lastError`, `lastErrorAt`, `maxBytes`, `keep`, `subjects` and the component-file count. Filesystem failures also go to stderr. The **log directory** is created user-only (0700, files 0600) where the platform permits, and an active symlink at a log path is refused." ("Capture directories" borrows `observe`'s noun for logfile's own directory.)
- MANUAL: "Malformed UTF-8 input uses lossless `rawBase64`; textual malformed input uses" | CODE: components/logfile/main.nim:105-120,122-136,195-201 | FIX: add — [missing] "Rotated generations are named `<file>.1` … `<file>.<KEEP>`, and every boot deletes any generation numbered above the current `NIF_LOGFILE_KEEP` — lowering the knob destroys history at the next start. `.jsonl` files already on disk at boot also count against `NIF_LOGFILE_MAX_FILES`."
- MANUAL: "`NIF_LOGFILE_SUBJECTS` can select other subjects. Non-log traffic, including" | CODE: components/logfile/main.nim:204-227,25-26,212-221 | FIX: add — [missing] "The list is validated at boot: a malformed or over-512-byte pattern, more than 64 unique patterns, or an empty result makes the component exit non-zero. With several patterns the tap is `>` and matching happens locally; with one pattern that pattern itself is subscribed."
- MANUAL: "Default input is `ev.log.>`. A valid component name gets one file:" | CODE: components/logfile/main.nim:91-99,32-36 | FIX: add — [missing] "one file per component name matching `[a-z0-9-]{1,64}` under `NIF_LOGFILE_DIR` (`$NIF_ROOT/var/logs` by default; an absolute value is used as-is, a relative one is resolved against the harness root)."
- MANUAL: "`logfile` is best-effort process-local persistence, not an audit log. Core NATS" | CODE: components/logfile/main.nim:1-7 (no `emit`/`publishEnvelope`) | FIX: none — [verified]
- MANUAL: "preserved message. Search never trusts an emitter-supplied timestamp for" | CODE: components/logfile/main.nim:381-384,406-407 | FIX: none — [verified] `since`/`until` filter the sink's `receivedAt`; the emitter's `at` is only echoed as `emittedAt`.
- MANUAL: "Directory enumeration is capped by `NIF_LOGFILE_DIRECTORY_ENTRIES` and reports" | CODE: components/logfile/main.nim:44-45,330-335,458-460 | FIX: none — [verified] (the accepted range 100..100000 is proposed in the env row below, not here).

## Environment variables

- MANUAL: "| `NIF_LOGFILE_DIR` | JSONL output directory | `$NIF_ROOT/var/logs` |" | CODE: components/logfile/main.nim:32-36 | FIX: update — [missing] "JSONL output directory (`$NIF_ROOT/var/logs` by default; an absolute path is used as-is, a relative one resolves against the harness root)".
- MANUAL: "| `NIF_LOGFILE_SUBJECTS` | comma-separated NATS patterns to persist | `ev.log.>` |" | CODE: components/logfile/main.nim:204-227 | FIX: update — [missing] "comma-separated NATS patterns to persist (validated at boot: malformed, over-512-byte, more than 64 unique, or an empty list exits non-zero)".
- MANUAL: "| `NIF_LOGFILE_MAX_BYTES` | active bytes per JSONL file before rotation | `10485760` |" | CODE: components/logfile/main.nim:37-38 | FIX: update — [missing] append "; accepted range 256..104857600, outside it the component exits non-zero".
- MANUAL: "| `NIF_LOGFILE_KEEP` | retained rotated generations (`0` disables) | `5` |" | CODE: components/logfile/main.nim:39,122-136 | FIX: update — [missing] append "; range 0..100, and generations above the value are deleted at every boot".
- MANUAL: "| `NIF_LOGFILE_MAX_FILES` | component-specific files before fallback to `bus.jsonl` | `64` |" | CODE: components/logfile/main.nim:40-41,195-201 | FIX: update — [missing] append "; range 1..1024, files already present at boot count toward it".
- MANUAL: "| `NIF_LOGFILE_SCAN_BYTES` | maximum bytes examined by one `logfile_search` | `16777216` |" | CODE: components/logfile/main.nim:42-43,350-360 | FIX: update — [missing] append "; range 1024..104857600, shared across all files of one search".
- MANUAL: "| `NIF_LOGFILE_DIRECTORY_ENTRIES` | maximum candidate JSONL paths enumerated per query | `10000` |" | CODE: components/logfile/main.nim:44-45,330-335,458-460 | FIX: update — [missing] append "; range 100..100000, applies to `logfile_paths` as well and is reported as `directoryTruncated`".

## Layout of a running system

- MANUAL: "| `logfile` | Nim | optional | rotating JSONL sink and bounded persisted-log search (see [Observation and logs](#observation-and-logs)) |" | CODE: components/logfile/main.nim:292,448; manifest.yaml:205-210 | FIX: update — [doc-edit] append "— both tools are on demand, and neither declares `x-harness.effect`, so the fabric batch host schedules even `logfile_search` as a write". The rest is verified: two on-demand tools, `autostart: true`, `required: false`, `restart: on-failure`, no `replicas` (a single-writer sink must not be replicated).

## State and configuration

- MANUAL: "`logs/` bus JSONL + child logs, `models/` catalog cache" | CODE: components/logfile/main.nim:33-36,111-120 | FIX: update — [doc-edit] replace with "`logs/` bus JSONL + per-component JSONL with `.1`…`.N` rotations + child logs, `models/` catalog cache", so the state table names the sink's rotation generations and not only the child logs that share the directory.

## Progressive tool discovery

- MANUAL: "- Search and inspection: `files` (sorted listing), the git" | CODE: components/logfile/main.nim:292,448 | FIX: update — [doc-edit] replace "the observe/logfile diagnostics" in that bullet with "the `observe_*` diagnostics and logfile's `logfile_search`/`logfile_paths`", so the two discoverable logfile tools are nameable from the on-demand inventory rather than only from their own subsection.

## Testing

- MANUAL: "`tests/t_logfile.nim` covers SDK log filtering, newest-first queries, time/regex" | CODE: tests/t_logfile.nim:1-374; Makefile:514 | FIX: none — [verified] the test is named and its coverage list matches (rotation, zero retention, exact-once overlapping patterns, response bounds, sink health, invalid configuration).
- MANUAL: "`/doctor deep` additionally fans out to each component's own self test over" | CODE: `grep -c selftest components/logfile/main.nim` → 0 | FIX: add — [delta] one clause where the logfile test is named: "`logfile` registers no `selftest`, so `/doctor deep` lists it as not implementing one" — or register one; the tests already cover the contract either way.

Finding count for this component: 20 rows — 8 in `## Observation and logs`,
7 env, 1 shipped row, 1 state table, 1 on-demand inventory, 2 testing. Classes:
11 `missing` (parameters, ranges, boot behaviour, the missing flags), 4 `doc-edit`
(mostly "state the numbers/ranges", plus the `var/` state row), 1 `delta`,
4 `verified` — the subsection's prose is right throughout; only its precision is
thin.

## 6. Not user-facing

- `readTail`'s boundary look-behind arithmetic (`main.nim:254-290`), the
  `SearchItem` ordering tuple (`:252`, `:428-430`) and the `matchesPattern`
  token walk (`:76-89`).
- `componentFiles`/`patterns` bookkeeping (`main.nim:50-51`) — only its two
  user-visible consequences (file cap, boot seeding) belong in the MANUAL.
- `pruneRotations`' `try/except` on a non-numeric suffix (`main.nim:132-136`).
- The `rawEntry` key layout beyond the documented example: the MANUAL already
  shows the happy path and summarizes the malformed variants in prose.
