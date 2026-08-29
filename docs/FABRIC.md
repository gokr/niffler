# Fabric + Subagents — Implementation Plan

Status: approved, revised after external review (docs/FABRIC_FEEDBACK.md) and
empirical verification of the review's claims.

One programmable tool (`fabric`) lets the LLM write a Nim program that owns the
intra-turn control flow — branching, loops, fan-out, data flow — instead of one
tool call per loop round. Only the program's result enters the conversation.
Alongside it, an `agent` tool turns any Niffler conversation into a subagent
(fresh context, own loop, summary returned). Both are thin surfaces over
infrastructure core already has, plus one shared core change.

Background research: pi-fabric analysis (github.com/monotykamary/pi-fabric) and
a validated embedding prototype (`nimeval` + natswrapper bridge, guest driving
20 real NATS tool calls from inside the VM).

## Architecture

```
LLM turn (session runner)
  └─ dispatchToolCall("fabric"|"agent")            ← approval: "always"
       │  args.__session injected (x-harness.sessionContext)
       ▼
 ┌─ fabric component ─────────────────┐  ┌─ agent component ─────────────┐
 │ spawns var/bin/fabric-exec (child) │  │ agent_run/steer: prepare a    │
 │ framed stdio protocol; parent owns │  │ child runner via core op,     │
 │ NATS and serves the child's bridge │  │ then talk to the runner's     │
 │ requests. Child holds no creds.    │  │ subject DIRECTLY (never via   │
 │   guest program (pure Nim)         │  │ core's session tool — that    │
 │     └─ callTool() ─────────────────┼─▶│ stash deadlocks mid-turn).    │
 └────────────────────────────────────┘  └───────────────────────────────┘
        nested work routes through:
   svc.session.<id>.tool  →  runner pump  →  dispatchToolCall
   (the only path a program has: approval, schema validation, timeout —
   one implementation of the gate)
```

Shared invariant: **every effect of a generated program crosses the session
proxy.** This is a *governance* guarantee (audit, approval, budgets), not a
security sandbox — see "Threat model" below. The envelope codec
(`sdk/envelope.nim`, WIRE.md, Go SDK) is untouched.

Design posture (resolved decisions):

- **Governance-only isolation** (verified posture): the guest is in `bash`'s
  trust class — a human approves the program once. Cheap, explicit hardening
  (below) replaces reliance on VM accidents; every effect is *encouraged*
  through the bridge so the gate sees it.
- The guest is an **orchestrator of references, not a runtime for data**:
  files/data/db live in components (`store`, `bash`/`read`/`write`, or a
  generated `db` component); the guest holds ids and artifact paths, never the
  data. Bridge helpers are pure JSON functions only — never new I/O.
- Result contract: guest calls `finish(value)` — a native bridge proc raising a
  control exception the executor catches as the result.
- First iteration ships `x-harness.onDemand` (reachable via discover/invoke)
  until proven.

## Threat model (governance-only, empirically grounded)

On Nim 2.2.10 the embedded VM is *accidentally* tight: `readFile` and
`import std/os` fail to compile in the guest (`importc`/`cmpic` errors),
`getEnv` is undeclared, and `staticExec`/`gorge` die at runtime with
"VM is not built with 'gorge' support" unless the host defines `-d:nimcore`.
We keep the accidents from regressing and add explicit policy:

1. Executor compiled **without** `nimcore`/`nimsuggest` (keeps the gorge gate).
2. **Pre-eval source lint**: guest source is scanned before `evalScript`;
   banned tokens (`staticExec`, `gorge`, `slurp`, `staticRead`, `importc`,
   `os`/`osproc`/`net` imports, `natswrapper`) reject the program with a clear
   error. A lint is not bulletproof — it is auditable policy, not a boundary.
3. Executor child runs with a **cleared environment** (no `NIF_*` vars) and
   **no NATS connection** — the fabric parent owns the bus and serves the
   child's bridge requests over framed stdio. Even a VM escape finds no
   credentials and no reachable bus.
4. `posix.setrlimit(RLIMIT_AS)` + process kill for timeout — resource limits,
   not effect limits.
5. Honest framing: approval is the boundary. `x-harness.approval: "always"` on
   the fabric tool means one approval covers the program's effects; effects
   that route through the bridge get per-call approval and audit; effects that
   exploit a VM accident are *policy violations caught by the lint*, treated
   like a guest that lied in its approved source.

## Phase 0 — Core plumbing (shared infrastructure) · ~150 lines

Files: `core/dispatch.nim`, `core/session.nim`, `core/conversation.nim`,
`core/catalog.nim`.

1. **`x-harness.sessionContext`** schema flag:
   - `conversation.nim`: add `toolSubject(sessionId)` next to `steerSubject`.
   - `dispatch.nim`: `CoreTools.turnSession: string` (mirrors
     `approval.session`; set/cleared around the turn in `runTurn`);
     `dispatchToolCall` injects `args.__session` for tools with the flag.
   - Provenance instead of numeric depth (see rules below).
2. **Nested-call proxy** `svc.session.<id>.tool`:
   - `session.nim`: sync subscribe alongside the steer subscription.
   - `dispatch.nim`: `NestedStream` ref (mirrors `SteerStream`) + `pumpNested`,
     called from `dispatchSubjectCall`'s idle slot. Handler: decode → validate
     → `dispatchToolCall` → reply.
   - **Proxy admission rules** (review item 4): reject hidden tools
     (`isHidden()` — currently only `invokeTool` checks it), reject `chat` and
     `session`, reject nested `fabric`. **Ephemeral lease**: `dispatchToolCall`
     injects a one-shot lease token with `__session`; `pumpNested` validates it
     against the in-flight token and expires it when the outer call settles —
     the predictable subject is worthless without the live lease.
   - **Schema validation at the proxy**: minimal required-fields JSON Schema
     check before dispatch (core currently validates nothing — review item 5).
     Unknown-key and full-type validation stay out of scope.
   - Fail closed: no `turnSession` or no live lease → nested requests denied.
3. **Delegated child-runner preparation** (review item 2 — blocking fix):
   `core` gains an op that ensures a conversation header + runner for a child
   session and returns the runner's **direct subject**
   (`svc.session.<child>.call`). `pumpCoreWhileBusy` stashes session calls
   while a turn is in flight (dispatch.nim:252: "turns must never nest") —
   so any component driving a subagent mid-turn MUST bypass core's session
   tool and call the child runner directly. The runner already serves
   `svc.session.<id>.call` itself (session.nim:72).
4. **Provenance rules** (replace numeric `__depth`):
   - fabric → fabric: deny (tool-name check in the proxy).
   - child session → child session: deny (store `sessionmeta {parent}`).
   - fabric → agent from a root session: allow (the hybrid design).
   - subagent → fabric: allow (a subagent is just a session).
   - fabric inside a subagent → agent: deny (parent metadata).

**Acceptance**: suite-style probe calls `svc.session.<id>.tool` during a live
turn (approval denied without `NIF_AUTO_APPROVE`, dialog with it); hidden tool
rejected; stale/expired lease rejected; child-runner prep returns a live
subject that serves a turn while the parent turn is still running.

## Phase 1 — `agent` component (synchronous scope) · ~200 lines

File: `components/agent/agent.nim` — pure SDK component. Per review item 3,
**only synchronous operations ship in this milestone** (the SDK serializes
handlers on one thread; background jobs need worker processes + durable state
— later phase).

- **`agent_run {task, model?, timeoutMs?}`**: prepare child runner via the
  Phase-0 core op → call the child runner's subject directly with the framed
  task → subscribe `ev.session.>` filtered by id → return on `done` with
  `{reply, sessionId}`. No core stash, no deadlock. *(As shipped: the child
  session call is a plain request/reply whose result carries the final reply —
  the event subscription is only needed for the later spawn/wait phase.)*
- **`agent_steer {sessionId, message}`**: fire-and-forget publish to
  `svc.session.<id>.steer` (safe synchronously; drainSteer consumes it).
- **Depth guard at dispatch time** (`x-harness.noSpawn: true` on agent_run):
  core's `dispatchToolCall` denies the call when the calling session has a
  `sessionmeta {parent}` record in the store. The check MUST live in
  dispatch, not in the component's handler — the handler blocks its
  component's pump for the child's whole turn, so a subagent's spawn request
  would queue behind it and circular-wait forever (found by t_agent; the
  handler keeps its own `hasParent` check as backstop).
- **Task framing**: fixed preamble ("You are a subagent. Work autonomously,
  report a concise result."). Subagent gets the full normal toolset and loop.
- Approvals inside the subagent route to the driving client
  (`approval.caller`) — the human still sees every gate.

## Phase 2 — `fabric` component · ~700 lines

**`components/fabric/executor.nim`** (binary `var/bin/fabric-exec`):

- **Framed stdio protocol** (review item 7 — one meaning per frame, bounded
  lines): stdin receives `{code, strings, sessionSubject, catalog}` once; the
  child then writes framed lines: `{t: "req", id, tool, args}` (bridge
  requests — the *parent* performs the NATS call and replies
  `{t: "resp", id, ok, result|error}` on the child's stdin), `{t: "log", s}`,
  and finally `{t: "result", ok, value, diagnostics?}`. Parent drains
  continuously — no pipe-fill deadlock (the bash-component lesson).
- Cleared environment, no NATS in the child (threat model above).
- `posix.setrlimit(RLIMIT_AS)` before `createInterpreter`; fresh interpreter
  per program (kill = timeout; the VM API has no interrupt hook).
- Runtime search paths: `findNimStdLibCompileTime()` + `pure` + `core` +
  `fabricguest/` — resolved from the compiling toolchain (compile-time
  self-locating: valid because components are built in place).
- Bridge via `implementRoutine`; the `.nimble` file in `fabricguest/` is
  **load-bearing** (callback key = nimble package name; no nimble →
  `"unknown"` → bridge never fires).
- Bridge surface: `callTool(tool, argsJson)` (→ parent → session proxy),
  `finish(value)`, `log(s)`, `artifact(text) → path`, `stringArg(key)`,
  native JSON helpers (`jsonGet`, `jsonQuery`, `jsonMap`). Guests stay
  **stdlib-free**: cold eval ~ms, heavy parsing stays native in the bridge.
- **Artifacts are a documented trusted-host exception** (review item 7):
  executor-side file writes, mode 0600, size quota, symlink-safe run
  directory, retention cleanup. Everything else crosses the bridge.
- Compile errors: real Nim compiler diagnostics passed back verbatim.

**`components/fabric/fabric.nim`** — SDK component, one tool `fabric`:

- Schema `{code: string required, strings?: object, timeoutMs?: int,
  maxCalls?: int}`; `x-harness: approval "always", timeoutMs 300000,
  sessionContext true, onDemand true`.
- Owns the NATS side of the bridge; enforces **per-program budgets** (review
  item 5): max bridge calls (default 200), max output bytes, remaining-deadline
  propagation (per-call timeout = min(tool timeout, remaining program time)).
- Pins a **catalog snapshot** at program start (review: semantic pinning) and
  passes it to the executor; the bridge rejects tools not in the snapshot, so
  a mid-program component reload cannot change semantics.
- Output cap 50k chars, oversized results → artifact + path returned.

## Phase 3 — Teaching the LLM

Doc comments are the LLM's only window; both tools carry the when-to-use
matrix (honestly worded — fan-out is sequential until concurrent bridge calls
exist; "atomic" means single-program consistency, not rollback):

| Situation | Use |
| --- | --- |
| One step, or each result changes the plan | direct loop |
| Mechanical, known shape: sequential fan-out, search+distill, big data that must never hit context, edit+verify in one program, polling/retry | `fabric` |
| Exploratory/fuzzy subtask wanting its own fresh context and loop | `agent_run` |
| Hybrid: program supervises fuzzy subtasks, does dataflow itself | `fabric` guest calls `callTool("agent", …)` |

- `components/fabric/examples/*.nim` — 4 worked examples that double as test
  fixtures: pipeline (grep → read window → digest), fan-out + aggregate,
  edit-verify (single-program consistency), fabric-calling-agent hybrid.
- Source pointers in the doc comments: `fabricguest.nim` (the typed API *is*
  the documentation) and `examples/`.

## Phase 4 — Observability & tests

- `console` sees nested calls live (every nested call is a bus envelope);
  `ev.fabric.done` / `ev.agent.done` summary events after completion.
- `tests/t_fabric.nim` (private NATS + temp NIF_ROOT, per suite convention):
  compile-error round-trip · fan-out program · nested approval denied · hidden
  tool rejected at proxy · stale lease rejected · timeout kill · budget
  exhaustion · output cap + artifact · fail-closed without session/lease ·
  provenance rules · escape-lint rejections (`staticExec`, `os` import) ·
  stdlib-free cold-eval under 1s.
- `tests/t_agent.nim`: run → reply (child runner direct, parent turn live) ·
  steer mid-turn · depth guard (agent-from-subagent denied) · model override ·
  deadlock regression test (subagent while parent turn in flight).

## Phase 5 — Wiring, dogfood, ship

- Build: `var/bin/fabric`, `var/bin/fabric-exec`, `var/bin/agent`. The executor
  needs `--path:$(libpath)/../compiler` at compile time only (computed in the
  nimble task).
- **Self-hosting criterion adjusted** (review item 8): the builder is
  single-source/single-binary, so the acceptance demo runs the *shipped*
  binaries: the agent uses `fabric` and `agent_run` mid-conversation via a
  hybrid program. Extending the builder for multi-binary package builds is a
  separate later project, not a fabric prerequisite.
- Docs: README milestone entry + MANUAL section.

Execution order: 0 → 1 → 2 → 3 → 4 → 5 (agent before fabric deliberately: a
tiny Phase-0 consumer proves the proxy and the child-runner path before
executor complexity lands).

## Later (explicitly out of scope)

- `agent_spawn`/`agent_wait` background mode: worker child processes +
  store-backed job records (terminal results must be durable — events are
  at-most-once).
- Concurrent bridge fan-out (multiple inboxes — still no threads); until then
  fan-out is sequential.
- Typed guest wrappers generated from the catalog snapshot
  (compile-time-checked proc signatures) — biggest known reliability lever,
  deliberately deferred until the mechanism is proven.
- Live executor event streaming.
- Persistent background agents / residency + watcher components.
- Speculative execution of read-only calls during streaming.
- Builder extension for multi-binary package builds (would restore true
  self-hosting of fabric through builder).
- Full JSON Schema validation and cancellation propagation at dispatch
  (request/reply has no cancel semantics; documented gap).
