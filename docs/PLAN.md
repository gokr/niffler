# Plan — next work and feature status

This is the active plan, not an inventory of every idea. Shipped behavior lives
in [MANUAL.md](MANUAL.md), protocol in [WIRE.md](WIRE.md), and unscheduled ideas
in the [research backlog](research/BACKLOG.md). Design notes are history unless
explicitly identified as the current target below.

## Configuration framework

`feat/settings` merged to `main` on 2026-10-22. Shipped: component-owned,
schema-described settings; the `config_list`/`config_get`/`config_patch`/
`config_reset` peer with `humanOnly` and per-property application timing; and
instance-scoped storage on SQLite and TiDB. Fleet instance records have a
store-backed registry, but importing existing records and migrating lifecycle
callers remain open. Track the remaining slices in
[CONFIG-TODO.md](research/CONFIG-TODO.md); [CONFIG.md](research/CONFIG.md)
records the design. Shared-scope settings remain a proposal, not shipped
behavior.

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
| Fleet | SSH/Incus/Lima provisioning and lifecycle; pinned receipts; native relay and TUI switching; agent definitions/heartbeat; bounded read-only tasks, durable parent notices and local inbox; queued and active cancellation | F2 exit (patch/commit artifact and real-provider acceptance); steering/continuation and a live remote-cancel exercise; scoped artifacts, background approvals and a human profile/grant UI; see [FLEET.md](FLEET.md) |
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

**Direction update (shipped):** [Fleet simplification](FLEET-SIMPLIFICATION.md)
supersedes this section's old task-profile/artifact ladder, and slices 1–3 have
landed on `main`. Delegation is now goal-oriented: name a registered worker, give
it a goal, read a paged prose report.

- **Slice 1 (report-first results)** — shipped. `fleet_task_result` pages a
  locally cached prose report (`report`, `offset`, `nextOffset`, `hasMore`,
  `reportBytes`, `reportComplete`); notices stay short; a legacy summary-only job
  answers `reportComplete:false`. The TUI reader is released.
- **Slice 2 (named worker, pinned route)** — shipped. `fleet_task_submit
  {instance}` takes a registry name or 32-hex identity (XOR the legacy `profile`)
  and pins the verified receipt into the job, so a registry edit cannot retarget
  an existing job or its retry.
- **Slice 2b (trusted-worker admission)** — shipped. Trust is ONE worker-side
  setting (`delegation/settings` via `fleet_delegation_set`/`_get`,
  approval-gated and on the control-plane deny list), off when absent and refused
  **before any turn runs**. `delegationPolicyVersion: 1` is advertised so a
  requester refuses an older peer instead of silently downgrading to `ask`.
  Tools and budgets are optional; an explicit value may only narrow. Every stored
  `taskProfile` job keeps its recorded policy verbatim.
- **Slice 3 (follow-up)** — shipped for the continuation half.
  `fleet_task_continue` appends an activation to a settled delegated goal on the
  SAME worker conversation, with a fresh admission key per activation and
  instruction-only changes; the parent's report is never overwritten. The
  active-cancellation half still needs a live exercise against a real peer
  (queued-vs-dispatched cancel semantics themselves are implemented and tested).
- **Slice 4 (Fleet-only acceptance)** — **not met, and blocked on a deployment
  step rather than on code.** The registered `worker` instance is pinned at a
  revision with no `delegationPolicyVersion`, so a delegated goal is correctly
  refused by the requester before dispatch. Acceptance needs the worker updated
  (`fleet_update`) and its operator to enable trust — deliberate operator acts,
  not something a merge can self-certify. The requester-side contract is covered:
  an older peer refuses a goal, and the same peer still serves an `ask` task.

Honest boundaries that did not change: the envelope `caller` is self-declared, so
unattended trust means trusted bus/SSH access, not per-requester authentication;
a worker with `bash` and its own credentials can push and open PRs, and no
sandbox is claimed; a worker's report is a claim, not verified fact. PR #24 is
assigned independently and was not dispatched here.

The older F2 ladder below is kept as history. Its exit stock (patch/commit
artifact as a completion contract, workspace isolation, runtime deadline) is
deliberately NOT the target any more: artifacts are optional supporting evidence.

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

The human inbox has landed: `fleet_task_inbox` is a paged, read-only view over
the `fleetjob` kind, so a settled job is answerable from your own machine
without the peer being reachable, and `ev.fleet.settled` lets a connected client
alert instead of polling (docs/FLEET-INBOX.md records the experience). The TUI
listing, toast, client-local seen markers and drill-down are implemented. Still
open there: artifact retrieval for a settled activation.

Still open: a live exercise of remote cancellation (F3) — the queued/dispatched
semantics and their tests exist, but no real peer has been stopped and observed;
scoped artifact retrieval and patch/commit return (F2/F4), now OPTIONAL evidence
rather than an exit condition; sequenced blocked/completion notices (F3/F4); a
human UI for the delegation setting and task profiles. Read-only tasks remain the
default, and unattended coding is never enabled by requesting it — it needs the
worker operator's `fleet_delegation_set` (or a named `taskProfile`). Human seen
state stays separate from agent notice acknowledgement. Published-revision update
and real-provider coding acceptance remain separate gates (they are what blocks
slice 4 above); the completed Linux Lima smoke does not certify macOS/VZ.

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

## Benchmark evidence: tool routing is the measured gap

The `droid` lane is on `main` (`bench/adapters/droid.mjs`), so the benchmark can
now be run against a third harness besides niffler and pi. The
`full31-syn-ds41-droid` run (31 tasks × 3 lanes, Synthetic DeepSeek V4.1 Flash)
is recorded in `bench/reports/full31-syn-ds41-droid-{report.md,report.csv,analysis.md}`:
**93/93 cells pass, no leaks, every cell in round 1**. That saturation is itself
the result — `full31` and the mid-tier are exhausted for this model class, so
any future capability claim needs a suite with headroom (`deepswe/` or the
SWE-bench slice), not another `full31` number.

What `full31` can still measure is shape, and it says the frozen-prefix
discipline is working but not yet paying off: droid's first prompt is ~60.4k
tokens against ~3.05k here (20× smaller), it buys that back with ~4.4 tool calls
per assistant message against 1.2, and round trips (1.9 vs 6.5), uncached input
(3.4k vs 7.0k) and wall clock (30 s vs 29 s) land within noise. Do not quote a
cost ordering without its basis: on Synthetic's catalog niffler is 20% cheaper
than droid, on first-party list prices it is ~18% more expensive, because
droid's prefix is cached and ours is sent fresh.

**Open quest — make the model use the direct tools it is given.** Per cell
droid reads (`read` 4.6, `bash` 1.5) while niffler shells (`bash` 4.2,
`read` 2.0), and across the 31 niffler cells the bash heads were `pwd` 26,
`cd` 20, `cat` 19, `ls` 6, `find` 3. So ~2.4 of our 4.2 bash calls per cell are
navigation and reading the direct tools should have absorbed, and ~1.5 are
spent establishing where we already are — despite the base prompt saying both
"Batch independent calls in one reply" and "Use bash for execution/computation,
not `cat`/`sed` file I/O". The tools and the words both exist and the model
routes around them; that is a prompt/description lever, not a core change.
In order: (1) make the read-vs-shell preference impossible to miss — a "not" in
a 12-word sentence is not carrying it; name `cat`/`ls`/`pwd` beside the tool
description; (2) ask for larger batches with a concrete shape ("three files →
one message"); (3) check whether `pwd` feels necessary because the workspace
line is ambiguous about the repo being the cwd. Verification is the same run,
not a spot check: re-run these 31 cells and compare bash-head counts per cell
and turns per cell. Pass rate cannot move — it is already 31/31 — so shape
(`bashCalls`, `turns`, `firstPromptTokens`) is the acceptance signal, and the
prefix must stay byte-stable.

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
One item is small, fully measured and can be taken in parallel with any of the
above: the read-vs-shell routing quest in "Benchmark evidence" (prompt and tool
description plus one re-run; acceptance is shape, since pass rate is saturated).
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
