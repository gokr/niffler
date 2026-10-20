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
| Fleet | Persistent identity; Linux user service; approved SSH/Multipass/Incus install/adopt/update and lifecycle; pinned private receipts; native relay; agent definitions and opt-in heartbeat; durable human completion feed; initial read-only fleet task slice with pinned jobs and durable runner notices | Real SSH-hosted guest provisioning and published-revision update smoke; released-client integration; background approval routing; broader task authority, confirmed remote cancellation and artifacts |
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

### Fleet: remote operations, not remote task orchestration yet

Merged Incus support adds native unprivileged containers and optional
SSH management hosts for Incus/Lima (Multipass was the earlier VM backend). An approved local Incus smoke on
`niffler1` installed published main, verified the ordinary ubuntu service, guest
linger, temporary sudo-rule removal, and matching TUI receipt import/native
relay using a scratch client registry. Optional LSP servers/trafilatura and
provider credentials are not part of the server bootstrap.

An approved **SSH-hosted** Incus run on `wowbagger` (`host` routing through
ordinary SSH) has since provisioned a container from published main, verified
identity, guest linger, sudo-rule removal, loopback-only NATS, the relay over
`ssh → incus exec → cli relay`, and qgroup-enforced 20 GB root volume. Its first
attempt failed honestly on a host firewall conflict (Docker's legacy
`FORWARD DROP` policy beating Incus's nftables rules), which the operator fixed
with bridge-scoped ACCEPT rules; that policy is not yet persisted across reboot.
This records branch validation, not a release claim.

Provisioning and lifecycle are implemented in the optional Nim component, not
manifest autostart. Matching TUI source has receipt import and switching, but
that repository and installed client versions must be verified separately.
The historical Multipass smoke passed; it does not validate Lima or replace real SSH or
published-revision download/update acceptance. No public NATS listener,
credential copying, shared bus namespace or distributed locks are implied.

`activity_list` / `ev.activity` are implemented on `main`: latest durable
completion per conversation, session-ID pagination and per-session sequence
reconciliation. They are not a remote fleet-job ledger. Process-completion
record-before-notify/ack/recovery is also implemented. Heartbeat still lacks
cron, daily token accounting, admission-ledger retention and an integrated
completion-delivery surface. See [FLEET-IMPLEMENTATION.md](research/FLEET-IMPLEMENTATION.md)
and [components/fleet/README.md](../components/fleet/README.md).

## Recommended work order

1. **Finish fleet cross-instance task delegation first.** Start with one persisted
   requester job pointing to one remote root conversation. Use explicit peer
   authority and per-task budgets; reconcile after disconnect or requester restart
   without duplicate submission. Distinguish unreachable/running/settled; keep
   remote subagent notices with their remote parent, human seen state separate
   from model acknowledgement, and retrieve results/artifacts explicitly.
   Unattended approval-requiring work must fail closed unless authority was
   explicitly granted; background UI approval routing can be a separate slice.
   Include failure/timeout/restart/identity-mismatch contracts and a live two-instance
   roundtrip. Fold real SSH/published-revision install/update and matching-TUI
   reconnect/completion checks into acceptance on human-approved targets. Release
   client changes separately; do not silently treat unreachable as interrupted.
   Completion adjudication is not a prerequisite for useful delegation.
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

### Lima transport replacement

Native Lima provisioning/lifecycle and matching TUI relay implemented in isolated fleet-lima worktrees; SSH/Incus preserved. Multipass profiles explicitly require migration. Real Lima smoke pending separate human authorization. No delegation implementation changes.
