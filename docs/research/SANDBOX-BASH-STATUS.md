# Bash guard integration — current status

Implemented on `feat/sandbox-implementation`, not merged or enabled by default.
Linux bwrap integration only; Seatbelt and tool read-scope enforcement remain
unimplemented. This is a scoped opt-in increment, not completion of the plan.

## Enable

Set these in the operator environment before starting the bash component:

```text
NIF_BASH_SANDBOX=on
NIF_BASH_SANDBOX_MASKS=/absolute/path/to/secret
```

Masks are exact existing files, one per line; relative entries resolve against
that call's primary workspace. Set `.env` to protect each workspace's top-level
`.env`; this is not an automatic recursive `.env` search. Missing configured
paths refuse rather than omit protection. Symlink masks resolve to the canonical
regular file; reads through that symlink and the canonical spelling are tested.
Files with multiple hard links refuse before user code runs: masking one name
would leave another readable. Concurrent alias creation/path replacement and
secret copies remain outside the current guarantee; no complete confidentiality
claim is made.

Session calls receive a workspace root through existing runner-owned private
context. Direct operator calls need `NIF_BASH_SANDBOX_ROOT`. A cwd does not
establish workspace authority. The bus is still trusted-local; manually forged
private context is not authenticated. Only the primary workspace is writable,
not every automatically discovered sibling checkout.

## Current behavior

- System bwrap: read-only host root, writable workspace, private tmpfs `/tmp`,
  fresh `/proc`, minimal `/dev`, isolated network, dropped capabilities.
- Child environment is cleared and sets only fixed PATH, HOME, TMPDIR, LANG.
  User toolchains outside system PATH may require a future explicit allowance.
- Arbitrary host reads remain possible except explicitly masked paths. This
  is **not** a workspace-only filesystem view or chroot.
- Background calls refuse until startup evidence and lifecycle integrate with
  the processes component. Benchmark container-map combination also refuses.
- Requested masks refuse under Landlock; a degraded backend must never silently
  ignore them. Landlock without masks remains a separate opt-in prototype.
- Existing off-mode execution is unchanged. Guarded timeout still reports 124;
  tested descendants do not survive timeout.
- `sandbox.state` is `applied` when the ACTUAL launch acknowledged. A bootstrap
  inside the real bwrap invocation performs the policy checks with a **negative
  test that would succeed unsandboxed** plus a workspace-writable positive
  control, writes an acknowledgment line to its stdout, closes nothing further,
  and only then execs the user command. The parent consumes exactly that line
  and forwards the command's remaining output byte-for-byte, so the user
  command cannot spoof the marker, suppress it, or have its output rewritten.
  No acknowledgment means the command never started: exit 125, `applied:false`.
  (This host's bwrap has no `--preserve-fds`, so the marker uses stdout rather
  than an extra descriptor.)
- An earlier self-check ran a SEPARATE bwrap process and therefore could not
  attest to the real launch. It also first tested "a write at `/` must fail" —
  which fails for an ordinary user with or without a sandbox, so a backend
  confining nothing passed. `tests/t_sandbox.nim` keeps both as permanent
  regressions: a non-confining fake bwrap, and a fake that skips the bootstrap.
- Honest limit: the system bwrap and `/bin/sh` bootstrap are trusted. This is
  not attestation against a malicious backend or arbitrary same-user host code.

## Verification

`tests/t_bash_guard.nim` exercises actual NATS calls: alternating A/B/A roots,
configured secret masking, provider-env stripping, cross-workspace write denial,
timeout/descendant teardown and missing-root/background refusals. It is picked
up by `make test-server`. `make test-sandbox` covers the helper separately.

Availability and policy probes now have 5-second bounds with process-group
teardown. `bash_sandbox_status` is an on-demand read tool: it distinguishes
configured/off from backend availability and warns that neither attests to the
actual launch. Guarded tool text also renders the policy-check limitation.

Cancellation-specific and spill regressions now pass through the real bash
component: cancel returns 130 and descendants cannot perform a delayed write;
large output remains capped and the trusted parent preserves its full spill.
Self-check writes use a random owned workspace directory, never a fixed user
filename. Status records also use a private random directory, not predictable
shared-temp filenames.

Remaining before calling Phase 2 complete: guarded background integration
decision, concurrent alias/race hardening, actual macOS implementation.
Seatbelt has no implementation at all yet. Guarded background execution still
refuses pending lifecycle integration.
No blanket whole-harness protection: `read`, grep traversal, native Fabric,
plugins and MCP need their own enforcement paths.

Prompt effect: existing direct schemas and frozen system prefix unchanged.
The new status tool is on-demand; discovery adds append-only history. Private
workspace context exists already. Status/refusals append ordinary tool results.
