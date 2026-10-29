# Fleet simplification

Agreed direction (supersedes the task-profile/artifact-first roadmap in
FLEET.md). Slices 1–3 are implemented; the Fleet-only acceptance run in slice 4
is blocked on a deployment step, not on code (see Slice status):

- Delegate a goal to a named trusted Niffler, like remote agent_spawn.
- Configure explicit worker trust once, off by default, through existing
  configuration/approval mechanisms. Do not invent per-assignment profiles.
  Private bus/SSH access is substantial authority; caller names are not auth.
- Use normal worker capabilities and defaults. Tools, round/call/token limits
  are optional like local agents, not mandatory Fleet-specific ceilings.
  Shell plus worker-owned GitHub credentials can push and create PRs; no
  separate push permission can enforce a boundary behind arbitrary shell.
- Primary result: a detailed natural-language report, with links and blockers.
  Git artifacts are optional evidence, not a completion requirement.
- Continue the remote conversation with content-only follow-ups and a fresh
  durable admission key per activation. Preserve the frozen prefix.
- Preserve route identity, durable intent/admission, duplicate-run protection,
  activation-specific results, record-before-notify and append-before-ack.
  Disconnect is not cancellation; require peer confirmation of stopping.
- Local children report to their worker parent. No implicit recursive Fleet
  authority, automatic credentials, checkout isolation or sandbox claims.
- Keep provisioning separate. Missing Fleet functionality is not an excuse for
  a hidden SSH/CLI delegation implementation.

## Slices

1. Report-first results: cache final prose, page locally through
   fleet_task_result, short notices, legacy summary compatibility; update TUI.
2. Trusted-worker admission: explicit operator configuration, named instance
   resolution, optional limits/tools. Negotiate a new capability; never widen
   old restrictive task policies implicitly. Define honest requester binding.
3. Follow-up and active cancellation: new keys per activation, exact report
   attribution, busy/retry/reconnect tests and stable prompt prefix.
4. Fleet-only acceptance with harmless approved remote work; no SSH workaround.

Buddydrive PR #24 is already assigned independently. Do not dispatch it again.
Each slice gets narrow tests, then the full build/server gate before merging.
No remote trust/service/credential changes are implied by implementing this plan.

## Slice status

- Slice 1 (report paging) — **implemented**: `report`, `offset`, `nextOffset`,
  `hasMore`, `reportBytes`, `reportComplete`; TUI renders paged prose.
- Slice 2 (named worker, pinned route) — **implemented**: `fleet_task_submit
  {instance}` resolves through the registry (name or identity, XOR the legacy
  `profile`) and pins the verified receipt into the job.
- Slice 2b (trusted-worker admission) — **implemented**: one `delegation/settings`
  document per worker (`fleet_delegation_set`/`_get`, approval-gated and on the
  control-plane deny list), off when absent and refused before any turn runs;
  `delegationPolicyVersion: 1` advertised so a requester refuses an older peer
  instead of downgrading to `ask`; tools and budgets optional, explicit values
  may only narrow. Profile-based `unattended` tasks and every stored
  `taskProfile` job keep their recorded policy verbatim.
- Slice 3 (follow-up) — **implemented**: `fleet_task_continue` appends an
  activation to a settled delegated goal on the SAME worker conversation, with
  a fresh admission key and instruction-only changes; the parent's report is
  never overwritten. Active *cancellation* of a continuation is still unproven
  against a real peer (see below).
- Slice 4 (Fleet-only acceptance) — **blocked on a deployment step, not on
  code**: acceptance needs a worker whose build actually carries this branch.
  The registered `worker` instance is pinned at `2890aff`, which has **no**
  `delegationPolicyVersion`, so a delegated goal is (correctly) refused by the
  requester before dispatch. Reaching a real acceptance run means publishing
  this branch, updating the worker with `fleet_update`, and the worker's
  operator enabling trust via `fleet_delegation_set` — all deliberate,
  approval-gated acts.

The requester-side half of that contract is covered by tests
(`t_fleet_tasks`: an older peer refuses a goal; the same peer still serves an
`ask` task), so the compatibility promise is verified even while the live
acceptance run waits on the deployment step.

## Trust model (slice 2b, as implemented)

Unattended authority must be decided on the WORKER, before any turn runs, and
must never become implicit. The pieces:

- A worker settings record (owner-pattern store document, so `config` can show
  and edit it) holding an explicit allow list: `unattended: bool`, permitted
  `tools`, `roots`, optional budgets, and an operator note. Default absent =
  no unattended delegation. Revoking it affects only future admissions;
running tasks keep the policy they were admitted under.
- A new capability version advertised in catalog `components`/`snapshot`.
  Requesters must refuse an older peer instead of silently falling back to
  `ask`, and the worker must refuse an admission whose requested policy shape
  it does not understand.
- The admission digest keeps binding the authority actually used, so an exact
  retry replays a receipt and a widened retry refuses.
- Remaining honest gap: the bus envelope's `caller` is self-declared. Until a
  requester identity is bound to the receipt (operator-configured shared
  secret or a provisioned key), unattended trust means "trusted bus/SSH
  access", exactly like today's `taskProfile`. Do not describe it as
  per-requester authentication.

Optional limits: when a caller omits `maxRounds`/`maxCalls`/`maxTokens` the
worker's settings decide — its own configured ceiling if it set one, else
the runner's normal turn default (for rounds) and no extra cap (for calls and
tokens), exactly like a local `agent_spawn` without budgets. An explicit
caller value may only narrow. A limit that stops work must report
`needs-attention` with the reason.

Compatibility: an existing `taskProfile`-based job keeps its recorded policy
verbatim; the new path never reinterprets or widens it. Old requesters that
still send `taskProfile` keep working while the capability is advertised.

## Report paging (slice 1)

fleet_task_result accepts offset (UTF-8 byte cursor, default 0) and limit
(4..32768 bytes, default 8192). It returns report, nextOffset, hasMore,
reportBytes and reportComplete beside the existing short summary. Reads are
local and require the same job authorization as before. Legacy jobs return
summary-only data with reportComplete:false and explicit detail. Incomplete or
ambiguous transcript scans never claim complete reports. Status and notices
exclude full report bytes; worker claims are not independently verified.
