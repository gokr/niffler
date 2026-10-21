# Fleet — tasks across Niffler instances

Status: **active design and delivery plan**. Provisioning and bounded read-only
remote tasks are implemented. Unattended coding delegation exists as an
experimental F2 slice whose authority boundary is now closed but whose exit is
not met (no patch/commit artifact — see §8). This file
supersedes the delivery ladders in [the original design](research/FLEET.md) and
[the old implementation schedule](research/FLEET-IMPLEMENTATION.md).

Operating instructions belong in [MANUAL.md](MANUAL.md#ssh-and-lima-provisioning);
implemented protocol belongs in [WIRE.md](WIRE.md). Proposed names and records
below are targets, not an assertion that the current tools accept them.

## 1. The outcome

> Assign a task to a named Niffler, let it work unattended within approved
> authority and budgets, learn when it finishes or needs help, and get a
> reviewable result back—even after disconnects and restarts.

Managing a VM, switching clients and counting notifications are supporting
features, not the outcome. The first complete milestone is **one remote coding
task returning a report, verification evidence and a patch or commit**.

Example target interaction:

1. “Ask worker-one to fix this issue in its checkout, run the tests, and return
   a patch. Allow ordinary coding tools, with these spend limits.”
2. A human approves the named worker, workspace, capabilities, unattended mode
   and budgets once. The peer's operator policy must also permit them.
3. The requester gets a durable job pointer immediately. The worker continues
   independently; disconnecting the client does not stop either service.
4. Completion or an actionable blocked state is recorded before notification.
   The requesting conversation learns through notices, not status polling.
5. The human can inspect the job inbox, open the worker conversation, retrieve
   artifacts, and approve integration. Completion never silently applies a patch.

## 2. What exists now

| Area | Implemented behavior | Remaining gap |
|---|---|---|
| Instances | Stable identity, root-scoped resident user service, SSH/Incus/Lima provisioning and lifecycle, pinned private connection receipts | Long-lived operation recovery/reporting and more live update acceptance |
| Transports | SSH forwarding; native guest CLI relay; optional SSH management host; Multipass explicitly rejected | No new transport needed for task semantics |
| Client | Per-instance connections and state, switching, identity checks, completion badges | Task inbox and background-instance approval interaction |
| Task submission | `fleet_task_submit`, owner-bound durable `fleetjob`, explicit read-tool allowlist and round/call/token budgets | Named task peers, coding authority, agent/model selection, continuation |
| Result | `fleet_task_status` and cached bounded `fleet_task_result`, remote-session pointer | Paged task-specific detail and artifact retrieval |
| Notification | Durable `fleet-settled` notice; runner append before ack; canonical-history dedup; bounded idle wake and busy-turn drain | Blocked/approval-needed notices and a human job inbox |
| Recovery | Reconcile uncertain submissions without blind replay; identity mismatch/unreachable are not success or interruption; durable worker admission with an activation-bound terminal receipt ([WIRE.md](WIRE.md) "Durable task admission") | Multi-activation/continuation records and a receipt retention policy |
| Cancellation | `fleet_task_cancel` cancels only queued, undispatched tasks | Confirmed cancellation of active remote work |
| Approval | Submission approval locally; worker explicitly receives `approvals: ask`; read-only tasks by default; operator task profiles ∩ an exact human grant ([WIRE.md](WIRE.md) "Task policy"), enforced at birth with the honest `unconfined` verdict | No default unattended mode (by design); no human UI for profiles/grants |
| Scheduling | Optional heartbeat, durable admission marks, daily attempt cap | Cron, daily token/cost budgets, retention and completion integration |

The implementation is in `components/fleet`, runner notice handling in
`core/conversation.nim`, and client surfaces in the separate `niffler-tui` repo.
The task allowlist's model-originated dispatch checks are an authority boundary,
not merely a prompt hint.

### Acceptance already recorded

- Hermetic two-instance NATS/mock-model tasks, notice delivery to idle/busy
  parents, wake-budget decline, restart dedup, owner checks, uncertain-outcome
  non-replay and store-failure tests.
- Incus local and SSH-hosted provisioning evidence; local Lima/KVM image boot,
  published-revision bootstrap, service/identity/loopback checks. See
  [LIMA-VALIDATION.md](research/LIMA-VALIDATION.md).
- The bootstrap lost-reply mechanism was reproduced on a fast-heartbeat bus:
  blocking transport waits starved the Nim client's protocol pump. The fix
  services protocol traffic without running other handlers re-entrantly.
  The original long VM bootstrap has not been repeated with that fix.

These do not certify macOS/VZ, every SSH topology, or real-provider coding
execution. A local test pass is not a release or installed-version claim.

## 3. Boundaries to preserve

- **One bus namespace per instance.** No shared unrestricted subjects, no public
  unauthenticated NATS listener. Identity pinning is routing protection, not
  authentication; SSH/management-account trust remains substantial authority.
- **A remote task is a root conversation on the worker.** Its local subagents
  belong to that worker and send notices to their remote parent, not directly
  to the requesting conversation. The requester owns a horizontal job pointer,
  not remote `sessionmeta.parent` lineage.
- **Core owns admission and enforcement; Fleet owns orchestration.** Core does
  not import Fleet code. Components do not directly rewrite another runner's
  transcript or frozen controls. New admission/control seams must be generic,
  with versioned capability checks; unsupported peers refuse before dispatch.
- **Single-hop remote delegation initially.** Granting coding tools must not
  indirectly grant `fleet_*`, arbitrary core control, store mutation or a
  capability-building route. Audit `invoke`, Fabric, builder, plugins, MCP,
  shell bus access and local subagent inheritance explicitly. A tool-name deny
  list alone is not a sandbox, especially once arbitrary shell is granted.
- **No silent escalation.** A cwd, discovered worktree, returned path, model
  argument or failed call never grants authority. No automatic credential
  copying, mounts, retry with wider rights, or automatic artifact application.
- **State belongs to its writer.** Fleet owns requester jobs/delivery state;
  worker runners own admissions, turns and completion receipts; clients own
  human seen state. No competing writers for one record.
- **Stable primary workspace per conversation.** Extra roots and task worktrees
  need explicit authority; a continuation retains its birth workspace and
  frozen model/tools/budgets unless an independently designed control allows
  changing them. A different birth policy starts a new task conversation.

## 4. Three kinds of receipts—not one success flag

| Receipt | Establishes | Does not establish |
|---|---|---|
| Connection/provisioning receipt | Verified route, instance identity and installation root/revision | Task admission, completion or permission to run arbitrary code |
| Task admission/terminal receipt | A specific request/activation was accepted, and its authoritative lifecycle outcome | That the worker's prose is factually correct |
| Verification/artifact evidence | Observed command, exit status, revision/diff and bounded artifact metadata | That tests are adequate or all requested behavior is correct |

Keep **dispatched**, **accepted**, **settled**, **verified** and **integrated**
distinct. Lease claims describe possible write reach, not observed mutations.
An LLM judge can assess evidence, but cannot manufacture a missing receipt.

### Durable task identity and state

Extend the existing owner/request-ID binding; persist immutable normalized birth
settings and their digest before submission. Bind the peer identity, remote
session, activation ID, task policy version and original requester. Reusing a
request ID with different settings refuses.

The next admission seam needs a durable **worker-side idempotency key**: retrying
an exact admission may return its existing acceptance, never run another turn.
A requester crash before/after send and a lost acceptance reply must be
reconcilable by that key. Until the peer advertises this guarantee, keep the
current conservative no-replay behavior—even if a job remains unknown.

Separate lifecycle from connectivity:

- Lifecycle: proposed `queued → admitting → accepted/running → settled`.
- Connectivity: reachable/unreachable/identity-refused, with last confirmed
  observation and checked time. Unreachable does not overwrite lifecycle.
- Blockers: reason and required human action; not an invented terminal success.
- Outcome: done, failed, cancelled, budget-exhausted or interrupted **only when
  supported by worker evidence**. Missing evidence remains unknown.

One task may eventually have multiple activations. Bind receipts and results to
an activation, not just the latest-per-conversation `activity` record: a later
human turn must never replace the evidence for an earlier delegated task.
Persist terminal receipts long enough for disconnected requesters to reconcile;
retention requires an explicit policy, not unbounded accumulation or early loss.

## 5. Unattended approval policy

**Target default:** tasks submitted through a human-approved unattended coding
profile should run ordinary granted tools without repeated approval prompts.
This is a task-scoped grant—not global auto approval and not automatic authority
because the model asked for it. Until the policy seam is implemented, current
Fleet remains read-only and `ask`.

### Two decisions, enforced at the worker

1. The worker operator configures which task profiles/roots/capabilities/budget
   ceilings may run unattended. Default: no new unattended coding authority.
2. The requesting human approves using a permitted profile for this exact task,
   workspace and budgets. A pre-authorized peer profile can cover repeated tasks
   only with explicit scope, inspect/revoke controls and recorded policy version.

The effective policy is the intersection of those decisions. Caller arguments
cannot widen the peer's ceiling. A normal local tool approval is not proof of
remote authorization: design a worker-verifiable admission grant tied to peer,
request digest, policy version and activation. The trusted-local bus is not an
untrusted multi-tenant security boundary; document that deployment assumption.

Admission returns the **effective** policy before work begins. If requested
unattended mode is refused, reject clearly—do not silently start in `ask` and
wait for a human who is not attached. Never set `NIF_AUTO_APPROVE=1` on the peer.
Blanket conversation auto mode must not bypass sandbox-specific root/network
or trusted-unconfined-tool approvals.

### A blocked task is visible, not forgotten

For an exceptional action outside pre-approved capabilities:

- Persist an approval-needed/blocked record with an activation-bound action ID,
  precise authority requested, deadline and reason, before notification.
- Notify the requester and the peer's attached human; actual approval must be
  presented and enforced on the authoritative peer. Do not relay an unscoped
  “yes” across machines.
- Background TUI prompts identify instance, conversation, task and action.
  Switching/connection loss cannot approve or transfer a stale prompt.
- Unattended tasks never wait indefinitely: timeout/deny yields an explicit
  blocked or failed outcome, with a usable report. Resume after a fresh grant
  is explicit and idempotent; do not rerun already-mutating actions blindly.

Approve-from-now-on, child inheritance, revocation and in-flight policy changes
must reuse the agreed sandbox policy semantics rather than create a competing
permission engine. Arbitrary shell on a trusted worker is broad machine access;
workspace labels and tool allowlists alone cannot confine it. Before coding
mode ships, either enforce the relevant sandbox boundary or present the task as
explicitly trusted/unconfined execution under the peer operator's policy.

## 6. Notices, human inbox and results

### Agent delivery (extend what exists)

Keep durable record-before-notify and runner append-before-ack. Add activation
and event sequence IDs for nonterminal events (blocked/resumed) and continuations;
job ID alone is sufficient only for the current one-shot settlement. Re-delivery
may happen after a crash, but must not append the same logical event twice.
Canonical history remains the dedup authority when projections are compacted.

Push is a hint to drain the outbox, not the receipt itself. A busy parent drains
between rounds and before stopping; an idle parent receives the existing bounded
wake. A declined wake leaves pending mail for the next human turn. Notifications
and policy updates enter append-only history, never a changing system prefix.
Bound summaries and include peer, task, activation, outcome/blocker and a pointer
to details. Child prose is labelled as a worker report, not a verified verdict.

### Human inbox (new)

Add an owner-scoped, paged task listing/inbox and a matching TUI surface
(proposed `/niffler tasks` or `/tasks`; settle naming in the TUI repo). Show peer,
objective, last confirmed lifecycle, connectivity, blocker, latest update,
budgets/usage and available result. Opening an instance is not opening every job.

Human seen/dismiss state is client-local and keyed by instance/job/event sequence;
reading a list never acknowledges the model's notice. First connection should
baseline historical completions instead of making all history appear newly
unread. Do not use a cross-runner timestamp watermark: page by stable keys and
merge per-item sequence. Reconnect must reconcile beyond a single 1000-item page.

### Results and artifacts (new)

Return bounded reports plus paged detail for the **specific activation**. Worker
transcripts remain canonical on the worker. Full-detail reads must not leak
another session via cursors, supplied paths or artifact IDs.

A coding result should include base revision, resulting commit/diff, dirty-state
warning, observed verification commands/outcomes and artifact descriptors
(size, media type, digest and ownership). Retrieve immutable bounded artifacts
on demand through a scoped protocol—not arbitrary remote reads or writable host
mounts. Pin the intended base for applying patches; surface drift/conflicts and
require separate approval before integration. Cancellation/partial failure may
still produce useful artifacts; missing bytes or evidence are never fabricated.

## 7. Lifecycle controls

- **Steer:** task-owned, activation-bound mail, persisted before delivery;
  distinguish accepted/queued/delivered. A message never grants new capabilities.
- **Cancel:** request on the worker's existing cancellation path; `cancel-requested`
  is not `cancelled`. Only worker acknowledgement/terminal evidence confirms it.
  Disconnect leaves cancellation pending/unknown, not falsely successful.
- **Continue:** append a new turn with durable admission identity; content-only
  controls keep the worker's cached prefix stable. Failed/cancelled tasks may be
  continued explicitly; closed tasks refuse. No duplicate activation after retry.
- **Budgets:** retain round/call/token caps; add an enforceable runtime deadline
  and ledger-backed spend limits separately. Killing the local transport does
  not prove the remote turn stopped. Define child accounting before allowing
  local subagents; child budgets cannot enlarge the task's aggregate authority.

## 8. Delivery slices and acceptance gates

Each slice gets its own tests and commit; do not postpone correctness until a
single giant Fleet rewrite. Transport-independent contracts use isolated buses
and mock models; live acceptance complements rather than replaces them.

### F1 — Reliable remote admission and receipts

Add versioned worker capability negotiation, immutable task-policy schema,
durable idempotent admission and activation-specific terminal receipts. Keep
read-only behavior until F2. Test duplicate/conflicting submissions, store outage
before/after commit, lost replies, requester/worker restarts, later human turns,
identity changes, paging and stale receipts. No unverified replay.

**Exit:** an accepted task can always be identified and reconciled after a
transport failure, without inferring acceptance or running it twice.

**Status: implemented (core seam + requester binding).** The generic contract is
[docs/WIRE.md](WIRE.md) "Durable task admission":

- `sdk/niffler/admission.nim` (re-exported by `core/admission.nim`) — pure
  record/idempotency module (no store or bus, no core import), shared
  by the runner and the system core so there is exactly one spelling of the
  policy version, key shape, birth-settings digest and receipt vocabulary.
- `handleSessionCall` reads/accepts the admission **before** appending the user
  message or calling a provider, compare-and-sets `accepted → running`, and
  commits the terminal receipt (turnId, outcome, usage, reply digest,
  `transcriptCommitted`) before the human activity receipt. A turn whose
  transcript writes failed stays `running` (honest unknown).
- Catalog `components`/`snapshot` advertise `admissionPolicyVersion: 1`;
  `fleet` refuses a peer without it before dispatch, binds each job to
  `admission.key = <jobid>`, reads the worker receipt after submitting (a read,
  never a replay) and prefers it to the latest-per-session activity record.
- Read-only surfaces: hidden `admission_get {session,key}` on the worker and
  `fleet_task_receipt {jobId}` on the requester.
- Present-but-unusable admission is refused, never downgraded to an ordinary
  turn; session refusals now carry their own `code` (`admission-conflict`,
  `-busy`, `-unconfirmed`, `-invalid`, `-unsupported`) instead of a generic
  runner error.

**Evidence:** `tests/t_fleet_admission.nim` (record, key shape, digest
normalization, lifecycle) and `tests/t_fleet_admission_e2e.nim` (real store +
runner + mock model: accept-before-start, exact replay spending no provider
round trip, conflicting digest refused, `running` refuses, `admission_get`
answers). `t_fleet_tasks` and `t_fleet_faults` still pass.

**Still open in F1:** multi-activation records (continuation), a retention
policy for terminal receipts, and the store-outage-before/after-commit and
requester-restart matrices as explicit contracts rather than incidental
coverage; paging applies once more than one activation exists per key.

### F2 — One unattended coding task

Implement operator-owned worker profiles and exact human task grants. Default
ordinary coding actions to unattended execution only inside that explicit grant;
report trusted/unconfined execution honestly where confinement is absent. Select
an existing worker workspace or approved isolated worktree; preserve dirty work.
Deny control-plane/indirect delegation routes unless deliberately authorized.
Model/agent defaults and effective caps resolve at birth and are recorded.

Test `ask` versus unattended mode, no human present, denied profile, rejected
widening, policy revocation, shell/indirect escape limits and child inheritance.

**Exit:** a permitted edit/build/test task runs without unattended approval stalls,
returns a bounded report plus patch/commit, and refuses outside its authority.
Do not claim general sandboxing as part of this gate.

**Status: the authority boundary is closed and the artifact now ships; two
exit clauses remain open (push authority, scoped artifact retrieval).** An earlier 95-test gate passed before this review; the review
itself found real gaps, each now fixed and covered:

- **Component/core import violation — fixed.** Shared contracts live in
  `sdk/niffler/{admission,taskpolicy,canonicaljson}.nim`; Fleet imports only the
  SDK and core keeps thin compatibility re-exports. A component enforcing a wire
  contract no longer has to import core to do it.
- **Callable control-plane denial — fixed, and widened to schema.** `build`,
  `build_package`, `task_profile_*` and orchestration-family prefixes are denied
  beside the component labels they belong to (`build`, not just `builder`).
  Beyond names, the worker audits its **own** catalog before persisting
  authority (`taskToolSchemaProblem`): a tool it does not serve, one with no
  `x-harness` contract, or any `hidden`/`runner`/`sessionContext`/`noSpawn`
  flag refuses in every mode, so an unfamiliar plugin name cannot smuggle in
  machinery the deny list has never heard of. A third-party plugin is still
  trusted to describe its own schema honestly — the same trust every dispatch
  decision already extends, not a new one.
- **Retry idempotency — fixed.** Durable admission is consulted *before*
  birth-policy resolution and the requested grant is in the admission digest.
  An exact retry returns the existing receipt and executes nothing (provider
  call counts prove it), including after the operator deletes the profile; the
  same key with a different grant refuses.
- **Grant binding — shipped.** The requester hashes the approved authority
  (`profile`, sorted tools, three budgets) into the job BEFORE dispatch and the
  worker recomputes it from what arrived, refusing a changed grant
  (`task-policy-grant-mismatch`). Both the refusal and the unchanged-grant
  acceptance are tested.
- **Stale authority on continuation — fixed by refusing.** Content-only turns,
  image turns and wakes on a task conversation refuse
  (`task-policy-continuation-required`) while live, after profile deletion, and
  after the runner retires and resumes — the stored policy is evidence of what
  was approved, never standing permission for another activation. What remains
  unproven is the stronger claim about the requester's own approval (that it
  was a human decision rather than a tool call the model made) and
  activation-bound *refusal* reporting: a refusal reaches the requester as a
  dispatch error, not as a settled task record.

Unattended submissions also require matching `taskPolicyVersion` before
dispatch; read-only tasks stay compatible with admission-only peers. Missing and
unsupported versions have regression coverage in `t_fleet_tasks`.

The draft generic seam is [docs/WIRE.md](WIRE.md) "Task policy":

- `sdk/niffler/taskpolicy.nim` (re-exported by `core/taskpolicy.nim`) — pure
  module (no store/bus, no core import) holding the intersection
  arithmetic, the control-plane deny set, profile validation, the effective
  policy document and its digest. The runner enforces it, the system core
  re-computes it for `admission_get`, and the requester validates the same
  contract, so three codes cannot disagree about what was authorized.
- Operator profiles: store kind `taskprofile`, written out-of-band by the
  worker's operator via `task_profile_set` / `task_profile_list` /
  `task_profile_remove` (approval-gated; not reachable from a task).
- At birth the runner resolves profile ∩ grant, refuses explicitly on any
  widening, and persists the effective policy in the conversation header before
  a tool can run. Task authority is birth-only: a second grant on the same
  conversation refuses (`task-policy-immutable`), with three witnesses (live
  session, header, admission records) and fail-closed behavior when none can be
  read.
- The gate (`core/approval.nim`) grants a tool because the *policy names it*,
  not because the conversation is in auto mode; a tool outside the policy is
  refused outright instead of waiting for an absent human. `NIF_AUTO_APPROVE` is
  never set on the peer and a caller's `approvals: auto` cannot widen a grant.
- Trustee/unconfined truth: the policy carries `confinement: "unconfined"`,
  `confined: false`, and a profile claiming `sandbox` is refused — this harness
  enforces no sandbox for delegated work, so it will not say otherwise.
- Control plane is never granted in any mode: delegation, self-reconfiguration
  and the record-keeping seam are denied on both sides.

**Evidence:** `tests/t_codingartifact.nim` (real git: base capture, produced
commit, diffstat, dirty/untracked, non-base detection, verification evidence,
unverifiable workspace), `tests/t_taskpolicy.nim` (intersection, widening,
roots, budgets, confinement honesty, control-plane callables and the worker's
own schema audit, grant identity), `tests/t_taskpolicy_e2e.nim` (real store +
runner + mock model: a granted `edit` AND `bash` commit run with no human
attached and the receipt names the repository's real HEAD; widened grants,
unknown/revoked profiles and content-only continuations refuse; retries replay
receipts; no refusal spends a provider round trip), and `tests/t_fleet_tasks.nim`
(the same through `fleet_task_submit`, where the requester's notice carries the
commit the worker made).

**Still open in F2 (do not read this as a finished gate):**
- **The artifact now ships** (`sdk/niffler/codingartifact.nim`): the receipt
  carries the base revision captured at admission, the commit produced, whether
  it is built on that base, the diffstat, dirty/untracked state, and the
  verification commands with their exit status. It is stated in the notice as a
  structured `artifact` plus a one-line summary, so the report is checkable
  beside the change instead of taken on faith. What it does not do: fetch the
  diff bytes or push anywhere (§F4 scoped retrieval; push authority is a
  separate, unimplemented policy field), and it never judges correctness.
- **No workspace isolation** — a task runs in an existing checkout it is
  granted; there is no automatic worktree-per-task or dirty-work preservation.
- **No runtime deadline** — round/call/token budgets exist; a wall-clock
  deadline and ledger-backed spend limits do not (§7).
- **Child inheritance is untested** — a local subagent cannot be spawned by a
  task (no `agent`/`fabric`), so inheritance has nothing to inherit yet; that
  becomes real only if delegation is ever deliberately granted.
- **No human UI** for profiles or the grant beyond the tool arguments.

### F3 — Task control and actionable notices

Add steer/confirmed cancel/continuation and sequenced blocked/resumed/settled
notices. Reuse existing outbox/drain/wake and add activation/event dedup; test
append failure, lost ack, compacted projection, busy/idle/retired parent,
exhausted wake budget, cancellation races and restart during delivery.

**Exit:** the parent learns completion or intervention-needed without polling,
can stop active remote work with an honest confirmation, and can follow up.

### F4 — Human inbox and reviewable artifacts

Expose a paged owner-bound inbox and task detail; implement TUI navigation,
per-job human read state and background-instance approval presentation. Add
scoped artifact retrieval/integration preview and verification evidence.
Test offline completions, first-use baseline, >1000 jobs, identity mismatch,
foreign cursors/artifacts, changed base revision and cancelled partial results.

**Exit:** disconnect, return later, find the task, understand what happened and
review its result without having watched the worker terminal.

### F5 — Live acceptance and release

On approved disposable targets, run a real-provider coding task over local Lima
and SSH-hosted Incus; interrupt the client/requester and a transport, reconcile,
continue/cancel, and receive exactly one logical settlement per activation.
Exercise published-revision install/update/adopt and the long-bootstrap reply
fix; verify persistent service/identity, guest restart, private receipts and no
implicit credentials/mounts/public bus. macOS/VZ needs its own host and evidence.

Run narrow contracts first, then `make build && make test` on the combined commit
plus TUI tests/vet/build in its repo. Record exact revisions, models, target and
cost; publish worker/harness/TUI compatibility requirements and release the TUI
plugin (pushing `main` or a tag alone is not a GitHub release).

## 9. Not prerequisites for the first complete task

Named team mailboxes, symmetric reverse delegation, leaf-node federation,
shared TiDB state, speculative best-of-N reviewers, automatic merge, cron and
cross-fleet cost dashboards remain separate work. Heartbeat can later submit
through the same task admission/authority path; it must not invent another way
to grant auto approvals or exceed task/daily budgets.

## 10. Ownership and prompt-cache effects

| Change | Owner | Provider-visible effect |
|---|---|---|
| Peer profiles/connection receipts | Operator/client and Fleet | No secret routing data in prompts |
| Worker admission/effective policy and terminal receipts | Worker runner/control seam | Birth defaults frozen; live policy updates append history |
| Requester job and notice outbox | Fleet | Bounded notices append history |
| Turn transcript and notice dedup/ack boundary | Session runner | Append-only; no prefix edits |
| Human seen markers, inbox and background prompts | TUI/client | No model acknowledgement or prefix changes |
| Artifact/evidence references | Producing worker and scoped retrieval component | Bounded tool results/history, not frozen prompt data |

Start with **F1, then F2**. F3/F4 complete the experience; do not describe the
current read-only slice as unattended coding delegation before those gates pass.
