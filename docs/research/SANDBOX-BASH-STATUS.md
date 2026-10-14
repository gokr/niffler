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
paths refuse rather than omit protection. Mask aliases/hardlinks and secret
copies are not yet covered; do not claim complete confidentiality.

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
- `sandbox.state` is `requested`, not `applied`: exit 125 can be the command's
  own exit, and no dedicated startup evidence FD is wired yet. No false success
  attestation is made. Availability probe still needs bounded execution and
  an enforcement test rather than `/bin/true` alone.

## Verification

`tests/t_bash_guard.nim` exercises actual NATS calls: alternating A/B/A roots,
configured secret masking, provider-env stripping, cross-workspace write denial,
timeout/descendant teardown and missing-root/background refusals. It is picked
up by `make test-server`. `make test-sandbox` covers the helper separately.

Remaining before calling Phase 2 complete: dedicated launch evidence,
`bash_sandbox_status`, cancellation-specific and spill regressions, guarded
background integration decision, mask alias tests, actual macOS implementation.
No blanket whole-harness protection: `read`, grep traversal, native Fabric,
plugins and MCP need their own enforcement paths.

Prompt effect: unchanged direct tool schema and frozen system prefix. Private
workspace context exists already. Status/refusals append ordinary tool results.
