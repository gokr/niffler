# Sandbox next slice — durable policy, uniform transport, strict Linux bash

Status: **experimental; stages A–C are not yet accepted as complete.** A
policy record, dispatch injection and strict Linux launcher exist, but the
failure paths and actual session-to-bash behavior require the milestone gate
below. Filesystem-tool and network enforcement, escape-capable tool gates, and
Seatbelt (needs a Mac) remain open. This
decomposes [PLAN.md](../PLAN.md) pillar 3 items 1 → 2 → 4 into independently
testable changes. [SANDBOX-CONVERSATION-POLICY.md](SANDBOX-CONVERSATION-POLICY.md)
owns the target policy; [SANDBOX-BASH-STATUS.md](SANDBOX-BASH-STATUS.md) owns
current behavior.

> **Review warning:** the historical stage descriptions below include claims
> not yet established by the merge gate. In particular, session-driven bash
> policy propagation, forbidden-file enforcement, read-only roots, failed
> inheritance and store outages need end-to-end evidence. Do not rely on this
> branch as a security boundary until those gaps are closed.

Implemented (stage A, `core/dispatch.nim` + `core/conversation.nim`,
contract: `tests/t_sandbox_conversation.nim`): a per-conversation policy
document (`sandboxpolicy` kind, `<session>:policy`) with revisions and
compare-and-set writes; the `session {sandbox}` human control
(`enabled`, `addRead`, `addWrite`, `remove`, `expectRev`) with the workspace
and `/` refused as removals; a human-only guard that refuses any session whose
durable `sessionmeta.parent` is set (refusing too when that lineage cannot be
read, because unreadable is not root); birth inheritance through the hidden
`sandbox_inherit` core tool; a status readback carrying the whole policy; and
`ensureWorkspace`/`addGrant`/`removeGrant` on the codec. **Nothing is confined
yet**: every readback reports `enforced: false` and `state: "configured"`, and
no component enforces it. Stage C (strict bash roots) is unstarted.

### Stage B — what now travels with a dispatch

`injectSandboxContext` sits beside `injectWorkspaceContext`, so the two
dispatch paths that already existed (the serial `dispatchToolCall` and the
parallel wave host) share ONE decision instead of two computations. Rules,
each with a contract test in `tests/t_sandbox_propagation.nim`:

- **Opt-in is data.** A tool that declares `x-harness.sandbox` in its schema
  receives `__sandbox`; one that does not receives nothing. Core keeps no
  component-name list, so a new consumer needs no core edit.
- **A caller cannot write the policy.** An incoming `__sandbox` is deleted
  before injection, so model-supplied arguments (or a forged component) cannot
  widen reach — asserted with a forged session id and a forged read root.
- **No conversation, no policy.** A direct bus call gets none: it cannot borrow
  another conversation's reach.
- **The document says what it is.** `enforced: false` is stamped where the
  document is built, not left for a consumer to infer, and an unreadable policy
  is an explicit `unreadable: true` marker rather than nil — a component must
  not meet "no policy" and take an unrestricted path.
- **Updates are visible within a bounded delay.** The snapshot is cached for
  2 s rather than for a runner's lifetime: the decision is a human's, and
  another process can change it at any time.

Note what this stage still does NOT do: no component acts on `enabled`. The
recorder fixture reports what it received and enforces nothing, which is why
the readback keeps saying `configured`.

### What stage A deliberately left open

Named so a later reader does not have to rediscover them:

- **No operator default.** There is no instance-wide "new conversations start
  sandboxed" setting. It needs an owner seam that core actually reads; a
  bash-owned config domain would be the accepted-and-ignored mirror the
  AGENTS.md rule warns about.
- **No revocation for a live child.** Inheritance is a birth snapshot, and the
  contract test asserts that a later parent change does NOT reach an existing
  child. Whether a human revoking a parent should narrow running children (and
  how a child mid-command settles first) is a lifecycle decision still open.
- **Read roots are recorded, not honored.** `addRead` writes `readRoots` and
  nothing else — in particular it does NOT enter the write fence's grant set
  (a fence synced from both would grant write for a read approval). Component
  read acceptance comes from one workspace set derived from WRITE grants, so
  making `readRoots` mean something requires that plumbing to carry a
  read/write distinction. That is stage B work.
- **`grants` stays opaque.** The codec round-trips it, nothing interprets it;
  the per-tool conditional-grant seam (stage D) is what will.
- **Bash policy support: denies are enforced, read-only roots are not.** The
  guard resolves exact-basename deny patterns to masks over the workspace and
  writable roots, and refuses unsupported patterns (globs, paths) rather than
  masking nothing. A read-only root still refuses before execution. Masking is a
  check-then-mask walk, so a denied file created after it starts, or one merely
  hard-linked elsewhere, is not covered by this slice.

### Stage C — what a confined command can now reach

`NIF_SANDBOX_STRICT`/`--reach strict` stops mounting the host root read-only and
mounts only `strictRuntimeBinds` (system executables and shared libraries), the
workspace, and the policy's **write** roots. `--reach compat` keeps the old
behaviour and is labelled as such. Measured on this host with bwrap: under
compat a command reads a file in `$HOME`; under strict that path does not exist
("No such file or directory"), and `$HOME` lists only the workspace. Both modes
still refuse writes outside the allowed set, still run with no network, no bus
and a private tmpfs, and the launcher's status file now records
`reach: strict|compat` so a result can never be read as stricter than it was.

How a conversation's decision reaches it: `__sandbox.enabled` (stage B) makes
the guard run the launcher and give it `--reach strict`, with the policy's
WRITE roots as `--allow`. A read-only approval never becomes an `--allow` (the
fence/allow conflation again, this time at the launcher boundary), and a policy
that says `enabled: false` cannot un-guard an operator who asked for
`NIF_BASH_SANDBOX=on`.

Honest limits, each a named follow-on rather than an implied gap:

- **Foreground bash only.** A guarded `run_in_background` still refuses.
- **Linux only.** Seatbelt is unimplemented, so "sandboxed" stays a Linux claim.
- **The runtime allow-list is a starting point for review**, not a settled
  answer: a toolchain under `/usr/local` or nix needs an explicit `--allow`.
- **Not the filesystem tools.** read/grep/edit/write still act under the
  workspace set, not this policy; item 3 of the pillar remains a release gate.
- **Denies are exact-path masks**, so a recursive deny rule is not expressible.
- **Check-then-open is not race-safe**; masks are a boundary against mistakes
  and ordinary probing, not a confidentiality model against a hostile process.

## Merge milestone: fail-closed foundation

Before merging, prove durable revisioned policy and child inheritance under
store read/write failure; distinct read and write roots and deny precedence;
serial, parallel, invoke and nested propagation; and an actual session-driven
foreground bash launch with positive workspace and negative host controls.
Unsupported requested restrictions must refuse before execution, never silently
run with weaker protection. Verify live on Linux and run `make build && make
test`. Status must say shell-only, not whole-conversation confinement. The user
has additionally decided sandboxed network defaults to off, with fetch and bash
permissions separate; network-capable tools are not yet governed by that target.
See [SANDBOX-CONVERSATION-POLICY.md](SANDBOX-CONVERSATION-POLICY.md).

## Outcome and claim boundary

First persist a human-controlled effective policy, then prove every dispatch
path carries the same snapshot, then enforce a restricted reachable set for
foreground Linux bash. Do not turn these into one large PR.

| Stage | Permitted claim | Not established |
|---|---|---|
| A: persistence | configured policy survives resume and is isolated per conversation | tool confinement |
| B: propagation | dispatched calls receive the authoritative policy revision | recipient enforcement or whole-conversation confinement |
| C: strict bash | this acknowledged foreground shell launch uses approved data roots plus reviewed runtime roots, private scratch and network isolation | filesystem tools, trusted infrastructure or approved unconfined tools being sandboxed |

A configured `enabled` bit is not `applied`. Whole-conversation enablement must
not be advertised as enforced until the filesystem and conditional-tool gates
also land. Fleet's sandbox verdict stays unavailable until its full contract is
met. Neither a working backend probe nor an approval proves confinement.

## Before code: authority and decisions

- **Owner:** core/session owns effective policy and update ordering; bash is a
  consumer, never the owner of a second policy mirror. An instance-scoped
  operator default can be declared through config only with a real owner seam
  that core actually reads. Config does not implement conversation-scoped
  settings. Document the default's authoritative reader before adding a setting.
- **Durability:** inspect `grantedroot` (`<session>:roots`) and `/roots` before
  choosing storage. Those documents already use the snapshot codec for write
  grants, but are not full sandbox policy. Choose one canonical record and a
  revisioned migration; do not leave `/roots` able to reset enablement, denies
  or read-only grants. A header reference is acceptable; a best-effort header
  write is not sufficient for a security decision. Persistence must succeed
  before live activation; conflicting updates must not overwrite each other.
- **Human control:** use an operator/client-control path, not authority inferred
  from model-supplied arguments. Config's `humanOnly` rejects child sessions but
  permits root conversations; that alone does not distinguish a human from the
  model acting in a root conversation. Neither ordinary auto-approval nor a
  forged private field may widen this policy through session dispatch. The bus
  remains trusted-local, not authenticated against malicious components.
- **Review before stage C:** exact runtime roots, symlink layout, private scratch,
  deny-rule matching and legacy compat behavior. No blanket home, `/etc`,
  harness-state or host-root bind as a shortcut for a missing toolchain. Extra
  user toolchains are explicit read allowances, not automatically discovered.
- **Inheritance decision:** the target document has both creation-snapshot and
  continuation/revocation requirements. Resolve later parent updates explicitly
  before implementing continuation. Until then, do not certify child revocation
  or let a continued child silently keep wider rights. Creation inherits policy
  AND active conversation-wide grants; one-call grants do not inherit.

## A — persist and resume, with a human update seam

Start with the existing pure `sdk/niffler/sandboxpolicy.nim` codec and contracts.
Resolve the initially-off operator default once for a new conversation. Resume
uses durable state, not the current default. Separate read/write allowances;
retain deny rules when granting a root. Discovery of sibling trees and a tool's
cwd are not sandbox grants. Preserve existing sandbox-off workspace behavior.

Updates are revisioned, persisted before activation and applied between tool
calls. An in-flight command retains its immutable launch policy; an unknown
transport outcome is not proof it stopped. For parallel batches, settle or
cancel/confirm the affected in-flight calls before advancing the policy revision.
Report the revision and pending/effective distinction to the human. This narrow
boundary does not require building pillar 4's general control queue.

Tests (extend the controls/roots/agent contracts where practical):

- Off → configured on → off, strict restart/resume, and two simultaneous
  conversations with different roots and enablement.
- Default changes affect only newly created conversations; malformed durable
  policy or store outage never silently becomes sandbox off. Reject activation
  when required persistence/readback fails.
- Stale-revision update refuses without losing either caller's changes.
- Model/child attempts to disable or widen refuse; real human updates succeed.
  `/roots` updates preserve unrelated policy fields and read/write distinctions.
- Child creation copies the effective revision and active grants without mutable
  aliases; continuation follows the explicitly reviewed rule above.
- A blocked command and parallel batch prove old policy remains effective until
  settlement; the next dispatch gets the new revision, including after restart.

Exit: durable, inspectable **configured/not-enforced** policy. No confinement
claim and no change to bash off-mode execution in this stage.

## B — one authoritative dispatch snapshot

Audit all dispatch entry points, not just `injectWorkspaceContext`. Define the
private policy payload and revision once; strip/overwrite caller-supplied
lookalikes and derive nested context from the runner's live lease. Never store
per-call policy in shared component globals or mutate process environment to
switch conversations. Missing context on a call requiring confinement refuses;
an explicitly scoped direct operator path must not infer authority from cwd.

Use recording test components to assert the exact effective policy/revision for:

1. serial direct calls;
2. parallel tool calls (mixed roots and concurrent conversations);
3. discovered `invoke`, including sticky discovery;
4. nested Fabric calls and subagent calls through their authorized proxy;
5. resumed runners and the first call following a human policy update.

A nested caller cannot override roots or replay a stale lease to widen reach.
Metadata that says a tool is read-only is not evidence that it enforces policy.
Native Fabric execution remains unconfined; its nested *tool calls* must pass
through the same decision as direct ones.

Exit: recording contracts prove uniform transport; consumers are still labelled
not enforced until separately audited. Private context is never returned in a
provider-visible schema or transcript by these fixtures.

## C — strict foreground Linux bash

Replace the strict mode's readable `--ro-bind / /` with an empty mount view and
explicit binds for approved data and reviewed read-only runtime roots. Support
system symlink layouts without resolving into an unapproved host tree. Supply
private scratch, minimal devices, a fresh proc view and a cleared environment;
do not expose host sockets, bus credentials or unrelated session artifacts.
Network remains off; per-call full-network approval is a later, separately
tested gate, not an automatic retry after command failure.

Apply denies after grants/binds; define handling for aliases, absent denied
files and newly created denied paths. Existing exact-file masks alone cannot
implement a recursive deny rule. Unsupported policy must refuse before user
code, not claim complete enforcement. Do not describe check-then-open alias
checks as race-safe. Stage C is blocked on the runtime/deny review above.

Keep legacy mode explicit and labelled as permitting host reads. Never fall
back to it (or write-only Landlock) when strict read confinement is requested.
Background commands continue to refuse until startup evidence, cancellation and
claim lifetime are integrated with processes. Writable data roots and lock
claims must be derived from the same authorized set; neither system may grant
what the other refused. Worktree git metadata outside the tree requires an
explicit policy decision, not an implicit bind of the primary checkout.

Tests (extend `t_sandbox` and `t_bash_guard`):

- Positive: a shell executes, reads approved source, writes an approved writable
  path and uses private scratch. A separate read-only grant permits read but not
  write. These positive controls prevent a deny-everything implementation from
  passing.
- Negative: same-user-readable sentinels outside grants (home, harness state,
  sibling worktree, another conversation's artifacts) cannot be read; ungranted
  writes and denied in-root content refuse. Include resolved symlink aliases
  and the documented hard-link/race handling.
- Network/bus unavailable; secrets and provider env absent; scratch isolated
  across concurrent launches. Off-mode remains unchanged.
- Actual-launch acknowledgement remains mandatory. Non-confining fake backend,
  skipped bootstrap, missing runtime path or unavailable backend starts no user
  command and never reports `applied`.
- Timeout/cancel tears down descendants; bounded output/spills still work and
  spill retrieval does not accidentally grant other sessions' files.
- Compat results explicitly say host reads are possible; strict requests never
  silently degrade. Background strict launches refuse before starting anything.

## Completion, follow-ons and validation

Filesystem enforcement is the next mandatory slice, not a solved problem from
reusing `readscope`: current grep filtering can read before filtering results,
and global exact-path masks do not implement per-conversation read roots.
Audit traversal, batches, caches, diff/undo output, new-file parents, hard links
and lazy instructions before claiming a boundary. Then land conditional
escape-tool grants, the remaining hardening matrix, Fleet integration and
Seatbelt on actual Mac hardware. Do not remove existing mask protections without
an explicit migration and sandbox-off regression tests.

For each implementation stage, run its narrowest Makefile contract targets;
for SDK/dispatch changes use `make build && make test`, with the full server
gate before merging and a live harness check for conversation-loop changes.
Unavailable Linux confinement must be recorded as unvalidated, not a successful
strict run; a Linux result never certifies macOS.

Prompt-prefix effect: no volatile policy in the frozen system prompt or direct
schemas. Human changes, inherited-policy notices and refusals are append-only
history; private per-call context is injected after model-visible history is
persisted. Assert prefix bytes remain identical across a mid-conversation update.
