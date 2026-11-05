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

Reconciled against local `main` at `v0.5.0`. This is source status, not a fresh
runtime certification of that release. Existing uncommitted implementation
changes were not used to mark work complete. The old fleet worktrees have been
removed, and the `compact` worktree was merged and is likewise gone; their
commits are included in `main`.

## Transcript safety

Canonical message appends are create-only, and full-kind reads refuse malformed
pages or stalled cursors rather than silently resuming from partial history.
Header merges use strict reads and compare-and-set retries; header creation is
create-only. Regression coverage includes stale continuation collisions, header
read failures and concurrent title updates. The existing durable tool-pair repair
ledger is also checked across a real runner restart, without rewriting history
or changing its byte-stable synthetic results.

## Isolated worktree lifecycle

`writes.primary` admits only the linked conversation's checkout-derived primary
as an explicit per-call target; merge/close take real leases without changing
root grants or the bash/edit fence. Peer close checks durable origin metadata
for the exact tree, preserving unrelated-owner, dirty and unmerged guards.
The git contract covers the isolated client-control path and primary contention.

## Larger features

| Feature | Implemented on main | Still open |
|---|---|---|
| Write arbitration | Durable `locks` peer; session dispatch claims; path-bound and opaque writers; harness-state claims for plugins; explicit no-claim declarations; nested Fabric calls; restart/outage/TTL contracts | Automatic worktree allocation/ownership — planned in 0.6.0 as pillar 2 and specified in [WORKTREES.md](research/WORKTREES.md); fencing or confirmed termination for writers that outlive leases; evidence-based completion adjudication is a separate feature |
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
Worktree ownership and liveness are now implemented: trees are recorded with
their owning conversation, and the workspace set rebuilds when the checkout graph
changes, so a tree created mid-conversation is inside the fence on the next
dispatch ([WORKTREES.md](research/WORKTREES.md)). The remaining gap is the one
this pillar names — automatic *allocation* (a conversation does not yet get a
tree by policy, only by asking) — plus fencing for writers that outlive leases.
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
  active-cancellation half was UNREACHABLE until `stop` was served by the busy
  pump (it was refused with `busy` mid-turn); it now needs only a live exercise
  against a real peer
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
semantics and their tests exist, and the mid-turn stop path is now fixed and
covered in-process (`t_controls` block 9), but no real peer has been stopped and
observed;
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

## 0.6.0 — authority boundaries that hold

Target release. Niffler grants reach in four places — a conversation in a
directory, a shell, a task on another machine, and a running turn — and none of
them has one authoritative policy object. This release gives each one a boundary
that can be stated without an asterisk. The headline sentence the release notes
should be able to write: *a delegated goal with `bash` runs inside a policy the
worker's operator set, in a tree nobody else is writing, and the person who owns
the machine can stop it mid-turn.*

Ordering rule for everything below: **a boundary is not shipped until a test
proves the refusal, and the refusal text says which layer refused.**
Availability is never enforcement; a skipped Mac test is not a pass.

### P0. Hotfix first — `session {stop: true}` is refused mid-turn

`pumpBusyCall` (`core/dispatch.nim`) answers `busy` to every session call while
a turn runs, deliberately including read-only ops. `stop` is served *inside*
`handleSessionCall`, so the one op whose purpose is cancelling a RUNNING turn is
rejected exactly when it is needed. Fleet's remote cancel
(`components/fleet/delegation.nim`) sends that call, and the only test
(`t_arbitration.nim` "sessionStopOp") runs it against an IDLE conversation — so
the path that matters has never been exercised.

- Fix: `stop` needs no session context, only a publish on the steer subject.
  Serve it in the busy pump, before the refusal, with the same reply shape.
- Gate: a test that stops a turn that is actually running (not an idle
  conversation), plus `fleet_task_cancel` against a mid-turn peer settling the
  job.
- This unblocks Fleet F3's live cancellation gate (pillar 1, F2).

### Pillar 1 — Fleet: from "works" to "trusted"

Slices 1–3 are merged; what remains is acceptance plus the edges that make a
remote task feel broken. Authority: [FLEET.md](FLEET.md),
[FLEET-SIMPLIFICATION.md](FLEET-SIMPLIFICATION.md),
[FLEET-INBOX.md](FLEET-INBOX.md).

| # | Slice | Gate |
|---|---|---|
| F1 | **Slice 4 acceptance**: publish, `fleet_update` the registered worker, operator enables trust with `fleet_delegation_set`, run a real delegated goal | a real worker returns a reviewable commit link and a paged report. Blocked on a deployment step, not code — the worker is pinned at a revision with no `delegationPolicyVersion`, so every goal is correctly refused |
| F2 | **Live remote cancel** (F3) — queued and dispatched, using P0 | a dispatched turn on a peer stops and settles; the requester reads settlement, not a guess |
| F3 | **Artifact retrieval from a settled activation** — the last ▢ in FLEET-INBOX.md | `/tasks <jobId>` shows the commit and diffstat for a settled job whose peer is offline |
| F4 | **Blocked / approval-needed notices, and approval routing to a human who is not attached** | a task that stalls on a question raises a `blocked` notice, and a human arriving later can answer it. Two known gaps to fix here: the broadcast fallback pre-denies on `clientCount() == 0`, and `reapDeadClients` judges a relayed client by local pid liveness |
| F5 | **Receipt retention policy** and reconcile beyond one 1000-item page | stated retention (no unbounded growth, no early loss); reconnect proven past a single page |
| F6 | **Authenticated bus for non-loopback Fleet** (`NIF_NAME`, key-gated flags) | a harness on a non-loopback bus refuses an unauthenticated peer. The envelope's `caller` is self-declared today |
| F7 | **macOS/VZ validation of Lima** | one macOS guest provisioned and one task run, recorded; the Linux/KVM smoke does not certify it |

Cut F5–F7 if the window is tight. **Fleet is not "really well" until F1–F4 land:**a
flag that has never run against a real peer, a cancel nobody has observed, an
inbox that cannot open what it lists, and a task that stalls invisibly are the
four things a user hits first.

### Pillar 2 — Worktrees: the substrate both other pillars need

The authoritative plan is [WORKTREES.md](research/WORKTREES.md) (basis
`v0.5.0`): nine independently shippable slices with their tests, plus
[WORKTREES-TUTORIAL.md](WORKTREES-TUTORIAL.md) for the workflows in operator
language (its Part 1 is what ships today). Prior art:
[CODEWHALE.md](research/CODEWHALE.md) D1, [OPENHANDS.md](research/OPENHANDS.md)
§3.15. This section records only what 0.6.0 requires of it and why it is not
optional.

**All eight slices are implemented.** Shared checkout parsing (`sdk/checkout`),
live graph invalidation, checkout-aware write claims, recorded sibling worktrees,
merge/commit verbs, `isolation: "worktree"` with the workspace readback, peer
`agent_fork` with immutable `origin` provenance and append-before-ack merge
notices, the client's `/worktree` commands, and this documentation pass.
Path-stripe arbitration is unchanged: these features do not impose a
worktree-wide mutex.

What remains open from this pillar is stated rather than implied: automatic
worktree *allocation* by policy (a conversation still asks for a tree rather than
being given one), fencing or confirmed termination for writers that outlive their
leases, and the single known delivery gap where a merge commits but a crash
before the notice write leaves the origin untold.

**The shape, adopted from WORKTREES.md:** a worktree is a first-class recorded
object created at `<repo>.wt/<name>` — a sibling of the repo, so it sits outside
the primary's opaque write claim and needs no ignore rule — locked with a reason
naming the conversation, recorded as a `worktree` store doc, and reachable
immediately because core recomputes the workspace set when git says the checkout
graph changed. The conversation stays pinned to its tree; merging is an ordinary
claimed write into the primary, not a move. `isolation: "worktree"` makes the
tree a FENCE rather than a convenience.

What 0.6.0 adds on top of that proposal, because the other pillars need it:

1. **Claims follow the resolved checkout (WORKTREES.md slice 2 + §4.4).** An
   opaque writer's claim is the workspace-set root that CONTAINS its resolved
   `cwd`, never a path-prefix guess and never blindly the primary — that is the
   cross-root arbitration hole, and it is a 0.6.0 blocker. Two consequences worth
   stating because they are *not* new rules: with sibling worktrees the primary's
   claim and a worktree's writes are disjoint by construction, and **`locks`'
   "disjoint stays parallel" striping is unchanged** — two conversations in ONE
   tree still proceed on different files. `isolation: "worktree"` is therefore a
   per-conversation FENCE (writes outside the tree refuse, absent an explicit
   `/roots` grant), not a mutex around the tree. WORKTREES.md §10 records why the stricter reading ("a second writer in
   the same worktree is refused") was rejected: it would reverse a shipped design
   rule and invalidate two `t_locks.nim` assertions without a decision record.
2. **Sandbox executable roots (pillar 3 item 4).** The bwrap reachable set and
   the policy's writable roots are computed from the same resolved checkout, so
   "the only writable root is my worktree" becomes expressible at all.
3. **Fleet lanes.** `fleet_task_submit`/`agent_spawn` gain
   `isolation: worktree|shared`; a worktree child does not see the parent's
   uncommitted or committed work, and escaping to `shared` needs the grant.
4. **Per-worktree state.** `edit` undo/seen store, repomap census, LSP roots,
   AGENTS discovery, readscope masks and the private `__workspace` context must
   key on the worktree, not the repo — mostly true by construction (`edit` keys
   undo/seen by `session:absolute-path`, `lsp` per root, `repomap` per path), so
   this is a verification pass rather than a change. The real gap is **census
   cost**: a worktree is a second full tree, so `lsp`/`repomap` may warm and map
   the same files twice; `__workspace.primary` is the fact that lets them decide.
5. **A conversation's move-or-fork is a first-class act (WORKTREES.md §5.1).**
   `/worktree add <name>` from an exploratory conversation moves it when that is
   safe (pristine or unpinned, and a clean tree — `repinWorkspace` already allows
   it, at no prompt-cache cost) and forks it into a linked conversation when it
   is not (a chosen workspace, or uncommitted edits). The human says "work in a
   worktree" and is told which happened; nobody has to reason about workspace
   immutability. This is the difference between worktrees being available and
   being usable. The fork's copy semantics are `forkHistory`'s as shipped
   (messages verbatim, `usage`/`summary`/`error` dropped, configuration the
   child's own) with one gap to close: a compaction checkpoint is not carried,
   so either copy it forward as the projection seed or say so in the output.
6. **The loop closes back on the origin (WORKTREES.md §5.3b).** `/worktree close`
   returns the client to the conversation that forked you there, and the merge
   settles a durable notice into that conversation's lane (`drainNotices` already
   folds `agent_notices`/`process_notices`/`fleet_notices`), so the parent learns
   the commit id without polling. Without this, `/session` works but the parent
   has no record that a fork ever existed — the work is done and the conversation
   that started it reads as if you stopped mid-thought.

**Gate.** Two conversations, same file, two worktrees: zero cross-talk, both
claims granted. A third writer in one worktree is allowed on a DIFFERENT file
("disjoint stays parallel") and refused on the same one. A tree created
mid-conversation is admitted on the NEXT dispatch without a restart. Resume
reuses the tree. Masks and sandbox policy still apply inside it. `/worktree add`
from an unpinned conversation moves it; from a pinned one, or with a dirty tree,
it forks and says so.

This supersedes the earlier "keep write arbitration in maintenance mode"
position: worktrees are no longer a nice-to-have, because the sandbox needs one
unambiguous writable root and Fleet needs parallel lanes.

### Pillar 3 — Sandbox: make "sandboxed" a defensible word

The target is the agreed contract in
[SANDBOX-CONVERSATION-POLICY.md](research/SANDBOX-CONVERSATION-POLICY.md),
slices 1–3, plus the hardening bundle from [STEAL-WAVE-2](research/STEAL-WAVE-2.md)
#7. Current behavior is [SANDBOX-BASH-STATUS.md](research/SANDBOX-BASH-STATUS.md);
the backend argument is [SANDBOX-MATRIX.md](research/SANDBOX-MATRIX.md) §5.

1. **Persist the policy.** Off/on, read roots, write roots, deny rules — per
   conversation, operator default via a `config` domain, human-only update seam,
   subagent inheritance. A running command settles or is cancelled before a
   change takes effect.
2. **Propagate uniformly.** One decision through serial, parallel, `invoke` and
   nested Fabric dispatch. A policy that guards only `bash` is a claim we cannot
   make.
3. **Filesystem enforcement** for the approved group (`read`, `grep`, `files`,
   `write`, `edit`, `replace_across`, `undo`) — including cached results, diff
   previews, undo data and lazy instructions, and the parent chain of new files
   rather than a lexical prefix.
4. **Kill the readable host root in bwrap.** Bind only reviewed runtime and data
   roots so the promise becomes "this command can only SEE and WRITE its
   workspace". Per SANDBOX-MATRIX §5 this requirement, not write protection, is
   what selects the backend; keep an explicit, honestly-labelled compat mode for
   toolchains.
5. **Seatbelt** — generate `.sbpl` profiles, spawn via `sandbox-exec`, same policy
   vocabulary. Unusable on a machine ⇒ honest `degraded`, never a false `applied`.
   Needs real Mac hardware (human authorization).
6. **Hardening bundle**, one matrix row each: masks matched on the RESOLVED path
   (symlink alias); deny writes to `.git/hooks|config|attributes` (a sandboxed
   command must not install a hook that later runs outside); read-only + network
   namespace mode for fetch-style reads; bwrap setup failure says WHY; guarded
   background commands gain a lifecycle.
7. **Locks ↔ sandbox co-design.** The sandbox's writable roots and the lock's
   claim roots are the same data. A denial must say which one refused. A
   sandboxed background process holding a claim past the turn is the "fencing /
   confirmed termination" gap and needs an answer here, not later.
8. **Fleet ↔ sandbox.** A guest (Incus/Lima) is the outer boundary, the
   conversation policy the inner one; the verdict names the layer. Then
   `confinement: "sandbox"` stops being a refusal and becomes the recommended
   mode for delegated work.
9. **Gate.** Off/on/off, two simultaneous conversations, child inheritance and
   revocation, traversal/cache/undo/diff paths, new-file parents, one matrix row
   per hardening item, and a recorded Mac run.

### Pillar 4 — Mid-turn is a first-class state

The client currently refuses 18 commands while a turn runs, in four different
styles, and core refuses the rest with one blanket `busy`. Two verbs work:
typed text steers, ESC cancels. Classify every session op once, in one table,
and make each class's behavior explicit:

| Class | Ops | Mid-turn behavior |
|---|---|---|
| Answer now | bare status readback, `export`, `approvals` read, `stop` | served from a SNAPSHOT in the busy pump — never by re-entering `handleSessionCall`. `context_status` and `svc.core.call` already answer mid-turn this way, so the machinery is proven |
| Queue, apply at the boundary | `compact`, `model`, `thinking`, `approvals` set, `limits`, `title`, `cwd` repin, `roots`, `profile`/`toolset` (next render) | accepted, persisted, applied when the turn settles, with a visible notice |
| Refuse precisely | a second `content` turn | stays refused in 0.6.0. **Decided:** queueing turns is deferred to 0.6.1 — the controls are safe and clearly right, a second turn changes what typing mid-turn means |

`roots` is special and is not a boundary case: per the sandbox contract, human
policy updates apply BETWEEN TOOL CALLS, never retroactively to a running
command. That is a finer seam than the queue's and is named as such.

**The queue.** Store-backed in core (`sessionqueue` records, monotonic sequence),
not client-side: a client queue dies with the TUI process and a resume would
show nothing.

- Opt-in per call (`session {queue: true}`), set by clients. Automation
  (`agent`, `fabric` nested calls) must never queue — it needs the instant
  refusal.
- Idempotent: each item carries a requester-chosen key, like Fleet's admission
  key, so a reconnecting client that retries cannot apply `/compact` twice.
- Ordering: steers fold into the running turn; queued items apply at settlement
  in store order.
- **`stop` ends the LLM turn and nothing else. (Decided.)** The queue is
  untouched and then DRAINS: queued controls apply once the stopped turn
  settles, in store order, exactly as they would after a turn that ended by
  itself. `/stop` is not a queue clear, and there is no "abandon everything"
  semantics to explain. The only thing a stop can affect is the turn's own
  in-flight tool, which finishes or is killed as it already does.
- This is also why the queue must be store-backed rather than client-side: the
  stop can be requested from another process (`session {stop: true}`), from a
  remote Fleet peer, or by ESC in a client that is about to exit — the items
  have to outlive whoever asked for the stop.

**Rendering — client, `niffler-tui`.**

- A queued item renders like the existing `Steer: ` line but dim, with the
  prefix `queued: `, so the human sees what is waiting without reading a list.
- When it is applied the same block changes color and its prefix becomes
  `applied: `. In-place update, keyed by the queue item's id — not by matching
  the text, which is how `Steer: ` blocks are found today (main.go:3044) and is
  fragile. No `dropped:` state exists, because a stop never drops a queued
  control.
- No editing of the queue. One command pops the last item: `/queue` lists what
  is pending and `/queue pop` removes the most recent (alias intent: the same
  "take the last thing back" gesture as `undo`). `queue pop` on an empty queue
  is a no-op with a note, never an error.
- The 18 local `m.busy` refusals collapse to one behavior: send it, let core
  classify it. `note.betweenTurns*` strings retire.
- Colour comes from the existing palette (`meta`/`thinking`), not a new theme
  field, so every theme keeps working.

**Two-stage stop.** Fixed in `niffler-tui` `524e339`: any key other than ESC now
disarms the "Stop? press esc again" prompt, because a human who armed it and
typed something else had already chosen otherwise; mouse events deliberately do
not disarm. The plan's remaining ask is the disarm on `stop` itself — already
covered by `cancelTurnCmd`, keep it pinned by test.

**Gate.** An op-table test that enumerates the whole session surface, so a newly
added op cannot silently default to `busy`. Then: a queued `/compact` applies
after the turn, once, with a notice; a duplicate retry applies zero extra times;
**a stop does not cancel the queue — the queued control still applies after the
stopped turn settles**; the `answerNow` class answers mid-turn without entering
`runTurn` (asserted by a counter, not by absence of an error).

### Other larger areas, ranked

Cheap, measured, and independent — each rides along any week of the above.

| Area | Why it earns the slot | Effort |
|---|---|---|
| **Tool-routing shape quest** (already in this file's "Benchmark evidence") | 31/31 is saturated, so shape is the only signal: our bash heads are `pwd` 26, `cd` 20, `cat` 19 against `read` 2.0/cell, at 1.2 calls/message vs Droid's 4.4 | ~½ day + re-run |
| **Fabric background / durable / resumable runs** (STEAL-WAVE-2 #1) | the one item that changes what the AGENT can do: the synchronous 5-minute ceiling is why t28–t30 fall back to scripted bash. Composes with Fleet (long remote fan-outs) and worktrees (parallel lanes) | 3–5 days |
| **Spend cap across the session tree** (STEAL-WAVE-2 #4) | delegation is bounded by shape, not cost; also the prerequisite for ever doing goal loops | 2–3 days |
| **Turn queue for a second turn** (STEAL-WAVE-2 #5) | the product half of pillar 4. **Decided:** not in 0.6.0 — controls only there, turns in 0.6.1 | 1–2 days |
| **Instruction budget with visible truncation** (#3) | one monorepo `AGENTS.md` can silently evict every other instruction file, invisibly to the model | 1 day |
| **Compaction byte budget** (#11) + **persist learned ceilings** ("Recommended work order" below, item 3) | both are "learn it once" fixes on the most context-pressed request of a session | ~1½ days |
| **`ask_user` structured question** (#8) | "which of these three?" is unanswerable today; also the prerequisite for MCP elicitation and Fleet's blocked notices (F4) | 2 days |
| **Semantic refactor through LSP** (BACKLOG) | two real defects where a rename rewrote JSON keys and missed call sites | ~5 days |

Deferred on purpose, so this plan is not read as a wish list: goal/loop
autonomy, memory component, checkpoints and rewind, ACP endpoint, MCP
per-conversation scoping, OS keyring, team/mailbox.

### Sequence

| Week | Work |
|---|---|
| 0 | **P0 stop hotfix** (unblocks Fleet F2/F3) + F1 publish/update/enable trust |
| 1 | Worktree creation, lineage, per-tree state (pillar 2 items 1–2, 4) |
| 2 | Locks claim verification, lifecycle, gate (pillar 2 items 3, 5–6) |
| 3 | Sandbox policy persistence + propagation (pillar 3 items 1–2) |
| 4 | Filesystem enforcement + bwrap reachable set (items 3–4) |
| 5 | Hardening bundle + Seatbelt + recorded Mac run (items 5–6, 9) |
| 6 | Fleet edges F2–F4, then pillar 4 queue + op table |

Pillar 4's `answerNow` snapshot class (M2) is small and can land in any week;
the queue itself wants a settled turn lifecycle, which P0 delivers. Client side
ships `niffler-tui 0.11.0`: queued blocks, `/queue`, `/tasks` artifact view,
worktree status, sandbox-policy panel.

## Recommended work order (older ordering, kept for context)

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
   **Follow-up — make what a refusal teaches durable.** Recovery now adopts the
   window a provider's `context-overflow` refusal names and the reply budget it
   implies (`window:refusal`/`calib:refusal`/`reserve:clamped`,
   `runOverflowFallback`; docs/COMPACTION.md "A refusal the ladder did not
   predict"). None of it survives the process: `ctxSize` is rehydrated on resume
   from the last assistant message's `context` field rather than a header field,
   and `ctxOutput` is re-resolved from the catalog every turn, so the clamp is
   overwritten. A provider whose real ceiling sits below its catalog window
   therefore pays one extra refused round trip per fresh runner and per turn —
   automatic and correct, but not remembered. Persist both to the conversation
   header beside `trimThrough` (that plumbing already exists) and seed them on
   resume, so a learned ceiling is learned once. Not urgent: it costs a wasted
   request, never a stuck turn.

One item is small, fully measured and can be taken in parallel with any of the
above: the read-vs-shell routing quest in "Benchmark evidence" (prompt and tool
description plus one re-run; acceptance is shape, since pass rate is saturated).
Do not turn the evidence ledger, settings UI or research shelf into
prerequisites for the above slices.

The earlier "keep write arbitration in maintenance mode" position is
**withdrawn**: the 0.6.0 pillars need automatic worktrees (one unambiguous
writable root for the sandbox, parallel lanes for Fleet), so pillar 2 is that
work, done deliberately.

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
