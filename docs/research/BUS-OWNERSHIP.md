# Bus ownership — one root, one bus, one set of component queue groups

Status: implemented (2026-11-10). Guards live in `core/catalog.nim`,
`core/niffler.nim` and the three SDKs' connect paths.

## The failure

Several `niffler-tui` windows at once reported, in this order:

1. a conversation's pinned provider "cannot be resolved" —
   `unknown provider "synthetic" (environment providers: default)` in
   `var/logs/llm.log`, with the *same* message naming `deepseek`,
   `openai-codex` and `synthetic` as this harness's stored providers;
2. `/fav` listing nothing, though `kind: modelfavorite` held all five entries;
3. turns failing with `not-found` when a session read its own transcript.

It read as data loss and it was not: every provider row was present at its
expected rev under the correct `instance-id`, and the favorites document was
intact. The database was never damaged.

## Why it looked like data loss

Tool dispatch is a NATS **queue group whose group name is the component name**
(`svc.store.call`, queue `store`). Every process that subscribes with that
group joins the same load balancer — so *any* second `store` on the bus, from
*any* root, answers a slice of the calls. If that second store belongs to
another root it serves another database, usually empty. The harness then sees,
intermittently and only for some calls:

| symptom | mechanism |
|---|---|
| `provider_get` → definitive `not-found` | the foreign store answered that read |
| the error still lists `deepseek, openai-codex, synthetic` | `provider_list` was answered by the *live* provider component |
| `/fav` empty | `modelfavorite` read hit the foreign store |
| session `not-found` | conversation/message read hit the foreign store |
| `provider=default model=gpt-6.1-terra` | the pinned nickname resolved not-found, so `llm` fell back to the environment default |

Two observables pin it, both in `var/logs/core.log`:

- `catalog: store replica registered (2 live) … (3 live) … (4 live)` — one core
  spawns exactly **one** store.
- the self-contradicting error line, where the note naming the stored providers
  came from a different call than the refusal beside it.

## How a foreign process reached this bus

Two independent mistakes, either sufficient:

1. **The SDK guessed a bus.** A component's resolution chain ended in a
   hardcoded `nats://127.0.0.1:4222`. That default is right for a *client*
   looking for its harness (`ensureHarness` probes and then checks the answering
   core's root); it is wrong for a *component*, which subscribes by queue group.
   Any root whose `var/nats-url` was missing therefore landed on whatever
   harness owned 4222.
2. **The catalog trusted any publisher.** `reg.publish` was accepted from any
   process on the bus, so the foreign replica was not even distinguishable in
   the catalog: its pid simply joined the existing component's `pids`.

The tests made this reachable rather than hypothetical: `make test-*` passes
`NIF_ROOT=$(ROOT)` (the repo, used for `NIF_REPO_ROOT`) and a test that starts a
component without a URL fell through the chain to 4222. `tests/helpers.nim`'s
`drain()` publishes the **bus-wide** `ev.sys.drain`, which is why an incident
also shows one core's components all departing at once and the surviving
supervisor restarting them into
`another store is already serving the database (/…/var/store.db.lock)`.

## The guards

**1. A component must not guess its bus** (`sdk/niffler/sdk.nim` `run()`,
`sdk/go/component.go` `dial()`, `sdk/ts/src/component.ts` `connect()`).
Resolution is `NIF_NATS_URL` → the root's `var/nats-url`; when both are absent
the component fails with an explicit error instead of inventing an address. The
well-known port stays available to *clients* (`ensureHarness`,
`resolveNatsUrl`, `reattachCandidates` — the last applies the identity rule, so
it only adopts 4222 when a core serving *our* root answers).

**2. A registration must serve this root** (`core/catalog.nim`).
Every SDK now announces `"root"` in `reg.publish`. The system core sets
`cat.ownsRoot`; a non-client registration whose announced root is not this
core's is refused with a line naming the offending root, and the refusal is
recorded (`lastRejection`) so `core.spawn` reports the real cause instead of a
timeout.

Two deliberate exemptions:

- **Interactive clients** answer no tool subject, so they cannot misroute a
  call; a UI also attaches from another terminal and outlives core restarts.
  They stay exempt and are swept by pid liveness instead.
- **A registration without a root** is accepted but announced once
  (`registered without a root — cannot verify it serves this harness`). Older
  SDKs and hand-rolled publishers predate the field and a harness must not break
  them on upgrade; the point is that an unvouchable publisher must be *visible*,
  because a silent accept is exactly how this bug hid.

Root identity rather than pid ownership is load-bearing: a stub `llm` or
`ctxtest` that `tests/t_core.nim` starts from the **same** root is a legitimate
stand-in and must keep registering, while a process from another root is by
definition reading another database. Keying on the supervisor's children broke
those tests — the first implementation did, and the core gate caught it.

**3. A departure only retires a recorded pid** (`core/catalog.nim`).
A `reg.depart` for a pid the registry never held is ignored, so no bus citizen
can erase a component it does not own.

**3. A component refuses to serve another root's bus** (`enforceBusRoot` in all
three SDKs). Registering is not the danger — *subscribing* is: a component joins
`svc.<name>.call` with queue group == its name, so connecting already takes a
share of that bus's calls. Before subscribing, the component asks the bus's core
for its root (`coreRoot`/`CoreRoot`, the handshake clients already used) and
refuses when the answer names a different root.

Only **positive proof** refuses. No core answering at the moment — boot, a bare
`nats-server`, a unit-test bus — is accepted, because a false refusal would be
worse than the leak. There is deliberately no escape hatch: core always exports
`NIF_NATS_URL` to its own children, so a legitimate child never needs one.

Measured on a live harness, with a foreign-root store merely *running* and
connected:

| | `/fav` reads empty | `provider_get` fails |
|---|---|---|
| before the guard | 20 / 40 | ~20 / 40 |
| after the guard | **0 / 40** | **0 / 40** |

The foreign process now exits on connect with
`refusing bus nats://127.0.0.1:4222: the core there serves <our root>, not this
root (<its root>)`.

## Residual notes

The catalog root check (guard 2) and the connect check (guard 3) overlap on
purpose: the connect check is what protects the queue group, and the catalog
check is what keeps a *registration* honest — including for a component built
against an older SDK, which announces no root at all. Neither can help a process
that connects while no core answers yet and is answered by a foreign core later;
the registration check then refuses it and the `registered without a root` /
`serves root …` lines name the cause.

## Verifying

`tests/t_catalog.nim` pins the admission rules: a foreign root is refused (and
the refusal names it), a same-root component is accepted, an external client is
exempt, a root-less registration still registers, and a foreign departure cannot
retire an owned component.

Live triage when the symptom recurs: `scripts/provider-triage.sh` (read-only)
separates "the DB lost rows" from "the store is not answering" and prints the
store's boot line and residency. `var/witness/watch.sh` samples a store read and
`provider_get` every few seconds and records, on failure, which root the
answering store serves (`readlink /proc/<pid>/cwd`), the flock holders and the
component log tails.
