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
make build      NIMFLAGS='-d:nifflerNimNats --path:$HOME/git/natsnim/src'
make test-server NIMFLAGS='-d:nifflerNimNats --path:$HOME/git/natsnim/src'
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
- Rollback is unsetting the flag; nothing else changes.

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
| handles are GC-managed, so `*Destroy` detaches rather than frees | Nim owns the memory; callers just drop the pointer, as they would after a C destroy |
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

## Remaining work (finishing P7)

1. **Green suite on the flag.** `make test-server` with `-d:nifflerNimNats`,
   then the same for `make test-ui` if it touches the bus (it does not — the
   SPA goes through the Go bridge — but the target is part of `make test`).
2. **Flip the default**: depend on `natsnim` in `niffler.nimble`, drop
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
