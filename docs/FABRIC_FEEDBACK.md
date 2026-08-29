Assessment
The core idea is sound: one model-generated program can internalize deterministic intra-turn control flow and keep intermediate tool results out of model context. It does not replace the completions protocol entirely, however. The model still emits the outer fabric call through completions, and semantic replanning still requires another completion or a subagent.
I would not consider the current plan implementation-ready. The overall seam is right, but several security and control-flow assumptions do not hold in the current codebase.
What Is Strong
- Reusing session-runner dispatch is the correct policy boundary. Approval and timeout policy belong in core/dispatch.nim, not in the executor.
- A disposable executor process fits Niffler’s process-isolation architecture.
- Returning only the program result gives the main context-economy benefit of pi-fabric.
- Treating a subagent as another persisted Niffler session is elegant.
- Shipping examples as executable fixtures is excellent.
- Starting on demand is sensible until model behavior and operational value are proven.
Blocking Issues
1. nimeval is not currently a security sandbox
RLIMIT_AS and process timeout constrain resources, but they do not constrain effects. Nim’s createInterpreter defaults to registerOps = true, and the VM exposes filesystem/environment operations. More seriously, staticRead and staticExec are system-level compiler magics implemented directly by the VM.
A guest can potentially bypass callTool() using operations such as staticExec, read host files, inspect environment variables, and reach NATS using inherited credentials. Supplying the stdlib pure and core directories also contradicts “stdlib-free”; it makes imports available unless explicitly prohibited.
This breaks the central invariant in docs/FABRIC.md:34.
A real design needs one of these:
- A patched/restricted Nim VM that rejects imports, Slurp, StaticExec, FFI, dangerous callbacks, and relevant compiler magics.
- An OS sandbox with an isolated filesystem, cleared environment, no process execution, and no network.
- A different isolated runtime such as QuickJS/WASM.
The executor should preferably have no NATS connection or NIF_NATS_URL. The trusted fabric parent component should own NATS and service child bridge requests. That is how the generated program can actually be limited to the host bridge.
Pi-fabric’s equivalent guarantee comes from QuickJS having no filesystem, process, or network globals, plus a host-owned registry path.
2. The proposed subagent call deadlocks against current core behavior
During a normal UI turn, system core is blocked forwarding to the parent session runner. If agent_run calls svc.core.call with tool session, pumpCoreWhileBusy stashes it unconditionally:
- core/dispatch.nim:270-272
- core/conversation.nim:801-812
The parent runner is waiting for agent_run; agent_run is waiting for the child session; system core will not process that child session until the parent finishes. That is a cycle.
Phase 0 therefore needs a delegated child-session mechanism, not only a nested tool proxy. A clean design would let core prepare a child runner and return its scoped subject, after which agent calls that runner directly.
3. Background agents are not implementable as described
The Nim SDK serializes synchronous handlers on one thread. agent_spawn cannot start a blocking svc.core.call request and return immediately without:
- A worker child process,
- A new asynchronous SDK request facility, or
- A core API that queues the turn and returns immediately.
Likewise, agent_wait cannot depend on ev.session.done. Core NATS events are at-most-once, so waiting after completion misses the event forever. Agent job status and terminal results need durable store records.
I would ship synchronous agent_run first and move spawn/wait into a later worker-process milestone.
4. The proxy currently grants hidden-tool access
dispatchToolCall routes any catalogued tool, including hidden tools. Only invokeTool checks isHidden() at core/dispatch.nim:60-64.
Without an explicit proxy restriction, a guest could request known hidden tools such as put, del, chat, or session. Some of those have no approval policy.
The nested proxy must reject:
- Hidden tools,
- The internal session and chat surfaces,
- Recursive fabric,
- Stale or cross-turn invocation leases.
Use an ephemeral call-scoped lease or subject, not merely predictable svc.session.<id>.tool. It should expire when the outer tool call finishes.
5. The claimed “one gate” does not exist yet
Current dispatch performs approval and timeout selection, but not JSON Schema validation:
- core/dispatch.nim:368-398
It also has no durable nested audit and no general cancellation propagation. A timeout means the caller stops waiting; it does not necessarily stop the target operation.
Phase 0 must either add these capabilities or stop claiming schema, cancellation, and audit enforcement. For fabric, I would add:
- Argument validation before injection and dispatch,
- Per-execution call and byte budgets,
- Remaining-deadline propagation,
- Cancellation of in-flight nested calls,
- Bounded per-call outcome events or a final structured trace,
- Cloning of arguments before private context injection so secrets do not enter UI events/history.
6. The depth rule contradicts the hybrid design
docs/FABRIC.md:59-60 says session-context tools reject at depth 1, but docs/FABRIC.md:141 explicitly wants fabric to call an agent. That call is already depth 1.
A numeric depth is too coarse. Use explicit provenance rules:
- Fabric calling fabric: deny.
- A child session spawning another child: deny via persisted parent metadata.
- Fabric calling agent from a root session: allow.
- A subagent using fabric: decide explicitly.
- Fabric inside a subagent calling another agent: deny through parent metadata.
7. The executor I/O contract is unsafe and contradictory
The plan gives stdout two meanings: final JSON framing and log() lines. It also proposes waiting for the child while capturing output. A chatty child can fill an undrained pipe and deadlock, exactly the problem already avoided in components/bash/main.nim:77-86.
Use bounded temporary files or a framed IPC loop. Reserve stdout for one protocol.
There is also an invariant conflict:
- docs/FABRIC.md:34: every effect crosses the session proxy.
- docs/FABRIC.md:115: artifact() writes directly to the filesystem.
Either artifacts must go through a component, or executor-owned artifact writing must be documented as a trusted-host exception with mode 0600, quotas, symlink protection, and retention cleanup.
8. The self-hosting acceptance criterion is not currently possible
The builder supports one Nim source and produces one binary. Fabric requires:
- fabric,
- fabric-exec,
- fabricguest/,
- A .nimble package,
- Compiler source paths.
Therefore docs/FABRIC.md:168-170 cannot work through the current builder. Either extend builder for package/multi-binary builds or change that acceptance criterion to the normal shipped build.
Also, findNimStdLibCompileTime() returns the compiler’s build-time libPath; it is not genuinely runtime self-locating.
Semantic Overclaims
- “Fan-out” is sequential until concurrent bridge calls exist.
- “Atomic edit+verify” is not atomic without rollback or transactional tooling.
- callTool(tool, argsJson) is not comparable to pi-fabric’s type-checked per-action API. It puts escaped JSON back inside source code and catches mistakes only at runtime.
- Catalog providers and schemas are not pinned for the duration of a program, so a reload can change semantics midway.
Generating typed guest wrappers from the active tool schemas would materially improve reliability, even if only the basic JSON Schema subset is supported.
Recommended Order
1. Establish the threat model and prove VM escape attempts fail: staticExec, staticRead, environment reads, imports, FFI, direct NATS, subprocesses, and filesystem access.
2. Implement an ephemeral nested-dispatch lease with hidden-tool rejection, validation, budgets, cancellation, and bounded tracing.
3. Build a sequential fabric MVP with the NATS bridge in the trusted parent, not the executor.
4. Add synchronous agent_run using a delegated child-runner path that cannot deadlock system core.
5. Add durable background agents using worker processes and store-backed job state.
6. Add typed wrappers, concurrency, richer observability, and hybrid examples afterward.
The fabric portion is a strong direction. The subagent portion should be separated from the initial milestone, and the Nim VM boundary must be resolved before calling the mechanism equivalent to pi-fabric’s isolated executor.