# NATSNIM — the pure-Nim NATS client, and how to build Niffler on it

Status: **P7 in progress** (branch `feat/natsnim-client`). The client itself is
[a separate repository](https://github.com/gokr/natsnim) — a pure-Nim
translation of `nats-io/nats.go`, not a binding to `nats.c`. This document is
the Niffler side: how the switch works, what it has found, and what is left.
Design rationale and the phase plan live in that repo's
[ASSESSMENT.md](https://github.com/gokr/natsnim/blob/main/ASSESSMENT.md) and
[PROVENANCE.md](https://github.com/gokr/natsnim/blob/main/PROVENANCE.md).

## Why

Nim's only NATS clients are FFI bindings to `nats.c`
(`gokr/natswrapper`, `deem0n/nim-nats`), which make `libnats`, OpenSSL,
libsodium and protobuf-c host prerequisites — `make doctor` checks
`pkg-config --exists libnats`, and `make install-native-deps` installs it.
The pure-Nim client removes that dependency without changing the architecture:
same wire protocol, same subjects, same bus.

## How the flag works

Every Nim file that spoke to the bus had a single `import natswrapper` line.
That line became:

```nim
when defined(nifflerNimNats):
  import natsnim as natswrapper     # pure-Nim client, aliased to the old name
else:
  import natswrapper
```

The alias is the whole trick: **every call site stays byte-identical**, so the
switch is a build flag rather than a refactor, and the two implementations can
be compared from the same source. No SDK change, no behavioural fork.

Build and test with the client:

```bash
make clean
make build       NIMFLAGS="-d:nifflerNimNats --path:$HOME/git/natsnim/src"
make test-server NIMFLAGS="-d:nifflerNimNats --path:$HOME/git/natsnim/src"
```

`NIMFLAGS` is threaded through every `nim c` invocation the Makefile owns
(components, core, session runner and the test binaries), so a single flag
switches the whole harness. `--path` points at a local checkout; once the
client is published to nimble the flag alone will do.

Notes:

- The *test-only* stub components that tests compile themselves with a raw
  `nim c` (e.g. `ctxtest` in `t_agent`, `t_fabric_cancel`) do **not** get
  `NIMFLAGS`. They keep using `natswrapper`, which is why mixed-client
  interop gets exercised for free in those tests.
- Make does not track changes to `NIMFLAGS` or the external client sources.
  Clean and rebuild after changing either; rollback likewise requires a clean
  rebuild without the flag. Use an isolated worktree: `make clean` removes
  its runtime state and UI build dependencies too.

## What the shim must provide

The exact subset of `natswrapper` that Niffler's sources use — extracted
mechanically, not guessed: `nats_Open`, `connect`, `publish`,
`natsConnection_{SubscribeSync,QueueSubscribeSync,Publish,PublishString,
PublishRequest,Request,Flush,FlushTimeout,GetMaxPayload,Destroy}`,
`natsSubscription_{NextMsg,Unsubscribe,Destroy}`,
`natsMsg_{GetData,GetDataLength,GetSubject,GetReply,Destroy}`,
`checkStatus`, `NATS_OK`, `NATS_TIMEOUT`, `NATS_NO_RESPONDERS`.

Deliberate deviations from `nats.c`, each documented in the client repo:

| deviation | why |
|---|---|
| `natsSubscription_Destroy` returns void (nats.c returns a status) | matches `natswrapper`, and Niffler uses it in `defer:`; detaching cannot fail |
| `natsConnection_Flush` is bounded by `defaultFlushTimeoutMs` | nats.c blocks on the connection default; this client never waits unbounded (no thread to interrupt it) |
| handles are raw allocations with explicit Destroy/free semantics | ownership was rewritten in the client's hardening pass; leaks are pinned by regression tests |
| one server URL, no TLS/nkeys/JetStream | scoped out; Niffler's bus is a loopback, plaintext, no-credentials bus by design |

## What P7 found

Two real bugs in the client, neither of which its own test suite caught —
which is the argument for doing this rather than trusting unit coverage:

1. **A 1 ms `NextMsg` never read the socket.** The remaining budget was
   computed with `inMilliseconds`, which truncates a 1 ms timeout to 0, and
   the function returned early "out of budget" *before* reading. So it always
   reported `NATS_TIMEOUT` without touching the socket. The library's tests
   used 100–2000 ms (where the truncated budget is > 0) and passed; Niffler's
   **component registry polls at 1 ms**, so core subscribed to `reg.>`, the
   server delivered registrations (visible in a `-DV` protocol trace), and core
   never saw them — boot stalled with "not all required components
   registered" while the components logged "online".
2. **No-responders was not implemented.** The client advertised
   `no_responders: false` and did not understand the server's 503 status
   message, so a request to a subject nobody serves waited out its timeout
   instead of failing immediately (nats.c and nats.go both set it `true`).
   Niffler depends on that: the agent component probes
   `svc.systemprompt.call`, which is absent in `t_agent`'s sandbox. The 5 s
   timeout that cost pushed the agent's child-session turn past the child
   runner's 2 s idle window; the runner retired; the turn then went to a
   subject with no subscriber and cost the agent's own timeout — the test's
   120 s budget expired, so a missing fail-fast path surfaced as "parent turn
   timed out".

Both are fixed in the client repo, with regression tests (a 1 ms call must
return an available message; a request with no responders must raise
`NoRespondersError` in well under the timeout and leave the connection
usable).

P7 also exposed two test-ordering bugs, both fixed by making the observation
precede the spawn or the assertion order-insensitive:

- `t_console` spawned the console before subscribing to its one-shot
  registration. A server protocol trace showed the announcement preceding the
  subscriptions used by the assertion. The test now subscribes and flushes
  before spawning, then waits on that same subscription, and probes viewer
  readiness before sending the rendering fixtures.
- `t_nested` used the same post-spawn `waitRegistered` for its test
  components; it now installs the `reg.publish` observer before spawning.
- `t_observe` asserted a total probe count that silently depended on the
  client's queue-drain order: with the pump draining the call subscription
  before the `>` tap, the creating `observe_listen` call's own tap copy can
  be captured after the probe exists (deterministic with this client,
  order-dependent by construction). The probe only ever sees the tap, so the
  real invariant — the send call is captured exactly once, never a call-sub
  copy plus a tap copy — is now asserted by filtering captured items on the
  tool name. The fixed test passes with both clients.

The full flagged server suite (36 Nim suites plus the Go tests) passes with
the flag from a clean rebuild, revalidated against the client's hardened
transport (natsnim main, including write-through publishes, in-place parser
scanning and the opt-in batch API). The flagged core and console binaries
show no `libnats` dependency in `ldd`. A green suite does not establish
complete compatibility — the differential validation (P6) remains the rigor
step.

## Remaining work (P7 and follow-up)

1. ~~**Green suite on the flag.**~~ Done: `make test-server` with
   `-d:nifflerNimNats` is green from a clean rebuild. (`make test-ui` does
   not touch the bus — the SPA goes through the Go bridge — but it is part
   of `make test`.)
2. **After validation and ownership audit, consider flipping the default**:
   depend on `natsnim` in `niffler.nimble`, drop
   `natswrapper` from `niffler.nimble` and from `config.nims`'s pkgs2 scan,
   drop `libnats` from `make setup`/`make doctor`, and collapse the `when`
   back to a plain import.
3. **Differential validation (P6)**, the rigor step: run the same operation
   trace through both clients against the same server and compare. Cheaper
   now that both are wired.
4. **Living with it**: the client's concurrency contract is one connection per
   thread (no threads in the Nim half today), and reconnect is lazy — driven
   by `nextMsg`/`flush`/`request` — rather than by a background thread. Both
   are documented in the client's README.
