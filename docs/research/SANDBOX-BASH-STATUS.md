# Bash guard + read scope — current status

Implemented on `feat/sandbox-implementation`, not merged or enabled by default.
Linux bwrap integration plus tool read-scope enforcement for `read` and `grep`;
Seatbelt remains unimplemented. This is a scoped opt-in increment, not
completion of the plan.

## Read scope (tools, not just commands)

A shell guard constrains a COMMAND through a mount policy. It cannot constrain
an in-process reader, so the same masked paths are also consulted by readers
via `sdk/niffler/readscope.nim` — one policy, one spelling, shared so two lists
cannot silently disagree:

- `read` (edit) refuses a masked path with `[E_MASKED]`, at the single place the
  component reads a file for display, so every argument shape (`path`,
  `reads[].path`, `windows[]`, glob-selected items) is covered by construction.
  Symlink aliases are refused too: the comparison is on canonical paths.
- `read`'s MUTATION path refuses as well. An edit necessarily reads the old
  bytes and its diff would echo them back.
- `grep`/`files` filter results through one funnel (`finish`), because argument
  checks are insufficient: `path` legitimately points at the workspace, and a
  traversal rooted there reaches masked files no argument names. `files` is
  covered too — a masked file's *name* is part of what masking hides.

Honest limits, stated rather than implied:

- Result filtering removes what would have been RETURNED, not what was read.
- This is a deny of declared absolute paths on canonical paths. It cannot hide a
  copy, an undeclared hard link, or the same bytes reached through a path that
  was never declared. It is a mask, not a confidentiality model.
- Relative mask entries are the shell guard's per-launch shorthand; a reader has
  no launch to resolve against, so it honours only absolute entries rather than
  guessing a workspace.
- `repomap` omits masked files from its census and checks again before
  cached-tag lookup or parsing. Both tool and auto-append map construction use
  this path; previously cached source tags cannot bypass the check.
- Skills discovery/load/audit skip masked on-disk SKILL.md files; resource
  listing/loading excludes masked resources. Baked-in bundled content is not
  an on-disk read and is not erased by a runtime mask.
- **Not yet covered**: `lsp`, `observe`, `fetch` and `builder`. LSP servers and
  compilers may read transitive inputs autonomously: checking only the named
  source file would not protect a masked dependency. They need process-level
  confinement or an explicit fail-closed policy, not just another `isMasked`.
  Observe also exposes bus payloads, not just file contents; a path check cannot
  redact previously captured secrets. Anything not listed as covered remains
  unaffected.

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

`tests/t_readscope.nim` drives the real `edit` and `grep` components over NATS
with a mask configured (a filename the policy does NOT need to know, so nothing
there depends on `.env` being special). It covers both failure shapes — a
DIRECT name (refused, policy named, symlink alias refused too) and a TRAVERSAL
that never names the file (workspace-wide search, match-all sweep, and the file
listing) — and asserts unmasked files still read and edit normally, because a
policy that denied everything would pass the denial checks while breaking the
tool. Note for future readers: an absence assertion ("does not contain X")
passes trivially when the call itself failed, so this test first proves each
tool actually answered.

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

Remaining before calling Phase 2/3 complete: guarded background integration
decision, concurrent alias/race hardening, read-scope coverage for the
in-process readers listed above, actual macOS implementation. Seatbelt has no
implementation at all yet. Guarded background execution still refuses pending
lifecycle integration.

No blanket whole-harness protection: `read` and `grep` are covered; the readers
listed as not yet covered, plus native Fabric, plugins and MCP, still bypass all
of it.

Prompt effect: existing direct schemas and frozen system prefix unchanged.
The new status tool is on-demand; discovery adds append-only history. Private
workspace context exists already. Status/refusals append ordinary tool results.
