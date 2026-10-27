# Wire protocol — Niffler

One page. Versioned, boring, identical on every transport (NATS, stdio/NDJSON
behind pipewrap, future HTTP gateway). JSON everywhere by default; codec
upgrades are per-seam via NATS headers, never a global format.

## Instance identity

Catalog `list`, `components` and `snapshot` replies carry `instanceId` (128
random bits encoded as 32 lowercase hex characters) and `name` (`NIF_NAME`,
otherwise hostname), alongside unchanged `root` and `gitHash`. System core
creates `var/instance-id` before spawning children; restarts preserve it and
malformed existing files refuse startup. Backups/clones copying var copy this
identity too: provision fresh roots without copied runtime state. This is routing
metadata, not authentication. It contributes nothing to frozen prompts or
append-only conversation history. Matching TUI clients pin imported receipt
identities before forwarding and on reconnect. Provisioning belongs to the
optional Nim `fleet` component, not core. Its approved mutation tools use the
normal approval gate; receipts are client-local JSON, not prompt context.
Lima clients use the installed native `cli relay` stdio/loopback seam,
never a Python bridge; SSH clients use standard native port forwarding.

### Session stop (cross-process turn cancellation)

`session {sessionId, stop: true}` cancels a running turn from another process.
It publishes the same `__cancel` control a UI emits on
`svc.session.<id>.steer`, so a stopped turn behaves identically however it was
asked for: the flag is raised between LLM rounds and an in-flight tool runs to
completion (bash kills the command's process group).

The reply says `stopped: "requested"`, never "stopped": publishing to a steer
subject succeeds whether or not a turn is running, so claiming an outcome would
be a claim about state nobody verified. The caller confirms from the record.

This exists because the bus-side control is not reachable across machines — a
delegating harness has no connection to the peer's bus, so `fleet_task_cancel`
drives remote cancellation through this op.

## Fleet task settlement

Optional fleet uses requester-owned `fleetjob` documents, never shared remote
stores or core imports. `fleet_task_submit` binds injected `__session.session`,
requestId, immutable receipt route/instance identity and explicit birth budgets
before dispatch. A submission accepts either `instance` (registered name or
32-hex identity) or legacy private `profile` receipt, never both. Resolution
happens only for a fresh job: its verified receipt is pinned into the record,
so removal/renaming of registry entries cannot retarget a retry. Catalog components/snapshot advertise `taskScopeVersion:1`:
model-originated calls in allowlisted sessions may not use runner/store
machinery exemptions. Internal runner persistence remains exempt. Fleet refuses
older peers and restricts its first slice to audited file/search/git read tools;
no invoke/orchestrator, shell, store or further delegation authority.

Only `queued` permits submission. Persisting `submitting` spends that permission
before remote preparation/submission; uncertain outcomes remain unknown, never
replayed or inferred successful/interrupted from disconnection. A durable remote
activity receipt establishes turn settlement, not factual task success. Remote
budgets use supported maxRounds/maxCalls/maxTokens, not a transport timeout as a
wall-clock deadline. Cancel is local queued-only; later cancellation is explicit
on the peer. The result tool reads a locally cached prose report, not a blocking relay.
`fleet_task_result {jobId, offset?, limit?}` returns `report`, `nextOffset`,
`hasMore`, `reportBytes` and `reportComplete`, alongside the short `summary`.
Offsets are UTF-8 byte boundaries, limit is 4..32768 bytes (default 8192).
Continue with `offset: nextOffset` while `hasMore`. Legacy jobs return their
summary with `reportComplete:false` and explicit detail. Ambiguous or capped
transcript scans never claim complete reports. Full reports are excluded from
status/notices; reading them never contacts the peer or replays work.

Terminal job and `notice:{kind:"fleet-settled",jobId,status,summary}` commit in
one revision before notification. A real transition into `settled` also
publishes `ev.fleet.settled` (an event, fire-and-forget): `{jobId, state, peer,
peerId, objective, status, activation, summary, transcriptCommitted, artifact?,
at}`. It exists so a connected client can alert instead of polling, and it
grants nothing — a client that wants to act calls a tool like any other caller.
No listener is required: the job record is the durable truth, so a missed event
costs a later read, never the notice. Re-reads of an already-settled job never
re-emit, so a client cannot be re-alerted by polling. Summary is a 2048-byte UTF-8-safe prefix plus
optional ellipsis. Hidden runner tool `fleet_notices {session,peek?,ack?}` reads
without consuming; ack marks delivered only for that owner. The conversation
runner appends a machinery message durably BEFORE ack. It scans canonical
messages to deduplicate replay after restart/compaction; failed append never
acks. Both opening and would-stop drains participate. Idle wake attempts use
the existing bounded wake admission; declined wakes leave notices pending.
Retries recover record-before-notify and append-before-ack crashes. Human
activity and client seen markers remain independent. Frozen prefixes do not
change; only appended notice messages enter model history.

## Durable task admission

A delegated turn that cannot be retried safely either runs twice or is lost.
Both sides therefore speak an idempotency contract; it is generic (Fleet holds
a pointer, core owns the record) and versioned, so an unsupported peer refuses
*before* dispatch.

A session call may carry `admission: {key, policyVersion}` (or the bare string
shorthand) alongside `content`. `key` is 1..128 bytes of `[A-Za-z0-9._:-]` and
belongs to the caller; the worker never invents one. Present-but-unusable
admission is refused (`code: admission-invalid`), never downgraded to an
ordinary turn — the caller would believe its work was idempotently recorded.
An unsupported `policyVersion` refuses with `code: admission-unsupported`.
Admitted turns need `content` and cannot be wakes or heartbeats.

Peers advertise the capability as `admissionPolicyVersion` in catalog
`components` and `snapshot` (alongside `taskScopeVersion`). This harness
defines `admissionPolicyVersion: 1`; a requester that requires admission
refuses a peer without it.

Store kind `admission`, id `<sessionId>:<key>`, one record per activation:

| Field | Meaning |
|---|---|
| `digest` | SHA-256 over canonical JSON of the normalized birth settings: `policyVersion`, `workspace`, `content`, sorted unique `tools`, `maxRounds`/`maxCalls`/`maxTokens` (0 = unset), plus `agent`/`model`/`provider`/`thinking`/`toolset` only when non-empty. Approval mode, titles, wake markers and retry-only fields are not birth authority |
| `state` | `accepted` → `running` → `settled` |
| `activation` | Activation number (1 for the current one-shot slice) |
| `turnId`,`outcome`,`turnOutcome`,`usage` | The terminal receipt of *this* activation, written with it |
| `transcriptCommitted`,`replyDigest`,`replyChars` | Whether the turn's transcript writes all landed, and the identity/size of the reply |

Lifecycle rules, in order:

1. Read the record. Absent → write `accepted` with `expectRev: -1` (create
   only). A concurrent creator's `rev-conflict` is answered by re-reading, never
   by overwriting.
2. Present with a different `digest` → refuse `admission-conflict`. An accepted
   admission is immutable; this is what makes "same key, different work"
   impossible.
3. `settled` → return `{ok:true, admissionReplay:true, admission:{…}}` and run
   nothing. The receipt is what the worker observed, never a factual-success
   verdict.
4. `running` → refuse `admission-busy` with the receipt. A turn may have
   started, so a second one is a replay; the caller reconciles instead.
5. `accepted` → compare-and-set to `running` **before** appending the user
   message or calling a provider. A failed CAS re-reads: another caller won
   (`admission-busy`) or the store is unreachable, in which case the untouched
   `accepted` record still permits a later exact retry
   (`admission-unconfirmed`, no turn started).

After the turn, the terminal receipt is committed with `expectRev` against the
`running` revision, retried once against the durable record. A turn whose
transcript writes failed stays `running` (an honest unknown) instead of
recording a receipt for history that is not durably there. A settled response
carries `admission:{…}`; the ordinary fields are unchanged.

Hidden read-only core tool `admission_get {session,key}` returns
`{ok,known}` — `known:false` plus a note when nothing was admitted under that
key, otherwise `{state,ageSeconds,admission:{…}}`. It never starts, resumes or
repairs work. Requester tool `fleet_task_receipt {jobId}` exposes the same
receipt, cached on the job pointer.

Unreachable, unknown and receipt-less remain neither interruption nor success.
The admission record does not extend authority: a caller cannot widen a peer's
ceiling by naming a profile in it, and the record is read from the same store
its writer owns.

## Trusted goal delegation (`mode: "delegate"`)

The simplified form of the above: **one** operator decision per machine instead
of a named profile per assignment, with tools and budgets optional.

- Worker setting: store kind `delegation`, id `settings` — the same document
  shape as a task profile (`unattended`, `tools`, `roots`, optional budgets,
  `confinement`), written only by `fleet_delegation_set` (approval-gated, and on
  the control-plane deny list so a task can never write it). Absent = off.
- `delegationPolicyVersion: 1` is advertised in catalog `components`/`snapshot`.
  A requester asking for `mode: "delegate"` refuses an older peer rather than
  downgrading to `ask`; the worker refuses a grant whose shape it cannot honor.
- Grant: the session call's `task` carries `{delegate: true, workspace, …}`. An
  omitted `tools`/`maxRounds`/`maxCalls`/`maxTokens` takes the worker's ceiling
  (and, for rounds, the runner's ordinary turn default when the ceiling is 0);
  a named value may only narrow, and a wider one refuses with
  `task-policy-widened`. Control-plane tools are refused in every case
  (`task-policy-denied`), as is `confinement: "sandbox"` — this harness
  enforces no sandbox for delegated work and will not claim one.
- The resolved policy is persisted in the conversation header exactly like a
  profile-based task (`profile: "trusted-delegation"` when it came from the
  setting), so an exact retry replays its receipt and a widened retry refuses.
- **Not authentication.** The envelope's `caller` is self-declared; `enabled:
  true` trusts reachability of that private bus/SSH route. Old `taskProfile`
  jobs keep their recorded policy verbatim and are never reinterpreted.

## Continuation (`fleet_task_continue`)

A settled DELEGATED goal can be continued in the same worker conversation:
`fleet_task_continue {jobId, requestId, content, close?}`.

- The new job carries the **parent's** `sessionId` and pins the parent's
  receipt, so every remote read and the turn itself address the conversation
  that already holds the context. A first activation has `sessionId == id`,
  which is why this distinction is easy to miss and is now explicit throughout
  `reconcileJob`.
- Only `content` (and `close`) may change. `cwd`, `instance`/`profile`,
  `tools` and the three budgets refuse if named: authority was frozen in the
  conversation header at birth, and re-stating it would be a second negotiation.
- The activation carries its own admission key (`<jobId>`), so a retry replays a
  receipt and can never run the follow-up twice. Its result is attributed to
  that activation; the parent's cached report is never overwritten.
- Sending a `task` grant to a delegated conversation is refused
  (`task-policy-immutable`); a content-only turn onto a delegated conversation
  is accepted **only with an admission key**, and without one refuses
  (`admission-invalid`) rather than running an activation nobody can prove. A
  profile-based `unattended` task keeps refusing content-only turns
  (`task-policy-continuation-required`) — that is the stale-authority guard.
- `close: true` marks the goal closed after a **successful** continuation; a
  failed or cancelled one leaves it open so the human can retry.
- An explicit `error` from the peer is recorded as the job's `diagnostic`
  instead of vanishing; a transport timeout stays silent, because that is the
  genuinely-unknown case durable admission exists for.

## Task policy (unattended authority)

An unattended task runs ordinary coding tools **without approval prompts**,
inside authority that two independent decisions define:

1. the **worker operator's** profile — store kind `taskprofile`,
   id = the profile name, written out-of-band by the operator (never by a
   model, never by a task);
2. the **requesting human's** grant — `task` on the session call, approved at
   submission by the requester's own gate.

The effective policy is the intersection, resolved on the worker **before any
tool runs** and persisted in the conversation header. A caller can only narrow
the operator's ceiling: anything wider is refused with a reason, never silently
clamped. `taskPolicyVersion: 1` is advertised in catalog `components`/`snapshot`
alongside `taskScopeVersion` and `admissionPolicyVersion`.

Operator profile (`task_profile_set` / `task_profile_list` /
`task_profile_remove` on the fleet component):

```json
{"name": "coding", "unattended": true, "confinement": "unconfined",
 "tools": ["read", "grep", "edit", "bash", "write"],
 "roots": ["/home/ubuntu/work"],
 "maxRounds": 8, "maxCalls": 40, "maxTokens": 200000,
 "note": "operator-only, never sent to a requester"}
```

Unknown fields are refused. `tools` must list at least one; `roots` entries must
be absolute and may not be `/`; every budget must be present (an unbounded
unattended task is exactly what this seam exists to prevent).
`confinement` is `unconfined` in this version: a profile claiming `sandbox` is
refused, because no sandbox is enforced for delegated work yet and saying
"confined" would be a claim a human could rely on.

Session call:

```json
{"sessionId": "fleet-…", "content": "…",
 "task": {"profile": "coding", "workspace": "/home/ubuntu/work",
          "tools": ["read", "edit", "bash"],
          "maxRounds": 4, "maxCalls": 20, "maxTokens": 50000,
          "grantDigest": "sha256:…"},
 "admission": {"key": "fleet-…", "policyVersion": 1}}
```

`grantDigest` is optional on the wire but always set by `fleet_task_submit`: the
requester hashes the approved authority before dispatch and the worker
recomputes it (see "Grant binding" below).

The grant is **activation-scoped**, with birth settings frozen for its
conversation. An exact task admission retry returns its durable receipt without
executing work or consulting current profile settings. Its digest includes the
requested `task` grant; changing that grant under the same key refuses
(`admission-conflict`). A different grant needs a new conversation
(`task-policy-immutable`).

Until a fresh-grant continuation protocol is implemented, content-only turns,
image turns and autonomous wakes on a task conversation refuse with
`task-policy-continuation-required`. A persisted policy is historical evidence,
not authorization for another activation. This applies both to a live runner
and after retirement/restart, including after the operator deletes the profile.
Receipt retries remain readable after revocation. In-flight revocation is a
separate, unimplemented lifecycle boundary; no termination guarantee is claimed.
Three witnesses identify a task (in-memory session, header, admission records);
unreadable policy history fails closed (`task-policy-unconfirmed`). These
controls add no provider prefix data or transcript messages on refusal/replay.

Effective policy (stored as `taskPolicy` in the header, returned in the turn
result and in the admission receipt):

```json
{"version": 1, "profile": "coding", "unattended": true,
 "tools": ["bash","edit","read"], "roots": ["/home/ubuntu/work"],
 "workspace": "/home/ubuntu/work",
 "budget": {"maxRounds": 4, "maxCalls": 20, "maxTokens": 50000},
 "confinement": "unconfined", "confined": false,
 "controlPlaneDenied": true, "digest": "sha256:…"}
```

`digest` is SHA-256 over canonical JSON of the policy with its own `digest`
field excluded, so a policy and its published form hash the same.

**Refusal codes:** `admission-conflict`, `admission-invalid`,
`admission-unsupported`, `admission-unconfirmed`, `task-policy-invalid`,
`task-policy-denied`, `task-policy-widened`, `task-policy-refused-root`,
`task-policy-unsupported`, `task-policy-unavailable`,
`task-policy-unconfirmed`, `task-policy-immutable`,
`task-policy-continuation-required`, `task-policy-grant-mismatch`.

**Grant binding.** Before dispatch the requester hashes the authority the human
approved — `profile`, the sorted/deduped `tools`, and `maxRounds`/`maxCalls`/
`maxTokens` — into `task.grantDigest` and records it in its durable job. The
worker recomputes it from what actually arrived and refuses a mismatch with
`task-policy-grant-mismatch`; this closes the window opened by recording the
grant before dispatch but executing it later. `workspace` is deliberately not
in the digest (the two peers spell one directory through different
filesystems) — `roots` bounds it on the worker instead.

The **worker audits its own catalog** before persisting an effective policy
(`taskToolSchemaProblem`): a tool it does not serve, a tool with no `x-harness`
contract, and any `hidden`/`runner`/`sessionContext`/`noSpawn` flag refuse with
`task-policy-denied` in every mode. That check is by schema, not by name, so a
plugin the deny list has never heard of cannot opt into orchestration access by
being novel.

**Control plane is never task authority**, in any mode and whatever a profile
says: `fleet_*`, `agent*`, `invoke`, `fabric`, `session*`, `spawn`/`kill`/
`remove`, `build`/`build_package`, `plugins*`, `mcp`, `toolset`/`profile`,
`conversation_delete`, `admission_get`, `taskprofile`, `task_profile_*`,
`heartbeat_*`, `ui`, `put`, `del`. Both sides check it; the requester refuses
to request it and the worker refuses to resolve a policy containing it. The
match is on **callable** names, not component labels (`build`, not `builder`),
and family prefixes keep a future `fleet_*`/`agent_*`/`plugin_*` tool denied
without editing the list.

**The honest limitation:** `bash` is broad machine access. This slice does not
confine it — not to the workspace, not to the machine. A workspace label, a tool
allowlist and `x-harness.effect` are not a sandbox, and the notice a requester
receives says `unconfined worker` for exactly that reason. Granting coding tools
is trusted/unconfined execution under the peer operator's policy
(docs/FLEET.md §5); it is not sandboxing and must not be described as such.

### Coding task artifact

The **result** of an unattended coding task is the change it produced, not a
description of it (docs/FLEET.md §6). The receipt therefore carries an
`artifact`, observed on the worker's checkout:

```json
{"version": 1, "observed": true,
 "base": {"commit": "<full sha>", "short": "<7>"},
 "head": {"commit": "…", "short": "…", "subject": "fix the failing test",
          "branch": "main"},
 "headMoved": true, "producedCommit": true, "onBase": true,
 "diffstat": " note.txt | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)",
 "dirty": false, "untracked": 0,
 "verification": [{"command": "make test", "exitCode": 0, "ok": true}]}
```

- **`base` is captured at admission**, before any tool runs. "What did it
  change" is only answerable against a revision recorded before the work; a task
  that commits and then rebases would otherwise look like it built on nothing.
- **`onBase`** reports whether the base is an ancestor of `head`. A commit that
  replaced the base (reset, rewritten branch) is reported as *not* built on the
  approved base rather than as a clean continuation.
- **`producedCommit: false`** is a real, reportable outcome — a task that left
  its work uncommitted says so, alongside `dirty` and `untracked`.
- **`verification`** is a record, never a verdict: the command and its exit
  status, so "verified" and "claimed" stay distinguishable. A failing command is
  surfaced in the notice's one-line summary even when nothing was committed.
- **`observed: false`** means the worker could not look (not a checkout, or not
  permitted to observe). Missing evidence is stated, never fabricated.

**A link, not a diff.** `head.url` carries a browseable link to the commit,
derived from the checkout's own `origin` (`git@host:owner/repo.git`,
`ssh://…` and `https://…` all reduce to `https://host/owner/repo`). Pasting a
diff into a terminal notice is noise; the link is what a reviewer can act on, so
the prose summary carries the URL and only a file *count*, never diff content.
A checkout with no browseable origin yields no link at all — a URL that goes
nowhere is worse than none.

`artifactSummary` renders that one-line form
(`artifact: commit 56fe18a "fix the note file" (1 file changed)` plus the URL),
and `artifactProblem` refuses a version a reader does not understand. This is
**evidence that something changed**; whether the change is correct remains a
human review decision, and nothing in the receipt claims otherwise.

## Human completion activity

Hidden read-only core tool `activity_list {after?:string,limit?:1..1000}`
(default 100) returns `{items,hasMore,nextAfter}`. Each item is
`{id,sessionId,turnId,seq,outcome,at}`: `id` equals `sessionId`, `seq` is a
positive per-session completion counter, `at` is Unix seconds, and `outcome`
is `done`, `failed`, `cancelled`, or `needs-attention` (hard/soft budget
endings). This is the **latest completion per conversation**, not a log of
all turns. Several offline completions intentionally collapse into one unread
conversation. Store kind `activity` is keyed by session ID; deletion of a
conversation deletes its activity too. Session IDs must not be reused after
deletion if a client retains old seen markers.

Subscribe to `ev.activity` before listing: its event-envelope payload is the
same persisted item, published only after the completion receipt commits and
only if this turn had no failed transcript writes. Persisted receipts survive
runner/core restarts; a crash after receipt commit but before publish is
recovered by listing. A crash before receipt commit (including killed mid-turn),
a lost transcript write, or a store outage can leave no receipt: absence is
**unknown**, never success. There is no atomic transcript/receipt transaction
and no guaranteed completion for a killed runner. Unexpected exceptions may
also have only the legacy terminal event, without a durable receipt.

On connect/reconnect, page the **entire snapshot from empty `after`**. `after`
and `nextAfter` are lexically ordered session-ID page cursors, NOT incremental
completion/time cursors. Pages are not a frozen snapshot: a new session inserted
before the cursor is seen through the live subscription or the next full scan.
Different runner commit order cannot cause a permanent time-watermark skip.
Merge push and snapshot by `(instanceId,sessionId)` keeping the largest `seq`;
deduplicate repeated `turnId`/`seq`. Human seen markers are client-local and
must advance only when that conversation is read, never by listing. They are
independent of agent settlement-notice acknowledgements. No activity data enters
the frozen system/tool prefix or conversation history.

The Go SDK's `NewWithURL(name, version, url)` pins one component to an explicit
bus without changing environment or loading dotenv; empty URLs are refused and
re-attachment retries only the pinned endpoint. This permits in-process clients
for multiple instances without process-global endpoint mutation.

## Context health

On-demand, read-effect core tool `context_status {sessionId?:string}` reports
stored context health. During a session turn an omitted/empty ID is injected
from that runner; direct callers must supply an ID. Unknown IDs and store
failures refuse rather than inventing an empty conversation.

The result contains `sessionId`, `window`, `used`,
`usageSource:"last-persisted"`, `trimAt`, `warnAt`, `outputReserve`, optional
`promptTokens`, and `trimThrough` (highest canonical sequence dropped by lossy
trim, zero if none). For a known window it adds `usedPercent`, `trimPercent`,
`headroomTokens` (clamped to zero), and `state:"ok"|"warning"|"trim-needed"`.
This is the last persisted occupancy, **not** the measured next request;
`trim-needed` does not claim a trim is running. Threshold arithmetic is shared
with admission, using the persisted output cap and current `NIF_CTX_RESERVE`.
Older headers without an output cap use the default reserve until refreshed.

`projection` is null or `{generation,covered,retained,prunes}` (the last two
are counts). Positive `trimThrough` adds `lostRecallRef` pointing to the first
canonical message and a structured `lossNotices` entry
`{kind:"history_omitted_without_summary",through,recallRef,compactFailures,compactReason}`.
These entries describe durable loss, not the runner's exact rendered synthetic
notice text. Positive failure counts also add top-level `compactFailures` and
`compactReason`.

`retainedSnapshots` lists compaction-input metadata
`{id,trigger,createdAt,canonicalHigh,bytes}` without page contents. Inputs may
be stale, failed or still in flight: existence does not certify retryability.
A failed listing adds `snapshotError`; an empty list with that field is not
proof no inputs exist. Store reads are independent, not an atomic snapshot.
The tool never compacts, retries, writes history or changes the frozen prefix;
when a model calls it, its normal tool result enters append-only history.

## Scheduled turns (heartbeat)

The opt-in heartbeat component publishes `session {sessionId, content,
notice:{kind:"heartbeat",id}}`. The runner requires an enabled heartbeat
record with the same session and prompt, checks `NIF_HEARTBEAT` and the rolling
24-hour `NIF_HEARTBEAT_MAX_PER_DAY` admission limit, and records a unique
`heartbeatmark` before inference. Store failures decline admission. A busy
runner refuses; scheduled turns never queue. Admitted messages carry the
heartbeat notice marker in durable history, not in provider-visible metadata.
Prefix effect: append-only history, unchanged system prompt and tool schemas.
Scheduling attempts are reserved before publication; a crash may lose a tick.
Fire-and-forget dispatch reports attempts, not completion. Results live in the
conversation transcript. See components/heartbeat/README.md.

## Agent definitions and toolsets

`persona` store documents contain `{name, body}`: prompt text only. `agent`
store documents contain technical birth defaults: `persona`, `toolset`, `model`,
`provider`, `thinking`, `tools`, `cwd`, `maxRounds`, `maxCalls`, `maxTokens`,
and optional `name`/`note`. `session {agent}` and fresh `agent_run`/`agent_spawn
{agent}` resolve these with explicit arguments taking precedence, including
explicit empty values. Unknown definitions, invalid types and unsupported
fields refuse. Definitions cannot carry `approvals`; approval authority stays
with human session controls. Selection is birth-only, recorded in the header;
continuations never reapply edited documents. Prefix effect: frozen at birth.

`toolset` is the canonical selector-list CRUD tool and store kind;
`session.toolset` and `NIF_TOOLSET` select it. Legacy `profile` tool/argument,
`NIF_PROFILE` and stored documents remain readable. New spelling wins when both
are supplied. List replies and frozen exposure records retain legacy keys for
released clients. The legacy tool is hidden; canonical toolset is on demand.
Neither spelling alters an existing conversation's frozen schemas.

## Envelope

```json
{
  "v": 1,
  "id": "01J...",          // uuid, every message
  "kind": "call",          // call | result | event | error
  "tool": "bash",          // tool name (call/result/error)
  "args": {"cmd": "ls"},   // tool arguments (call only)
  "payload": {...},        // event payload (event only)
  "error": {"code": "...", "message": "..."},  // error only
  "caller": "tui"          // component name of the call originator (call only;
                            // self-declared routing hint, not an auth claim)
}
```

Rules:

- `call` → `result` (or `error`), matched by `id`. One reply per call.
- `args`/`payload` are JSON values (objects, or anything JSON — array, string).
  Tool-history projection uses bare strings raw (no JSON quotes/escapes),
  an object's string `text` when present, otherwise serialized JSON;
  machine-readable bus results are unchanged.
- Missing fields are omitted, never null. Unknown fields ignored (forward compat).
- Errors: `code` is a stable machine string (`timeout`, `no-tool`, `boom`),
  `message` is human text.
- A request carrying malformed JSON or a non-`call` envelope receives a
  `bad-envelope` error when it has a reply subject. Decodable inputs preserve
  their envelope id in that reply.
- Interactive frontends (UIs) register with `"client": true` in reg.publish.
  A core spawned with `NIF_AUTOSTART=1` (the SDK's `ensureHarness`) exits
  when the last interactive client departs; a manually started core never
  self-terminates.
- Streaming: a caller may send `call` frames, each carrying a chunk, and a
  final `result` frame with `done: true` (custom field). `ev.*` streams
  (LLM tokens) are chunked events on a dedicated subject instead.

## Subjects

```
reg.publish            # component process announces itself on connect
                       #   {name, version, pid, tools: [ {name, schema} ], client?,
                       #    slash?: [SlashCommand]}; repeated logical name +
                       #    identical contract joins its replica group
reg.depart             # {name, pid, ...}, graceful process departure; the logical
                       #   component remains while another replica PID is live
svc.<component>.call   # queue-grouped request/reply (one replica handles each call)
svc.session.<id>.call  # session runner for conversation <id> (queue "session"):
                       #   tool "session" {sessionId, content?, provider?, model?,
                       #   thinking?, title?, cwd?, profile?, discovery?, tools?,
                       #   maxRounds?, maxCalls?, maxTokens?, approvals?, limits?,
                       #   compact?, export?, wake?};
                       #   content runs a turn; model-only calls persist/resolve
                       #   selection without inference; model present + empty clears
                       #   the conversation override. provider pins the conversation
                       #   to a stored nickname (empty clears to the harness-global
                       #   default); a model-only call pins the provider the model
                       #   resolves under in the same header write — provider and
                       #   model are one selection, never separate halves (see
                       #   "Provider/model pins are one selection"). thinking
                       #   (low|medium|high|max,
                       #   empty clears) persists a per-conversation thinking-effort
                       #   selection forwarded to the LLM as reasoning_effort
                       #   (provider-dependent; providers without support never see it).
                       #   approvals?/limits? are the human's mutable conversation
                       #   controls; compact? runs the compactor now (no turn);
                       #   export? returns the exact provider request (no turn);
                       #   wake? runs a notice-only turn — see "Autonomous wake".
                       #   attachments? is a turn's dropped images — see
                       #   "Attachments (images in a turn)".
                       #   profile names a stored tool profile resolved into the
                       #   direct toolset once, at the first call (unknown names
                       #   fail the call; resumes ignore the argument — the
                       #   snapshot is byte-stable). discovery {…} is an explicit
                       #   client discovery: it runs `discover`, appends the
                       #   schemas as a user message and records them, with no
                       #   LLM turn. tools/maxRounds/maxCalls/maxTokens are frozen per-session
                       #   controls (first call wins, then the conversation header
                       #   carries them across runner resumes): a tool allowlist,
                       #   LLM rounds per turn (1-NIF_MAX_TURN_ROUNDS when explicitly set;
                       #   default 1000), total tool dispatches per
                       #   turn (1-500), and cumulative tokens per turn — budget
                       #   exhaustion ends the turn as a budget-exhausted error.
                       #   approvals/limits are the human's conversation controls
                       #   (see "Conversation controls"): mutable per conversation,
                       #   persisted in the same header — a gate mode (ask|auto) and
                       #   SOFT turn limits (rounds/tokens/seconds) that ask the human
                       #   instead of ending the turn
svc.session.<id>.steer # fire-and-forget event envelope {content} injected into the
                       #   running turn as a user message ("Steer: ..."); folded in
                       #   before the next LLM round or before done (no reply)
svc.session.<id>.advise # turn-bound advisory request/reply (the expert peer,
                        #   research/EXPERT.md): {sessionId, turnId, source, content, ...};
                        #   answered {accepted, reason?} — accepted only while
                        #   that exact turn is live (stale-turn, no-active-turn,
                        #   advisory-limit, duplicate, ...); never queued past it
svc.session.<id>.map    # fire-and-forget event envelope {workspace, conversationId,
                        #   map} from the repomap component: a finished workspace map
                        #   the runner appends to history once (append-only, never
                        #   the frozen prefix — a later trim lets the repo_map tool
                        #   re-create it). Gated on by default
                        #   (NIF_REPOMAP_AUTOAPPEND=0 opts out;
                        #   research/REPOMAP-GATES.md); a map that never arrives
                        #   never fails a conversation
svc.session.<id>.diag   # fire-and-forget event envelope {conversationId, path, text,
                        #   clean} from the lsp component: rendered diagnostics for a
                        #   file you just edited, delivered when the server answered
                        #   (instead of making the edit wait). Non-clean verdicts append
                        #   to history once; a clean:true whole-file verdict is
                        #   display/storage-only (kind diagnostic) and never enters
                        #   model history. A cold or absent server yields a one-line note
cancel.<component>     # turn-cancel side-channel (see "Cancellation"): a runner
                        #   publishes an event envelope {sessionId, tool, ts} when
                        #   it abandons an in-flight dispatch; components opt in
                        #   by subscribing and matching sessionId (bash kills the
                        #   command's process group; others drop it)
ev.<topic>             # session.*, catalog.updated, sys.drain, sys.shutdown, log.*
                       # models.updated reports effective model-catalog refreshes
                       # provider.switch selects the global backend; provider.changed
                       # invalidates redacted provider/runtime views
ev.log.<component>     # {component, level, msg, ctx?, at}; SDK log threshold applies
```

## Slash commands (declarative UI surface)

Components declare how interactive UIs (TUIs, web) expose them as slash
commands. The spec is pure data — a UI renders it with its own widgets and
never executes component-supplied code:

```json
SlashCommand = {
  "name": "deploy",          // command word; globally unique like tool names
  "description": "...",      // one line for /help and completion
  "tool": "deploy_run",      // optional; target tool (defaults to name) —
                             //   must be a tool this same component registered
  "params": [                // command-line surface, positional order
    {"name": "env", "kind": "enum",     // kind: string|bool|int|enum (default string)
     "source": {"tool": "deploy.envs", "args": {}},  // value candidates for
                             //   completion; the UI calls this tool lazily on Tab
                             //   (resolved server-side via core.invoke)
     "description": "target environment"},
    {"name": "force", "kind": "bool", "default": false},
    {"name": "mode", "kind": "enum", "values": ["fast", "safe"]}  // inline
                             //   candidates for small enums (no roundtrip)
  ]
}
```

Invocation contract for UIs: parse the command line against `params`
(positional values in order; `name=value` named; bool flags bare or
`=on|off`), then issue a regular `svc.<component>.call` to `tool` with the
resulting arguments object — result/error rendering is the UI's business.

Core validates at registration (bad entries are rejected with a warning and
skipped): command names are `[a-z0-9_-]` and unique across the catalog, the
target tool must be registered by the same component, at most 32 commands
per component and 16 params per command. `source.tool` may live in another
component and is not resolved at registration time.

**Naming convention: namespace by the registering package.** Because the
namespace is global and duplicates are rejected, a package prefixes its
commands with its own component or package name — the MCP bridge registers
`mcp-<server>-<prompt>`, the `synthetic` plugin registers `/synthetic`,
`/synthetic-models` and `/synthetic-search`. A generic verb (`/install`,
`/models`, `/search`) would collide with another installed package's
command and the later registration is silently dropped, so keep the prefix
root equal to the package name.

Checkpoint: on every catalog change core persists the merged table
*first* (store kind `slash`, id `slash`: `{updatedAt, commands: [{name,
description, component, tool, params}]}`), then publishes `ev.catalog.updated`.
UIs read the store first for the last-known table and follow
`ev.catalog.updated` live; the live catalog (`catalog` op `snapshot`, which
now carries each component's `slash` array) remains authoritative. Built-in
UI commands (e.g. `/help`) shadow registered ones with the same name.

Session runners: one conversation = one process. The system harness
(`svc.core.call`, tool `session`) ensures a runner for the session id
(spawns `var/bin/session <id>` if none is alive — presence of component
`session-<id>` in the catalog is the readiness signal) and forwards the
turn to `svc.session.<id>.call`. Clients keep a single stable address
(`svc.core.call`); runners are ephemeral — history lives in the store,
a fresh runner resumes the conversation on the next call.

Session subjects (the runner emits during a turn as
`ev.session.<sessionId>.<kind>` — one subject hierarchy per conversation,
so a client watching one conversation subscribes `ev.session.<id>.>` and
receives only its frames, while observers subscribe `ev.session.>` for
everything — UIs render live from the narrow subscription):

```
ev.session.<id>.turn        # {sessionId, turnId, phase: start|done, content?, error?,
                       #   outcome?, usage?}
                       #   turn lifecycle; content (the user request) on start.
                       #   turnId identifies the turn — advisory delivery binds
                       #   to it and every session event carries it. The ONE
                       #   phase:done frame per turn is the authoritative
                       #   terminal frame: it carries the same `outcome` and
                       #   `usage` object the session result returns (see
                       #   "Turn usage")
ev.session.<id>.assistant   # {sessionId, turnId?, content, provider?, model?,
                       #   context?, usage?}
                       #   complete model text + actual backend metadata per LLM round
ev.session.<id>.status      # {sessionId, turnId?, provider?, providerSource?, model?,
                       #   catalog?, context?, contextSource?, output?,
                       #   outputSource?, vision?, visionSource?, promptTokens?,
                       #   usedTokens?, cache?: {prompt, read, hitRate}, warning?}
                       #   resolved turn config and live context occupancy.
                       #   cache reports cumulative provider-reported
                       #   prompt-cache reads (A3; present when the provider
                       #   sends prompt_tokens_details). warning is present
                       #   when a pinned provider/model pair has no catalog
                       #   match and resolved to the fallback window. vision
                       #   is the resolved model's image capability and
                       #   visionSource its provenance ("catalog" today); both
                       #   are ABSENT when nobody determined it, which is not
                       #   the same as false (a text-only model elides every
                       #   image — see "Tool results"). Also emitted by
                       #   model-only session calls (no inference)
ev.session.<id>.context     # {sessionId, turnId?, reason, detail?, promptTokens,
                       #   usedTokens, context, trimAt?, warning?, trimmed?,
                       #   bytesSaved?, pruned?, generation?, covered?,
                       #   beforeTokens?, afterTokens?} — one row per admission
                       #   decision: `warn:threshold` (75% of the effective
                       #   line; `trimAt` is that line in tokens), `reset:prune`,
                       #   `reset:trim`, `reset:compact`, and EVERY compaction
                       #   refusal (`compact:unavailable|failed|declined|invalid|
                       #   stale`) with a human-readable `detail`, plus
                       #   `compact:retry` when the runner replays a failed
                       #   compactor once before the lossy rung (a
                       #   decline/invalid/absent compactor is a verdict and is
                       #   never retried). A `reset:trim` may carry
                       #   `proportional: true`: the rung dropped the measured
                       #   smallest whole-turn prefix that fits rather than
                       #   falling through to its structural floor. The stub
                       #   tiers (§6.3a stale reads, §6.3b declared-re-obtainable
                       #   results) need no event of their own: both are part of
                       #   the existing `reset:prune` rung and arrive in
                       #   `bytesSaved`/`pruned` with the rest. Only the
                       #   reset:* reasons rebuild the provider prompt prefix
ev.session.<id>.retry       # {sessionId, turnId, attempt, maxRetries, delayMs, error}
                       #   a transient LLM failure is being retried after delayMs
                       #   (exponential backoff; NIF_LLM_MAX_RETRIES, default 2).
                       #   Auth/quota/bad-request failures never retry
ev.session.<id>.token       # {sessionId, turnId?, content, reasoning} live token deltas
                       #   (streamed while the model generates)
ev.session.<id>.toolcall    # {sessionId, turnId?, callId?, phase: start|done,
                       #   tool, args, at?, result? | error?, durationMs?}
                       #   start fires before dispatch, done after the result
                       #   (error keeps its legacy string shape; durationMs is
                       #   on done only)
ev.session.<id>.steer       # {sessionId, turnId?, content} a steer message was folded in
ev.session.<id>.steer_sent # {sessionId, contents: [string]} folded steers included
                       #   in the candidate dispatched to chat (not merely queued).
                       #   Clients clear their pending "Steer: " display marker.
ev.session.<id>.advice      # {sessionId, turnId?, source, content, reason?} an
                       #   advisory message (svc.session.<id>.advise) was folded in
ev.session.<id>.notice      # {sessionId, turnId?, kind?, content?, jobId?, child?,
                       #   status?} a settlement notice, background process exit,
                       #   or the opening of an autonomous wake turn was folded in;
                       #   `content` is the rendered text UIs show (the durable
                       #   `agentnotice` record carries the summary and the recourse
                       #   to the full reply; see "Settlement notices")
ev.session.<id>.map         # {sessionId, workspace, bytes} the workspace map was
                       #   appended to history (once per conversation; the append
                       #   itself arrives on svc.session.<id>.map). Appended, not
                       #   injected into the frozen prefix
ev.session.<id>.diagnostics # {sessionId, path, bytes, text, clean, createdAt}
                            #   async verdict received on svc.session.<id>.diag.
                            #   All verdicts persist as kind diagnostic, id <session>:<id>.
                            #   clean:true is UI/storage-only, including late idle delivery;
                            #   other verdicts also append to model history. Missing clean
                            #   defaults false (never hide unknown/failure results).
                            #   No wake or extra model call; frozen prefix unchanged.
ev.session.<id>.done        # {sessionId, turnId, reply} or {sessionId, turnId, error}
                       #   the legacy end-of-turn frame; it deliberately carries
                       #   NO accounting, so a client that reads both this and
                       #   the terminal `turn` frame cannot double count (see
                       #   "Turn usage")
```

Wildcards compose: `ev.session.>` observes every conversation's frames,
`ev.session.<id>.>` one conversation, `ev.session.*.token` every token
stream. The payload keeps `sessionId` for clients that subscribe wide.

### Turn usage

A headless driver must be able to bill one turn without replaying the event
stream or re-reading canonical history. A session turn therefore answers with
`turnId`, `outcome` and `usage` beside the legacy `reply`/`turnError`:

```
{"ok": true, "sessionId": "...", "reply": "...",
 "turnId": "turn-...", "outcome": "success",
 "usage": {"turnId": "turn-...", "outcome": "success",
           "providerResponses": 3, "responsesWithUsage": 3,
           "toolCalls": 2, "durationMs": 3126,
           "usageReported": true, "descendantsExcluded": true,
           "provider": "...", "model": "...",
           "promptTokens": 3345, "completionTokens": 10, "totalTokens": 3355,
           "cacheReadTokens": 1671, "cacheWriteTokens": 300,
           "reasoningTokens": 21},
 "providerOverride": "", "modelOverride": "", "approvals": "",
 "limits": {"rounds": 0, "tokens": 0, "seconds": 0}, "cwd": "..."}
```

The SAME `usage` object rides the turn's one terminal frame
(`ev.session.<id>.turn {phase: "done", outcome, usage, error?}`), so a client
whose request reply was lost — a reconnect, a cancelled wait — reconciles by
`turnId` from the event stream alone. The legacy `done` frame carries no
accounting, so summing frames can never double count.

- **Scope is one activation, not the conversation.** Only the successful
  provider responses of THIS turn contribute; a turn resumed in a fresh runner
  starts at zero, so a driver is never charged again for an earlier execution
  of the same conversation. `promptTokens` is the sum of the per-round
  `prompt_tokens` (the whole prompt of each round, cache hits included — the
  provider's own accounting), not a delta.
- **`outcome`** is `success`, `cancelled` (a `__cancel` control),
  `budget-exhausted` (a hard job budget: rounds, tool calls, tokens),
  `limit-exhausted` (a human soft limit the human declined or never answered),
  `error` (LLM failure, empty reply, context-recovery-required) or `aborted`
  (the turn left through an unexpected path). `turnError` keeps its string
  detail; `reply` is empty for everything but `success`.
- **Partial turns are honest.** A cancelled or budget-ended turn still reports
  the usage of the rounds that completed, and `providerResponses` /
  `toolCalls` say how far it got. A failed (retried) request contributes
  nothing. A control-only session call — status readback, `/compact`,
  discovery, a declined wake — runs no turn and returns no `turnId`/`usage`.
- **Unknown counters are absent, never zero.** `cacheReadTokens` and
  `cacheWriteTokens` appear only when the provider sent
  `prompt_tokens_details`; `reasoningTokens` only with
  `completion_tokens_details.reasoning_tokens` (Anthropic reports cache
  writes and no reasoning split; an OpenAI-style provider reports the
  reverse). `usageReported: false` with no counters means no response of the
  turn carried a usage object at all.
- **Descendants are excluded explicitly** (`descendantsExcluded: true`): a
  subagent runs its own conversation and its tokens belong to that child's own
  accounting, never to the parent's. There is no mixed-in descendant total.
- `provider`/`model` name the last successful response's backend — the same
  values the turn's `status` frames reported.

LLM streaming (adapter → core → UI): the `llm` component emits
`ev.llm.token {sessionId, content, reasoning}` deltas while generating;
core forwards matching deltas for the active turn as
`ev.session.<id>.token` and heals any last-frame race with the final
assistant event (which always carries the complete content). Cancellation:
publish an envelope to `llm.cancel.<sessionId>` to abort an in-flight
streaming call.

Approval subjects (human gate for `x-harness.approval: "always"` tools):

```
svc.approval.<name>.request  # directed request to the interactive component
                             #   that drove the current turn: {id, tool, args,
                             #   sessionId, caller}. Core derives <name> from
                             #   the call envelope's caller field — component
                             #   names are never hardcoded.
ev.approval.request    # broadcast fallback: {id, tool, args, sessionId,
                       #   caller?, fallback: true} — used for direct
                       #   (non-session) calls, or when the driver did not
                       #   ack a directed request within ~1.5s
                       #   (terminal harness prompts instead)
ev.approval.reply      # UI → core: {id, ack: true} when a directed request
                       #   is taken (modal shown), then {id, ok} — the
                       #   decision. Broadcast/direct requests need no ack.
ev.approval.resolved   # core → UIs: {id, ok} gate verdict; clients dismiss
                       #   stale modals for id
```

The `ui` tool (hidden) is the interactive-client registry: `register` /
`renew` / `release` / `claim` / `release_session` / `owner`. Core assigns
monotonic display numbers ("Niffler 1", …) and brokers conversation
ownership between cooperating UIs; an ~20s lease is the liveness signal. A
caller name is self-declared, so this is coordination, not authentication.
The TUIs register unique `tui-<hex>` component names (their approval caller);
a browser-hosted SPA client mints one identity per browser tab (`ui-<hex>`) and
stamps it as the `caller` of that tab's session turns, so directed approvals
stay per tab.

`svc.core.call` is core's own service surface, served by core itself
(queue "core"): tools `session` (hidden from the LLM), `spawn`, `catalog`,
`kill`, `remove`. `catalog` ops: `list` (the name-sorted *direct*
projection — tools without `x-harness.onDemand`/`x-harness.hidden`),
`components` (component→tools view over the full catalog for bus clients
— the CLI reads this authoritative snapshot for catalog, tool lookup, and
registration/install verification; raw `reg.publish` is not acceptance) and
`snapshot` (full registration payloads incl. schemas — session runners
seed their catalog from it at startup, then follow `reg.>` live).
The LLM-facing core tools also include `discover` (hint/schema lookup
over the non-hidden catalog) and `invoke` (generic gateway into any live
non-hidden tool, preserving its approval/timeout policy; `sticky: true`
appends a successful target's schema to the persisted direct toolset —
one durable prefix change, capped by `NIF_MAX_DIRECT_TOKENS`). `profile`
(onDemand) manages the named tool profiles a new conversation resolves
its direct toolset from — see docs/MANUAL.md, section
"Progressive tool discovery". The stock direct set is eight tools: `bash`,
`read`, `edit`, `write`, `replace_across`, `grep`, `discover`, `invoke`.
Shortened schemas and prompts affect only future conversations; existing
snapshots remain frozen. Routing hints in results append to tool history,
never the prefix.

`discover`'s capability registry excludes components with zero visible tools.
It tries three hints, then one, then a shorter hint before deterministic
name-sorted pages, each bounded to 6000 encoded bytes including cursor
metadata. It preserves on-demand routing hints. Continue a `hasMore` page
with `discover {after: "<nextAfter>"}` (no query/component/tools).
`limit` bounds summaries per exposure group (0 = all, maximum 200);
`tools: []` behaves as omitted. Query words use case-insensitive word-AND;
a no-match answer includes that routing hint. The administrative catalog
remains complete.

Core stays responsive while a turn dispatch is in flight: tool calls from
components that land on `svc.core.call` mid-turn (e.g. `plugin_install`
calling `core.spawn`) are served from the dispatch's idle slot, and
`session` calls never block core — each rides its private forwarding inbox
(`routeSessionCall`) and is completed by `pumpSessionForwards`, so separate
conversations' turns overlap while a mid-turn conversation refuses further
turns with `busy` — turns never nest.

- Presence = connection; component death detected by core via NATS disconnect
  plus `reg.depart` (graceful) vs silence (crash). A Nim or Go SDK component
  whose connection stays unhealthy past `NIF_RECONNECT_GRACE_S` re-attaches —
  it re-resolves the bus, rebuilds its subscriptions and re-publishes
  `reg.publish` on the fresh connection — rather than requiring a process
  restart (docs/MANUAL.md "Re-attaching after a bus outage").
- Tool names are unique across the whole catalog — enforced by core at
  registration; conflicting registrations are refused in full. The LLM only
  sees tool names; core maps tool → component at dispatch. The namespace is deliberately
  **flat**, not `component.tool`-qualified: flat names are the LLM's call
  vocabulary (no `edit.edit` noise), and dot-names would break Anthropic-style
  providers that restrict tool names to `[a-zA-Z0-9_-]`. Clash avoidance is by
  convention: **shipped core components own their semantic names** (`read`,
  `edit`, `bash`, ...); **plugin/third-party components prefix every tool with
  the component name** (`stocks_quote`, `weather_current`, `git_status`) so
  independently published packages never collide. Core rejects a clashing
  registration instead of letting two components share a name, and
  `core.spawn` waits for that acceptance before answering `ok`
  (`NIF_SPAWN_WAIT_MS`): a refused registration comes back to the spawn
  caller with the catalog's reason and a bounded child-log tail, and the
  attempt is rolled back (replicas stopped, nothing persisted) so the name
  is free for a corrected re-spawn.
- `ev.sys.drain` (core → component): stop taking new calls, finish in-flight,
  then exit. `ev.sys.shutdown` (component → core): I'm leaving.

## Lifecycle

1. Core boots: spawn NATS if no `NIF_NATS_URL` → read `manifest.yaml` → select
   the boot profile → spawn children (no ordering; ordering emerges from the
   bus). A stateless entry may set `replicas: N` (1–16; default 1), producing N
   queue-group subscribers under one logical component name. Normal mode uses
   the manifest; `--minimal` filters it to `store`, `bash`, and `llm` and skips
   restoration of persisted spawned components.
2. Each component process connects and publishes `reg.publish` with its tool
   schemas. Core tracks all live PIDs for an identical logical registration;
   `catalog {op: snapshot}` exposes `pids` and `replicas`, while `core.status`
   also exposes `runningReplicas`.
3. Core converges when the selected profile's required set has registered
   (normally the manifest's required entries; `store`, `bash`, and `llm` in
   minimal mode). Every new registration is announced as
   `ev.catalog.updated` with the direct projection (same shape as
   `catalog {op: list}`). Each conversation freezes its direct toolset at
   first turn — late registrations reach an existing conversation through
   `discover` + `invoke`, not schema churn.
4. Teardown = exit; the OS is the disposer. Core drains children in reverse
   registration order: `ev.sys.drain` → grace period → SIGTERM → SIGKILL.

## Cancellation

No transport-native cancellation in NATS. Two implemented cancel paths:

- `llm.cancel.<sessionId>` — aborts that session's in-flight provider
  request (see `components/llm/main.go`).
- `cancel.<component>` — published by a session runner when a turn cancel
  lands while a tool dispatch is in flight (event envelope
  `{sessionId, tool, ts}`). Components opt in by subscribing their own
  subject and matching `sessionId` against the injected `__session.session`
  private context (`x-harness.sessionId`); bash kills the running command's
  process group (exit 130), mcp-bridge aborts the in-flight MCP call —
  the MCP server's `notifications/cancelled`-equivalent (its per-call
  context) fires immediately. fabric subscribes `cancel.>`: a fabric
  program's bridge calls are dispatched for it by the session runner, so a
  stop that lands while a NESTED call is in flight arrives on that call's
  component subject — the fabric run still terminates its guest
  (`fabric-exec`), reports a cancelled outcome, and dispatches nothing
  further. agent cancels the child of an in-flight `agent_run` whose parent
  turn was stopped. Direct callers (CLI scripts) see
  `""` for `__session.session` and cannot spoof a session id. Components
  without a subscription drop the message and run to completion or deadline —
  request/reply callers that stop waiting only abandon the reply; the target
  work is not stopped. A generic `ev.cancel.<call-id>` subject remains a
  possible future addition.

## Settlement notices

A background subagent (`agent_spawn`) that reaches a terminal state writes a
durable `agentnotice` record and delivers it to its **parent conversation** —
not just to UIs (`ev.agent.done` is observe-only). Rationale and design:
docs/research/SUBAGENTS-PLAN.md P0.1.

**Background processes use the same lane, plus a durable one**
(components/processes): a tracked child that exits writes a durable outbox
record (`var/processes/notices/<id>.json`, `delivered: false`) **before** it
notifies, then publishes the steer notice and requests a wake
(`svc.core.call` `session {wake: true}`). A busy parent folds the steer
notice; an idle one is woken under the same bounded admission as a subagent
settlement; a missed publish or an absent runner is retried by the
component's idle tick every 10 s, so a completion cannot be lost — the
record survives a component or core restart, and the runner acknowledges it
through the hidden `process_notices {session, ack: processId}` tool after
appending (peek never acknowledges). The notice is a pointer too: the
process id, its status, how long it ran and how many bytes of output exist;
the output itself stays in the spool for `process_poll`, and the command
text never travels. One process is folded at most once: the runner skips a
notice whose `processId` is already in its history and only acknowledges
after a successful append, so a persistence failure leaves the record
pending rather than dropping it.

The boot sweep retains session ownership and records previously running jobs as
`interrupted(component restart)` (exitCode -1), never as successful exits.
PID/starttime verification still guards signals. A failed recovery write refuses
startup without clearing the sweep file. Acknowledged completion receipts and
spools expire seven days after acknowledgement; pending receipts never expire.

Record (store kind `agentnotice`, id `<parentSession>:<zero-padded seq>`):

```json
{ "v": 1, "parent": "conv-…", "jobId": "job-…", "child": "agent-…",
  "status": "done|failed|stopped",
  "summary": "<bounded head of the reply, ≤400 chars; absent when the job
                produced no reply>",
  "replyBytes": 12345,
  "fullReplyIn": "agent_status",
  "createdAt": 1765400000.0,
  "deliveredAt": 1765400001.0, "deliveredVia": "wake|pull" }
```

The notice is a **pointer, not the reply**: `replyBytes` counts the
untruncated reply and `fullReplyIn` names the tool that returns it, because
the full reply is already durable in the `agentjob` record (`agent_status`
returns it). A model told only "your subagent finished" does not know to make
a second call; the pointer is what makes the summary a delegation rather
than a loss. Same convention as the tool-spill paths (`bash`, `mcp`, `fetch`).

Delivery is two-lane by **parent state**, and the durable record is written
before either is attempted:

- **parent runner mid-turn** → the steer subject
  (`svc.session.<parent>.steer`) with a `notice` payload object instead of a
  `content` string. The runner queues it separately from user steer and
  folds it in as a structurally marked user message — it is runtime
  machinery about a subagent, never something the human typed.
- **otherwise** (idle, retired, or no runner) → **the agent component wakes
  the parent** (below); if that is declined the notice stays pending and the
  parent's next turn pulls every pending notice at the top of the turn
  (alongside steer and advisories), marking it `deliveredVia: "pull"`.

Taking the pushed lane first is what prevents double delivery. Notices are
best-effort throughout: a store or agent-component failure costs a notice,
never a turn, and a completed job is never turned into a failed call.
`agent_notices {session?, peek?}` drains manually (on demand) for callers
that want to look without waiting for a turn.

### Busy-parent inbox (a turn cannot close over a settlement)

A settlement that lands while the parent's turn is live takes the steer lane
and is folded at the next step — and the would-stop point drains notices the
same way it drains steer and advisories, so a child that finished during the
model's final response keeps the turn alive for one more step instead of
waiting for the human to come back. Every notice waiting in the two lanes
folds in **one** drain: a burst of N settlements costs one extra step, not
N. `NIF_AGENT_NOTICE_HOLD=0` disables only this hold — the notices then stay
pending for the next turn's opening drain (the scripted bus-contract suites
pin it off for deterministic round counts; `tests/t_agentwake.nim` pins the
default behavior with a stub that injects the notice mid-answer).

### Autonomous wake

An **idle** parent must not wait for the human to ask. When a child settles
while its parent has no live turn, the agent component wakes the parent:
it publishes a `session` call with `{sessionId: <parent>, wake: true,
content: "[wake] …"}` and a dropped reply (fire-and-forget — a wake turn
runs as long as any turn, and the component must keep serving tool calls
while it does). Core ensures the parent's runner exactly as for a UI call.

The runner admits a wake only when all of these hold, and **persists nothing
on a decline**:

- `NIF_AGENT_WAKES` is non-zero (0 disables wakes);
- pending notices exist (`agent_notices {peek: true}` count is non-zero) —
  a wake with nothing to fold is `wake: "skipped"`;
- the **consecutive-wake budget** has room: at most `NIF_AGENT_WAKES`
  (default 3) trailing wake turns since the last real user message. The
  budget is derived from stored history (a wake turn persists a user message
  marked `notice.kind: "wake"`; machinery messages neither count nor reset
  it), so it survives runner restarts with no counter to lose. A declined
  wake returns `{wake: "declined", reason: "budget"|"wakes disabled"|
  "notices unreachable"}`.

An admitted wake runs a normal turn whose user message is structurally
marked:

```json
{ "role": "user", "content": "[wake] background subagent settled…",
  "notice": { "kind": "wake" } }
```

so rendering, trimming and compaction treat it as runtime machinery, and the
request prefix is untouched (append-only history). The turn's opening drain
folds the pending notices, the model answers, and the conversation has
visibly moved on — without a human message. A declined or skipped wake
leaves the notice pending for the next real turn (never lost); the human's
next message resets the budget.

The process-exited lane has no waker (a process notice is announced on the
same subject but nothing wakes for it): its fallback remains the next turn's
pull drain.

## Subagent continuation (`agent_run`/`agent_spawn {session}`)

Both drivers accept `session`: a previously returned `sessionId` gives that
EXISTING child another turn instead of minting a fresh one. On a fresh
spawn (no `session`) an omitted `model` inherits the parent's EXPLICIT pin
(`modelOverride` with the provider pinned beside it). With no explicit pin
the child resolves from the same defaults the parent's own turns resolve
from — the parent's serving configuration, not a snapshot of its header.
The header's resolved/echo `model` name is deliberately never inherited as
a pin: a provider's echo can name a model some OTHER provider owns
(DeepSeek echoes `deepseek-flash` for a `deepseek-v4-flash` request), and
pinning it manufactured a cross-catalog mismatch on the child's first turn
while the parent kept working. Design and
testing: docs/research/SUBAGENTS-PLAN.md P1.3.

- **Authorization is the durable lineage relation**: the child's
  `sessionmeta.parent` must equal the caller's session. Unknown sessions,
  root conversations (a lineage record with no `parent`), foreign children,
  closed children and an unreachable store all refuse with distinct errors —
  fail-closed, never a silently fresh child.
- **Frozen controls**: model, thinking, tool allowlist and budgets were
  frozen into the child's conversation header at its first turn. A
  continuation sends content only (no preamble, no system prompt) — the
  caller's model/thinking/tools/budget arguments are ignored by
  construction, and the synchronous result carries the child's `effective`
  controls as a readback. This keeps the child's cached request prefix
  stable (append-only history).
- **Busy semantics by promise**: `agent_run {session}` promises a result
  now, so a mid-turn child is refused with `code: "busy"` (naming
  `agent_spawn` to queue or `agent_wait`/`agent_status` for the current
  turn). `agent_spawn {session}` promises the work happens, so it queues —
  the child's runner serializes turns. The busy check runs AFTER
  authorization, because the caller itself is always "mid-turn" while its
  own `agent_run` executes.
- **Activation ledger**: each accepted turn advances
  `sessionmeta.activations` (1-based; the first turn counts as 1) and sets
  `firstActivationAt` once. Background continuations stamp `continued` and
  `activation` on their `agentjob` record (the completion tap preserves
  them when it terminalizes the record).
- **Close**: `close: true` marks the child retired (`sessionmeta.closed`)
  AFTER its turn — synchronously in `agent_run`, via the job's completion
  tap in `agent_spawn`. Nothing is deleted (record + transcript survive for
  forensics); only further continuation refuses.

## Subagent fork (`fork: true | {lastK} | {maxChars}`)

On fresh spawns only — a fork is a birth, not a continuation (`fork` +
`session` is refused). The child's message log is seeded with the CALLER's
completed turns before its first request, so the child has READ the
conversation instead of being told about it. Design and testing:
docs/research/SUBAGENTS-PLAN.md P1.4 (DSH-STEAL §3).

- **The seed is contiguous-from-0 and replay-valid**: `balancedPrefixLen`
  walks the transcript with a pending-tool_calls count and stops at the
  first record that breaks the provider invariants (a user message over
  unanswered calls, an orphaned tool record, a closing assistant over
  unanswered calls); a tail ending with pending calls is cut before the
  dangling assistant. Blocks within that prefix open at a user message and
  close at an assistant with no `tool_calls` — a steered turn's extra user
  messages fold into the same block. The fork copies whole blocks only, so
  the child's first request can never carry a dangling `tool_call_id`.
- **The one store-ownership exception**: this is the documented case where
  `agent` writes `message` records (core otherwise owns that kind). Safe
  because it is a one-time COPY written before the child's runner exists —
  no concurrent writer for that session id, no lost-update window — and the
  child's `seqNo` continues AFTER the copied ids (`loadStoredMessagesEx`
  derives it from the highest stored id). The copy site in
  `components/agent/main.nim` carries the ownership comment.
- **Not copied**: per-message `usage` (the child's meters are its own —
  born cold), `summary`/`error` roles (a summary is a derivation of records
  copied raw; errors are the parent's audit), the `<session>:tools` toolset
  snapshot, and the header's control fields. The forked child's frozen
  controls come from THIS call (a birth), not from the source conversation.
- **Fork × compaction** (the gate is satisfied — compaction landed): a
  forked child receives the parent's **raw transcript**, which may be
  LARGER than the parent's current live context — compaction's projections
  are checkpoint nodes (`<convId>#ck<gen>`, outside the message kind) and
  are never copied, and the child's ledger is rebuilt from the copied
  records on its first resume. The child's own compaction then shrinks it
  on its own schedule. Read-visibility framing: a fork is a reader of
  records the parent may no longer hold in context — that is the point
  (the child gets the real history, not the parent's summary of it).
- **Provenance before the first turn, fail-closed**:
  `sessionmeta[child] = {parent, fork: {source, uptoId, copied}}`, surfaced
  by `session_info` as `fork`. A budget (`lastK`/`maxChars`) that drops
  everything fails closed — never an empty child.
- **Cache effect**: born cold (the first request replays the history
  uncached; warm from the second turn). The tool descriptions say this,
  because the cost is otherwise surprising — and point bulk mechanical
  transfer at `fabric`.

## Delegation depth (`NIF_AGENT_MAX_DEPTH`)

Delegation depth is capped by `NIF_AGENT_MAX_DEPTH` (default **1** —
subagents cannot spawn subagents). The cap is evaluated at dispatch time
(`core/dispatch.nim`, where the session-context gate lives) by a **depth
walk** over `sessionmeta.parent` links from the calling session to a root:
a root is depth 0, children 1, grandchildren 2 — a spawn is denied when
`depth >= cap`. `0` forbids delegation entirely (even a root may not
spawn). The walk is bounded by the cap + 2 reads (a corrupt lineage cycle
exceeds the cap and is denied) and fails closed when the lineage store is
unverifiable.

The spawn-class tool stays **visible at the cap** — each start rejects
with an errored result naming the limit and the caller's depth
(`subagent depth 1 exceeds NIF_AGENT_MAX_DEPTH=1 (subagents cannot spawn
subagents)`), so the model learns why instead of finding a hidden tool.
The component enforces the same rule a second time at its own trust
boundary (defense in depth; core's dispatch gate is the primary).

**Raising the cap above 1** changes the trust shape and needs the nested
synchronous path to work: a child's synchronous `agent_run` arrives at the
agent component while the parent's synchronous `agent_run` holds the
component's pump — so `requestChildTurn` serves queued calls re-entrantly
(`pumpCallsReentrant` in the SDK), depth-bounded by the same cap. Each
level blocks in its own downstream wait; handler state is per-call.

## Nested-call leases (keyed)

The nested-call proxy validates requests against the lease a
session-context dispatch granted. Leases are **keyed by id** — each
session-context dispatch registers its own lease (with its own deadline)
and removes exactly that key on exit:

- two overlapping session-context dispatches can neither clobber nor
  prematurely restore one another (the old single-string lease was the
  latent hazard that made parallel session-context dispatch unsafe);
- a lease's validity window gates everything else: an expired outer call
  is denied (`expired`) before tool resolution or argument validation;
- an unknown, stale or empty lease reads `bad-lease`; no live turn reads
  `no-session`;
- a completed dispatch's lease is dead immediately, and leases never
  outlive their turn (cleared at turn end).

The wave scheduler still refuses `sessionContext` tools — serial dispatch
is fine (children are what run in parallel) — but the invariant "leases
are per-call" now holds regardless of future dispatch policy.

## Approvals

Dispatch honors `x-harness.approval` on the tool schema (docs/research/REBOOT.md,
"policy rides the schema"): a tool marked `"always"` is held until a human
answers. Terminal harness: y/N prompt on stdin. Service mode: the request
is routed to the interactive component that drove the current turn — its
private subject `svc.approval.<name>.request` (name from the envelope's
self-declared `caller`, never hardcoded). The driver acks on
`ev.approval.reply` (a human is being asked) and answers `{id, ok}`.
When the driver does not ack within ~1.5s (crashed, or not interactive)
the request is rebroadcast on `ev.approval.request` with `fallback: true`
so any attached interactive client can step in; direct (non-session) calls
broadcast immediately. The gate verdict is published on
`ev.approval.resolved` so other clients dismiss stale modals. Timeout →
denied. No human reachable → deny. `NIF_AUTO_APPROVE=1` bypasses.

## Conversation controls (`/approvals`, `/limit`, `/compact`)

Per-conversation controls belong to the human, never to the model, and ride
the ordinary session call (`svc.session.<id>.call`, tool `session`):

```json
{"sessionId": "conv-…", "approvals": "auto"}
{"sessionId": "conv-…", "limits": {"rounds": 20, "tokens": 50000, "seconds": 600}}
{"sessionId": "conv-…", "compact": true}   // run the compactor now, no turn
{"sessionId": "conv-…"}                    // status readback, runs no turn
```

- **`approvals`** is this conversation's gate mode: `""` (was never
decided — the instance default applies, `NIF_APPROVALS_DEFAULT`, i.e. the
ordinary gate unless the instance opted into auto) or `"ask"` gates every
`x-harness.approval` tool as described above; `"auto"`
grants them without asking any client, loudly (`core: approval auto-granted
for <tool>`) — a silent grant is exactly what the gate exists to prevent.
The two non-auto values are stored distinctly: an explicit `"ask"` is the
human's decision and outranks the instance default, while `""` clears back
to it. It applies from the NEXT turn on and, unlike the frozen scoping
arguments,
may be changed at any point in a conversation's life.
- **`limits`** are SOFT budgets: `rounds` (LLM rounds per turn, 1–200),
`tokens` (cumulative per turn) and `seconds` (wall clock per turn, checked
before every dispatch as well as at round boundaries — one bash call can
outlast a whole round). Each key is optional and independent; an empty
object clears all three. Job-scoped budgets — `maxRounds`/`maxCalls`/
`maxTokens` (what the `agent` component freezes into a child's header) and
`NIF_MAX_TURN_ROUNDS` — remain HARD: they end the turn and never ask, because
a subagent must not be able to negotiate its own budget.
- **`compact`** runs the same replaceable-compactor rung the automatic ladder
runs at pressure, explicitly: the compaction component proposes a checkpoint
over a permitted cut, core validates and installs it atomically, and the
usual `reset:compact` context event follows — with no LLM turn and no user
message. The reply is `{ok, compacted: true, beforeTokens, afterTokens,
generation}` or `{ok, compacted: false, reason}` (no compaction component
configured / compactor declined / no permitted cut). A decline is explicit —
it never silently degrades to lossy trim.
- **Reaching a soft limit asks the human.** The question travels the approval
transport on the same routing (directed to the driver, then broadcast), with
`tool: "turn-limit"`, `purpose: "continue"` and
`args: {dimension, detail}` — `dimension` is `rounds`/`tokens`/`seconds`,
`detail` is a human-readable "3 LLM rounds (limit 2)". The answer is the
existing `ev.approval.reply` (with the usual `{id, ack: true}` first):
`ok: true` extends THAT limit by one more step and the turn continues;
`false`, no answer or no reachable human ends the turn with a distinct error
record (`error: "limit-<dimension>"`) naming the limit and the command that
raises it. `NIF_AUTO_CONTINUE=1` (or `NIF_AUTO_APPROVE=1`) answers yes
without a human, for headless automation.
- The `approvals` and `limits` settings are persisted in the conversation
header (`approvals`, `limits`), so a resumed runner re-applies exactly what
the human last chose, and both are echoed by the status readback and the turn
result (`approvals`, `limits`) for UIs. Invalid values are refused with a
clear error (unknown mode, unknown limit key, out-of-range value).

### Attachments (images in a turn)

`svc.session.<id>.call` accepts `attachments` beside `content`: an array of
`{type:"image", name?, mimeType, data, width?, height?}` where `data` is the
base64 pixels. A dropped image IS content — a call with attachments and no
`content` runs a turn, not a control call — and the turn's text is the
caption (a caption-less drop gets a `(image attached)` placeholder so the
model has an anchor and protocols without an image-only user message still
accept the request).

Core validates every claim (base64 decodes, magic bytes match the MIME
allowlist `image/png|jpeg|gif|webp|bmp`, per-image ≤ 4 MB base64, ≤ 8 per
turn, ≤ 4.5 MB per turn): a refusal fails the call with a reason naming the
image, and nothing is persisted — there is no half-attached turn.

**Pixels are stored apart from the message.** The `message` document keeps
the text plus small `attachments` refs. The bytes live in TWO documents per
image, both with id `<messageId>:a<i>`: kind `attachment` holds only metadata
(message id, MIME, dimensions, original name) and kind `attachmentdata`
holds the base64 pixels. The split is not an optimization. A `list` reply is
bounded by the bus `max_payload` (8 MiB), the store contract has no field
projection, and the metadata kind is what enumeration reads — so pixels in
the listed documents meant a page of two screenshots could never be
delivered (the failure mode that already truncated a resume). Keep the
metadata kind pixel-free; that is the property that lets a delete sweep, or
any future listing, see every attachment at all. Refs also keep fork-copy,
search and recall cheap.

**The projection is deterministic.** The in-memory context materializes each
message's refs into the provider shape — text parts first, then `image_url`
data-URL parts — and keeps the newest images that fit the projection budget
(`NIF_ATTACH_BUDGET`, default 5 MB of base64); older images become an honest
text marker naming the file and its size. The rule is greedy-newest at
whole-message granularity and a pure function of the refs, so a resume
(including a runner restart) rebuilds exactly the projection the previous
turn sent. Compaction digests a elision-independent `snapshotForm` of each
message, so a new drop eliding an older image cannot invalidate an in-flight
compaction with a spurious "snapshot became stale", and the summarizer
receives text only — never image bytes.

`conversation_delete` sweeps the conversation's `attachment` documents with
its messages.

### Provider/model pins are one selection

A conversation's provider and model are pinned **together**, never
separately, because a model id is only meaningful under the provider it was
chosen from:

- `provider` (a stored nickname; empty clears it) and `model` (empty clears
  it) are the two halves of one pin, persisted in the conversation header as
  `providerOverride`/`modelOverride`.
- **A model-only call pins the provider it resolves under.** When `model`
  arrives without `provider`, core resolves the effective provider
  (`llm_resolve`) at that moment and persists both fields in one header
  write. This is what makes `/model` in a UI safe: the model cannot later be
  sent to a provider that does not serve it because another UI switched the
  harness-global active provider.
- **The turn result and status readback always report the effective pair**
  (`provider`, `providerSource`, `model`, `catalog`, `context`,
  `providerOverride`, `modelOverride`), so a UI can show what a turn will
  actually use rather than what was selected earlier.
- **A legacy half-pin is healed on resume.** A conversation stored before
  this invariant (a model override with no provider pin) gets the provider
  it currently resolves under pinned to it on the runner's first load, so
  old subagents and conversations stop following global provider switches.
- **Explicit failures are loud.** An explicit `provider` that cannot be
  resolved is an error naming it; it never silently falls through to the
  harness-global default (which would send the model to a foreign provider).
  The no-provider case still resolves through the active provider, by design.
- **A model the catalog places under another provider is refused at call
  time.** The `llm` component checks an explicitly requested model against the
  models catalog: when the exact id exists and no entry for it names the
  resolved provider, the call fails naming the model, its real provider(s),
  the resolved provider and its catalog — the last line of defense against a
  pairing created before the pin invariant (a UI that pinned a model without
  its provider), instead of a raw provider 400. Ownership is read from
  `models_resolve` (the exact id), never from a `models_list` substring page:
  a popular id is shared by many providers and buries its own entry, so a
  clipped page used to read as "no provider serves this" and refuse a model the
  resolved provider does serve. The check is deliberately narrow: it fires
  only on a positive catalog answer, and it exempts the provider's own
  configured model — the pin-less conversation shape, which core then sends as
  an explicit model override — so an unknown or self-hosted model, a missing
  `models` component and the provider default all pass through untouched.

Agents inherit the whole EXPLICIT pin: a fresh subagent gets the parent's
`modelOverride` with the provider pinned beside it, so the child cannot
drift under a later global switch either. With no explicit pin the child
inherits nothing and resolves defaults exactly as the parent's turns do. `session_info` and the status readback expose
`provider`/`model` so a caller can read back the effective pair.

### Session calls during a turn

The runner is single-threaded and a turn must never nest, so a session call
that arrives while a turn is running is refused **immediately** with
`{code: "busy"}`, message `the conversation is mid-turn — retry when the turn
finishes`. It used to stay silent until the turn ended, which made any client
with a deadline report a generic timeout ten seconds in (`/export` waits 10s
and looked like a hang).

The refusal is answered by whichever layer the caller reaches, and the two
layers differ only in the hop:

- **`svc.core.call` (what UIs use)** — core is mid-dispatch for the running
turn, so its idle-slot pump (`pumpCoreWhileBusy`) cannot serve the call
inline; it forwards the session call — control and turn-starting alike —
through a private inbox (`routeSessionCall`) to the conversation's runner,
which serves it now or refuses it `busy` when the conversation is mid-turn.
Nothing is stashed: the forward either reaches a runner or the caller gets
an explicit error reply.
- **`svc.session.<id>.call` (a client addressing the runner directly)** — the
runner's own idle-slot pump (`pumpBusyCall`, `ct.callSub`) refuses everything
it sees mid-turn with the same `busy`, since serving any of it would mean
re-entering the session handler while the running turn owns the context.

Both pumps answer within milliseconds; a caller that ignores `busy` and keeps
waiting will still hit its own deadline. `agent_run`'s refusal of a mid-turn
child uses the same `busy` contract.

## x-harness schema extensions

Tool schemas may carry an `x-harness` object (docs/research/REBOOT.md,
"policy rides the schema") that the session runner honors at dispatch. Known
keys:

- `approval`: `"always"` gates the call on a human (see Approvals).
- `timeoutMs`: per-tool request timeout (default 120s).
- `hidden`: tool invisible to the LLM catalog (e.g. `chat`, `session`).
- `variables`: the tool may opt a call into pipeline plumbing: `resolve_vars: true`
  substitutes explicit `$name` references in its args and `save_as: {name, from?}`
  captures a response field. Calls without those directives are untouched even
  when their strings contain `$` (`$HOME`, shell syntax and code stay literal).
  Pipelined calls execute in message order on the serial spine; the resolved
  copy is dispatched (so approvals show real values) while raw args remain in
  history. Values live in the conversation header, never the prompt. bash never
  sets this — its `$` is shell syntax. Capture alone does not enable
  substitution. A capture receipt reports the actual JSON encoded size of
  the saved value; captured payloads stay in the persistent header instead
  of being copied into history.

  For `read` only, core overwrites private `__capture` with capture intent.
  When true, read bypasses unchanged/outline shortcuts and returns separate
  `__captureText` source-window content without paging or lazy-instruction
  notices; rendered `text` remains for display. Source omission, beyond-EOF
  windows and non-contiguous batch/select top-level views yield null and
  default text capture refuses with `E_CAPTURE_UNAVAILABLE`. Explicit batch
  `items.N.content` and select `items.N.contents.M` capture one raw region;
  unavailable item/region fields also refuse instead of silently saving null.
  Raw select regions are bounded at 64KB each and 512KB aggregate.
  These private fields are not advertised arguments; ordinary reads keep
  their existing behavior and limits.
- `onDemand`: kept out of a conversation's frozen direct toolset; reachable
  via `discover` + `invoke` (docs/MANUAL.md, "Progressive tool discovery").
- `hint`: the when-to-use sentence `discover` shows for this tool instead of
  the first sentence of its description. It exists for tools whose choice
  between shapes needs saying once (fabric: one-shot batch vs long-lived
  guest; agent: spawn vs run vs continue), and it is the routing line a
  component contributes to the registry (`discover` with no arguments).
- `runner`: when `true` on a `hidden` tool, exempts internal runner machinery
  from a conversation's frozen tool allowlist. This is how replaceable
  `chat`, model-resolution, compaction, and recall tools remain available to
  restricted subagent sessions without hardcoding their names in core.
  `runner` does not expose the tool and is ignored unless `hidden` is also
  true.
- `sessionContext`: the call runs in the live conversation (fabric, agent);
  the runner injects `__session` context and a nested-call lease.
- `sessionId`: the runner injects `__session.session` (the live session id,
  `""` for non-session callers) so the component can match
  `cancel.<component>` events against its in-flight work (see Cancellation).
  Carries no lease and does not fail closed, so a read-only tool may also use
  it purely to learn its caller (`agent_list`, `agent_notices` do); core
  overwrites any client-supplied `__session` for such tools at
  dispatch — the key is core-owned private context, never caller data.
- `effect`: `"read"` or `"write"` (default) — how the fabric batch host
  schedules items (reads fill the concurrency cap together, writes run
  exclusively). Not to be confused with `writes` below: `effect` is
  *scheduling*, `writes` is *ownership*.
- `derivable`: `true` declares that this tool's RESULT is re-obtainable by
  calling it again, which is what licenses the runner to elide an old result
  when the context window is tight (`docs/research/COMPACTION.md` §6.3 tier 2).
  It is deliberately a declaration and not an inference: `effect: read`
  answers *"is this call safe to schedule concurrently?"*, while `derivable`
  answers *"may the model lose this body and get it back?"* — and the two
  disagree where it matters. `bash` is a write effect yet `git log` output is
  trivially re-obtainable, while a read-effect tool could return something no
  second call reproduces. Only the component can answer the second question,
  so it opts in and an operator can revoke it per tool by removing the line.
  An elided result always keeps `role`, `tool_call_id` and `name` and carries
  a `context_recall` pointer, so pairing stays intact and nothing is lost.
- `writes`: the tool mutates files, so the dispatch gate takes a write lease
  over them from the `locks` component before the call runs
  (docs/research/WRITE-ARBITRATION.md). Two shapes:
  `{"paths": ["path", "glob", "paths"]}` names the argument fields
  (single string or string array) that hold the files it will change — the
  values are already workspace-resolved by `workspace.pathFields`;
  `{"root": true}` claims the conversation workspace root for a tool whose
  reach is opaque (`bash`, `builder`), which conflicts with any claim beneath
  it; `{"harness": ["var/plugins"]}` names paths **relative to `$NIF_ROOT`**
  for a tool that mutates harness state rather than conversation files
  (`plugins` writes `var/plugins` and `var/bin`) — the claim is confined to
  `$NIF_ROOT/var` and every entry outside it is refused with a core warning,
  because the rest of the root is the control plane the agent edits and a lease
  over it would be theater; and `{"none": true}` declares that the call
  takes **no** filesystem claim at all, because it mutates no path (`mcp`'s
  mutating tools write store documents only; the store serializes its own
  writers, so a lease would be redundant as well as misdirected). The key names
  what the gate does, not where the writes land. The last two exist so a tool does not fall
  back to the opaque root claim over a tree it never touches: for a client
  launched in a project directory (`NIF_ROOT` != workspace) that claim guarded
  nothing real while serializing unrelated conversations. The `store` engine's
  own tools are the worked example, and getting them wrong is invisible until
  it is not: undeclared, a `store.list` READ took a workspace-root lease and was
  then refused by its own conversation's `bash` — `[E_WRITE_BUSY] <workspace> is
  being modified by conversation <the same conversation>` — while every document
  write serialized all conversations sharing a checkout. A store engine
  therefore declares `effect: "read"` on `get`/`list`/`search` and
  `writes: {"none": true}` on `put`/`del`/`selftest`. A declared value carrying a wildcard
  (`*` or `?` — a `replace_across` glob) is claimed as the **base directory
  before the first wildcard**, not as the pattern text: the pattern
  `/ws/**/*.go` claims `/ws`, and `/ws/src/*.go` claims `/ws/src`. The gate does
  not expand globs (that would mean a filesystem walk in the dispatch path,
  duplicating the component's matcher, and racing its own expansion); it claims
  the one directory the pattern cannot escape, which can only ever over-claim —
  the safe direction. **Declaring nothing means opaque**:
  the conservative default, so a component that forgets the key still
  cannot write unguarded. A conflicting lease refuses the call with a normal
  tool error naming the holder — `[E_WRITE_BUSY] <path> is being modified by
  conversation <id> (edit, 4s ago)` — which reaches the model as an ordinary
  tool result (append-only history, no prefix change). The lease is released
  after an acknowledged successful reply; an unacknowledged timeout/cancel
  retains it until expiry. Session dispatch requests a lifetime at least the
  tool timeout plus 60 seconds (minimum 10 minutes), after approval. Expiry is
  cooperative recovery, not proof a remote process stopped. `effect: "read"`,
  hidden runner machinery, and `sessionContext` orchestration take no outer
  claim; nested calls acquire independently at the same gate. Direct bus calls
  and autonomous background execution are outside this dispatch guarantee.
- `workspace`: path-shaped arguments are resolved against the conversation
  workspace at dispatch. Such tools also receive core-owned private context
  `__workspace = {root, roots}` — the conversation's **workspace set**: the
  primary workspace plus its linked git worktrees (`git worktree list`) and
  sibling checkouts of the same `remote.origin.url` (core/workspace.nim;
  bounded by `maxWorkspaceRoots`, currently 8). It exists
  so a component can recognize work in another tree of the same project
  instead of treating it as "outside the workspace" — `lsp` indexes a file in
  a declared root as *that* tree. Like `__session`, it is injected after the
  model's message is written and never rendered into the frozen system prompt
  or a tool schema: worktree awareness must not cost a cache miss, and a
  worktree appearing mid-conversation is picked up on the next dispatch.
- `noSpawn`: a subagent (a session with a parent lineage record) may not call
  this tool (depth guard enforced at dispatch).
- `parallel`: `true` marks the tool safe to dispatch **concurrently** with
  other `parallel`-marked tools in the same assistant message. The runner
  fans out the batch over the bus and reassembles results in call order.
  Default (absent/`false`) is strictly serial — which is also enforced for
  any tool carrying `approval: "always"` or `sessionContext: true`, whatever
  `parallel` says. `parallel` is a *runner-side* scheduling hint: it does not
  by itself make one process execute two handlers concurrently. Server-side
  execution is an independent, explicit component choice: stateless services
  can use process replicas; audited Go handlers can register with
  `ToolConcurrent`; a Nim component may own native workers even though the
  default SDK pump remains serial. The NATS queue group on
  `svc.<component>.call` distributes one call per process subscriber.

## Self tests (`selftest`) and `/doctor`

Every component may register a hidden tool **`selftest`** (SDK: `selfTest()`,
both SDKs) — a component checking its own wiring, on core's behalf:

- input: `{deep: bool, default false}` — quick mode must stay cheap (no
  spawns, under ~10s: configuration, binary resolution, own-store sanity);
  `deep` runs live end-to-end probes and may spawn real processes (e.g. the
  lsp component boots every configured language server against fixtures).
  Callers pick the timeout: `deep` legitimately takes minutes.
- result: `{ok: bool, summary: string, checks: [{name, ok, detail, ms}]}` —
  one entry per check, `ms` the per-check duration; `ok` is false when any
  check failed. The canonical `{ok, error}` envelope conventions still apply
  for transport-level failures.

Components without a selftest tool are not broken — the mechanism is
opt-in; `/doctor` lists them under `selftestMissing` (and as one
`selftest (not implementing)` row in its markdown report), so the gaps are
visible without ever failing the check.

Catalog note: tool names are unique across the harness (discover/invoke
dispatch by bare name), but `selftest` is deliberately exempt — it exists
on every implementing component by design, is hidden, and is addressed
per subject (`svc.<component>.call`) by `/doctor`, never by bare name.

**`/doctor`** (core tool `doctor`, also a declarative slash command) is the
user entry point: core's own read-only probes (bus, store, llm/provider,
systemprompt, catalog size, conversations) plus a **self-test fan-out** —
a `selftest` request to every registered component that implements one
(skipping core itself and UI clients), results collected under
`selftest: [{component, ok, summary, checks}]`. The fan-out is sequential
(core serves one call at a time) with a per-component timeout (10s quick /
120s deep); a timeout or transport error is a failed check, never a crash.

## Store contract (`svc.store.call`)

Instance registry infrastructure (both engines, hidden from the model):

- `instance_register {instanceId, name, root, gitHash}` atomically inserts or
  refreshes metadata in the `instances` table. `instanceId` is exactly 32
  lowercase hexadecimal characters. All fields are required strings; name,
  root and gitHash are bounded to 255, 4096 and 64 UTF-8 bytes respectively;
  NUL/CR/LF and unknown fields refuse `bad-request`. Refresh preserves
  `firstSeen`, replaces supplied metadata and updates database `lastSeen`.
  Returns `{ok: true, instanceId}`. This internal write carries no human
  approval requirement: it records observations, never grants authority.
- `instance_list {after?, limit?}` returns
  `{ok, items: [{instanceId, name, root, gitHash, firstSeen, lastSeen}], hasMore,
  nextAfter?}` in ascending identity order. `after` is an exclusive full ID;
  `limit` defaults to 100 and must be 1..1000. One-row lookahead makes hasMore
  exact; nextAfter is present only when more rows remain. Times are database
  timestamp strings. Listing is read-effect; registration is write-effect.

`store_claim {to, dryRun?, limit?, afterKind?, afterId?}` is the explicit,
admin-only migration of pre-scoping documents into one instance. It is hidden,
write-effect and approval-gated, and moves rows **only** from the unowned owner
`''` to a valid instance id — never between two real instances. It reports
`{ok, dryRun, to, examined, conflicts[], hasMore, nextAfterKind?, nextAfterId?,
claimed?}`; when any examined document's `(kind, id)` is already owned by the
target it refuses `claim-conflict` instead of overwriting it. Batches are capped
at 1000 documents in `(kind, id)` order with an exclusive cursor, so a large
history is claimed in resumable batches rather than one unbounded transaction.
`dryRun` defaults to **true**. Neither engine adopts legacy rows implicitly:
on a shared TiDB dataset `''` may be another instance's pre-scoping history.

Registry metadata is not verified remote identity, connection routing or a
permission grant. Hidden tools are not an authentication boundary: direct bus
callers are trusted. No retirement/delete API or implicit shared configuration
fallback is provided. The registry alone does not scope existing documents;
instance-aware document ownership is separate work.

The store's bus contract is the artifact; every engine implements exactly
these tools (docs/MANUAL.md "Store engines"). `put` / `get` / `del` carry
`{kind, id, value?, expectRev?}`; docs are opaque JSON, ids sort
lexicographically, and `expectRev` gives optimistic concurrency
(`rev-conflict` on mismatch). `expectRev: -1` is **create-only**: the write
succeeds only when the document does not exist yet and is refused with
`rev-conflict` otherwise, so a caller can establish a single owner without a
read-then-write race. `expectRev: 0` (the default) is an unconditional upsert.

`list` takes `{kind, idPrefix?, limit?, after?}` and returns
`{ok, items: [{id, rev, value}], hasMore, nextAfter?}`.

**`list` is a page, not a complete view.** `limit` is capped at 1000. When
more documents follow, the reply carries `hasMore: true` and `nextAfter`
(the last returned id); pass it back as `after` to continue. `after` is a
strictly exclusive cursor — the id equal to `after` is never returned — and
it advances by *key*, so a page whose documents are all tombstoned still
moves forward rather than stranding the caller. A caller that needs the
whole kind loops until `hasMore` is false or `nextAfter` is absent.

Core's own full-kind reads (session resume, `session_info`,
`conversation_delete`) use `storeListAll` (core/dispatch.nim; the SDK
exposes the same helper) rather than a single call, because a capped read
silently truncated a resumed transcript at 1000 messages and the next
write then targeted an existing id.

`search` takes `{kind, query, idPrefix?, rank?, snippet?, offset?, limit?,
after?}` and returns `{ok, items: [{id, rev, value, snippet?}], hasMore,
nextAfter?|nextOffset?, ranked}` — the documents of `kind` whose indexed
text matches `query`. It is the server-side filter for session browsers
(niffler-tui and any other client): find conversations by title/id, or
messages by content, without downloading the whole kind and filtering
locally. It is also the retrieval half of context recovery (`context_recall
mode: search`, issue #51): `idPrefix` scopes to one conversation's
messages, `rank` orders by relevance, `snippet` marks the matched span.

- **Indexed fields** (documented, per kind): `conversation` = id +
  `value.title`; `message` = id + every string under `value.content` +
  `value.reasoning` (capped at 16KB per document in total); any other kind
  = id only.
- **Matching** is contract, identical in every engine: query and indexed
  text tokenize the same way — runs of unicode letters/digits are tokens,
  every other character is a separator — and *every* query token must
  match as a case-insensitive **prefix** of some token in the document's
  text (AND). There is nothing to escape: no user character can act as an
  operator (`OR` is just a word, `kind:` is just two words). A query that
  tokenizes to nothing fails `bad-request`; a query that matches nothing
  is `ok: true` with an empty `items`. `idPrefix` narrows to ids with that
  literal prefix — LIKE metacharacters in it are escaped, never widened.
- **Ordering and paging** come in two documented modes. Default (and
  `rank: false`): `list`'s — ascending id, `after` exclusive,
  `nextAfter` = last returned id when `hasMore`. `rank: true`: relevance
  ordering, paged by `offset` with `nextOffset` when more remain (a
  ranked order is recomputed per call — a concurrent write can shift
  items between pages; the id-order cursor does not apply). `limit`
  default 100 / cap 1000 in both modes; page until `hasMore` is false —
  `search` never silently truncates a result set. Every reply carries
  `ranked: true|false` so a caller always knows which ordering it holds.
- **`snippet: true`** attaches a one-line `snippet` per hit with the
  matched text in `[brackets]` (engines without an index mark the first
  matched token's window — best effort, same shape).
- **Vector search** (a second mode of the same `search` tool): pass
  `vector` (the query embedding) and `model` instead of `query`, with
  `kind: "embedding"`. The reply is
  `{ok, items: [{id, rev, value, distance}], hasMore, ranked: true,
  vector: true}`, ordered by **cosine distance** (0 = identical, 2 =
  opposite) and paged by the same `limit` rules (`hasMore` when more
  neighbours exist). `limit` defaults to 20.

  Embeddings are ordinary documents of kind `embedding`, so the document
  contract is unchanged:

  ```json
  {"kind": "embedding", "id": "<ref>@<model>",
   "value": {"model": "hf:nomic-ai/nomic-embed-text-v1.5",
             "dimensions": 768, "vector": [0.013, …],
             "source": "message", "sourceId": "conv-1:000042"}}
  ```

  `model` and `vector` are required; `dimensions` defaults to
  `len(vector)` and **must** equal it, or the write is refused with
  `bad-embedding` (a document stored but not indexed is unfindable, with no
  error anywhere to explain the silence). `source`/`sourceId` are
  informational — they name the document the vector describes, so a hit
  resolves to real content without parsing the embedding id.

  `model` is required on the query because two models are different
  embedding spaces: mixing them is meaningless, so an unnamed space could
  only return nonsense. `kind` and `model` are filters *inside* the search,
  not applied afterwards, so `k` neighbours come back rather than a
  post-filtered shortfall. Vectors of different widths live in separate
  indexes and are never compared; a width no document uses answers with an
  empty page rather than an error.

  The index is **derived state**, exactly like `docs_fts`: put/del maintain
  it in the same transaction, a startup disagreement re-derives it from the
  documents, and dropping it loses nothing. Consumers never see which index
  answered. The sqlite engine implements it with sqlite-vec (`vec0` tables
  partitioned by kind and model, one table per vector width); the tidb
  engine does not yet, and answers `code: "unsupported"` rather than
  pretending to have searched.
- **Engines**: the sqlite engine (default) answers from an FTS5 index
  (`docs_fts`) whose rowids are `docs`' rowids — put/del maintain it in
  the same transaction, and startup rebuilds it from `docs` whenever the
  two disagree (derived state: dropping it loses nothing). It ranks with
  FTS5's bm25 (ties broken by id) and marks snippets with FTS5's
  `snippet()`. The tidb engine has no index (issue #94) and applies the
  same matcher by scanning the kind in id order: matching is equivalent,
  `rank: true` is accepted and answered `ranked: false` in id order (with
  `offset` still paging the match set) — engine-private detail otherwise;
  consumers see the same contract.

## Conventions

- Component names: lowercase, hyphens (`hashline-edit`). Tool names: lowercase,
  letters/digits/underscore (LLM function-calling grammar).
- Tool results are JSON values. A result object carrying a string `text`
  field is the LLM-facing rendering: session runners put `text` verbatim
  into the tool message (`role: "tool"`), and nothing else from the result
  reaches the transcript. Every other field is machine data for bus
  consumers — fabric programs, tests, UIs, plugins — and must stay stable
  even when the `text` wording changes. Text-oriented tools follow the
  `(exit N)` status-line convention as the first line of `text` (non-zero =
  failure) and repeat the same facts in structured fields (`exit_code`,
  `cancelled`, `spill`, ...). A bare-string result is rendered as-is; a
  result without `text` is serialized into the transcript unchanged.
- **Tool results may carry images.** A result object may add an `images`
  array beside `text` — the one channel by which a TOOL can return something
  the model *sees* rather than reads (a screenshot, a rendered chart, an
  image the agent was asked to inspect). Items are
  `{type:"image", name?, mimeType, data, width?, height?}` exactly as a
  session call's `attachments` are, and they are validated by the same code
  against the same byte-sniffed allowlist (`image/png|jpeg|gif|webp|bmp`),
  with one difference: at most **4** per result, because a turn's drop is a
  human choosing files while a result is one call's side effect. `width`,
  `height` and `name` are advisory metadata for the caption and the token
  proxy; the bytes are the facts.

  Core, not the component, owns what happens next, so no component can widen
  the bound:

  1. **Validation.** A well-formed array is stored; a malformed one never
     fails the turn. The refusal is appended to the result's `text`
     (`[images from this result were not attached: <reason>]`) so the model
     learns why the pixels it expected are missing, and the tool's own text
     still answers the call.
  2. **Storage.** Pixels become `attachmentdata` documents (kind
     `attachmentdata`, id `<toolMessageId>:a<i>`) with a pixel-free
     `attachment` metadata doc beside them — the same two-document split a
     dropped image uses, so the tool pixels are swept by
     `conversation_delete` and never appear in a `list` page. The stored tool
     message keeps the text plus small `attachments` refs.
  3. **The projection.** The tool message materializes into the multimodal
     content array through the SAME rule as a user turn: text parts first,
     then `image_url` data-URL parts, newest-first within `NIF_ATTACH_BUDGET`,
     older images replaced by the honest text marker. There is one budget and
     one rule for every image in a conversation, whatever produced it. A
     single result's images are capped below that budget, so the newest
     result's image is never born already elided.
  4. **Non-vision models.** The projection consults the resolved model's
     capability, which `llm_resolve` reports as `vision` + `visionSource`
     (from the catalog's `modalities.input`): when the model positively cannot
     take image parts, EVERY image is elided to the text marker above instead
     of being materialized, so the request stays one the provider accepts. This
     matters because a provider rejects the whole conversation, not just the
     turn, so one image in history would strand every later turn. Unknown is
     not "no": an unresolvable model, an unavailable models component or an
     older `llm` component that omits the field all keep images materialized,
     and the same rule is re-applied at the start of a turn (a resumed
     conversation materialized before any capability was known).

  A tool's images are **append-only history**, never part of the frozen
  prefix: the request prefix is the system prompt plus the direct tool
  schemas, so pixels entering mid-conversation cannot invalidate a
  conversation's cached prefix. A result's `images` is also the one field core
  rewrites for a bus-facing event: `ev.session.<id>.toolcall`'s `result` carries
  the stored refs (id, name, mimeType, bytes, dimensions) with the base64
  removed — and a refused array is replaced by `imagesDropped: <reason>`
  instead of passing through, which is the case where the payload is largest
  and nothing stored the bytes. The dispatching caller already holds the
  pixels; no observer should pay megabytes for them.

  What core does **not** do is re-encode. An oversized image is reported, not
  resized: silently downscaling is a wrong answer to "what does this look
  like", and the alternative — an unsendable payload entering history — is the
  failure this bound exists to prevent (an over-limit image makes a provider
  reject the whole conversation, not just the turn). A component that wants a
  large capture sent shrinks it before returning it, exactly as `bash` caps its
  own output.

  Elision keeps working on image-carrying results: the stub rung elides the
  result's text AND drops its refs (reclaiming the pixels), so a superseded
  screenshot leaves the projection instead of being re-materialized from stale
  refs. Middle-pruning refuses such a result rather than silently dropping its
  images.
  One `userMessage` convention rides the same machine-data rule: a result
  object carrying `userMessage` (string) asks the *client UI* to render
  that string as a user-authored message (MCP prompt templates, e.g.
  `mcp-<server>-<prompt>` slash commands) — it never enters the transcript
  as system or assistant content, and it is not required for the result to
  carry `text` alongside.
- Big payloads (tool output > ~64KB): reference, never inline —
  `{"ref": "store://bucket/key"}`; JetStream Object Store later, filesystem
  under `var/store/` for milestone 1.
- One message = one envelope. NDJSON for stdio streams (pipewrap) — same
  codec, line-delimited.
- One envelope still has to fit the NATS `max_payload`. Core spawns the
  bundled `components/nats` build — the only bus it ever uses — with
  `--max_payload 8388608` (8MiB; a Niffler flag extension) because an `llm`
  `chat` request carries the whole conversation. A missing bundled binary is
  a hard error naming `make build`, never a fallback to a PATH `nats-server`.
  Core also checks the connected bus's cap at boot and warns when it is
  below the harness's 8MiB. A publish over the cap fails and reports the
  size against the server's `max_payload`.
