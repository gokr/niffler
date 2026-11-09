# Sandbox next slice — durable policy, uniform transport, strict Linux bash

Status: **implementation task draft, not shipped behavior**. This decomposes
[PLAN.md](../PLAN.md) pillar 3 items 1 → 2 → 4 into independently testable
changes. [SANDBOX-CONVERSATION-POLICY.md](SANDBOX-CONVERSATION-POLICY.md) owns
the target policy; [SANDBOX-BASH-STATUS.md](SANDBOX-BASH-STATUS.md) owns current
behavior. No new protocol fields or tool names here are implemented contracts.

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
