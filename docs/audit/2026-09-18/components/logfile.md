# Audit — `components/logfile/` (Nim, `main.nim`, 493 lines, component v0.1.0)

Scope: `components/logfile/main.nim` (the only file; no README),
`manifest.yaml:205-210`, `sdk/niffler/sdk.nim:268-284` (`configInt`),
`tests/t_logfile.nim` (374 lines), `Makefile:514` (`test-logfile`), and the
current `docs/MANUAL.md`: `### `logfile`: rotating JSONL persistence`
(MANUAL:2279-2328) inside `## Observation and logs` (2220), the shipped row
MANUAL:83, env rows MANUAL:417-423, state row MANUAL:330, shipped policy
MANUAL:1911-1912. Read-only audit: no builds, no edits.

## 1. What it offers

- A **durable-ish JSONL sink** for bus events, one file per emitting component,
  with rotation: `appendEntry` opens/appends/flushes/closes per record
  (`main.nim:153-176`), and rotates when `current size + record size` would
  exceed `NIF_LOGFILE_MAX_BYTES` (`main.nim:163-166`, `rotate` at `:105-120`).
- Best-effort, deliberately: the header says so and the MANUAL repeats it —
  core NATS is at-most-once, so anything published while the component is down
  is lost (`main.nim:1-7`, MANUAL:2281-2283).
- **Publishes nothing and calls nothing.** No `comp.emit`/`publishEnvelope`,
  no store access, no idle seam (`grep -n 'emit\|publish\|storePut\|onIdle'
  components/logfile/main.nim` → only an `emittedAt` field read at `:406-407`).
  It is a pure consumer, which is why `replicas` would be meaningless here.
- Two read tools over the sink: `logfile_search` (bounded search of persisted
  history) and `logfile_paths` (directory listing + sink health), both
  `onDemand` (`main.nim:292`, `:448`).
- Whole-file leniency on input: a record whose subject is a *valid* component
  name becomes `<component>.jsonl`; everything else (non-log traffic, a
  whole-bus `>` tap, spoofed component names, and any component beyond the file
  cap) goes to one `bus.jsonl` so dynamic inbox subjects cannot exhaust inodes
  (`main.nim:91-99`, `:41-50`, `:53-59`).
- Lossless retention of bytes it cannot decode: invalid UTF-8 is stored as
  `rawBase64` + `encoding` + `bytes` + `decodeError`; valid-UTF-8 non-JSON is
  stored as `raw` + `decodeError` (`main.nim:138-151`).
- Restart hygiene: every boot prunes rotation generations above the configured
  `keep` (`main.nim:122-136`, called at `:194`) and re-seeds the component-file
  registry from the `.jsonl` files already on disk (`main.nim:195-201`) so the
  file cap counts files that predate this process life.
- Fail-loud configuration: all five numeric knobs go through `configInt`, which
  raises `ValueError` on an unparsable or out-of-range value
  (`main.nim:37-45`; `sdk/niffler/sdk.nim:268-284`), and an invalid
  `NIF_LOGFILE_SUBJECTS` raises before `comp.run()` (`main.nim:212-221`) — the
  process exits non-zero instead of substituting a default.

## 2. Tools

| Tool | Registered at | Purpose (doc-comment text) | `x-harness` flags verbatim |
|---|---|---|---|
| `logfile_search` | `main.nim:292-446` | "Search persisted JSONL history. Structured ev.log.\* records expose component/level/msg/ctx; raw bus records expose their original JSON message (or raw + decodeError). Results are newest first by sink receivedAt. The bounded scan reports truncated when it hits its byte or candidate limit." (`main.nim:296-300`) | `{"onDemand": true}` (`main.nim:292`) — **no** `approval`, **no** `effect`, **no** `timeoutMs`, **no** `parallel` |
| `logfile_paths` | `main.nim:448-491` | "Report the configured directory, retained JSONL files, and sink health. A non-empty lastError means writes were lost; inspect stderr and fix the filesystem before relying on subsequent records." (`main.nim:450-452`) | `{"onDemand": true}` (`main.nim:448`) — **no** `approval`, **no** `effect`, **no** `timeoutMs`, **no** `parallel` |

- Both are discover-only (kept out of the conversation's frozen direct toolset);
  the MANUAL reflects this in prose — "the observe/logfile diagnostics" are
  listed under the on-demand tail (MANUAL:1911-1912) — but there is no tools
  table naming them or their flags, unlike `observe`.
- Neither declares `x-harness.effect`; the fabric batch host classifies an
  undeclared tool as `"write"` and schedules it exclusively
  (`components/fabric/fabric.nim:226-228`, `:309`, `:327`) even though both are
  read-only. The MANUAL states this exact consequence for `bash` (MANUAL:129)
  and `fetch` (MANUAL:1222) but not here.
- Without `x-harness.timeoutMs`, core's dispatch default of 120 000 ms applies
  (`core/dispatch.nim:173`, `:1638-1641`) — a `logfile_search` over a large
  `NIF_LOGFILE_SCAN_BYTES` budget can therefore hold a call for up to two
  minutes.

Parameters (`main.nim:293-295`, doc at `:301-306`):

- `logfile_search {component="", level="", regex="", since=0.0, until=0.0, limit=100}`
  — `component` is `ev.log.<component>` (max 64 chars, `:307-308`); `level` is
  one of `debug|info|warn|error` (`:29`, `:309-310`); `regex` ≤1024 bytes
  (`:27`, `:311-312`); `since > until` is refused (`:313-314`); an invalid regex
  is refused (`:321-322`); `limit` is clamped to 1..500 (`:323`) although the doc
  says "cap 500" (`:306`). `since`/`until` are epoch **seconds** compared against
  the sink's own `receivedAt`, never against the emitter's `at`
  (`:381-384`; emitter time is only echoed as `emittedAt`, `:406-407`).
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
  (count), `subjects`, `totalFiles`, `truncated`, `directoryTruncated`,
  `maxDirectoryEntries`, `responseBytes` (`:483-491`).
- **Error convention differs from `observe`**: invalid `logfile_search`
  arguments return a *successful* result containing `{"error": ...}`
  (`main.nim:308`, `:310`, `:312`, `:314`, `:322`) instead of the SDK's
  `errResult` shape (`sdk/niffler/sdk.nim:198-204`) that `observe` uses. A model
  must inspect the payload for `error`, not the call status.
- No `selftest` tool (`grep -c selftest components/logfile/main.nim` → 0), so
  `/doctor deep` reports this component as not implementing one.

## 3. Configuration

### Event subjects it consumes

- One tap either on the single configured pattern (default `ev.log.>`) or, when
  more than one pattern is configured (or the list contains `>`), on `>` with
  local filtering (`main.nim:204-227`). Because the multi-pattern case taps
  `>`, the component then *sees* every bus message — including `_INBOX.*`
  replies — and writes the ones that match a pattern into `bus.jsonl`.
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
| `NIF_LOGFILE_MAX_BYTES` | `main.nim:37-38` | `10_485_760` (`DefaultMaxBytes` `:14`) | 256 … 104 857 600 (`:20`) |
| `NIF_LOGFILE_KEEP` | `main.nim:39` | `5` (`:15`) | 0 … 100; `0` = no rotated generation kept (`rotate`, `:108-110`) |
| `NIF_LOGFILE_MAX_FILES` | `main.nim:40-41` | `64` (`:16`) | 1 … 1024; counts *component* files only (`bus.jsonl` is exempt, `:199`) |
| `NIF_LOGFILE_SCAN_BYTES` | `main.nim:42-43` | `16_777_216` (`:17`) | 1024 … 104 857 600; shared across all files of one search (`:350-360`) |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | `main.nim:44-45` | `10_000` (`:18`) | 100 … 100 000; applies to both tools (`:332`, `:458`) |
| `NIF_LOGFILE_SUBJECTS` | `main.nim:204-221` | `ev.log.>` | validated, not numeric; fatal on bad input |

Not environment-driven, hardcoded in the file: rotation generation naming
`<file>.1..N` (`main.nim:111-120`), the boot prune (`:122-136`, `:194`),
`MaxSearchItems = 5000` (`:21`), `MaxResponseBytes = 60_000` /
`ResponseItemBudget = 55_904` (`:22-23`), `MaxPathItems = 500` (`:24`),
`MaxRegexBytes = 1024` (`:27`), the allowed levels (`:29`), O_APPEND-per-record
writes, and directory/file permissions (0700 dir `:156`, 0600 files `:174`).

### Where output lands

`$NIF_ROOT/var/logs/` by default: `<component>.jsonl` plus `<file>.1 … <file>.N`
rotations per component, and `bus.jsonl` for everything else. One JSON object
per line: `{receivedAt, subject, message}` for decodable input, plus
`rawBase64`/`encoding`/`bytes`/`decodeError` or `raw`/`decodeError` for the
undecodable cases (`rawEntry`, `main.nim:138-151`). The MANUAL's `var/` state row
already claims `logs/` for "bus JSONL + child logs" (MANUAL:330) — accurate, but
it does not mention the rotation generations or the 0700/0600 modes.

## 4. How `docs/MANUAL.md` covers it today

The section **exists** (a subsection, not its own chapter):
`### `logfile`: rotating JSONL persistence` at MANUAL:2279, body 2281-2328,
inside `## Observation and logs` (MANUAL:2220). It is unusually complete — most
of the behaviour above is stated — and it is *correct*; the deltas are missing
numbers and flags, not false claims. Exact current text:

- MANUAL:2281-2283:
  > `logfile` is best-effort process-local persistence, not an audit log. Core NATS
  > is at-most-once: records emitted before startup or during a restart are lost.
  > Guaranteed replay would require an explicit JetStream design.
- MANUAL:2285:
  > Default input is `ev.log.>`. A valid component name gets one file:
- MANUAL:2293-2298:
  > `` `NIF_LOGFILE_SUBJECTS` can select other subjects. Non-log traffic, including ``
  > `` whole-bus `>`, goes to a single `bus.jsonl`; dynamic inbox subjects therefore do ``
  > `not create unbounded file descriptors or filenames. The number of component log`
  > `files is capped, and excess/spoofed component subjects also fall back to`
  > `` `bus.jsonl`. Multiple configured patterns are treated as one locally filtered ``
  > `union, so overlapping patterns persist each matching publication exactly once.`
- MANUAL:2300-2304 (the record example, `{"receivedAt": 1780000000.25, ...}`).
- MANUAL:2306-2312:
  > `Malformed UTF-8 input uses lossless `rawBase64`; textual malformed input uses`
  > `raw` and `decodeError`. The sink opens, appends, flushes, and closes each record.`
  > `Rotation compares `current size + record size` before`
  > `renaming closed files, so exact-boundary writes cannot leave a stale file handle.`
  > `A single record larger than the configured file size is retained as the active`
  > `file and rotated before the next record. `NIF_LOGFILE_KEEP=0` retains no rotated`
  > `generation.`
- MANUAL:2314-2323:
  > `` `logfile_search` reads only a bounded tail from the retained files, sorts ``
  > `` matching records by `receivedAt` newest-first, and reports `truncated`, ``
  > `` `scannedBytes`, malformed line counts, and read errors. Results also have an ``
  > `encoded response-byte budget. Structured log records expose `component`,`
  > `` `level`, `msg`, `ctx`, and optional emitter time; raw bus records expose the ``
  > `` preserved message. Search never trusts an emitter-supplied timestamp for ``
  > `` `since`/`until` windows. ``
  > `Directory enumeration is capped by `NIF_LOGFILE_DIRECTORY_ENTRIES` and reports`
  > `` `directoryTruncated` when more files exist; searches still inspect the bounded ``
  > `subset.`
- MANUAL:2325-2328:
  > `` `logfile_paths` reports a bounded retained-file list plus `writeErrors`, ``
  > `` `lastError`, and `lastErrorAt`. Filesystem failures also go to stderr. Capture ``
  > `directories are user-only where the platform permits; active symlink targets`
  > `are rejected.`

Verified against code (no change needed): the at-most-once framing
(`main.nim:1-7`); the one-file-per-valid-component-name rule and `bus.jsonl`
fallback (`main.nim:91-99`); the file cap and spoofed-name fallback
(`main.nim:41-50`, `:95-96`); multi-pattern local union and exactly-once
persistence (`main.nim:187-191`, `:224-227`); the record shape
(`main.nim:138-151`); rotation arithmetic and the oversize-record rule
(`main.nim:163-166`, `:105-120`); `KEEP=0` (`main.nim:108-110`); bounded-tail
search, `receivedAt` sorting, `truncated`/`scannedBytes`/`parseErrors`/
`readErrors` (`main.nim:340-446`); the response-byte budget (`main.nim:433-440`);
`since`/`until` never using emitter time (`main.nim:381-384`, `:406-407`);
`DIRECTORY_ENTRIES` + `directoryTruncated` (`main.nim:330-335`, `:458-460`);
`logfile_paths` health fields and stderr on write failure (`main.nim:178-185`,
`:483-491`); symlink refusal (`main.nim:160-161`); the shipped row MANUAL:83 and
env rows MANUAL:417-423 (all seven variables present with the documented
defaults).

**Explicitly absent / incomplete in the MANUAL**:

1. The two tool names are mentioned in prose only; no flags are stated, and in
   particular the missing `x-harness.effect` consequence (write-scheduled) is
   not mentioned although the MANUAL states it for `bash` (129) and `fetch`
   (1222).
2. Parameter names, defaults and clamps of `logfile_search`
   (`component ≤64` chars, `level` enum, `regex ≤1024`, `limit` 100/500,
   `since ≤ until` in epoch seconds) and of `logfile_paths` are not documented.
3. The invalid-input `{"error": …}`-inside-a-successful-result convention.
4. The fatal validation of `NIF_LOGFILE_SUBJECTS` (>64 patterns, >512-byte
   pattern, malformed pattern, empty result) and the accepted *ranges* of the
   five numeric knobs (the env table gives only the defaults; MANUAL:2435-2436
   does say invalid configuration exits non-zero, which is correct).
5. Boot-time prune of `.jsonl.N` above `keep` and the re-seeding of the
   component-file registry from files on disk.
6. Rotation generation naming and the 0700/0600 permission modes.
7. `NIF_LOGFILE_DIR` may be absolute or root-relative (`main.nim:32-36`); the
   env table says only "JSONL output directory".
8. The wording "Capture directories are user-only …; active symlink targets are
   rejected" (MANUAL:2326-2328) borrows `observe`'s noun for logfile's own log
   directory. True, but misleading about which directory and which component.

## 5. DELTA list (classed)

1. **[missing] Tool flags are never stated.** Both tools are `{"onDemand": true}`
   (`main.nim:292`, `:448`) with no `approval`, no `effect` and no `timeoutMs`;
   the fabric consequence (classified as a **write**, scheduled exclusively —
   `components/fabric/fabric.nim:226-228`, `:309`) is exactly the kind of fact
   the MANUAL states for `bash`/`fetch`. Fix: one short "The tools" table for
   the logfile subsection (matching `observe`'s), stating on-demand reachability,
   read-only intent, the missing `effect`, and the 120 s default deadline.
2. **[missing] `logfile_search` parameters and caps.** `main.nim:293-306`,
   `:307-323`: `component` ≤64, `level ∈ {debug,info,warn,error}`, `regex`
   ≤1024, `since ≤ until` (epoch seconds), `limit` default 100 / cap 500,
   candidates capped at 5000 (`:21`, `:371-374`), response budget 55 904 bytes
   (`:22-23`, `:433-440`), file list capped at 500 items for `logfile_paths`
   (`:24`).
3. **[missing] Env ranges.** The five numeric knobs are fatal outside
   `256..104857600`, `0..100`, `1..1024`, `1024..104857600`, `100..100000`
   (`main.nim:37-45`); the env table (MANUAL:419-423) lists only defaults.
   `NIF_LOGFILE_SUBJECTS` is itself validated and fatal (`main.nim:212-221`) —
   the row (MANUAL:418) says only "comma-separated NATS patterns to persist".
4. **[missing] Boot prune and registry seeding.** `pruneRotations()` deletes any
   `.jsonl.N` with `N > keep` at every start (`main.nim:122-136`, `:194`), and
   existing `*.jsonl` files are counted against `NIF_LOGFILE_MAX_FILES`
   (`main.nim:195-201`). Operators lowering `NIF_LOGFILE_KEEP` lose files at the
   next boot; nothing says so.
5. **[missing] Storage layout detail.** `<file>.1 … <file>.N` generation naming
   (`main.nim:111-120`), the log directory created 0700 and files 0600
   (`main.nim:156`, `:174`), and `NIF_LOGFILE_DIR`'s absolute-vs-root-relative
   rule (`main.nim:32-36`). The `var/` row (MANUAL:330) mentions `logs/` only.
6. **[code-bug?] Invalid `logfile_search` input is reported as success.**
   `{"error": ...}` inside an otherwise successful tool result
   (`main.nim:308`, `:310`, `:312`, `:314`, `:322`) diverges from the SDK's
   `errResult` convention used by `observe` (`sdk/niffler/sdk.nim:198-204`).
   Either return `errResult` (code) or document the shape in the subsection.
7. **[missing] Read-vs-write classification.** Covered by 1; called out
   separately because the current MANUAL gives the model/pipeline no way to know
   that two obviously read-only diagnostics are serialized as writes.
8. **[doc-edit] "Capture directories" wording.** MANUAL:2326-2328 speaks of
   "Capture directories" in the `logfile` subsection; the sentence is about the
   log directory (and the symlink refusal at `main.nim:160-161`). Say "the log
   directory" here and leave "capture" to `observe`.
9. **[missing] No `logfile_search`/`logfile_paths` names in the shipped-policy
   tail.** MANUAL:1911-1912 says only "the observe/logfile diagnostics"; naming
   the two tools there (or linking the table added by 1) makes discovery
   predictable.
10. **[delta] Both tools inherit core's 120 s default deadline.** With
    `NIF_LOGFILE_SCAN_BYTES` at its maximum a single search may scan 100 MB;
    the 120 s default (`core/dispatch.nim:173`, `:1638-1641`) is the only bound.
    One clause; a `timeoutMs` on the schema would be the code-side alternative.
11. **[delta] The component registers no `selftest`**
    (`grep -c selftest` → 0) while `tests/t_logfile.nim` and `make test-logfile`
    exist (`Makefile:514`) and are already named in MANUAL:2447 — the gap is
    only the `/doctor` clause.
12. **[verified] The whole `logfile` subsection is factually right.** Every claim
    in 2281-2328 was re-checked against `main.nim` (evidence per sentence listed
    in §4); the two `NIF_*` names it cites (`NIF_LOGFILE_SUBJECTS` at 2293,
    `NIF_LOGFILE_DIRECTORY_ENTRIES` at 2321, `NIF_LOGFILE_KEEP` at 2311) match
    the code.
13. **[verified] The env table rows 417-423 are complete and correct** for this
    component: all seven variables, with the right defaults
    (`main.nim:32-45`, `:204-206`).
14. **[verified] MANUAL:2435-2436's "All bounds are validated at startup; invalid
    configuration exits non-zero rather than silently substituting a default"
    holds for `logfile`** (`configInt` raises, `sdk/niffler/sdk.nim:268-284`;
    the subject list raises at `main.nim:212-221`).

## 6. Machine-parsed rows

### Observation and logs

- MANUAL: "`logfile_search` reads only a bounded tail from the retained files, sorts\nmatching records by `receivedAt` newest-first, and reports `truncated`,\n`scannedBytes`, malformed line counts, and read errors. Results also have an\nencoded response-byte budget." | CODE: components/logfile/main.nim:292-295,323,433-446 | FIX: add after the sentence — "It is `onDemand` and declares no `x-harness.effect`, so the fabric batch host schedules it as a write; the arguments are `{component?, level? (debug|info|warn|error), regex? (≤1024 bytes), since?, until? (epoch seconds, since ≤ until), limit? (default 100, cap 500)}`, and an invalid argument comes back as `{"error": …}` inside a successful result rather than an error envelope."
- MANUAL: "`logfile_paths` reports a bounded retained-file list plus `writeErrors`,\n`lastError`, and `lastErrorAt`. Filesystem failures also go to stderr. Capture\ndirectories are user-only where the platform permits; active symlink targets\nare rejected." | CODE: components/logfile/main.nim:448,463-491,156,174 | FIX: update — "`logfile_paths` (`onDemand`, no `x-harness.effect`) reports up to 500 retained files plus `writeErrors`, `lastError`, `lastErrorAt`, `maxBytes`, `keep`, `subjects` and the component-file count. Filesystem failures also go to stderr. The **log directory** is created user-only (0700, files 0600) where the platform permits, and an active symlink at a log path is refused."
- MANUAL: "Malformed UTF-8 input uses lossless `rawBase64`; textual malformed input uses\n`raw` and `decodeError`. The sink opens, appends, flushes, and closes each record.\nRotation compares `current size + record size` before\nrenaming closed files, so exact-boundary writes cannot leave a stale file handle.\nA single record larger than the configured file size is retained as the active\nfile and rotated before the next record. `NIF_LOGFILE_KEEP=0` retains no rotated\ngeneration." | CODE: components/logfile/main.nim:105-120,122-136,138-151,153-176 | FIX: add — "Rotated generations are named `<file>.1` … `<file>.<KEEP>`, and every boot deletes any generation numbered above the current `NIF_LOGFILE_KEEP` (so lowering the knob destroys history at the next start); `.jsonl` files already on disk at boot also count against `NIF_LOGFILE_MAX_FILES`."
- MANUAL: "`NIF_LOGFILE_SUBJECTS` can select other subjects. Non-log traffic, including\nwhole-bus `>`, goes to a single `bus.jsonl`; dynamic inbox subjects therefore do\nnot create unbounded file descriptors or filenames. The number of component log\nfiles is capped, and excess/spoofed component subjects also fall back to\n`bus.jsonl`." | CODE: components/logfile/main.nim:204-227,25-26,212-221 | FIX: add — "The list is validated at boot: a malformed or over-512-byte pattern, more than 64 unique patterns, or an empty result makes the component exit non-zero; with several patterns the tap is `>` and matching happens locally, with one pattern the pattern itself is subscribed."
- MANUAL: "Default input is `ev.log.>`. A valid component name gets one file:" | CODE: components/logfile/main.nim:91-99,32-36 | FIX: add — "one file per component name matching `[a-z0-9-]{1,64}` under `NIF_LOGFILE_DIR` (`$NIF_ROOT/var/logs` by default; an absolute value is used as-is, a relative one is resolved against the harness root)."
- MANUAL: "`logfile` is best-effort process-local persistence, not an audit log. Core NATS\nis at-most-once: records emitted before startup or during a restart are lost.\nGuaranteed replay would require an explicit JetStream design." | CODE: components/logfile/main.nim:1-7 (no `emit`/`publishEnvelope`; pure sink) | FIX: none — verified
- MANUAL: "`logfile_paths` reports a bounded retained-file list plus `writeErrors`,\n`lastError`, and `lastErrorAt`. Filesystem failures also go to stderr." | CODE: components/logfile/main.nim:178-185,483-491 | FIX: none — verified
- MANUAL: "Search never trusts an emitter-supplied timestamp for `since`/`until` windows." | CODE: components/logfile/main.nim:381-384,406-407 | FIX: none — verified (`since`/`until` filter the sink's `receivedAt`; the emitter's `at` is only echoed as `emittedAt`)

### Environment variables

- MANUAL: "| `NIF_LOGFILE_DIR` | JSONL output directory | `$NIF_ROOT/var/logs` |" | CODE: components/logfile/main.nim:32-36 | FIX: none — verified: empty → `$NIF_ROOT/var/logs`, absolute → as-is, relative → `$NIF_ROOT/<value>`
- MANUAL: "| `NIF_LOGFILE_SUBJECTS` | comma-separated NATS patterns to persist | `ev.log.>` |" | CODE: components/logfile/main.nim:204-227 | FIX: update — "comma-separated NATS patterns to persist (validated at boot: malformed, >512-byte, more than 64 unique, or an empty list exits non-zero)"
- MANUAL: "| `NIF_LOGFILE_MAX_BYTES` | active bytes per JSONL file before rotation | `10485760` |" | CODE: components/logfile/main.nim:37-38 | FIX: update — append "; accepted range 256..104857600, outside it the component exits non-zero"
- MANUAL: "| `NIF_LOGFILE_KEEP` | retained rotated generations (`0` disables) | `5` |" | CODE: components/logfile/main.nim:39,122-136 | FIX: update — append "; range 0..100, generations above the value are deleted at every boot"
- MANUAL: "| `NIF_LOGFILE_MAX_FILES` | component-specific files before fallback to `bus.jsonl` | `64` |" | CODE: components/logfile/main.nim:40-41,195-201 | FIX: update — append "; range 1..1024, files already present at boot count toward it"
- MANUAL: "| `NIF_LOGFILE_SCAN_BYTES` | maximum bytes examined by one `logfile_search` | `16777216` |" | CODE: components/logfile/main.nim:42-43,350-360 | FIX: update — append "; range 1024..104857600, shared across all files of one search"
- MANUAL: "| `NIF_LOGFILE_DIRECTORY_ENTRIES` | maximum candidate JSONL paths enumerated per query | `10000` |" | CODE: components/logfile/main.nim:44-45,330-335,458-460 | FIX: update — append "; range 100..100000, applies to `logfile_paths` as well and is reported as `directoryTruncated`"

### Shipped components

- MANUAL: "| `logfile` | Nim | optional | rotating JSONL sink and bounded persisted-log search (see [Observation and logs](#observation-and-logs)) |" | CODE: components/logfile/main.nim:292,448; manifest.yaml:205-210 | FIX: none — verified: two on-demand tools, `autostart: true`, `required: false`, `restart: on-failure`, no `replicas` (a pure sink must not be replicated)

### Progressive tool discovery (`discover`/`invoke`)

- MANUAL: "- Search and inspection: `files` (sorted listing), the git\n  tools, `undo_last_edit`, `repo_map` (the ranked workspace map the model\n  asks for explicitly), and the observe/logfile diagnostics." | CODE: components/logfile/main.nim:292,448 | FIX: update — replace "the observe/logfile diagnostics" with "the `observe_*` diagnostics and logfile's `logfile_search`/`logfile_paths`"

### Layout of a running system

- MANUAL: "| **`var/`** (gitignored) | `bin/` built binaries, `logs/` bus JSONL + child logs, `models/` catalog cache, `nats-url`/`nats-pid` bus claiming, `processes/` spools, `repomap-tags/` per-file tags cache (`{mtime, tags}` JSON keyed by the sha1 of the absolute path; empty results are never cached), `fetch/`, `captures/`, `store.db` (the store engine's file — exactly one owner) | runtime, regenerable |" | CODE: components/logfile/main.nim:33-36,111-120 | FIX: update — replace "`logs/` bus JSONL + child logs" with "`logs/` bus JSONL + per-component JSONL with `.1`…`.N` rotations + child logs"

### Testing

- MANUAL: "`tests/t_logfile.nim` covers SDK log filtering, newest-first queries, time/regex\nfilters, encoded response and actual disk-read bounds, exact-once overlapping\nsubject patterns, closed-file rotation, zero retention, embedded-NUL whole-bus\npreservation, bounded path listings, sink health, and invalid configuration." | CODE: tests/t_logfile.nim:1-374; Makefile:514 | FIX: none — verified (this is the one component of the four whose test is already named)

## 7. Not user-facing

- `readTail`'s boundary look-behind arithmetic (`main.nim:254-290`), the
  `SearchItem` ordering tuple (`:252`, `:428-430`) and the `matchesPattern`
  token walk (`:76-89`).
- `componentFiles`/`patterns` bookkeeping (`main.nim:50-51`) — only its two
  user-visible consequences (file cap, boot seeding) belong in the MANUAL.
- `pruneRotations`' `try/except` on a non-numeric suffix (`main.nim:132-136`).
- The `rawEntry` key layout beyond the documented example (MANUAL:2302-2304
  already shows the happy path; the malformed variants are summarized in prose).

**Finding count: 14** (6 MANUAL gaps, 1 error-convention inconsistency
(code-bug? candidate), 3 small doc-edits/deltas, 4 verified-OK blocks).
