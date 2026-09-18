# Audit — `components/observe/` (Nim, `main.nim`, 770 lines, component v0.1.0)

Scope: `components/observe/main.nim` (the only file; no README),
`manifest.yaml:196-203`, `sdk/niffler/sdk.nim:169-173` (tap) + `:723-727`
(result vs error envelope) + `:268-284` (`configInt`), `tests/t_observe.nim`
(485 lines), `Makefile:513` (`test-observe`), `core/niffler.nim:414-427` (the
monitor discovery file), and `docs/MANUAL.md` — `## Observation and logs` with
its `Boundary`, `observe`, `Monitoring` and `Verification` subsections, the
shipped row, the eight `NIF_OBSERVE_*` env rows. Read-only audit: no builds, no
source or MANUAL edits.

> **Line-number drift:** the numbers below are `docs/MANUAL.md` as it stood
> while this report was written (2850 lines); the concurrent consolidation pass
> kept editing it (3072 lines by the end, `## Observation and logs`
> ≈2220→2363, the `observe` subsection ≈2236→2387, `Monitoring` ≈2412→2563, the
> `NIF_OBSERVE_*` env rows ≈409→444). The quotes are the durable anchor — every
> row's quote was re-verified against the file — so re-resolve a number by
> searching its quote.

## 1. What it offers

- **Bounded, queryable inspection of the live bus without touching core or any
  observed component**: one raw `>` tap (`main.nim:3-6`, `:270-290`) feeds a
  count- and byte-bounded global ring (`addRing`, `main.nim:159-175`, bounds
  `:71-73`) and every active probe.
- **Targeted probes** with their own bounded buffers and two kinds
  (`ProbeKind = pkListen | pkTrace`, `main.nim:40-41`): `pkListen` captures
  subjects matching a pattern (optional regex over the serialised wire JSON);
  `pkTrace` correlates `svc.<component>.call` requests with their `_INBOX.*`
  replies by envelope id and records `elapsedMs` (`captureFor`,
  `main.nim:213-268`; `traceSubjectMatches` `:206-211` accepts `svc.<c>.call`
  and the scoped `svc.<c>.<id>.call` form).
- **Lossless-but-bounded message preservation**: the original JSON node is kept
  (unknown envelope fields included); invalid UTF-8 becomes lossless
  `rawBase64` + `decodeError`; undecodable JSON becomes `raw` + `decodeError`;
  a message larger than `NIF_OBSERVE_ENTRY_BYTES` becomes a base64 preview of
  3/4 of the cap instead of being retained whole (`wireMessage`,
  `main.nim:142-157`).
- **Component discovery two ways**: opportunistic `reg.publish`/`reg.depart`
  tracking from the tap (`main.nim:278-287`) and an authoritative
  `catalog {op: components}` snapshot with a 250 ms deadline when core is
  reachable (`observe_subjects`, `main.nim:303-317`).
- **Subject census**: concrete subjects are counted (top-100 reported, `:347-348`),
  inbox subjects excluded from the census; both the census and the component
  table have caps with `dropped*` counters (`main.nim:167-175`, `:30`, `:91-93`).
- **Approval-gated side effects only where they can change the world**: three
  tools (`observe_send`, `observe_request`, `observe_monitor`) plus the
  filesystem-writing `observe_dump` carry `approval: "always"`
  (`main.nim:361`, `:376`, `:677`, `:714`); the other eight tools only read
  in-memory state.
- **Confinement on export**: `observe_dump` only writes
  `<captureDir>/<probeId>.jsonl` for a probe that exists (so the id cannot be
  path-traversed), refuses a symlinked target, creates the directory 0700 and
  files 0600, and prunes oldest-first against a byte quota and a 256-file cap
  (`main.nim:677-712`; `prepareCapture` `:652-675`).
- **Process-local by construction**: ring, probes and the census live in the
  process (`main.nim:87-93`); no store use, no `onIdle`, no `selftest`
  (`grep -c 'storePut\|onIdle\|selftest' components/observe/main.nim` → 0). The
  manifest sets no `replicas` (`manifest.yaml:198-203`) — correctly, since
  replicating it would split one process's view into several.

## 2. Tools (exactly twelve)

All twelve are `onDemand: true` → discover-only (`discover` + `invoke`); none is
`hidden`. Flags are quoted verbatim from the registration:

| Tool | Registered at | Purpose (doc-comment text, abridged) | `x-harness` flags verbatim |
|---|---|---|---|
| `observe_subjects` | `main.nim:297-360` | "Discover components, service subjects, known event patterns, and the most frequently observed concrete subjects." (`:299-302`) | `{"onDemand": true}` |
| `observe_send` | `main.nim:361-375` | "Publish one event envelope. Use this only to exercise an event-driven behavior; it cannot call tools or spoof registrations." (`:363-366`) | `{"approval": "always", "onDemand": true}` |
| `observe_request` | `main.nim:376-408` | "Send a request/reply call to a concrete service subject for diagnosis. … The timeout is clamped to 100..30000 ms." (`:379-382`) | `{"approval": "always", "timeoutMs": 35_000, "onDemand": true}` |
| `observe_listen` | `main.nim:419-446` | "Start a bounded recording probe for a NATS subject pattern. Optional regex matches the preserved wire JSON." (`:422-424`) | `{"onDemand": true}` |
| `observe_trace` | `main.nim:447-471` | "Trace calls to svc.<component>.call and one scoped suffix (svc.<component>.<id>.call), correlating result/error inbox replies by envelope id with elapsedMs." (`:450-452`) | `{"onDemand": true}` |
| `observe_probes` | `main.nim:472-493` | "List active and stopped probes with their bounds and pending trace counts." (`:474-475`) | `{"onDemand": true}` |
| `observe_stop` | `main.nim:494-505` | "Stop recording into a probe while keeping its entries queryable." (`:496-497`) | `{"onDemand": true}` |
| `observe_remove` | `main.nim:506-514` | "Delete a probe and release its captured memory." (`:508`) | `{"onDemand": true}` |
| `observe_events` | `main.nim:515-590` | "Query a probe buffer or the global ring, newest first. Filters combine." (`:520-521`) | `{"onDemand": true}` |
| `observe_logs` | `main.nim:591-651` | "Search recent structured ev.log.\* events in memory, newest first. For persisted history use logfile_search." (`:595-596`) | `{"onDemand": true}` |
| `observe_dump` | `main.nim:677-712` | "Export a probe to NIF_OBSERVE_CAPTURE_DIR (default var/captures). The generated filename is confined to that directory; arbitrary paths are intentionally unsupported." (`:679-681`) | `{"approval": "always", "onDemand": true}` |
| `observe_monitor` | `main.nim:714-769` | "Read nats-server HTTP monitoring counts and the most-subscribed subject patterns." (`:716-717`) | `{"approval": "always", "onDemand": true}` |

Not one of the twelve declares `x-harness.effect`; fabric classifies an
undeclared tool as `"write"` and schedules it exclusively
(`components/fabric/fabric.nim:226-228`, `:309`, `:327`) — so a read-only
`observe_events` query serializes against other reads. None declares `parallel`
either.

Parameters, clamps and response bounds:

- `observe_send {subject, payload?}` — subject must be concrete (`*`/`>` refused)
  and must start with `ev.` or `llm.cancel.` (`main.nim:367-372`); the published
  envelope is always `kind: event` (`comp.emit`, `sdk/niffler/sdk.nim:175-177`),
  which is why it cannot forge a call/result/error or a registration.
- `observe_request {subject, tool, args?, timeoutMs=5000}` — subject must be a
  concrete `svc.*.call`; `tool` 1..256 bytes; `timeoutMs` **fatal unless in
  100..30000** (`main.nim:387-393`); the tool call itself is capped at 35 s by
  `x-harness.timeoutMs` (`:376`). A large reply is truncated to bite-size
  metadata rather than returned (`:398-408`).
- `observe_listen {subject, regex?, label?, cap=500}` — pattern validated with
  wildcards enabled: `*` allowed per token, `>` only as the terminal token;
  total ≤512 bytes, no whitespace (`validSubject`, `main.nim:95-115`); `label`
  ≤256 (`:431-433`); `regex` ≤1024 (`:434-436`); `cap` clamped to
  1..`MaxProbeEntries = 2000` (`:21`, `:415`).
- `observe_trace {component, toolRegex?, cap=500}` — `component` must be one
  subject token ≤128 bytes with no `.`/wildcards (`validComponent`,
  `main.nim:117-120`); `toolRegex` ≤1024; `cap` clamped as above. Correlation
  entries expire after `MaxPendingSeconds = 60` (`:22`, `prunePending`,
  `:197-204`), and the pending table is trimmed to `cap` (`:243-251`).
- `observe_events {probeId?, limit=100, since?, until?, kind?, component?,
  subject?, regex?}` — `kind ∈ {call,result,event,error}` (`:532-534`); `limit`
  clamped to 1..500 (`:551`); `component` matches `svc.<component>.*`,
  `ev.log.<component>`, or an envelope's own `component` field (`:574-578`);
  `subject` is exact (`:579`); results are newest-first under a 60 000-byte
  response bound with a `truncated` flag (`:23`, `:584-590`).
- `observe_logs {level?, component?, regex?, since?, limit=100}` — in-memory ring
  only; `level ∈ {debug,info,warn,error}` (`:602-603`); `limit` 1..500 (`:617`);
  items carry `at`, `subject`, `component`, `level`, `msg`, plus `emittedAt` and
  `ctx` when the emitter supplied them (`:637-643`).
- `observe_probes` reports per probe `{probeId (form `pr-<id>`, `:414`), kind,
  label, subject, startedAt, stopped, captured, pending, cap, bytes, byteCap,
  dropped}` under a response budget (`:472-493`).
- `observe_dump {probeId}` — path `<captureDir>/<probeId>.jsonl`; the probe must
  exist (`:685-687`); a symlinked target is refused; quota 64 MiB / 256 files
  (`:32`, `prepareCapture` `:652-675`); returns `{path, lines, bytes,
  captureByteCap}` (`:711-712`).
- `observe_monitor {}` — reads `NIF_OBSERVE_MONITOR_URL` else
  `<root>/var/nats-monitor-url` (`:719-723`; core writes the file only for a bus
  it spawned, `core/niffler.nim:414-427`); `/subsz?subs=1&limit=1024` and
  `/connz` with a fresh 3 s-timeout `HttpClient` per request (`:727-738`);
  returns `{connections, subscriptions, mostSubscribed (top 30),
  subscriptionDetailsReturned, subscriptionDetailsTruncated}` (`:753-767`).

## 3. Configuration

### Event subjects it consumes

A single `discard comp.tap(">", onBus)` (`main.nim:290`) — every message on the
bus, by design: the ring is a raw wire capture, the probes filter locally, and
`reg.publish`/`reg.depart` are read straight off the tap (`main.nim:278-287`).
It publishes only through `observe_send` (`comp.emit`, `main.nim:373`).

The patterns it advertises as "known event subjects" (`KnownEvents`,
`main.nim:33-37`, returned by `observe_subjects`): `reg.publish`, `reg.depart`,
`ev.sys.drain`, `ev.catalog.updated`, `ev.llm.token`, `ev.session.>`,
`ev.approval.request`, `ev.approval.reply`, `ev.approval.resolved`,
`svc.approval.>.request`, `ev.log.>`, `ev.models.updated`, `llm.cancel.>` — a
static list, not derived from the bus.

### Retention knobs (every `NIF_*` variable the component reads)

| Var | Where | Default | Accepted range (fatal outside it, `configInt`) |
|---|---|---|---|
| `NIF_OBSERVE_RING` | `main.nim:71` | `2000` (`:16`) | 1 … 10 000 |
| `NIF_OBSERVE_RING_BYTES` | `main.nim:72-73` | `16_777_216` (`:17`) | 65 536 … 104 857 600; approximate wire bytes (`$message.len + subject.len`, `:160`) |
| `NIF_OBSERVE_ENTRY_BYTES` | `main.nim:74-75` | `65_536` (`:18`) | 1 024 … 1 048 576; above it a message becomes a base64 preview (`:143-147`) |
| `NIF_OBSERVE_PROBE_BYTES` | `main.nim:76-77` | `2_097_152` (`:19`) | 65 536 … 16 777 216; per-probe byte bound (`:184-195`) |
| `NIF_OBSERVE_MAX_PROBES` | `main.nim:78` | `32` (`:20`) | 1 … 256; the refusal is a raised error (`:410-413`) |
| `NIF_OBSERVE_CAPTURE_BYTES` | `main.nim:79-80` | `67_108_864` (`:31`) | 65 536 … 1 073 741 824; aggregate quota for generated captures |
| `NIF_OBSERVE_CAPTURE_DIR` | `main.nim:81-85` | `$NIF_ROOT/var/captures` | absolute → as-is; relative → `$NIF_ROOT/<value>` |
| `NIF_OBSERVE_MONITOR_URL` | `main.nim:719` | unset → `<root>/var/nats-monitor-url` (`:720-723`) | any URL; empty leaves the tool reporting "no NATS monitoring endpoint" |

Hardcoded (not env): `MaxProbeEntries = 2000` per-probe entry count (`:21`),
`MaxPendingSeconds = 60.0` (`:22`), `MaxResponseBytes = 60_000` /
`ResponseItemBudget = 55_904` (`:23-24`), `MaxSubjectBytes = 512` (`:25`),
`MaxComponentBytes = 128` (`:26`), `MaxToolBytes = 256` (`:27`),
`MaxLabelBytes = 256` (`:28`), `MaxRegexBytes = 1024` (`:29`),
`MaxComponents = 1000` (`:30`), `MaxCaptureFiles = 256` (`:32`), the subject
census cap 2000 (`:170`), the top-100/30 output caps (`:347-348`, `:754`), and
the ring's `_INBOX.` exclusion from the census (`:167-175`).

### Where output lands

- In memory: ring plus probe buffers (lost at restart — nothing is persisted).
- On disk, only via `observe_dump`: `$NIF_ROOT/var/captures/<probeId>.jsonl`, one
  JSON object per captured entry, directory 0700 / file 0600 where the platform
  permits (`main.nim:688-710`). The `var/` state row already lists `captures/`,
  and the env table documents `NIF_OBSERVE_CAPTURE_DIR`.
- The monitor URL is *read* from `var/nats-monitor-url` (written by core, not by
  this component).

## 4. How `docs/MANUAL.md` covers it today

The section **exists** and is accurate: `### `observe`: bounded live inspection`
inside `## Observation and logs` (MANUAL:2236 in the revision read), body
2238-2277, plus `### Boundary` (2224), `### Monitoring` (2412) and
`### Verification` (2439). Exact current text (quotes anchor; numbers are the
revision read):

- **MANUAL:2238-2242** — "`observe` has one raw `>` subscription. It preserves
  the original JSON node, including unknown envelope fields and bare registration
  payloads. Malformed JSON is retained as `{raw, decodeError}` when it is valid
  UTF-8; arbitrary bytes use lossless `rawBase64` instead. Oversized messages are
  represented by a bounded base64 preview rather than letting one message consume
  the process." → verified (`main.nim:290`, `:142-157`, `:278-287`).
- **MANUAL:2244-2247** — "The global ring is bounded by both message count and
  approximate wire bytes. Each targeted probe has independent count and byte
  bounds; the number of probes is also capped. Stopped probes remain queryable
  until `observe_remove` releases their memory." → verified (`main.nim:159-166`,
  `:184-195`, `:410-413`, `:494-514`), but no numbers are given.
- **MANUAL:2249-2262** — the twelve-row tools table; the names and one-line
  purposes match the code exactly (verified row by row against
  `main.nim:297-769`). The `observe_request` row ends "approval-gated and limited
  to 30 seconds" — accurate for the *argument clamp* (`main.nim:392-393`) but it
  hides the 35 s `x-harness.timeoutMs` on the tool itself (`main.nim:376`).
- **MANUAL:2264-2270** — "`observe_send` cannot send call/result/error envelopes
  or registrations. `observe_send`, `observe_request`, `observe_monitor`, and the
  filesystem-mutating `observe_dump` carry `x-harness.approval: always`, so an LLM
  path must pass core's human gate. A client talking directly to
  `svc.observe.call` is already a trusted bus peer and bypasses core policy, just
  as it can call any other service subject directly. Generated captures are pruned
  oldest-first to a byte quota and a 256-file cap." → verified
  (`main.nim:367-373`, `:361`, `:376`, `:677`, `:714`, `:652-675`).
- **MANUAL:2272-2277** — "Trace requests expire from the pending correlation
  table after 60 seconds. Probe subjects, labels, and regular expressions have
  fixed input limits; oversized probe entries are dropped and counted rather than
  retained outside the byte budget. Tool responses stop before the wire's
  approximately 64 KiB inline-result convention and report `truncated` (or value
  byte metadata for a large diagnostic reply) rather than returning unbounded
  data." → verified (`main.nim:22`, `:197-204`, `:95-120`, `:25-29`, `:186-188`,
  `:23-24`, `:584-590`, `:398-408`).
- **MANUAL:2412-2437** (`### Monitoring`) — `observe_monitor` reads `/subsz` and
  `/connz` with a fresh HTTP client, reports `subscriptionDetailsTruncated`, and
  "`mostSubscribed` means subscriber density, not message throughput"; the
  discovery file is written only after the client connection succeeds → verified
  (`main.nim:727-767`; `core/niffler.nim:414-427`).
- **MANUAL:2226-2234** (`### Boundary`) — "core never imports them", the only
  core integration is optional nats-server HTTP monitoring, and the admin-only
  trust warning → verified (`manifest.yaml:198-203`).
- **MANUAL:2433-2437** — "All `NIF_OBSERVE_*`, `NIF_LOGFILE_*` and `NIF_LOG_LEVEL`
  variables are listed in the master Environment variables table above." and "All
  bounds are validated at startup; invalid configuration exits non-zero rather
  than silently substituting a default." → verified: all eight observe rows exist
  and every numeric knob goes through `configInt` (`main.nim:71-80`;
  `sdk/niffler/sdk.nim:268-284`).
- **MANUAL:2441-2446** (`### Verification`) names `tests/t_observe.nim` and what
  it covers → verified (`Makefile:513`).

**Explicitly absent from the MANUAL**: every per-tool flag except approval (all
twelve are `onDemand`; none declares `effect`); the retention numbers (ring 2000
/ 16 MiB, per-entry 64 KiB, per-probe 2 MiB and 2000 entries, 32 probes, capture
quota 64 MiB / 256 files); the parameters of `observe_events`, `observe_listen`,
`observe_trace` and the `pr-<id>` probe id; `observe_subjects`' output shape
(including the `session-<id>` → `svc.session.<id>.call` mapping and the 13-entry
`KnownEvents` list) and its best-effort 250 ms catalogue probe; the capture file
naming and modes; the single-instance requirement; the mixed raise-vs-`errResult`
error convention; and the missing `selftest`.

## 5. DELTA list

Rows are the findings in the audit's machine-parsed shape, grouped by the current
MANUAL section they land in. `[class]` marks the ledger class; `FIX` starts with
the verb, and the proposed wording/evidence is in the row. §1–§4 hold the
long-form reasoning.

## Observation and logs

- MANUAL: "The global ring is bounded by both message count and approximate wire bytes." | CODE: components/observe/main.nim:16-32,71-80,184-195,410-413 | FIX: add — [missing] the numbers: "the ring keeps 2 000 messages and ~16 MiB (`NIF_OBSERVE_RING`, clamped 1..10000; `NIF_OBSERVE_RING_BYTES`, 64 KiB..100 MiB), a single retained message is capped at 64 KiB (`NIF_OBSERVE_ENTRY_BYTES`, 1 KiB..1 MiB — larger ones become a base64 preview), each probe keeps at most 2 000 entries and 2 MiB (`cap`, clamped 1..2000; `NIF_OBSERVE_PROBE_BYTES`, 64 KiB..16 MiB), and at most 32 probes exist at once (`NIF_OBSERVE_MAX_PROBES`, 1..256), so the 33rd `observe_listen`/`observe_trace` fails until one is removed."
- MANUAL: "| `observe_request` | Diagnostic request/reply to a concrete `svc.*.call`; approval-gated and limited to 30 seconds |" | CODE: components/observe/main.nim:376,392-393 | FIX: update — [doc-edit] "Diagnostic request/reply to a concrete `svc.*.call`; approval-gated. The request wait is clamped to 100–30000 ms (`timeoutMs`), and the tool call itself carries `x-harness.timeoutMs: 35000`."
- MANUAL: "| `observe_events` | Query a probe or the global ring, newest first, with time/kind/component/subject/regex filters |" | CODE: components/observe/main.nim:515-534,551,574-579 | FIX: add — [missing] "`kind` is `call|result|event|error`, `component` matches `svc.<component>.*`, `ev.log.<component>` or an envelope's own `component`, `subject` is an exact concrete subject, and `limit` is clamped to 1..500."
- MANUAL: "| `observe_listen` | Start a bounded capture for a token-correct NATS pattern (`*` and terminal `>`) plus optional regex |" | CODE: components/observe/main.nim:95-115,415,419-446 | FIX: add — [missing] "`cap` defaults to 500 and is clamped to 1..2000; the returned `probeId` is `pr-<id>` (same for `observe_trace`)."
- MANUAL: "| `observe_trace` | Capture calls to one component and correlate result/error inbox replies by envelope id |" | CODE: components/observe/main.nim:206-211,243-251,447-471 | FIX: add — [missing] "it watches `svc.<component>.call` and the scoped `svc.<component>.<id>.call` form, `toolRegex` filters by tool name, `cap` defaults to 500 (max 2000), and each reply carries `elapsedMs` measured on a monotonic clock."
- MANUAL: "| `observe_subjects` | List the authoritative component/service view when core is reachable, known event patterns, and the most frequently observed concrete subjects |" | CODE: components/observe/main.nim:292-295,303-317,33-37,167-175,347-348 | FIX: add — [missing] "the service view maps a `session-<id>` component to `svc.session.<id>.call`; the known-event list is the fixed set `reg.publish`, `reg.depart`, `ev.sys.drain`, `ev.catalog.updated`, `ev.llm.token`, `ev.session.>`, the three `ev.approval.*` subjects, `svc.approval.>.request`, `ev.log.>`, `ev.models.updated` and `llm.cancel.>`; the observed-subject census keeps the top 100 concrete subjects and excludes `_INBOX.*`. The core snapshot is a best-effort 250 ms `catalog` request — when core does not answer, the list falls back to the tap-derived registrations, and the `*Truncated`/`dropped*` counters say when the view is partial."
- MANUAL: "| `observe_dump` | Approval-gated export of one probe beneath `NIF_OBSERVE_CAPTURE_DIR`; arbitrary output paths are not accepted |" | CODE: components/observe/main.nim:677-712,652-675 | FIX: add — [missing] "the file is `<captureDir>/<probeId>.jsonl` (one JSON object per captured entry), the directory is created user-only (0700, files 0600), a symlinked target is refused, and older captures are pruned to a byte quota and a 256-file cap — when even pruning cannot fit the dump the tool fails with `capture directory quota is exhausted`."
- MANUAL: "| `observe_logs` | Query recent `ev.log.*` events in memory |" | CODE: components/observe/main.nim:591-651 | FIX: add — [missing] "in-memory ring only — for persisted history use `logfile_search`; items carry `component`, `level`, `msg` plus the emitter's `at` as `emittedAt` and `ctx` when present, and `limit` is clamped to 1..500."
- MANUAL: "| `observe_send` | Publish an event to a concrete `ev.*` or `llm.cancel.*` subject; approval-gated |" | CODE: components/observe/main.nim:361-375 | FIX: none — [verified] a concrete subject is required and the published envelope is always `kind: event`, which is what makes the "cannot send call/result/error envelopes or registrations" sentence true.
- MANUAL: "`observe_send`, `observe_request`, `observe_monitor`, and the" | CODE: components/observe/main.nim:361,376,677,714 | FIX: none — [verified] those are exactly the four tools carrying `approval: "always"`.
- MANUAL: "Generated captures are pruned oldest-first to a byte quota and a 256-file cap." | CODE: components/observe/main.nim:652-675,31-32,79-80 | FIX: none — [verified] (`NIF_OBSERVE_CAPTURE_BYTES` default 67108864, clamped 64 KiB..1 GiB; `MaxCaptureFiles = 256`).
- MANUAL: "Trace requests expire from the pending correlation table after 60 seconds." | CODE: components/observe/main.nim:22,197-204 | FIX: none — [verified]
- MANUAL: "Probe subjects, labels, and regular expressions have fixed input limits;" | CODE: components/observe/main.nim:25-29,186-188,23-24,584-590,398-408 | FIX: none — [verified] 512/256/1024-byte input limits, the `dropped` counter, the 60 000-byte response budget with `truncated` and the `valueTruncated`/`valueBytes` metadata for a large diagnostic reply.
- MANUAL: "`observe` has one raw `>` subscription. It preserves the original JSON node," | CODE: components/observe/main.nim:142-157,278-290 | FIX: none — [verified]
- MANUAL: "`observe_monitor` reads `/subsz` and `/connz` with a fresh HTTP client for each" | CODE: components/observe/main.nim:714-769 | FIX: none — [verified] plus: `/subsz` is queried with `limit=1024`, each request has a 3 s client timeout, and a missing endpoint is a plain error asking for `NIF_OBSERVE_MONITOR_URL`.
- MANUAL: "All bounds are validated at startup; invalid configuration exits non-zero" | CODE: components/observe/main.nim:71-80; sdk/niffler/sdk.nim:268-284 | FIX: none — [verified] every numeric `NIF_OBSERVE_*` goes through `configInt`, which raises `ValueError` outside its range.
- MANUAL: "All `NIF_OBSERVE_*`, `NIF_LOGFILE_*` and `NIF_LOG_LEVEL` variables are" | CODE: docs/MANUAL.md env table (8 observe rows); components/observe/main.nim:71-85,719 | FIX: none — [verified] all eight are listed with the right defaults.
- MANUAL: absent | CODE: manifest.yaml:198-203; components/observe/main.nim:87-93 | FIX: add — [missing] one sentence to the Boundary paragraph, right after `Observation is an administrative capability. A bus capture can contain tool`: "do not replicate observe — the ring, the probes and the component census are process-local, so replicas would split one view into several and multiply exactly that surface; the manifest leaves replicas unset for this reason."
- MANUAL: absent | CODE: components/observe/main.nim:387-393,429-436,443,468,531,557; sdk/niffler/sdk.nim:723-727 | FIX: none — [delta] note only: the component uses two error conventions — argument checks that *raise* (subject/tool/timeout/cap, which the SDK turns into an error envelope with the message intact) and errResult returns (bad regex, unknown probe) — and the MANUAL's own `known event patterns` table is where a reader would look for the difference. Worth a clause only if the tool table gains a parameters column; both paths reach the model with the right text.

## Environment variables

- MANUAL: "| `NIF_OBSERVE_RING` | messages retained in observe's global ring | `2000` |" | CODE: components/observe/main.nim:71 | FIX: update — [missing] append "; clamped 1..10000, outside it the component exits non-zero".
- MANUAL: "| `NIF_OBSERVE_RING_BYTES` | approximate wire bytes retained in the global ring | `16777216` |" | CODE: components/observe/main.nim:72-73 | FIX: update — [missing] append "; clamped 65536..104857600".
- MANUAL: "| `NIF_OBSERVE_ENTRY_BYTES` | maximum retained bytes per observed message | `65536` |" | CODE: components/observe/main.nim:74-75,143-147 | FIX: update — [missing] append "; clamped 1024..1048576, and a larger message is kept as a base64 preview of three quarters of the cap".
- MANUAL: "| `NIF_OBSERVE_MAX_PROBES` | active + stopped probes retained at once | `32` |" | CODE: components/observe/main.nim:78,410-413 | FIX: update — [missing] append "; clamped 1..256, and the next `observe_listen`/`observe_trace` fails with 'probe limit reached'".
- MANUAL: "| `NIF_OBSERVE_PROBE_BYTES` | retained bytes per probe | `2097152` |" | CODE: components/observe/main.nim:76-77,184-195 | FIX: update — [missing] append "; clamped 65536..16777216, entries are evicted oldest-first and a single entry above the cap is counted in `dropped`".
- MANUAL: "| `NIF_OBSERVE_CAPTURE_DIR` | confined directory for `observe_dump` | `$NIF_ROOT/var/captures` |" | CODE: components/observe/main.nim:81-85 | FIX: none — [verified] empty → `$NIF_ROOT/var/captures`, absolute → as-is, relative → resolved against the harness root.
- MANUAL: "| `NIF_OBSERVE_CAPTURE_BYTES` | aggregate generated-capture quota; oldest files are pruned | `67108864` |" | CODE: components/observe/main.nim:79-80,667-675 | FIX: update — [missing] append "; clamped 65536..1073741824, and when even pruning cannot fit a dump the tool fails with 'capture directory quota is exhausted'".
- MANUAL: "| `NIF_OBSERVE_MONITOR_URL` | explicit nats-server HTTP endpoint for an external/reused bus | core discovery file |" | CODE: components/observe/main.nim:719-725 | FIX: none — [verified] empty falls back to `<NIF_ROOT>/var/nats-monitor-url`, then to a clear error.

## Layout of a running system

- MANUAL: "| `observe` | Nim | optional | bounded live bus ring, listen/trace probes, safe capture export, and NATS monitoring (see [Observation and logs](#observation-and-logs)) |" | CODE: components/observe/main.nim:297-769; manifest.yaml:198-203 | FIX: update — [doc-edit] append "— all twelve tools are on demand, and none declares `x-harness.effect`, so the fabric batch host schedules even `observe_events`/`observe_logs` as writes". The rest is verified: twelve tools, `autostart: true`, `required: false`, `restart: on-failure`, and no `replicas` (impossible here: ring and probes are process-local).

## Progressive tool discovery

- MANUAL: "- Search and inspection: `files` (sorted listing), the git" | CODE: components/observe/main.nim:297,361,376,419,447,472,494,506,515,591,677,714 (all `onDemand`) | FIX: none — [verified] every `observe_*` tool is on demand, so the generic "the observe/logfile diagnostics" phrasing is right; naming them individually (or linking the tool table) is the optional improvement.

## Testing

- MANUAL: "`tests/t_observe.nim` covers exact-once taps, wildcard boundaries, registration" | CODE: tests/t_observe.nim:1-485; Makefile:513 | FIX: none — [verified] the test is named and its coverage list matches the file's scope.
- MANUAL: "`/doctor deep` additionally fans out to each component's own self test over" | CODE: `grep -c selftest components/observe/main.nim` → 0 | FIX: add — [delta] one clause in the same Verification paragraph: "`observe` registers no `selftest`, so `/doctor deep` lists it as not implementing one" — or register one; `t_observe` already covers the contract.

Finding count for this component: 31 rows — 19 in `## Observation and logs`,
8 env, 1 shipped row, 1 on-demand inventory, 2 testing. Classes: 14 `missing`
(retention numbers, tool parameters, `observe_subjects`' output shape, the
single-instance rule), 2 `doc-edit` (the 30 s/35 s pair and the shipped-row
flags), 2 `delta`, 13 `verified` — the subsection's prose and the twelve-row tool
table are right throughout; only their precision is thin.

## 6. Not user-facing

- `Probe`/`Captured` internals (`main.nim:39-68`), `removePending` (`:177-182`),
  the `addResponseItem` budget helper (`:119-125`), and the `initOrderedTable`
  choice for probes (`:89`).
- The exact `$message`-length accounting that makes "approximate wire bytes"
  approximate (`main.nim:160`) — the MANUAL's word "approximate" is the right
  level of detail.
- `prepareCapture`'s prune loop arithmetic (`main.nim:666-675`) beyond its two
  visible consequences (quota failure, 256-file cap).
- The `pairs.sort` comparator and the top-30 `mostSubscribed` slice
  (`main.nim:747-756`) — only the "density, not throughput" caveat matters.
- The `_INBOX.` exclusion from the census (`main.nim:167-175`) is worth at most a
  parenthetical inside the `observe_subjects` row (already proposed in §5).
