# B1b investigation — worker threads vs. component replicas

> Design record for same-component concurrency after B1a runner fan-out.
> Companion documents: [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) and
> [PI_EFFICIENCY_FINDINGS.md](PI_EFFICIENCY_FINDINGS.md).
>
> Status: worker-thread design **rejected**; process replicas shipped instead.

## Problem

B1a can publish several `x-harness.parallel` calls concurrently, but one
component process still handles them serially: its SDK pump invokes one handler
at a time. Two slow calls to one logical component therefore need either
in-process workers or multiple queue-group subscribers.

## Nim mechanism evaluation (2.2.10, ORC)

| Mechanism | Finding |
|---|---|
| `std/threadpool` | Mature, but its task model deep-copies arguments and introduces a shared-heap/`{.gcsafe.}` boundary around long-lived component state. It is also a poor lifecycle fit for a server-owned fixed queue. |
| `std/tasks` | Lower-level ownership primitive (`toTask`/`invoke`) rather than an ergonomic server pool in 2.2.10; using it means writing the scheduler too. |
| `taskpools` 0.2.1 | Good for isolated map/reduce jobs, but `spawn` isolates non-literal arguments. Passing Niffler's shared `Component` ref fails with `expression cannot be isolated: comp`; avoiding that requires a global pointer registry or serializing every job around the API. |
| `std/threads` + `std/locks` | Technically the cleanest in-process fit: fixed workers, mutex/condition queue, and clean joins. It still requires `{.gcsafe.}` handlers and shared component/NATS state. |

A prototype of the last option confirmed the compiler boundary and exposed two
otherwise-serial globals (`envelope.newId`'s counter and `procutil.runCmd`'s
temporary-file counter). It was not retained.

## Why worker threads were rejected

`AGENTS.md` makes the SDK contract explicit: the Nim SDK has no callbacks and
no threads; handlers run serialized on the polling thread, with normal GC, and
the `{.gcsafe.}` dance must not be introduced. This is not merely a default:
it is one of the architecture invariants that keeps the SDK small and portable.
An opt-in `run(workers=N)` mode would still put thread ownership, payload
aliasing, shutdown coordination, and two handler types into the shared SDK.
That conflicts with the project contract.

## Shipped alternative: process replicas

NATS already supplies the right process-native primitive. Every component
subscribes to `svc.<name>.call` in queue group `<name>`; N identical processes
therefore distribute concurrent requests one per process while each process
retains the simple serial SDK pump.

Replica support adds:

- `replicas: N` (1–16, default 1) in `manifest.yaml`;
- optional `replicas` on `core.spawn`, persisted across harness restarts;
- supervisor groups with distinct process instances/logs and group-wide
  `core.kill`/`core.remove`;
- replica-aware catalog presence (`pids`) so one departure does not remove the
  logical component while peers remain;
- `replicas`, `runningReplicas`, and `pids` in `core.status`;
- four shipped `grep` replicas, because `grep`/`files` are stateless.

`tests/t_parallel.nim` proves two one-second calls to one logical tool complete
in about one second through two replicas, while transcript results remain in
the model's original call order. It also verifies group-wide kill.

## Limits and follow-ups

Replicas are appropriate only for stateless or externally coordinated
components. `grep`, `fetch`, and `bash` fit; `store` is single-writer. The
current `edit` component mixes read-only tools with mutation and a per-process
undo store, so replicating it would be incorrect. Parallel `read` calls require
either splitting reads into a stateless component or making edit state
externally coordinated—not weakening the SDK invariant.
