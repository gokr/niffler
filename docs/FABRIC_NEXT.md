# Fabric Reliability and Typed Wrappers Plan

Status: in progress as a follow-up to the shipped Fabric implementation in
`docs/research/FABRIC.md`.

This plan keeps Fabric's current architecture: a disposable Nim guest owns
deterministic intra-turn control flow, while every declared effect crosses the
session proxy and re-enters normal dispatch. The guest remains trusted code in
the same trust class as `bash`. Sandboxing is explicitly out of scope here and
may be added later through a separate runtime or OS isolation capability.

The work has three goals:

1. Make the current sequential implementation correct and predictable.
2. Make Fabric programs substantially easier to write through generated,
   input-typed Nim wrappers.
3. Add concurrency, durable agents, and richer workflow facilities only after
   the underlying execution path is reliable.

Implementation progress on `feat/fabric-reliability`:

- [x] persistent bounded frame buffering and executor cleanup;
- [x] scoped nested leases, including Fabric calls after `agent_run`;
- [x] private session context stripped from targets and public events;
- [x] trusted-guest wording aligned with the actual boundary;
- [x] monotonic deadline propagation and complete bounded schema validation;
- [x] source, strings, call, frame, log, result, artifact, and OS limits;
- [x] transport cancellation: resolved by deferral — NATS request/reply has
  no cancel semantics; kill-on-timeout remains the only stop (documented in
  `research/FABRIC.md`), revisited with durable workers;
- [x] generated input-typed Nim wrappers and catalog pinning;
- [x] approval manifests: source digest, viewable source artifact, selected
  tools and budgets at the gate; digest-keyed persisted auto-approval;
- [x] agent lifecycle: `agent_steer` removed (unreachable during synchronous
  runs; returns with durable workers), fail-closed lineage, interactive-caller
  propagation to child approvals, child LLM failures reported as failures,
  idle runner retirement. Lineage-record cleanup lands with a conversation
  deletion surface (none exists yet);
- [ ] bounded concurrency, durable agents, and structured observability.

## Usage model

Fabric is a context firewall and deterministic orchestration mechanism, not a
replacement for the normal agent loop.

| Situation | Mechanism |
| --- | --- |
| One tool call or one shell pipeline | Direct tool |
| Known sequence involving several heterogeneous tools | Fabric |
| Large intermediate results that should not enter model context | Fabric |
| Per-step interpretation or uncertain exploration | `agent_run` |
| Deterministic evidence collection followed by judgment | Fabric with a final `agent_run` |
| Independent parallel research or a multi-agent council | Later Fabric concurrency and durable agents |

Programs should:

- discover target schemas before execution;
- select a small, explicit set of tools;
- inspect result-level `ok` and `exit_code` fields rather than assuming a
  result envelope means operational success;
- pass dynamic and large values through `strings`;
- return compact structures such as `{status, coverage, failures, result}`;
- set deliberate call and time budgets;
- treat mutations as sequential and compensatable, not atomic.

The existing routing guidance in the `fabric` and `agent_run` tool descriptions
is authoritative. A short system-prompt mention may improve discovery, but it
is not a prerequisite for this plan.

## Phase 1: correctness and governance

These changes precede new capability work.

### 1. Preserve framed input

`readFramed` currently allocates a fresh buffer for each call. If one OS read
contains multiple newline-delimited frames, the unread frames are discarded.

Replace it with persistent per-process framing state:

- retain bytes after the first newline for the next read;
- cap individual frames and the retained buffer;
- reject malformed or oversized frames explicitly;
- test coalesced log, request, and result frames;
- centralize selector, stream, and child cleanup in `defer` blocks;
- terminate, reap, and close the child on every error and timeout path.

### 2. Make session leases scoped

The session runner currently stores one mutable lease. A nested
session-context call such as `agent_run` replaces the Fabric program's lease,
so later calls from the outer program fail.

Use stack semantics in `dispatchToolCall`:

1. Save the previous lease.
2. Install a fresh lease for the session-context dispatch.
3. Restore the previous lease in a `defer` block.
4. Clear all leases at turn completion as today.

This permits a root Fabric program to call `agent_run` without invalidating its
own capability, while retaining the existing depth and recursion rules.

### 3. Keep private context private

`__session` is transport context, not a tool argument. It must not reach target
components, approvals, transcript events, or model-visible results.

For every dispatch:

- clone model-authored arguments before adding private fields;
- validate the lease and any Fabric snapshot metadata;
- remove private fields before schema validation and approval;
- dispatch only the cleaned argument object;
- publish the original public arguments in session events.

The same rule applies to future fields such as catalog fingerprints,
deadlines, and cancellation identifiers.

### 4. Use one absolute deadline

Before this milestone, the bridge used a fixed 120-second nested timeout even
when the target schema or remaining program time differed.

At Fabric admission, calculate one monotonic absolute deadline. Every nested
call receives:

```text
min(target schema timeout, remaining program time)
```

The implementation must:

- clamp caller-supplied `timeoutMs` to the outer Fabric dispatch limit;
- reject non-positive and unreasonable budgets;
- stop admitting calls after the deadline;
- terminate the guest when the deadline expires;
- prevent an approval completed after expiry from starting a late side effect;
- add explicit cancellation propagation when the transport supports it.

### 5. Validate complete input shapes

Required-field checks are not sufficient. Nested admission should validate the
JSON Schema subset Niffler publishes:

- root object shape;
- required properties;
- string, integer, number, boolean, object, and array types;
- array item types;
- enums;
- numeric and collection bounds;
- `additionalProperties: false`;
- bounded recursion and schema size.

Malformed `argsJson` must return a clear error rather than silently becoming
an empty object. Typed wrappers improve authoring but never replace host-side
validation.

### 6. Bound all guest-controlled data

Add limits for:

- source bytes;
- total `strings` bytes and entries;
- `maxCalls` and `timeoutMs` ranges;
- request and response frame bytes;
- log event count and bytes;
- final result bytes;
- artifact count and retained bytes;
- CPU, address space, file descriptors, and child processes where portable.

Artifacts need quotas, expiry, cleanup, safe creation permissions, and stable
IDs rather than unbounded paths alone.

### 7. Keep the threat model explicit

Fabric remains a trusted guest. Source linting is policy guidance and defense
in depth, not a security boundary. The child shares the host UID, filesystem,
network namespace, and working directory.

Documentation and tool descriptions must use `guest`, `executor`, or
`trusted guest`, not imply that the current VM is a sandbox. Future sandboxing
may use QuickJS, WASM, a restricted Nim VM, or OS isolation, but is a separate
capability and milestone.

### 8. Make approval useful for programs

Approval should show more than a truncated argument string. A Fabric approval
view should include:

- the full source through a viewable artifact;
- a source digest;
- selected tools;
- call, time, output, and agent budgets;
- whether selected tools can mutate state;
- the catalog snapshot fingerprint.

Session-wide auto-approval keyed only by the name `fabric` is too broad.
Program approval should remain per invocation or be keyed by source digest and
capability manifest.

### 9. Repair agent lifecycle semantics

`agent_steer` cannot normally run while synchronous `agent_run` occupies the
agent component's serialized handler, and the child ID is unavailable until
completion.

Until durable workers ship, either remove the misleading steering tool or
expose steering through a path that remains responsive during the run. Also:

- fail closed when lineage cannot be persisted or read;
- propagate the original interactive caller to child approvals;
- report child LLM failures as failures, not successful text replies;
- retire idle child runners and clean up lineage records with conversations.

## Phase 2: input-typed Nim wrappers

### Design principle

The Nim SDK already performs:

```text
Nim proc signature -> JSON Schema + argument decoder
```

Fabric will perform the inverse at guest compilation time:

```text
runtime JSON Schema -> generated Nim wrapper procedures
```

Normal Nim macros run at build time, but `nimeval` compiles each guest at
invocation time. A macro can therefore receive a selected schema snapshot as a
static JSON string and generate wrapper AST immediately before execution.

The wrappers are advisory and ergonomic. Core remains authoritative for
schema validation, approval, timeout, routing, and effects.

### Invocation contract

Add an optional selected-tool list to `fabric`:

```json
{
  "tools": ["grep", "git_diff", "bash"],
  "code": "let hits = tools.grep(...)"
}
```

Typed mode resolves and pins only the selected tools. Benefits include:

- a small generated API and faster compilation;
- a clear approval capability manifest;
- compile-time checking of common argument mistakes;
- an execution allowlist;
- deterministic catalog pinning.

Legacy programs may continue using `callTool`. In typed mode, `callTool` must
reject tools outside the selected set.

### Macro module

Add `components/fabric/fabricguest/fabricmeta.nim` containing:

- `FabricTools`, the method-call receiver;
- `tools`, its singleton value;
- `FabricArg[T]`, the omitted-versus-present argument wrapper;
- an implicit converter from `T` to `FabricArg[T]`;
- JSON encoding helpers shared by generated wrappers;
- the `fabricTools` macro that parses schemas and emits procedures.

The executor evaluates an internal prelude before model-authored code:

```nim
import fabricmeta

fabricTools("""[
  {"name": "grep", "schema": {...}},
  {"name": "git_diff", "schema": {...}}
]""")
```

The original program can then write:

```nim
let hits = tools.grep(
  pattern = "sessionContext",
  path = "core",
  glob = "*.nim",
  max_results = 50)

let diff = tools.git_diff(
  path = "components/fabric",
  stat = true)
```

The macro emits AST rather than source strings. This avoids code injection
through tool names, property names, and descriptions and gives generated code
normal Nim diagnostics.

### Optional arguments

Schemas usually state whether a property is required but do not carry the
component's actual default. Fabric does not need that default.

Use a present-value wrapper:

```nim
type FabricArg*[T] = object
  present*: bool
  value*: T

converter toFabricArg*[T](value: T): FabricArg[T] =
  FabricArg[T](present: true, value: value)
```

A generated optional parameter uses an empty `FabricArg[T]` as its default.
The converter makes explicit values natural at the call site. The wrapper
serializes only present values, preserving the distinction between omission
and explicit `false`, `0`, or `""`. Omission lets the target component apply
its own default unchanged.

Conceptually, `grep` becomes:

```nim
proc grep*(
  tools: FabricTools,
  pattern: string,
  path: FabricArg[string] = FabricArg[string](),
  glob: FabricArg[string] = FabricArg[string](),
  max_results: FabricArg[int] = FabricArg[int]()
): JsonNode =
  var args = newJObject()
  args["pattern"] = %pattern
  if path.present: args["path"] = %path.value
  if glob.present: args["glob"] = %glob.value
  if max_results.present: args["max_results"] = %max_results.value
  result = parseJson(callTool("grep", $args))
```

The first receiver parameter enables `tools.grep(...)` through normal Nim
method-call syntax without generating a module file per execution.

### Schema-to-Nim mapping

The first version deliberately supports a small, reliable subset:

| JSON Schema | Nim type |
| --- | --- |
| `string` | `string` |
| `integer` | `int` |
| `number` | `float` |
| `boolean` | `bool` |
| scalar array | `seq[T]` |
| object | `JsonNode` |
| mixed or complex array | `JsonNode` |
| unsupported union, `$ref`, or recursive shape | `JsonNode` |
| required property | `T` |
| optional property | `FabricArg[T]` |

String enums remain `string` initially, with allowed values in generated API
documentation. Host validation enforces the enum. Nim enums can be added later
when sanitization and exact string round-tripping are specified.

Wrappers return `JsonNode` in this phase because Niffler's registration
contract currently publishes input schemas only.

### Names and collisions

Nim identifiers are style-insensitive, while wire names are exact. The
generator must account for:

- hyphens and other non-identifier characters;
- names beginning with digits;
- Nim keywords such as `method`;
- collisions such as `foo_bar` versus `fooBar`;
- two raw names that sanitize to one Nim name.

Rules:

- preserve exact raw tool and JSON property names in generated bodies;
- sanitize only the Nim-facing identifiers;
- use backticks for keywords where valid;
- compare identifiers with Nim's style-insensitive semantics;
- omit ambiguous wrappers and report them explicitly;
- retain allowlisted `callTool` as the fallback.

Generated API metadata should report raw-to-Nim mappings, signatures, degraded
types, and omitted collisions.

### Selected schema query

Add a bounded catalog operation:

```json
{"op": "schemas", "tools": ["grep", "git_diff", "bash"]}
```

It returns normalized, non-hidden schemas:

```json
{
  "tools": [
    {
      "name": "grep",
      "component": "grep",
      "version": "0.1.0",
      "schema": {},
      "fingerprint": "..."
    }
  ]
}
```

The operation must:

- resolve exact globally unique tool names;
- reject unknown and hidden tools without leaking hidden names;
- normalize every schema;
- include owner component and version;
- produce a stable canonical fingerprint;
- cap tool count, schema depth, and total returned bytes.

The Fabric component requests this snapshot once before spawning the executor.
It filters recursive and internal surfaces already forbidden by nested
admission.

### Catalog pinning

Each bridge call privately carries the selected tool's expected owner and
schema fingerprint. Nested admission compares these with the live catalog
before dispatch. A mismatch fails with an actionable catalog-changed error and
the private metadata is stripped before approval and target dispatch.

This prevents one program from compiling against one component version and
calling a replacement with different semantics midway through execution.

### Model-facing discovery

A separate `fabric_api` tool is optional for the first version. The model
usually already has target schemas through its direct tool list or a preceding
`discover` call, and wrapper syntax follows a deterministic rule:

```nim
tools.<tool_name>(required = value, optional = value)
```

If naming transformations or degraded schemas prove confusing, add an
on-demand `fabric_api {tools}` tool returning exact generated signatures,
raw-to-Nim mappings, the catalog fingerprint, and omitted wrappers.

### Component language independence

Input wrapper generation depends on the wire JSON Schema, not component source
language. Nim, Go, and TypeScript components all register the same schema, so
their input wrappers are equally straightforward. Manually weak schemas simply
produce weaker or `JsonNode` arguments.

Output typing is separate and language-sensitive because the catalog currently
has no output schema. Add it later as an optional registration field:

1. Keep all initial wrapper results as `JsonNode`.
2. Extend registration with optional `outputSchema`.
3. Let the Nim macro derive scalar and explicitly typed return schemas where
   possible.
4. Let Go and TypeScript SDKs accept explicit output schemas.
5. Generate typed guest results only when a trustworthy output schema exists.

## Phase 3: model teaching and examples

Replace the current examples with cases where Fabric has a clear advantage
over one direct tool or shell pipeline.

### Search matrix

Run several bounded searches, parse each result, retain compact evidence, and
return coverage and previews rather than every raw result.

### Edit, verify, compensate

Apply an exact edit, run a focused check, and call `undo_last_edit` if the check
fails. Document that this is compensation, not a transaction: verification may
have external effects and rollback can become stale.

### Release gate

Combine `git_status`, compact `git_diff`, focused tests, and generated-file or
version checks. Return only named checks, pass counts, and bounded failures.

### Evidence then judgment

Collect deterministic evidence with typed wrappers, then make one final
`agent_run` call to interpret it. After scoped lease restoration ships, the
program may continue with more calls, but result reduction should remain local.

### Partial-success batch

Process a bounded inventory with per-item outcomes:

```json
{
  "status": "partial",
  "coverage": {"requested": 20, "completed": 17},
  "failures": [],
  "result": {}
}
```

Retry only failed items. Never rerun successful work merely because coverage
is partial.

The actual example files must be compiled and executed by tests rather than
duplicated as similar strings in test-only components.

## Phase 4: bounded concurrent calls

Independent reads benefit from parallelism, but guest-level async is not
required initially. Add a host-backed batch primitive:

```nim
let results = tools.batch(@[
  request("grep", ...),
  request("git_status", ...),
  request("git_log", ...)
], concurrency = 3)
```

The Fabric parent can issue several NATS requests with separate inboxes and
pump them from one serialized event loop. No callbacks or threads are needed.

Initial rules:

- require an explicit concurrency cap;
- parallelize approval-free reads first;
- serialize mutations and approval-gated calls by default;
- account for calls before launch so concurrent branches cannot overshoot the
  budget;
- preserve input order in returned outcomes;
- represent each result as success or failure rather than aborting unrelated
  calls;
- apply the one absolute execution deadline to every branch.

Effect declarations and conflict detection may be added later. They are not
required for a useful read-only batch primitive.

## Phase 5: durable agent jobs

Synchronous `agent_run` remains useful for one bounded judgment task, but
background work and steering require worker processes plus durable state.

Add:

- `agent_spawn` returning a job and child session ID immediately;
- `agent_status` as a non-blocking durable lookup;
- `agent_wait` for workflows that need the result;
- `agent_stop` with process and LLM cancellation;
- steering addressed to a known live child;
- terminal completion and failure events;
- store-backed job status and final results so late waits cannot miss them.

Agent requests should support:

- model and reasoning selection;
- tool allowlists;
- call, token, and time budgets;
- structured output schemas;
- canonical working directories;
- optional isolated Git worktrees;
- explicit parent lineage and depth;
- original interactive caller propagation.

Fabric can then implement bounded councils, map/reduce research, and verifier
workflows without making those special core primitives.

## Phase 6: observability and retention

Emit correlated lifecycle events:

```text
ev.fabric.started
ev.fabric.call.started
ev.fabric.call.done
ev.fabric.done
ev.agent.started
ev.agent.done
```

Events carry bounded metadata:

- run, session, and parent IDs;
- sequence number;
- selected tool and component;
- start time and duration;
- success, failure, timeout, or cancellation;
- result size and artifact reference;
- call and agent budget usage.

Add a Fabric-specific UI activity card showing source approval, selected tools,
progress, nested calls, child agents, budgets, compact results, and artifacts.
Logs and traces need retention limits and cleanup; they are diagnostic records,
not a claim of durable audit unless backed by a durable store.

## Testing plan

### Framing and process lifecycle

- multiple frames delivered by one OS read;
- multiple `logg` calls followed immediately by `finish`;
- oversized and unterminated frames;
- malformed JSON frames;
- child compile failure, runtime failure, timeout, and early exit;
- selector, descriptor, temp-file, and child-process cleanup.

### Lease and private context

- Fabric call, nested `agent_run`, then another Fabric call;
- stale and cross-session leases;
- nested private fields absent from target arguments;
- private fields absent from approvals and session events;
- tool reload during a pinned run;
- schemas with no required properties;
- complete schema type and bound validation.

### Wrapper generation

- required and optional scalar properties;
- explicit `false`, `0`, and empty string versus omission;
- scalar arrays;
- object and unsupported-shape fallback to `JsonNode`;
- enum documentation and host enforcement;
- Nim keywords and invalid identifiers;
- style-insensitive name collisions;
- oversized, deeply nested, and recursive schemas;
- wrong named argument and wrong scalar type compile errors;
- exact raw JSON keys after identifier sanitization;
- hidden, internal, unknown, and unselected tool rejection;
- schemas from Nim, Go, and TypeScript registrations;
- catalog fingerprint mismatch;
- wrapper results remaining `JsonNode` without `outputSchema`.

### Agents, approval, and deadlines

- real directed approval routing from parent through child;
- approval denial and expiry;
- no side effect after execution deadline;
- in-flight steering before child completion;
- child failure represented as failure;
- lineage-store failure closes spawning;
- durable wait both before and after job completion;
- cancellation and runner retirement.

### Examples

- compile and execute every checked-in example file;
- assert compact result contracts and partial-success semantics;
- ensure examples do not depend on duplicated test-only source strings.

## Recommended implementation order

1. Persistent framing and unconditional process cleanup.
2. Scoped leases and private-context stripping.
3. Absolute deadlines, full validation, and bounded data.
4. Trusted-guest wording and improved approval manifests.
5. Selected schema lookup and catalog fingerprints.
6. `FabricArg`, `FabricTools`, and schema-driven wrapper macro.
7. Selected-tool enforcement and typed examples.
8. Host-backed bounded batch calls.
9. Durable agent workers and usable steering.
10. Structured lifecycle events, UI, and retention.
11. Optional output schemas and typed results.
12. A separate sandboxing milestone if and when untrusted guests are required.

This order first makes the shipped mechanism dependable, then exploits Nim's
runtime metaprogramming for a small and natural typed API, and only afterward
adds the concurrency and durable orchestration features that increase the
system's operational complexity.
