# Fabric: compiled Nim transformation

Status: phases 2-6 implemented on feature/fabric-compiled-nim.
  - 2 native executor  3 executable cache  4 structured SDK + diagnostics
    5 fabric_help discovery  6 reference/examples rewrite (+ examples migrated
    to the structured finish). Remaining: 7 stored-program migration/native-only
    cutover, 8 calibration. See git log for the incremental commits.
Worktree: `/home/gokr/git/niffler-fabric-compiled`.
Baseline: `be8d880`.

## Decision and success criteria

Replace the embedded Nim VM with ordinary compiled Nim guest processes.
Retain one Fabric host, the session nested-call proxy, and the existing NATS
contract. Improve the agent-facing API and selection guidance at the same
time; native compilation alone will not solve the t30 authoring overhead.
No Node/Go guest runtime and no permanent dual-runtime support in this scope.

Measured baseline: t30 comparison runs `t30-compare-{low,high}-20260909-172817`.
Pi high: 5 model-facing calls, 36.1s, $0.00196259. Niffler high: 29 calls,
383.8s, $0.02966565. Niffler knew a shell loop would work, chose Fabric,
searched for docs and batch contracts, investigated Nim JSON macros, then
recovered from using JArray as a type. The corrected program applied 24
edits and passed verification. This is principally authoring/selection cost,
not evidence that native execution speed will improve task time.

Acceptance:
- No compiler/nimeval or embedded compiler-source dependency in Fabric.
- Existing leases, approvals, budgets, read/write scheduling, schema pins,
  cancellation, artifacts and hybrid agent_run behavior remain enforced on
  calls through the proxy.
- Agents can discover docs, copy a complete example, and call the structured
  API without locating component or compiler source files.
- Cold compilation, warm compilation/cache hit, execution and model latency
  are measured separately. A few seconds for compilation is a hypothesis to
  measure, not a promised upper bound.
- All shipped examples compile AND execute in automated tests.

## Architecture and trust decision

Keep core independent of Fabric. Keep sdk/envelope.nim pure runtime JSON.
Keep the existing child framing seam private to Fabric; NATS remains the
inter-component bus. The compiled guest does not register as a component
and does not receive NATS credentials or the nested-call lease. The host
owns the lease and executes guest tool requests through the session proxy.

Implement compilation/lifecycle within the Fabric component boundary. Audit
builder's compiler-launch/cache code for reusable process mechanics, but do
not route ephemeral guest compilation through builder.build's persistent
component-install path. No core imports of component code. Do not introduce
asyncdispatch or global threading requirements into the SDK.

Trust model: approved native code, same basic trust class as bash, NOT an
OS sandbox. Approval precedes compilation, including cache-miss builds:
macros, static blocks, staticExec and compiler configuration can execute code.
All proxied calls still face their own policy checks; the initial approval
is not a blanket authorization for later calls. Direct native OS effects
cannot honestly be described as mediated or audited by the tool proxy.

Use a private build directory, controlled compiler argv, isolated config
loading and an environment allowlist. Do not inherit workspace nim.cfg,
config.nims, arbitrary package hooks, provider credentials or bus secrets.
Verify the exact Nim flags against the installed compiler. SDK and stdlib
only initially; no automatic dependency installation or user compiler flags.

Remove VM-specific import prohibitions and misleading claims that source
lint enforces filesystem/network isolation. Documentation recommends tool
calls for auditable operations, but does not claim native code cannot bypass
them. If mandatory OS isolation becomes a requirement, it is a separate
explicit launch mode/design, not a token blacklist masquerading as a sandbox.

## Proposed guest API (freeze in phase 1)

One preferred style: structured values end to end; `import fabricguest`
exports the supported JSON operations and API. Keep serialization in SDK
internals. Avoid generated scalar-output special cases in the preferred API.

```nim
import fabricguest

let test = call("bash", %*{"command": "./test.sh"})
finish(%*{"testExitCode": test{"exit_code"}.getInt(-1)})
```

Proposed signatures:
- `call(tool: string, args: JsonNode): JsonNode`
- `toolCall(tool: string, args: JsonNode): FabricCall`
- `batch(calls: openArray[FabricCall]): seq[FabricOutcome]`
- `finish(value: JsonNode)` (terminal; normal return without it is an error)
- `log(message: string)` (bounded activity output, not conversation history)
- `inputs(): JsonNode` / existing `stringArg(key)` for runtime payloads

Outcome: typed `ok`, parsed `value`, and structured error code/message; no
JSON string nested inside the successful value. `call` raises FabricCallError
on proxy/tool failure. bash nonzero exit and grep no-matches are ordinary
results; callers inspect exit_code. Do not inspect human `text` to decide
whether edit succeeded. Add an additive edits_applied field to edit results
if callers need a count, preserving existing machine fields and text.

Batch automatically chunks requests above the private frame batch limit,
preserves input order and individual errors, and charges each admitted tool
call against maxCalls. Validate the whole input before sending mutations.
Bound total input/output and check cancellation between chunks. Independent
reads may overlap under the host cap; writes remain exclusive. No claim of
parallel writes or budget savings from batching. Batch is not transactional:
return/report partial outcomes on interruption without implying rollback.

Selected schemas still pin allowlists and host validation. Optional typed
input wrappers may remain, but their preferred output is consistently
JsonNode. During transition keep the old callTool/batch(string)/finish(string)
functions and j* helpers as explicitly legacy compatibility APIs; test their
old string semantics. No ambiguous implicit conversions between new and old
interfaces. Retire compatibility only with an explicit library migration.

## Phased implementation / commit sequence

### 1. Contract and regression fixtures

- Add native execution lifecycle tests and freeze new API/error shapes.
- Capture current stored-program, schema-pin, approval, batch, artifact and
  hybrid behavior as regression cases.
- Add deterministic reproductions of t30 authoring pitfalls (nested JSON,
  array node types, batch request/results, exact edits and verification).
- Decide bridge versioning and preserve existing external Fabric result
  shapes where possible; additive phase/timing/error fields only.

### 2. Native compiler/executor path

Primary files: `components/fabric/executor.nim`, `fabric.nim`,
`fabricguest/fabricguest.nim`, `fabricguest/fabricmeta.nim`, `framing.nim`,
`Makefile` and the corresponding nimble/build/setup references.

- Turn fabric-exec into a bounded compile/run supervisor, or factor that
  responsibility into component-local modules while retaining its executable
  entry point. Replace implementRoutine hooks with a real native guest SDK.
- Generated driver supplies bridge setup and source mapping. Diagnostics
  identify guest.nim with correct source lines, not confusing wrapper offsets.
- Use dedicated protocol descriptors/channels: guest echo/stdout/stderr must
  not corrupt request frames. Capture ordinary output with bounded tails.
- Compilation and execution share the caller's total deadline. Also bound
  each phase, compiler output, frame sizes and retained artifacts.
- Cancel/timeout kills and reaps compiler, C compiler/linker, guest and their
  descendants; handle host death and pipe EOF. Test Linux and macOS behavior.
- Do not auto-retry guest execution: a failed run may already have mutated
  files. Successful compilation alone never reports a successful Fabric run.
- Missing compiler/toolchain reports a direct actionable admission error.

### 3. Safe content-addressed executable cache

- Key by source, generated driver, guest SDK content/version, selected
  normalized schemas, compiler identity, C toolchain/target and flags.
- Runtime strings/inputs/session ids/leases/secrets do NOT enter the key or
  executable. Every invocation initializes fresh inputs and proxy context.
- Private directories, atomic publish, no partial-executable reuse, no
  symlink/path traversal acceptance, lock concurrent builds of one key.
- Cache lookup does not skip authorization or schema-pin checks. Concurrent
  waiters honor their own deadlines/cancellation.
- Bound disk usage and evict unused entries; running binaries protected from
  cleanup. Per-build nimcache prevents concurrent compiler corruption.
- Integrate with clean/recovery documentation; no shared var/ with main.

### 4. Structured guest SDK and diagnostics

- Implement the API above, automatic chunking, coherent exceptions and exact
  structured outcomes. Keep legacy compatibility paths separately tested.
- Structured failures distinguish compile-error, compile-timeout,
  runtime-error, runtime-timeout, cancelled, protocol-error and tool-error.
- Retain firstError/diagnostics compatibility; add source line, column,
  excerpt and phase where available. Bound inline detail, spill full logs.
- Add compileMs, executionMs, cacheHit and real nested-call counts to terminal
  metadata/events. Every announced start has one terminal event, including
  compile failure and cancellation.
- Verification evidence includes the nested tool/command, exit code and run
  provenance from host-observed calls. Do not treat arbitrary finish text as
  trusted verification. Existing UI can show generic events first; avoid
  expanding into a UI rewrite.

### 5. Discovery and documentation access

- Provide on-demand component-local `fabric_help` with a short reference and
  named examples. It reads packaged assets from its own component location,
  never arbitrary user paths. No workspace/harness-root guessing required.
- Improve `discover {component: ...}` so a single visible tool's callable
  schema is returned directly where unambiguous. For multi-tool components,
  return an explicit next discovery action rather than encouraging trial
  calls with empty args. Honor hidden tools and session allowlists throughout.
- Make Fabric schema/doc snippets point at fabric_help. Keep full reference
  and examples out of the frozen direct toolset.
- Prompt-cache effect: new tool descriptions/baseprompt apply only to newly
  frozen conversations; discovery/help content is append-only tool history.
  Do not retrofit existing prefixes or embed volatile absolute paths.

### 6. Reference, examples and prompt/tool guidance

- Rewrite REFERENCE.md for compiled Nim with one recommended structured API,
  complete minimal program, exact batch contract, bounds and error semantics.
- Explicitly document JsonNode as the type; JArray is a kind; nested %* and
  JsonNode embedding work. Show array accumulation without speculative types.
- Fix contradictory guest header, subagent, bash-error, batch-budget and
  example-link claims. Do not require import fabricguest to be literal line 1.
- Port all five examples; add real batch-read and plan/edit/verify examples.
  Keep examples bounded and small; no tests requiring an actual LLM.
- Test runnable docs snippets from their source, not hand-copied equivalents.
- Selection guidance: prefer a short workspace script for deterministic local
  transformations, including per-item variation. Fabric is for composing
  harness tools when that provides an advantage. File count alone is not a
  reason; neither is having large local files a script can aggregate locally.
- Clarify read_many surveys and exact edits without banning appropriate bulk
  scripts. Clarify workspace vs harness root and no /tmp source archaeology.
- A successful nested test is a real verification; no rerun solely to make it
  visible. Tell the model to consume structured success, not text substrings.

### 7. Stored-program migration and native-only cutover

- Inventory store kind fabricprog schemas/source usages before changing
  interpretation. Add an explicit guest API/runtime version where needed;
  no silent rewriting or deletion of stored programs.
- Exercise existing stored sources through native compatibility. Native Nim
  does not guarantee every VM guest compiles unchanged: report actionable
  migration errors and document the bounded supported compatibility surface.
- Make compiled Nim the sole execution backend after contract tests pass.
  Remove embedded VM dependencies and update setup/doctor/manual/build docs.
- No changes to persistent component naming or agent spawning semantics.

### 8. Verification and calibration

Deterministic tests:
- cold/warm compile, missing compiler, syntax/type failure, bad/missing finish;
- string/quote/newline/unicode round trips and nested JSON; all examples;
- batches of 0/1/16/17/large bounded size; parsed success/failure outcomes;
- read concurrency, exclusive writes, per-item accounting and partial failure;
- approval denied BEFORE compilation (static side-effect sentinel untouched);
- cancellation during compile, link, execution, nested call and batch;
- descendants reaped, bounded noisy output, fragmented/malformed frames;
- cache invalidation for source/SDK/schema/toolchain changes, concurrent same
  key, cancelled waiter, no runtime-input or lease reuse, cleanup races;
- catalog replacement, allowlists, workspace resolution, artifacts, stored
  programs, hybrid agent_run with restored outer lease;
- new doc discovery visibility and frozen-prefix regression tests.

Run narrow tests after each change. Final gate: `make build && make test`,
plus a live isolated conversation exercising compiled Fabric and hybrid
calls. Trust passing runs; do not repeat suites merely to get more output.

Before bench calibration harden t30's verifier: assert all 24 expected files
and immutable profile/width values instead of trusting mutable headers or
accepting an empty directory. Audit actual patches against those invariants.
Keep any resulting task revision distinct from historical benchmarks.

Bench experiments (fresh sessions, same model/settings, multiple independent
trials; rounds are repair opportunities, not statistical repetitions):
1. t30 natural choice, Pi/Niffler low/high: does Niffler stop over-selecting?
2. matched orchestration fixtures under old baseline/new compiled runtime:
   authoring cost, first successful run, compile/cache/execution breakdown.
3. workloads with real harness-service composition, not only local files.
Report schema/help/source lookup counts, program bytes, compile failures,
model-facing/nested calls, input/output/cache tokens, cost and wall time.
Do not force Fabric in natural-choice comparisons; label forced-runtime
microbenchmarks separately. No promise of beating a local script on t30.

## Worktree hygiene and delivery

All implementation and builds occur in this worktree with its own var/ and
NIF_ROOT. Never symlink main's runtime state or rebuild its binaries. Probe
with a private bus (NIF_NATS_SPAWN=1; no copied production .env), and explicitly
supply only credentials needed for an authorized live model test. Build locks
are worktree-local; bench model registrations/auth refreshes may still be
shared external state and need coordination. Check session model/root before
any live probe. Do not stop unrelated harness processes.

Deliver as reviewable commits following the phases above. Update README
milestone status, WIRE for any additive event/catalog contract changes, and
MANUAL for compiler requirements/trust/cache semantics. Keep research history
as history. No merge to main or full benchmark launch implicit in this plan.
