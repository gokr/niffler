# Plan — next work and feature status

This is the active plan, not an inventory of every idea. Shipped behavior lives
in [MANUAL.md](MANUAL.md), protocol in [WIRE.md](WIRE.md), and unscheduled ideas
in the [research backlog](research/BACKLOG.md). Design notes are history unless
explicitly identified as the current target below.

## Active branch: configuration framework

`feat/settings` is implementing component-owned, schema-described settings and
instance-aware storage, including moving fleet instance records out of JSON
files and into the store. Track delivery and validation in
[CONFIG-TODO.md](research/CONFIG-TODO.md); [CONFIG.md](research/CONFIG.md) records
the design. Shared-scope policy, migration and wire details remain proposals
until resolved in the checklist; they are not shipped behavior.

## Baseline

Reconciled against local `main` at `6300a06`. This is source status, not a fresh
runtime certification or a claim about the v0.4.0 release. Existing uncommitted
implementation changes were not used to mark work complete. The old fleet
worktrees have been removed; their commits are included in `main`.

## Larger features

| Feature | Implemented on main | Still open |
|---|---|---|
| Write arbitration | Durable `locks` peer; session dispatch claims; path-bound and opaque writers; harness-state claims for plugins; explicit no-claim declarations; nested Fabric calls; restart/outage/TTL contracts | Automatic worktree allocation/ownership; fencing or confirmed termination for writers that outlive leases; evidence-based completion adjudication is a separate feature |
| Sandboxing | Opt-in synchronous Linux bwrap shell guard; launch-time checks, environment clearing, network isolation and configured masks; partial component mask checks; pure versioned conversation-policy model | Persisted effective conversation policy and human controls; uniform dispatch propagation; approved-root enforcement; conditional grants; migration from global masks; background execution; Seatbelt and real Mac validation |
| Fleet | SSH/Incus/Lima provisioning and lifecycle; pinned receipts; native relay and TUI switching; agent definitions/heartbeat; bounded read-only tasks and durable parent notices | Idempotent worker admission/activation receipts; authorized unattended coding; active cancellation/continuation; inbox, background approvals and artifacts; see [FLEET.md](FLEET.md) |
| Vision path | Tool results may carry `images` (`docs/WIRE.md` "Tool results"): core validates them against the byte-sniffed allowlist, stores them as attachment docs under the tool message, and materializes them through the same budget/projection rule as a dropped image; `read` answers an image path with the image plus a caption; elision drops refs with text so a superseded screenshot leaves the projection | Re-encoding an oversized capture (reported today, never silently downscaled — needs an image codec in a component plus a bound on its output); provider-specific degradation beyond the honest elision marker; TUI-side rendering of tool images |

### Write arbitration: usable foundation, not a sandbox

Phases 1 and the main phase-2 declarations are implemented, including `plugins`
claiming `$NIF_ROOT/var` paths rather than the unrelated project workspace, and
`mcp` declaring no filesystem claim for store-only mutations. Crash/restart,
store-outage, nested-call and running-writer TTL cases already have contracts;
they are not all future phase-3 work.

The guarantee is cooperative coordination at session dispatch, not OS fencing.
Direct bus calls, autonomous jobs, native guest I/O and other instances remain
outside it. A claim records declared reach, not proof that bytes changed.
Existing worktree awareness is not automatic worktree-per-conversation ownership.
See [WRITE-ARBITRATION.md](research/WRITE-ARBITRATION.md).

### Sandboxing: prototype shipped, conversation product unfinished

The implementation is on `main`, not an unmerged branch. The current guard is
explicitly opt-in and off by default. Its read-only host-root mount still permits
arbitrary host reads except configured masks: it is not a workspace-only view
or a hostile-agent security boundary. Guarded background commands refuse;
Seatbelt is not implemented. Availability is not enforcement attestation.

Use [SANDBOX-BASH-STATUS.md](research/SANDBOX-BASH-STATUS.md) for current
experimental behavior and [SANDBOX-CONVERSATION-POLICY.md](research/SANDBOX-CONVERSATION-POLICY.md)
for the agreed target. The older PLAN/IMPLEMENTATION/ROUTE notes are historical
context, not competing delivery checklists. The snapshot model alone does not
persist or enforce a conversation sandbox. Do not call an approved unconfined
builder, MCP server or native Fabric guest sandboxed.

### Fleet: finish the remote-task workflow

The authoritative delivery plan is [FLEET.md](FLEET.md). Provisioning over SSH,
Incus and Lima, stable identity, private receipts, TUI switching, and bounded
read-only remote tasks with durable parent notices are implemented. Local Lima
bootstrap and SSH-hosted Incus provisioning have live evidence; the original
long-bootstrap lost-reply mechanism has a tested heartbeat-pump fix.

Durable worker admission is implemented (F1: versioned capability negotiation,
immutable birth-policy digest, idempotent admission, activation-bound terminal
receipts). F2 has an experimental unattended-execution implementation with
narrow contracts and real store/runner tests, but is not ready to ship. Review
found component/core import violations, incomplete callable control-plane denial,
non-idempotent policy retries, and unproven grant/resume/revocation semantics;
all four are now closed — shared contracts moved to the SDK, denial matches
callable names plus a worker-side schema audit, exact retries replay receipts,
and stale grants plus content-only continuations refuse under test. The exit
stock still is not met: there is no patch/commit artifact, workspace isolation or
runtime deadline, and no fresh-grant continuation or in-flight revocation. See
the blocker list in [FLEET.md](FLEET.md). Complete that artifact before treating
F2 as shipped or proceeding to F3.

The human inbox's local half has landed: `fleet_task_inbox` is a paged,
read-only view over the `fleetjob` kind, so a settled job is answerable from
your own machine without the peer being reachable (docs/FLEET-INBOX.md records
the intended experience). Still open there: the settle event a connected client
can toast on, and the TUI surface with client-local seen markers.

Still open: multi-activation records and receipt retention (F1); scoped
artifact retrieval, verification evidence and patch/commit return (F2/F4);
active cancellation, steering and continuation (F3); sequenced
blocked/completion notices and a human task inbox (F3/F4); a human UI for task
profiles and grants. Read-only tasks remain the default, and unattended coding
is never enabled by requesting it. Human seen state stays separate from agent
notice acknowledgement. Follow F1–F5 in the Fleet plan rather than the
historical research ladders. Published-revision update and real-provider coding
acceptance remain separate gates; the completed Linux Lima smoke does not
certify macOS/VZ.

Unattended work on a resident instance has both halves of the approval story
shipped: `NIF_APPROVALS_DEFAULT=auto` (rendered by `scripts/server.sh`) gives
conversations nobody has decided about auto approval, per conversation and
overrideable by an explicit `/approvals ask`, and it ALSO decides a direct,
context-free core call — the `core.spawn` inside `plugin_install`, a
`cli`-driven `spawn` — where no conversation exists to be consulted, so a
detached instance can install a plugin and extend itself. What remains for
"background approval routing" is interaction, not reachability: raising a
QUESTION on an instance nobody is watching, and routing it to a human who
arrives later. Two reachability gaps accompany that: the broadcast fallback
pre-denies on `clientCount() == 0` before asking, and `reapDeadClients` judges
a registered client by local pid liveness, so a relayed/tunnelled client is
never visible to that check (its directed `svc.approval.<caller>.request`
routing still works).

## Recommended work order

1. **Complete remote task delegation.** Follow [FLEET.md](FLEET.md): F1 durable
   worker admission/activation receipts, F2 explicitly authorized unattended coding,
   F3 task control and actionable notices, F4 inbox/artifacts, F5 live acceptance
   and compatible releases. The outcome is “assign a coding task to another
   Niffler and get a reviewable result back,” not just remote management or badges.
2. **Finish one vertical conversation-sandbox slice.** Persist and resume the
   effective policy; provide a human-only update seam; propagate it through
   serial/parallel/invoke/nested dispatch; enforce it first on filesystem tools.
   Prove off/on/off, two simultaneous conversations, child inheritance and
   revocation decisions, traversal/cache/undo/diff paths and new-file parents.
   Then replace the shell's readable host root with reviewed runtime/data roots.
   Conditional approvals, background lifecycle and Seatbelt each get their own
   acceptance gate; a skipped Mac test is not a pass.
3. **Expose context health and recovery.** Read-effect `context_status` now
   reports persisted window/usage, shared thresholds, `trimThrough`, structured
   loss attribution, projection coverage and retained snapshot metadata. Usage
   is not a live request measurement; snapshot presence is not retryability.
   An explicit bounded retry for failed snapshots remains to be designed. Recent
   proportional trim, compaction retry/loss attribution and both stub tiers are
   implemented: tier 1 elides results a later write superseded, tier 2 elides
   results whose producing tool declares them re-obtainable
   (`x-harness.derivable`, disabled with `NIF_STUB_DERIVABLE=0`).
Keep write arbitration in maintenance mode unless real contention demonstrates
a need for automatic worktrees or stronger fencing. Do not turn the evidence
ledger, settings UI or research shelf into prerequisites for the above slices.

## Gates and documentation ownership

- Narrow component contracts first; `make build && make test-server` before
  merging runtime changes. SDK/bus changes also require `make test`; live
  conversation changes need a live harness check. No fresh test run is claimed
  by this documentation reconciliation.
- Privileged sandbox setup and real fleet provisioning need human authorization.
  Fake transport tests do not certify SSH, AppArmor or Seatbelt enforcement.
- README: introduction and quick start. Manual: operating behavior. WIRE: exact
  contract. FEATURES: coarse capability index. This plan: next work. Research:
  decisions and deferred ideas, not another current-status authority.
- Preserve old design links; mark superseded notes rather than deleting evidence.
  Refresh affected localized docs after English; client-only help belongs to the
  client repository. See [the documentation index](README.md).
