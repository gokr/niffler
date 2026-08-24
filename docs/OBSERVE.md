# Bus observation and structured logs

Status: **implemented** by the `observe` and `logfile` components.

## Boundary

Observe the bus, not component internals. Both components are ordinary NATS
citizens built on the SDK; core never imports them. The only core integration is
optional nats-server HTTP monitoring: when core owns the bus it allocates a
second loopback port and writes `var/nats-monitor-url` after the server is live.

Observation is an administrative capability. A bus capture can contain tool
arguments, model output, approvals, and data from every session. Niffler's
current trust model is a single trusted user/admin; do not expose the observe
service or capture directories to untrusted bus clients.

## `observe`: bounded live inspection

`observe` has one raw `>` subscription. It preserves the original JSON node,
including unknown envelope fields and bare registration payloads. Malformed JSON
is retained as `{raw, decodeError}` when it is valid UTF-8; arbitrary bytes use
lossless `rawBase64` instead. Oversized messages are represented by a bounded
base64 preview rather than letting one message consume the process.

The global ring is bounded by both message count and approximate wire bytes.
Each targeted probe has independent count and byte bounds; the number of probes
is also capped. Stopped probes remain queryable until `observe_remove` releases
their memory.

| Tool | Use |
|---|---|
| `observe_subjects` | List the authoritative component/service view when core is reachable, known event patterns, and the most frequently observed concrete subjects |
| `observe_listen` | Start a bounded capture for a token-correct NATS pattern (`*` and terminal `>`) plus optional regex |
| `observe_trace` | Capture calls to one component and correlate result/error inbox replies by envelope id |
| `observe_probes` | Inspect probe state, retained bytes, caps, and pending traces |
| `observe_stop` | Freeze a probe while retaining its entries |
| `observe_remove` | Delete a probe and release its memory |
| `observe_events` | Query a probe or the global ring, newest first, with time/kind/component/subject/regex filters |
| `observe_logs` | Query recent `ev.log.*` events in memory |
| `observe_dump` | Approval-gated export of one probe beneath `NIF_OBSERVE_CAPTURE_DIR`; arbitrary output paths are not accepted |
| `observe_monitor` | Read nats-server connection/subscription counts and most-subscribed patterns |
| `observe_send` | Publish an event to a concrete `ev.*` or `llm.cancel.*` subject; approval-gated |
| `observe_request` | Diagnostic request/reply to a concrete `svc.*.call`; approval-gated and limited to 30 seconds |

`observe_send` cannot send call/result/error envelopes or registrations.
`observe_send`, `observe_request`, and the filesystem-mutating `observe_dump`
carry `x-harness.approval: always`, so an LLM path must pass core's human gate.
A client talking directly to `svc.observe.call` is already a trusted bus peer
and bypasses core policy, just as it can call any other service subject directly.
Generated captures are pruned oldest-first to a byte quota and a 256-file cap.

Trace requests expire from the pending correlation table after 60 seconds.
Probe subjects, labels, and regular expressions have fixed input limits;
oversized probe entries are dropped and counted rather than retained outside the
byte budget. Tool responses stop before the wire's approximately 64 KiB
inline-result convention and report `truncated` (or value byte metadata for a
large diagnostic reply) rather than returning unbounded data.

## `logfile`: rotating JSONL persistence

`logfile` is best-effort process-local persistence, not an audit log. Core NATS
is at-most-once: records emitted before startup or during a restart are lost.
Guaranteed replay would require an explicit JetStream design.

Default input is `ev.log.>`. A valid component name gets one file:

```text
var/logs/bash.jsonl
var/logs/bash.jsonl.1
...
```

`NIF_LOGFILE_SUBJECTS` can select other subjects. Non-log traffic, including
whole-bus `>`, goes to a single `bus.jsonl`; dynamic inbox subjects therefore do
not create unbounded file descriptors or filenames. The number of component log
files is capped, and excess/spoofed component subjects also fall back to
`bus.jsonl`.

Every line records sink time and original wire data:

```json
{"receivedAt": 1780000000.25, "subject": "ev.log.bash", "message": {"v": 1, "id": "...", "kind": "event", "payload": {"level": "info", "msg": "..."}}}
```

Malformed UTF-8 input uses lossless `rawBase64`; textual malformed input uses
`raw` and `decodeError`. The sink opens, appends, flushes, and closes each record.
Rotation compares `current size + record size` before
renaming closed files, so exact-boundary writes cannot leave a stale file handle.
A single record larger than the configured file size is retained as the active
file and rotated before the next record. `NIF_LOGFILE_KEEP=0` retains no rotated
generation.

`logfile_search` reads only a bounded tail from the retained files, sorts
matching records by `receivedAt` newest-first, and reports `truncated`,
`scannedBytes`, malformed line counts, and read errors. Results also have an
encoded response-byte budget. Structured log records expose `component`,
`level`, `msg`, `ctx`, and optional emitter time; raw bus records expose the
preserved message. Search never trusts an emitter-supplied timestamp for
`since`/`until` windows.
Directory enumeration is capped by `NIF_LOGFILE_DIRECTORY_ENTRIES` and reports
`directoryTruncated` when more files exist; searches still inspect the bounded
subset.

`logfile_paths` reports a bounded retained-file list plus `writeErrors`,
`lastError`, and `lastErrorAt`. Filesystem failures also go to stderr. Capture
directories are user-only where the platform permits; active symlink targets
are rejected.

## SDK APIs

All three SDKs expose the same two additions:

```nim
type TapHandler* = proc(c: Component, subject: string, data: string)
proc tap*(c: Component, pattern: string, handler: TapHandler): Component
proc log*(c: Component, level, msg: string, ctx: JsonNode = nil)
```

```go
func (c *Component) Tap(pattern string, h TapHandler) *Component
func (c *Component) Log(level, msg string, ctx any) error
```

```ts
comp.tap(pattern, handler)
comp.log(level, msg, ctx?)
```

Each SDK lets NATS perform subject matching and dispatches only the handler bound
to the subscription that delivered the message. This avoids the previous
cross-product where one call could be delivered through the call, event, and tap
paths multiple times. Nim remains callback-free and thread-free; Go uses its
existing mutex and TypeScript its promise chain.
Go waits for drained subscription callbacks (up to its bounded shutdown grace),
and TypeScript waits for queued handlers without deadlocking a handler that
explicitly closes its own component.

Structured logs publish an event on the exact subject `ev.log.<component>` with
`{component, level, msg, ctx?, at}`. Levels are `debug`, `info`, `warn`, and
`error`. `NIF_LOG_LEVEL` defaults to `info` and suppresses lower levels before
publication in every SDK. Invalid emitted levels fail; an invalid threshold
falls back to `info`.

## Monitoring

When core spawns nats-server it uses distinct loopback client and HTTP ports,
then writes:

```text
var/nats-url
var/nats-monitor-url
```

The monitor discovery file is written only after the client connection succeeds.
A reused or remote bus has no discoverable HTTP endpoint; configure
`NIF_OBSERVE_MONITOR_URL` explicitly. `NIF_NATS_SPAWN=1` forces an isolated
core-owned bus (primarily useful for tests and diagnostics).

`observe_monitor` reads `/subsz` and `/connz` with a fresh HTTP client for each
request. It reports whether subscription detail was truncated; `mostSubscribed`
means subscriber density, not message throughput.

## Environment

| Variable | Default | Meaning |
|---|---:|---|
| `NIF_OBSERVE_RING` | `2000` | global ring message count |
| `NIF_OBSERVE_RING_BYTES` | `16777216` | approximate global ring wire bytes |
| `NIF_OBSERVE_ENTRY_BYTES` | `65536` | max retained bytes per observed wire message |
| `NIF_OBSERVE_MAX_PROBES` | `32` | simultaneous stopped + active probes |
| `NIF_OBSERVE_PROBE_BYTES` | `2097152` | retained bytes per probe |
| `NIF_OBSERVE_CAPTURE_DIR` | `$NIF_ROOT/var/captures` | confined probe exports |
| `NIF_OBSERVE_CAPTURE_BYTES` | `67108864` | aggregate generated-capture quota; oldest files are pruned |
| `NIF_OBSERVE_MONITOR_URL` | core discovery file | nats-server HTTP base URL |
| `NIF_LOGFILE_DIR` | `$NIF_ROOT/var/logs` | JSONL output directory |
| `NIF_LOGFILE_SUBJECTS` | `ev.log.>` | comma-separated NATS patterns; `>` captures the bus |
| `NIF_LOGFILE_MAX_BYTES` | `10485760` | active bytes per file before rotation |
| `NIF_LOGFILE_KEEP` | `5` | retained rotated generations; `0` disables |
| `NIF_LOGFILE_MAX_FILES` | `64` | component-specific active files before fallback to `bus.jsonl` |
| `NIF_LOGFILE_SCAN_BYTES` | `16777216` | maximum bytes examined by one search |
| `NIF_LOGFILE_DIRECTORY_ENTRIES` | `10000` | maximum candidate JSONL paths enumerated per query |
| `NIF_LOG_LEVEL` | `info` | SDK publication threshold |
| `NIF_NATS_SPAWN` | unset | `1` forces core to spawn an isolated bus instead of reusing 4222 |

All bounds are validated at startup; invalid configuration exits non-zero rather
than silently substituting a default.

## Verification

`tests/t_observe.nim` covers exact-once taps, wildcard boundaries, registration
capture, cap/byte eviction, trace correlation, timeout behavior, embedded-NUL
and invalid-UTF-8 raw data, response bounds, approval metadata, quota-pruned safe
dumps, monitor discovery, and invalid configuration.

`tests/t_logfile.nim` covers SDK log filtering, newest-first queries, time/regex
filters, encoded response and actual disk-read bounds, closed-file rotation,
zero retention, embedded-NUL whole-bus preservation, bounded path listings,
sink health, and invalid configuration. Both tests use isolated temporary output
directories and are part of `make test`.
