# B1b investigation — component concurrency and the SDK pump

> Design record for same-component concurrency after B1a runner fan-out.
> Companion documents: [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) and
> [PI_EFFICIENCY_FINDINGS.md](PI_EFFICIENCY_FINDINGS.md).
>
> Status: process replicas and concurrent-safe Go tools shipped; a generic Nim
> worker-aware pump is deferred. Component-owned Nim threads are allowed.

## Where calls serialize

B1a publishes several `x-harness.parallel` calls concurrently and polls their
reply inboxes round-robin. Reply collection in the session runner is cheap and
already concurrent. The remaining bottleneck is the callee: one component
process's default SDK pump invokes a handler synchronously, so its next queued
call waits for that handler to return.

Starting a task from inside that handler does not fix call-level concurrency if
the handler immediately waits for it. The receiving pump must either hand the
call off and return, use a custom service loop, or have multiple queue-group
subscriber processes.

## Nim mechanism evaluation (2.2.10, ORC)

| Mechanism | Finding |
|---|---|
| `std/threadpool` | Mature but legacy and less explicit about the lifecycle of a long-running server pool. Its task argument handling is awkward around a shared component context. |
| `std/tasks` | Lower-level ownership primitive (`toTask`/`invoke`) rather than an ergonomic server pool in 2.2.10; using it means writing the scheduler too. |
| `taskpools` 0.2.1 | Excellent for isolated map/reduce-style input/output jobs. Its `spawn` isolation correctly rejects an aliased shared `Component` ref (`expression cannot be isolated: comp`), so it is not the general shared-context answer. |
| **`std/threads` + `std/locks`** | Preferred general model for a long-lived Nim component that needs shared-state concurrency: fixed worker lifecycle, explicit mutex/condition queues, and clean joins. |

Project guidance is therefore:

- never use `asyncdispatch`;
- keep ordinary `Component.run()` serial and threadless;
- use `std/threads` + `std/locks` for explicit component-owned workers sharing
  process state;
- use `taskpools` when jobs and results can be genuinely isolated;
- synchronize mutable component state deliberately and keep the concurrency
  opt-in rather than making every SDK handler `{.gcsafe.}`.

## Why the generic Nim pump is deferred

A useful generic pump is more than `spawn handler(args)`. It must define:

1. payload ownership (`JsonNode` should not be aliased casually across threads;
   encoded JSON or isolated copies are safer queue payloads);
2. a gcsafe handler boundary only for opted-in tools;
3. bounded admission/backpressure;
4. serial-tool barriers so mutations/events cannot overlap parallel reads;
5. reply publication, timeout/cancellation, and shutdown/join ordering;
6. what worker handlers may do with shared `Component`/NATS state.

The clean eventual shape keeps subscription polling on the main thread, queues
parallel-safe jobs behind `Lock`/`Cond`, and drains encoded completions back on
the main thread. Ordinary handlers remain exclusive. This is needed for a
mixed stateful component such as `edit`; it is not needed to make the session
runner consume replies faster.

## Immediate process-native path

NATS already supplies concurrency for stateless components. Every process
subscribes to `svc.<name>.call` in queue group `<name>`; N identical processes
distribute concurrent requests one per process while each keeps the simple
serial Nim SDK pump.

Replica support includes:

- `replicas: N` (1–16, default 1) in `manifest.yaml`;
- optional `replicas` on `core.spawn`, persisted across harness restarts;
- supervisor groups with distinct process instances/logs and group-wide
  `core.kill`/`core.remove`;
- replica-aware catalog presence (`pids`) so one departure does not remove the
  logical component while peers remain;
- `replicas`, `runningReplicas`, and `pids` in `core.status`;
- four shipped `grep` replicas, because `grep`/`files` are stateless.

`tests/t_parallel.nim` proves two one-second calls to one logical tool complete
in about one second through two replicas while transcript results remain in the
model's original call order.

## Go: concurrent-safe tools

The Go SDK's nats.go subscription callback is serial for one subscription, and
its previous component-wide mutex serialized handlers further. The SDK now has
an explicit `ToolConcurrent` registration path with bounded goroutine dispatch
(default 16, configurable with `ConcurrentLimit`). Concurrent tools share an
RW-lock read side; ordinary tools, events, and taps take the exclusive side, so
they remain barriers. Shutdown waits for detached handlers before closing NATS.

`llm.chat`, `llm_resolve`, and the minimal `llm-openai.chat` are enabled after
an audit: request state, HTTP clients, cancellation subscriptions, stream
accumulators, and results are per-call; package maps are read-only; nats.go
connections are concurrency-safe. This removes accidental serialization of
independent conversations and subagents.

## Limits and follow-ups

Replicas are appropriate only for stateless or externally coordinated
components. `store` is single-writer. The current `edit` component mixes
read-only tools with mutation and a per-process undo store, so replicating it
would be incorrect. Parallel `read` calls require either splitting reads into a
stateless component or implementing the deferred worker-aware Nim pump with an
exclusive mutation barrier.
