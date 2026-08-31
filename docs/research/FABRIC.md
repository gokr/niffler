# Fabric + Subagents

> Research note — full design record. Operating reference for the `fabric` and
> `agent` tools: [docs/MANUAL.md#fabric-and-subagents](../MANUAL.md#fabric-and-subagents).

Status: **shipped**. The design was an approved plan (revised after external
review — see `FABRIC_FEEDBACK.md` (same directory) for the review that shaped it); this
document describes what actually shipped. Divergences from the original plan
are marked where they matter.

One programmable tool (`fabric`) lets the LLM write a Nim program that owns the
intra-turn control flow — branching, loops, fan-out, data flow — instead of one
tool call per loop round. Only the program's result enters the conversation.
Alongside it, an `agent` tool (`agent_run`/`agent_steer`) turns any Niffler
conversation into a subagent (fresh context, own loop, summary returned). Both
are thin surfaces over infrastructure core already has.

## Architecture

```
LLM turn (session runner)
  └─ dispatchToolCall("fabric"|"agent")            ← approval: "always"
       │  args.__session = {session, lease, remainingMs} injected
       ▼
 ┌─ fabric component ─────────────────┐  ┌─ agent component ──────────────┐
 │ spawns var/bin/fabric-exec (child) │  │ agent_run/steer: prepare a     │
 │ framed stdio protocol; parent owns │  │ child runner via session_pre-  │
 │ NATS and serves the child's bridge │  │ pare, then talk to the run-    │
 │ requests. Child holds no creds.    │  │ ner's subject DIRECTLY (never  │
 │   guest program (pure Nim)         │  │ via core's session tool — that │
 │     └─ callTool() ─────────────────┼─▶│ stash deadlocks mid-turn).     │
 └────────────────────────────────────┘  └────────────────────────────────┘
         nested work routes through:
    svc.session.<id>.tool  →  runner pumpNested  →  dispatchToolCall
    (the only path a program has: approval, schema validation, timeout —
    one implementation of the gate)
```

Shared invariant: **every effect of a generated program crosses the session
proxy.** This is a *governance* guarantee (audit, approval, budgets), not a
security sandbox — see "Threat model" below. The envelope codec
(`sdk/envelope.nim`, docs/WIRE.md, Go SDK) is untouched.

Design posture:

- **Governance-only isolation**: the guest is in `bash`'s trust class — a
  human approves the program once. Explicit hardening (below) replaces
  reliance on VM accidents; every effect is *encouraged* through the bridge
  so the gate sees it.
- The guest is an **orchestrator of references, not a runtime for data**:
  files/data live in components (`store`, `bash`/`read`/`write`); the guest
  holds ids and artifact paths, never the data. Bridge helpers are pure JSON
  string functions only — never new I/O.
- Result contract: the guest calls `finish(value)` — a native bridge proc
  raising a control exception the executor catches as the result.
- `fabric` ships `x-harness.onDemand` (reachable via discover/invoke);
  `agent_run` is a direct tool.

## Threat model (governance-only)

On Nim 2.2.10 the embedded VM is *accidentally* tight: `readFile` and
`import std/os` fail to compile in the guest (`importc`/`cmpic` errors),
`getEnv` is undeclared, and `staticExec`/`gorge` die at runtime unless the
host defines `-d:nimcore`. We keep the accidents from regressing and add
explicit policy:

1. Executor compiled **without** `nimcore`/`nimsuggest` (keeps the gorge gate).
2. **Pre-eval source lint**: guest source is scanned before `evalScript`;
   banned tokens (`staticExec`, `gorge`, `slurp`, `staticRead`, `importc`,
   `os`/`osproc`/`net` imports, `natswrapper`) reject the program with a clear
   error. A lint is not bulletproof — it is auditable policy, not a boundary.
3. Executor child runs with a **cleared environment** (no `NIF_*` vars) and
   **no configured NATS connection** — the fabric parent owns the bus and
   serves the child's bridge requests over framed stdio. The guest still
   shares the host filesystem, UID and network namespace, so this reduces
   accidental access rather than creating a security boundary.
4. `posix.setrlimit(RLIMIT_AS)` + process kill for timeout — resource limits,
   not effect limits.
5. Honest framing: approval is the boundary. `x-harness.approval: "always"`
   means one approval covers the program's effects; effects that route through
   the bridge get per-call approval and audit; effects that exploit a VM
   accident are *policy violations caught by the lint*, treated like a guest
   that lied in its approved source.

## Core plumbing (shipped)

- **`sessionContext: true`** schema flag (`x-harness`): `dispatchToolCall`
  injects `args.__session = {session, lease, remainingMs}` for `fabric` and
  `agent_run`.
  The lease is a one-shot token owned by the in-flight call — the predictable
  nested-call subject is worthless without the live lease. Fail closed: no
  live turn or no matching lease → denied.
- **Nested-call proxy** `svc.session.<id>.tool` (`pumpNested` in
  `core/dispatch.nim`): admission checks, in order —
  live session context → live lease → not an internal/recursive surface
  (`fabric`, `agent`, `chat`, `session`, `invoke`, `session_prepare` are all
  rejected) → tool exists → not hidden → complete bounded schema validation —
  then re-enters the single `dispatchToolCall` gate (approval, remaining
  deadline, target timeout). Drained from the idle slot of
  `dispatchSubjectCall`, like steer, so the blocked runner stays responsive.
- **`session_prepare`** core op: ensures a conversation header + runner for a
  child session and returns the runner's **direct subject**
  (`svc.session.<child>.call`) — the only way to drive a subagent mid-turn,
  since core's `session` tool stashes concurrent calls ("turns never nest").
- **Depth rule**: a session recorded as a child (`sessionmeta {parent}`) is
  denied `agent_run` — checked at dispatch time (`x-harness.noSpawn: true`),
  not in the component handler (the handler blocks its component's pump for
  the child's whole turn; a dispatch-time check cannot circular-wait). The
  component keeps its own `hasParent` check as backstop.

## The `agent` component (`components/agent/`)

Synchronous only (the SDK serializes handlers on one thread; background jobs
need worker processes + durable state — not shipped):

- **`agent_run {task, model?, timeoutMs?}`** — prepare a child runner via
  `session_prepare`, call the child runner's subject directly with the framed
  task, return its final reply with `{reply, sessionId}`. The child session
  call is a plain request/reply whose result carries the final reply.
- **`agent_steer {sessionId, message}`** — fire-and-forget publish to
  `svc.session.<id>.steer`; the running turn folds it in at the next round.
- Fixed task preamble ("You are a subagent. Work autonomously, report a
  concise result."). The subagent gets the full normal toolset and loop.
- Approvals inside the subagent route to the driving client
  (`approval.caller`) — the human still sees every gate.

## The `fabric` component (`components/fabric/`)

**`fabric.nim`** — SDK component, one tool:

- Schema `{code: string required, tools?: string[], strings?: object,
  timeoutMs?: int, maxCalls?: int}`; `x-harness`: approval "always", timeoutMs 300000,
  sessionContext, onDemand.
- Owns the NATS side of the bridge; enforces per-program budgets: **maxCalls**
  (default 200) bridge calls, per-call timeout = min(tool timeout, remaining
  monotonic program time). Nested arguments are validated against the complete
  bounded schema subset before approval or dispatch; malformed `argsJson` is
  rejected rather than rewritten. Source, strings, frames, logs, and results
  all have explicit byte/count limits.
- Oversized `finish()` values spill to mode-0600 files under
  `var/fabric-artifacts/`; artifacts expire after seven days and the directory
  is capped at 100 files / 100 MB.
- Emits `ev.fabric.log` per guest `logg()` call within the log budget.
- `tools` selects up to 16 exact non-hidden tools. Core returns a canonical
  owner/version/schema fingerprint snapshot; every selected bridge call checks
  that pin against the live catalog and fails if a component changed mid-run.

**`executor.nim`** (binary `var/bin/fabric-exec`):

- **Framed stdio protocol**: stdin receives `{code, strings, schemas?}` once;
  the child then writes framed lines — `{t: "req", id, tool,
  args}` (bridge requests: the parent performs the NATS call and replies
  `{t: "resp", id, ok, result|error}` on the child's stdin), `{t: "log", s}`,
  and finally `{t: "result", ok, value, diagnostics?}`. The parent drains
  continuously — no pipe-fill deadlock (the bash-component lesson).
- Cleared environment, no NATS in the child; CPU, address-space, file
  descriptor, and child-process `setrlimit` caps before `createInterpreter`;
  fresh interpreter per program (kill = timeout; the VM API has no interrupt
  hook).
- Runtime search paths resolved from the compiling toolchain (compile-time
  self-locating — valid because components are built in place).
- Bridge via `implementRoutine`; the `.nimble` file in `fabricguest/` is
  **load-bearing** (callback key = nimble package name).
- Compile errors: real Nim compiler diagnostics passed back verbatim.

**Raw guest API** (`components/fabric/fabricguest/fabricguest.nim`) —
stdlib-free (no imports; cold eval ~ms):

| Proc | Purpose |
| --- | --- |
| `callTool(tool, argsJson): string` | call a bus tool through the proxy; returns the result JSON |
| `finish(valueJson)` | end the program with a result (control exception) |
| `logg(message)` | emit an `ev.fabric.log` event |
| `stringArg(key): string` | read a `strings` argument |
| `jesc / jpair / jobj / jarr / jnum / jbool` | JSON string builders — heavy parsing stays native in the bridge |

Selected mode injects `fabricmeta.nim`, whose `fabricTools` macro generates
`tools.<tool>(required = value, optional = value)` wrappers from the pinned
runtime schemas. Scalar arguments and arrays are Nim-typed; objects degrade to
`JsonNode`; wrappers return `JsonNode`. Optional arguments use `FabricArg[T]`,
so omission remains distinct from explicit `false`, `0`, or `""`. Ambiguous
style-insensitive names omit the wrapper and retain allowlisted `callTool` as a
fallback. Host validation remains authoritative.

## Teaching the LLM

Doc comments are the LLM's only window; both tools carry a when-to-use
matrix (honestly worded — fan-out is sequential until concurrent bridge calls
exist):

| Situation | Use |
| --- | --- |
| One step, or each result changes the plan | direct loop |
| Mechanical, known shape: sequential fan-out, search+distill, big data that must never hit context, polling/retry | `fabric` |
| Exploratory/fuzzy subtask wanting its own fresh context and loop | `agent_run` |
| Hybrid: program supervises fuzzy subtasks, does dataflow itself | `fabric` guest calls `callTool("agent", …)` |

Worked examples (double as test fixtures) in `components/fabric/examples/`:
`pipeline.nim` (grep → read window → digest), `fanout.nim` (fan-out +
aggregate), `hybrid.nim` (fabric calling agent).

## Tests

- `tests/t_nested.nim` — proxy admission: lease checks, internal-surface
  rejection, hidden tools, private-context stripping, live-turn fail-closed.
- `tests/t_schema_validation.nim` — full supported scalar/object/array types,
  enums, bounds, additional properties, and schema depth/size limits.
- `tests/t_agent.nim` — run → reply (child runner direct, parent turn live),
  steer mid-turn, depth guard, deadlock regression.
- `tests/t_fabric.nim` — compile-error round-trip, real programs driving bus
  tools, typed wrapper generation, catalog replacement, malformed arguments,
  budget/deadline behavior, and private artifacts.

## Not shipped (deliberately later)

- `agent_spawn`/`agent_wait` background mode (worker processes + store-backed
  job records).
- Concurrent bridge fan-out (multiple inboxes — still no threads).
- Live executor event streaming beyond `ev.fabric.log`;
  `ev.fabric.done`/`ev.agent.done` summary events.
- Cancellation propagation into a running guest (request/reply has no cancel
  semantics; kill-on-timeout is the only stop).
