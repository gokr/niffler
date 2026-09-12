# SANDBOX-PLAN — a small, honest first release

Status: **revised plan; nothing implemented**, branch `feat/sandbox`, worktree
`~/git/niffler-sandbox`. This revision supersedes the implementation decisions
in [SANDBOX.md](SANDBOX.md) and the original version of this plan. The research
is useful background, not an implementation specification.

**Recommendation: first ship opt-in shell write protection, not a new security
framework.** Use the same small launcher on Linux and macOS, leave the shared
bash component trusted, and restrict each command to its resolved workspace.
Add one-shot path grants next. Component-wide ceilings and hostile-code
containment are separate decisions, not prerequisites for this limited feature.

## 1. Scope: what we promise, and what we do not

The first release reduces accidental filesystem damage by shell commands and
their descendants. It is **not containment of a malicious agent or component**.

| Property | First release |
|---|---|
| Direct filesystem mutations by the launched command | Restricted to approved workspace, private scratch directory and explicit writable roots, within the backend's tested guarantees |
| Filesystem reads | Unrestricted; this does not protect secrets stored in readable files |
| Network | Unrestricted; no domain filtering or claim of exfiltration prevention |
| Child environment / inherited descriptors | Explicit allowlists, not the harness's full environment and descriptor set |
| Other tools and components | Unchanged; file tools, builder, plugins and MCP can still have broader authority |
| NATS bus | Existing trusted-local deployment; neither caller names nor hidden tools are authentication |
| Modified workspace programs/configuration | Still untrusted inputs when later executed elsewhere; no protection for future unconfined launches |

This limited scope is useful, but must be visible in documentation and tool
results: **"shell write protection"**, not "the agent is sandboxed".

For genuinely untrusted code, use a disposable VM or carefully configured
container now (§8). Do not wait for a large NATS authorization project before
providing either that deployment option or the limited local guard.

### Corrections to the earlier proposal

- `bash` is a shared service; calls carry different session ids and `cwd`
  values (`components/bash/main.nim`). One startup policy cannot isolate
  several workspaces unless it grants their union. Per-command confinement
  is therefore necessary for workspace-specific limits.
- The supervisor is a useful lifecycle boundary, not the only execution path:
  components themselves launch commands, compile code and perform file I/O.
  `edit`, `builder`, `plugins`, `logfile` and the store write files directly.
- `docs/WIRE.md` calls `caller` a **self-declared routing hint, not an auth
  claim**. The local NATS launch in `core/niffler.nim:spawnNats` does not
  configure per-component subject permissions. Shell access to the bus can
  bypass filesystem restrictions by requesting work from a broader service.
  Removing bus variables is hygiene, not prevention of that access.
- Landlock TCP rules are port-based, not host/domain rules or a complete
  network firewall. A bwrap network namespace cannot retain access to the
  host's loopback bus without additional plumbing. Neither is needed in v1.
- Landlock rules only tighten inherited restrictions. A process cannot widen
  its own ceiling. Keeping the bash service trusted lets it launch separately
  restricted invocations without a new privileged core execution API.

## 2. Keep policy small

Proposed startup setting: `NIF_BASH_SANDBOX=off|on`, initially **off**.
When on, failure to apply the requested guard prevents that command from
starting. No automatic unconfined fallback and no per-call model-controlled
"off" switch. The harness itself remains available to explain the failure.

Only two configuration states are needed. `probe` is a diagnostic command,
not a third "sometimes secure" execution mode. Default-on is a later rollout
decision after cross-platform testing and dogfooding.

Each launch resolves one immutable request:

```text
workspace: canonical existing directory
cwd: canonical existing directory inside workspace or an approved root
writeRoots: explicit canonical existing directories (empty normally)
scratch: newly created private directory for this invocation
env: explicitly selected child environment
argv: exact executable and arguments (bash -c keeps its existing semantics)
```

- Workspace authority comes from the stored conversation workspace, not an
  arbitrary `cwd` argument. For direct CLI calls, use an operator-configured
  workspace; reject guarded calls without an authoritative root. Cache a
  session's immutable root if useful. This uses the existing trusted bus
  model, not a new claim that session ids are authenticated.
- Resolve paths at launch, reject malformed paths, and define symlink
  behavior in tests. Do not implement a generic policy lattice, deny-list
  language, glob rules or `none < read-only` privilege ordering.
- First allow only existing directory grants. New files can be created below
  an allowed directory. Exact-file grants and nonexistent grant roots are
  deferred: rename-based atomic saves otherwise make their semantics tricky.
- A grant for a directory includes its descendants; the UI must say so.
  Path normalization alone is not a defense against concurrent symlink or
  directory replacement. Backend lookup behavior and known race limits
  must be tested and documented; reject unsupported cases rather than claim
  stronger guarantees.
- Do not grant all of `/tmp`, `$HOME` or `NIF_ROOT/var` for convenience. Use
  private per-call scratch/cache locations and preserve output spilling in
  the trusted bash service.

The launcher consumes a bounded request through a private inherited pipe/FD,
not an agent-writable policy file. It closes that FD before running user code.
A human-readable audit copy may be stored separately; it is not authority.
On macOS, if the backend needs a profile file, securely create it outside
writable roots and retain it only for the required startup lifetime.

## 3. PR 1 — launcher and real enforcement tests

Suggested files (names may be adjusted during implementation):

- `sandbox/policy.nim`: the small launch policy, parsing and path validation.
- `sandbox/landlock.nim`: Linux filesystem backend and ABI detection.
- `sandbox/seatbelt.nim`: macOS profile generation and availability checks.
- `sandbox/main.nim`: `var/bin/niffler-sandbox`, launch/probe commands and
  startup-report protocol. A helper executable, not a NATS component.
- `tests/t_sandbox.nim`: policy, enforcement and inheritance checks.
- `niffler.nimble`, `Makefile`: build/test targets and incremental dependencies.

Do not add a bwrap stub or several backend-selection layers. Landlock on
Linux and Seatbelt on macOS are the two candidates. Reuse reviewed reference
patterns where licensing permits; do not promise a line count. If either
backend needs excessive compatibility machinery, stop and compare the
existing-wrapper alternative in §8 before expanding the implementation.

### Backend requirements

**Linux:** detect the available Landlock ABI, not just the kernel version.
Define and test the minimum ABI that supports the promised write protection,
including truncation, creation, removal and rename/link behavior. Older ABIs
must not silently lose a required restriction. Account for file descriptors
opened before restriction; close unnecessary inherited FDs. Read protection,
TCP policy and newer optional Landlock features are not part of v1.

**macOS:** probe actual `sandbox-exec` availability and the generated profile.
Permit the runtime reads and execution needed by the command, but only the
specified writes and explicitly required sinks such as `/dev/null`. Escape
profile strings correctly. No hostname filtering claims or hardcoded NATS
port exceptions. The launched shell has no legitimate need for a bus socket,
although v1's unrestricted network does not prevent opening one.

### Startup evidence

Use a dedicated launcher-to-parent channel, separate from stdout/stderr, with
a launch id, policy digest, backend and outcome. Distinguish application
failure, executable-start failure and the command's own exit code. A command
can itself exit 125; that status alone is not a sandbox diagnosis.

The backend must document how it verifies policy application during the
actual launch, not just an earlier probe. Where a wrapper prevents direct
acknowledgment, use a minimal restricted bootstrap/exec-status protocol and
prove its failure behavior. Do not treat a self-reported log line as evidence
against malicious same-user code; the trusted-component scope still applies.

### Tests that demonstrate a restriction

Use two temporary sibling directories owned by the test user: `allowed` and
`outside`. First prove the unsandboxed process can mutate both. Then verify:

- creation, overwrite, truncate, rename, unlink and child-process writes are
  denied outside and behave as documented inside;
- symlinks pointing outside do not become write escapes; link/rename edge
  cases and policy-string injection are covered;
- a requested policy that cannot be applied starts **no user command**;
- probes test a forbidden operation, not merely `/bin/true` succeeding;
- the report channel cannot be confused with command output; relevant FDs
  are closed; inherited writable descriptors do not accidentally bypass tests.

Never use `/etc` as the only negative test: Unix permissions already deny it.
Local unsupported-platform tests may skip with reasons; dedicated Linux and
macOS CI lanes must exercise enforcement, not produce an all-skipped green run.

## 4. PR 2 — integrate with bash, opt-in

Keep process execution and output handling in the bash component. Review its
`runCmd` implementation and SDK process helper before changing launch: preserve
cancellation, timeouts, process-group teardown, output bounds and spill files.
Do not confine the shared bash service itself in this PR.

- `components/bash/main.nim` and its execution helper: launch the guard for
  each enabled invocation, using the immutable workspace and launch request.
- Construct an environment allowlist: required platform variables, reviewed
  executable search paths and a minimal locale/toolchain set. Do not forward
  provider keys, NATS credentials/URLs, loader-injection variables or agent
  sockets by default. Any extra forwarding is operator-configured and shown
  in diagnostics without printing values. Readable files can still contain
  the same secrets: sanitizing env is not confidentiality isolation.
- Preserve trusted-parent logging/spilling. Avoid opening arbitrary output
  files outside approved roots before applying the guard.
- Return a small structured `sandbox` field alongside existing result fields:
  scope `shell-write`, backend, applied/failed/off state and policy digest.
  Keep existing `text` rendering; necessary limitations and failure guidance
  must appear there because machine-only fields do not reach the LLM.
- Provide an on-demand read-only diagnostic such as `bash_sandbox_status` in
  the bash component. Core `doctor` integration is optional, not a dependency.
- Update `docs/MANUAL.md` and `docs/WIRE.md` for any added result or private
  context fields. Keep `sdk/envelope.nim` pure JSON; no backend imports there.

Acceptance: alternate calls from two sessions through the same bash process;
workspace A must not become writable for B merely because A ran first. Test
`cwd` overrides, direct CLI behavior, timeout/cancel, process descendants and
unchanged off-mode behavior. No manifest changes or store schema migrations.

**Prompt effect:** tool schemas remain frozen for existing conversations.
Status and denial guidance enter append-only tool results. Any later optional
schema addition applies at normal conversation/tool-exposure creation; do not
assume denial text can add an argument to an already frozen schema.

## 5. PR 3 — outside-path access, without a permissions framework

### Simplest initial route

Let the human configure a short list of additional writable directories at
startup, outside agent-controlled project configuration. Resolve that list
once in the trusted service. No approval cache, grant store, hidden execution
API or new UI is necessary. Restart to change the list. Document that these
roots apply to every guarded invocation using that service, not just one
conversation. Prefer one-shot grants when that scope is too broad.

### Preferred next increment: one-shot grants

Allow a bash invocation to **request** additional writable directories plus a
reason. Reuse the approval UI transport, but add a separate grant-purpose
check; do not reuse blanket tool/conversation auto-approval semantics.

Approval is bound to the exact command/argv, cwd, workspace, normalized roots,
relevant environment configuration, session/call identity and a short expiry.
Consume it once for this launch; discard it on cancel, restart or timeout.
The UI shows the actual requested access and warns that a prior failed run
may have partially completed. `NIF_AUTO_APPROVE=1` and a conversation's ordinary
"auto-approve tools" setting must not silently authorize extra sandbox rights.

Under the v1 trusted-component assumption, authorization remains central and
the trusted bash service performs the approved launch. The exact transport
binding must be specified and tested before shipping this increment. A
self-declared bus caller or an LLM-supplied approval boolean is not proof.
If that binding needs broad core/SDK changes, ship operator-configured roots
first rather than introduce a generic `sandbox_exec` privilege gateway.

An `EACCES`/`EPERM` or stderr string is only a **possible** sandbox denial.
Do not invent the denied path or automatically rerun commands. Preserve the
original outcome and let the model/human explicitly request a new execution.
Approval never promises rollback or idempotency.

Deferred: session/project remembered grants, exact-file grants, secret-read
exceptions, endpoint grants and full unconfined one-shot escapes. A user can
explicitly restart with guarding off when necessary; this does not weaken a
running guarded invocation.

## 6. Follow-ups, each with its own decision gate

**Component ceilings:** after command guarding works, optionally use the same
launcher from `core/supervisor.nim` for stable service-wide limits. Put reviewed
policy in boot configuration and persisted spawn records, not a component-name
switch statement in core. Retain the existing restart-policy field name; adding
`sandbox` does not require a rename. A ceiling must cover a service's legitimate
workspaces and resources; it is not per-session isolation. Grants beyond that
ceiling need a new worker launched by an authorized parent or a human restart.

**File tools and other execution:** inventory `edit`, `builder`, `plugins`,
`fabric`, `git`, MCP and direct SDK exec paths. Decide between trusted
workspace-aware handlers and isolated workers. Builder compilers and plugin
installation scripts execute untrusted code too. Do not claim complete agent
coverage until these paths and indirect requests are accounted for.

**Hostile-code containment:** separate project requiring authenticated bus
principals, scoped publish/subscribe permissions and service-side authorization
(or a narrow broker), protected grant/control state, and protection against
process/socket/credential bypasses. NATS ports are dynamic and may be remote;
monitoring is not a capability to hand to shell code. An agent-writable store
record is not a trustworthy grant database merely because core conventionally
owns that record kind.

**Self-extension:** editing the running harness's own repository can replace
future binaries, manifests and profiles. Do not pretend a blanket workspace
write grant protects that control plane. Separate deployed control state from
the editable source/build tree, or perform self-development inside an outer
VM. Operator-approved promotion of built artifacts is a distinct trust step.

Do not automatically pull these follow-ups into PRs 1–3. If strict containment
is the real requirement, compare an outer VM before adding a bespoke security
system to Niffler.

## 7. Validation and stopping rules

Each PR includes its own tests; there is no later "security tests" milestone.
Run narrow tests while developing, then `make build && make test` for core/SDK
or bus-contract changes. Follow repository build locks and isolated temporary
roots; never test against the live store. Validate on actual supported Linux
and macOS machines and document their versions/backend capabilities.

Stop and revise scope if implementation requires silent fallback, generic
privileged RPC, persistent grant authority, or pretending unimplemented network
rules exist. No day-count estimates or default-on deadline: acceptance evidence
sets the rollout pace. Success for v1 is the limited promise in §1, not the
original plan's universal component-confinement invariant.

## 8. Simpler alternative routes

| Route | Simpler because | Trade-off / when to choose |
|---|---|---|
| **Local shell write guard (recommended here)** | Two small backends, existing bash lifecycle, no new bus authorization or grant database | Limited accident protection; not malicious-code isolation |
| **Existing wrapper such as Anthropic sandbox-runtime** | Reuses filesystem/network wrapper engineering instead of maintaining all of it | Adds Node/package/platform dependencies; audit coverage and lifecycle integration, do not assume equivalent policy semantics |
| **Whole Niffler in a disposable VM** | Core, components and NATS stay together behind one outer boundary; no per-component ACL redesign | VM/image/toolchain overhead; mount only the intended project, keep host secrets/control bus outside; strongest simple deployment choice for untrusted work |
| **Whole Niffler in Docker/Podman** | Often already installed; one deployment recipe and a scoped bind mount | Shared kernel on Linux, daemon/runtime trust and writable-mount risk; never mount host Docker socket, whole home or host control bus, and avoid privileged/host-network modes |
| **Operator runs exceptional commands outside the guard** | Zero new grant API or persistent permission system | Manual interruption; a reasonable first-release escape hatch |

Gondolin, Boxlite and other micro-VM runtimes are candidates for the VM route,
not dependencies of this plan. Verify current licensing, platform support and
lifecycle APIs before selecting one; earlier notes about Boxlite's availability
were not established by the shallow repository search and must not drive the
choice. OpenSandbox-style remote execution is a deployment alternative, not
another backend we need to implement now.

**Decision:** begin with PRs 1–2 and operator-configured extra roots. Add
one-shot approvals only when dogfooding demonstrates a need. Keep component
ceilings optional, and prefer a VM/container deployment over expanding this
small write guard into a large security platform.
