# Worklist slice: Observation and logs

From `worklist.tsv` (37 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A236 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1746–1757 "Boundary … Observe the bus, not component internals"
- CODE: correct, but the section never states the negative half — none of `observe`, `logfile`, `console` is a durable record of *decisions*: observe keeps a bounded in-memory ring (`components/observe/main.nim:16–20`), logfile is explicitly best-effort (MANUAL:1808 says so), console renders and forgets (`components/console/main.nim:75–105`), hooks keep nothing
- FIX: add a "Not an audit trail" list to §Boundary: "None of these is an audit log: observe is a bounded in-memory ring that dies with the component, logfile is best-effort (at-most-once, `ev.log.>` by default), console prints and forgets, and hooks record nothing. The only durable artefacts of the approval gate are the client-written grant record (store kind `approval`) and the program source core writes to `var/approval-sources/<digest>.nim` — no request/verdict history exists."

## A238 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1785 table row "`observe_monitor` | Read nats-server connection/subscription counts and most-subscribed patterns"
- CODE: the tool carries `approval: always` (`components/observe/main.nim:714`) like `observe_send`/`observe_request`/`observe_dump` — MANUAL says this two paragraphs later (1791–1794) but the table column reads as a plain read
- FIX: add "(approval-gated — it borrows the operator's monitoring endpoint)" to the row, or move the gate marker into the table for all four.

## A239 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1791–1794 "A client talking directly to `svc.observe.call` is already a trusted bus peer and bypasses core policy"
- CODE: matches the design (the gate lives in `core/dispatch.nim:1556–1559`, not in the component)
- FIX: none — but consider one clause: "the component itself enforces only its own input/subject validation (`components/observe/main.nim:366–372,392`)."

## A240 (verified)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1946–1952 "`NIF_OBSERVE_MONITOR_URL` explicitly … `observe_monitor` reads `/subsz` and `/connz` with a fresh HTTP client for each request"
- CODE: `components/observe/main.nim:719` (`NIF_OBSERVE_MONITOR_URL`) and `:727` (`proc fetch` per request)
- FIX: none.

## A241 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1961–1973 Verification section names `tests/t_observe.nim` and `tests/t_logfile.nim`
- CODE: both exist and are wired into `make test-server` (`tests/t_observe.nim`, `tests/t_logfile.nim`, `Makefile:501` for hooks) — but `tests/t_hooks.nim` is not named anywhere in MANUAL
- FIX: add "`tests/t_hooks.nim` covers env→subject mapping, stdin payload delivery and timeout behaviour" to the hooks section or to §Testing.

## A587 (verified)
source: `components/console.md`

- MANUAL: MANUAL: "`console` prints and forgets, and `hooks` record nothing."
- CODE: components/console/main.nim:1-11 (no ring, no file, no state)
- FIX: fix: none — verified [verified]

## A677 (doc-edit)
source: `components/hooks.md`

- MANUAL: MANUAL: "All bounds are validated at startup; invalid configuration exits non-zero"
- CODE: components/hooks/main.nim:93-97; sdk/niffler/sdk.nim:268-284
- FIX: none — [verified] the sentence is scoped to `NIF_OBSERVE_*`/`NIF_LOGFILE_*`, whose knobs go through `configInt` and kill the component when out of range; `hooks` deliberately clamps instead, which its own env row states.

## A679 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "`logfile_search` reads only a bounded tail from the retained files, sorts"
- CODE: components/logfile/main.nim:292-295,307-323,433-446; sdk/niffler/sdk.nim:198-204,723-727
- FIX: add — [missing] after that sentence: "It is `onDemand` and declares no `x-harness.effect`, so the fabric batch host schedules it as a write. Arguments are `{component?, level? (debug|info|warn|error), regex? (≤1024 bytes), since?, until? (epoch seconds, `since ≤ until`), limit? (default 100, cap 500)}`; an invalid argument comes back as `{"error": …}` inside a *successful* result rather than as an error envelope, and with no `timeoutMs` on the schema the call runs under core's 120 s default deadline."

## A680 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "`logfile_paths` reports a bounded retained-file list plus `writeErrors`,"
- CODE: components/logfile/main.nim:448,463-491,156,174
- FIX: update — [doc-edit] "`logfile_paths` (`onDemand`, no `x-harness.effect`) reports up to 500 retained files plus `writeErrors`, `lastError`, `lastErrorAt`, `maxBytes`, `keep`, `subjects` and the component-file count. Filesystem failures also go to stderr. The **log directory** is created user-only (0700, files 0600) where the platform permits, and an active symlink at a log path is refused." ("Capture directories" borrows `observe`'s noun for logfile's own directory.)

## A681 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "Malformed UTF-8 input uses lossless `rawBase64`; textual malformed input uses"
- CODE: components/logfile/main.nim:105-120,122-136,195-201
- FIX: add — [missing] "Rotated generations are named `<file>.1` … `<file>.<KEEP>`, and every boot deletes any generation numbered above the current `NIF_LOGFILE_KEEP` — lowering the knob destroys history at the next start. `.jsonl` files already on disk at boot also count against `NIF_LOGFILE_MAX_FILES`."

## A682 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "`NIF_LOGFILE_SUBJECTS` can select other subjects. Non-log traffic, including"
- CODE: components/logfile/main.nim:204-227,25-26,212-221
- FIX: add — [missing] "The list is validated at boot: a malformed or over-512-byte pattern, more than 64 unique patterns, or an empty result makes the component exit non-zero. With several patterns the tap is `>` and matching happens locally; with one pattern that pattern itself is subscribed."

## A683 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "Default input is `ev.log.>`. A valid component name gets one file:"
- CODE: components/logfile/main.nim:91-99,32-36
- FIX: add — [missing] "one file per component name matching `[a-z0-9-]{1,64}` under `NIF_LOGFILE_DIR` (`$NIF_ROOT/var/logs` by default; an absolute value is used as-is, a relative one is resolved against the harness root)."

## A684 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "`logfile` is best-effort process-local persistence, not an audit log. Core NATS"
- CODE: components/logfile/main.nim:1-7 (no `emit`/`publishEnvelope`)
- FIX: none — [verified]

## A685 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "preserved message. Search never trusts an emitter-supplied timestamp for"
- CODE: components/logfile/main.nim:381-384,406-407
- FIX: none — [verified] `since`/`until` filter the sink's `receivedAt`; the emitter's `at` is only echoed as `emittedAt`.

## A686 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "Directory enumeration is capped by `NIF_LOGFILE_DIRECTORY_ENTRIES` and reports"
- CODE: components/logfile/main.nim:44-45,330-335,458-460
- FIX: none — [verified] (the accepted range 100..100000 is proposed in the env row below, not here).

## A697 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "`tests/t_logfile.nim` covers SDK log filtering, newest-first queries, time/regex"
- CODE: tests/t_logfile.nim:1-374; Makefile:514
- FIX: none — [verified] the test is named and its coverage list matches (rotation, zero retention, exact-once overlapping patterns, response bounds, sink health, invalid configuration).

## A699 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "The global ring is bounded by both message count and approximate wire bytes."
- CODE: components/observe/main.nim:16-32,71-80,184-195,410-413
- FIX: add — [missing] the numbers: "the ring keeps 2 000 messages and ~16 MiB (`NIF_OBSERVE_RING`, clamped 1..10000; `NIF_OBSERVE_RING_BYTES`, 64 KiB..100 MiB), a single retained message is capped at 64 KiB (`NIF_OBSERVE_ENTRY_BYTES`, 1 KiB..1 MiB — larger ones become a base64 preview), each probe keeps at most 2 000 entries and 2 MiB (`cap`, clamped 1..2000; `NIF_OBSERVE_PROBE_BYTES`, 64 KiB..16 MiB), and at most 32 probes exist at once (`NIF_OBSERVE_MAX_PROBES`, 1..256), so the 33rd `observe_listen`/`observe_trace` fails until one is removed."

## A700 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe_request` | Diagnostic request/reply to a concrete `svc.*.call`; approval-gated and limited to 30 seconds |"
- CODE: components/observe/main.nim:376,392-393
- FIX: update — [doc-edit] "Diagnostic request/reply to a concrete `svc.*.call`; approval-gated. The request wait is clamped to 100–30000 ms (`timeoutMs`), and the tool call itself carries `x-harness.timeoutMs: 35000`."

## A701 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe_events` | Query a probe or the global ring, newest first, with time/kind/component/subject/regex filters |"
- CODE: components/observe/main.nim:515-534,551,574-579
- FIX: add — [missing] "`kind` is `call|result|event|error`, `component` matches `svc.<component>.*`, `ev.log.<component>` or an envelope's own `component`, `subject` is an exact concrete subject, and `limit` is clamped to 1..500."

## A702 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe_listen` | Start a bounded capture for a token-correct NATS pattern (`*` and terminal `>`) plus optional regex |"
- CODE: components/observe/main.nim:95-115,415,419-446
- FIX: add — [missing] "`cap` defaults to 500 and is clamped to 1..2000; the returned `probeId` is `pr-<id>` (same for `observe_trace`)."

## A703 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe_trace` | Capture calls to one component and correlate result/error inbox replies by envelope id |"
- CODE: components/observe/main.nim:206-211,243-251,447-471
- FIX: add — [missing] "it watches `svc.<component>.call` and the scoped `svc.<component>.<id>.call` form, `toolRegex` filters by tool name, `cap` defaults to 500 (max 2000), and each reply carries `elapsedMs` measured on a monotonic clock."

## A704 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe_subjects` | List the authoritative component/service view when core is reachable, known event patterns, and the most frequently observed concrete subjects |"
- CODE: components/observe/main.nim:292-295,303-317,33-37,167-175,347-348
- FIX: add — [missing] "the service view maps a `session-<id>` component to `svc.session.<id>.call`; the known-event list is the fixed set `reg.publish`, `reg.depart`, `ev.sys.drain`, `ev.catalog.updated`, `ev.llm.token`, `ev.session.>`, the three `ev.approval.*` subjects, `svc.approval.>.request`, `ev.log.>`, `ev.models.updated` and `llm.cancel.>`; the observed-subject census keeps the top 100 concrete subjects and excludes `_INBOX.*`. The core snapshot is a best-effort 250 ms `catalog` request — when core does not answer, the list falls back to the tap-derived registrations, and the `*Truncated`/`dropped*` counters say when the view is partial."

## A705 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe_dump` | Approval-gated export of one probe beneath `NIF_OBSERVE_CAPTURE_DIR`; arbitrary output paths are not accepted |"
- CODE: components/observe/main.nim:677-712,652-675
- FIX: add — [missing] "the file is `<captureDir>/<probeId>.jsonl` (one JSON object per captured entry), the directory is created user-only (0700, files 0600), a symlinked target is refused, and older captures are pruned to a byte quota and a 256-file cap — when even pruning cannot fit the dump the tool fails with `capture directory quota is exhausted`."

## A706 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe_logs` | Query recent `ev.log.*` events in memory |"
- CODE: components/observe/main.nim:591-651
- FIX: add — [missing] "in-memory ring only — for persisted history use `logfile_search`; items carry `component`, `level`, `msg` plus the emitter's `at` as `emittedAt` and `ctx` when present, and `limit` is clamped to 1..500."

## A707 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "| `observe_send` | Publish an event to a concrete `ev.*` or `llm.cancel.*` subject; approval-gated |"
- CODE: components/observe/main.nim:361-375
- FIX: none — [verified] a concrete subject is required and the published envelope is always `kind: event`, which is what makes the "cannot send call/result/error envelopes or registrations" sentence true.

## A708 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "`observe_send`, `observe_request`, `observe_monitor`, and the"
- CODE: components/observe/main.nim:361,376,677,714
- FIX: none — [verified] those are exactly the four tools carrying `approval: "always"`.

## A709 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "Generated captures are pruned oldest-first to a byte quota and a 256-file cap."
- CODE: components/observe/main.nim:652-675,31-32,79-80
- FIX: none — [verified] (`NIF_OBSERVE_CAPTURE_BYTES` default 67108864, clamped 64 KiB..1 GiB; `MaxCaptureFiles = 256`).

## A710 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "Trace requests expire from the pending correlation table after 60 seconds."
- CODE: components/observe/main.nim:22,197-204
- FIX: none — [verified]

## A711 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "Probe subjects, labels, and regular expressions have fixed input limits;"
- CODE: components/observe/main.nim:25-29,186-188,23-24,584-590,398-408
- FIX: none — [verified] 512/256/1024-byte input limits, the `dropped` counter, the 60 000-byte response budget with `truncated` and the `valueTruncated`/`valueBytes` metadata for a large diagnostic reply.

## A712 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "`observe` has one raw `>` subscription. It preserves the original JSON node,"
- CODE: components/observe/main.nim:142-157,278-290
- FIX: none — [verified]

## A713 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "`observe_monitor` reads `/subsz` and `/connz` with a fresh HTTP client for each"
- CODE: components/observe/main.nim:714-769
- FIX: none — [verified] plus: `/subsz` is queried with `limit=1024`, each request has a 3 s client timeout, and a missing endpoint is a plain error asking for `NIF_OBSERVE_MONITOR_URL`.

## A714 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "All bounds are validated at startup; invalid configuration exits non-zero"
- CODE: components/observe/main.nim:71-80; sdk/niffler/sdk.nim:268-284
- FIX: none — [verified] every numeric `NIF_OBSERVE_*` goes through `configInt`, which raises `ValueError` outside its range.

## A715 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "All `NIF_OBSERVE_*`, `NIF_LOGFILE_*` and `NIF_LOG_LEVEL` variables are"
- CODE: docs/MANUAL.md env table (8 observe rows); components/observe/main.nim:71-85,719
- FIX: none — [verified] all eight are listed with the right defaults.

## A716 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: absent
- CODE: manifest.yaml:198-203; components/observe/main.nim:87-93
- FIX: add — [missing] one sentence to the Boundary paragraph, right after `Observation is an administrative capability. A bus capture can contain tool`: "do not replicate observe — the ring, the probes and the component census are process-local, so replicas would split one view into several and multiply exactly that surface; the manifest leaves replicas unset for this reason."

## A717 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: absent
- CODE: components/observe/main.nim:387-393,429-436,443,468,531,557; sdk/niffler/sdk.nim:723-727
- FIX: none — [delta] note only: the component uses two error conventions — argument checks that *raise* (subject/tool/timeout/cap, which the SDK turns into an error envelope with the message intact) and errResult returns (bad regex, unknown probe) — and the MANUAL's own `known event patterns` table is where a reader would look for the difference. Worth a clause only if the tool table gains a parameters column; both paths reach the model with the right text.

## A728 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "`tests/t_observe.nim` covers exact-once taps, wildcard boundaries, registration"
- CODE: tests/t_observe.nim:1-485; Makefile:513
- FIX: none — [verified] the test is named and its coverage list matches the file's scope.

## A782 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:2566-2567 `(the binary is the built component `var/bin/nats-server` from `components/nats` when present, else a PATH `nats-server`)`
- CODE: `core/niffler.nim:51-60` (`natsServerBinary`: `getAppDir()/nats-server` wins, else `"nats-server"` from PATH, with the `ours` flag deciding the payload route)
- FIX: none — verified accurate.

