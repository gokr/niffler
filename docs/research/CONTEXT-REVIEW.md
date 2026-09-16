# Pi / DSH review — close the contracts before adding more features

Status: **historical review** (2026-09-13). The recommended context
ownership split and bounded recovery have since shipped; current behavior is in
[MANUAL.md](../MANUAL.md#context-window) and [COMPACTION.md](COMPACTION.md).

Reviewed the latest [COMPACTION.md](COMPACTION.md),
[PI-NEXT.md](../PI-NEXT.md), [PI-VS-NIFFLER.md](../PI-VS-NIFFLER.md),
[DSH-STEAL.md](DSH-STEAL.md), [DEEPSEEK-HARNESS.md](DEEPSEEK-HARNESS.md),
[ESCALATION.md](ESCALATION.md), [OCTOFRIEND-STEAL.md](../OCTOFRIEND-STEAL.md),
and the store/sandbox plans against the architecture and selected source paths.
Niffler basis: `1329b7e`; local Pi: `71dca871b`; local DSH: `c291e7961a`.
The process-tool work mentioned in the original snapshot has since shipped.
Findings below distinguish source observations, specification gaps,
and recommendations. This is not a fresh exhaustive upstream feature census.

## Recommendation

**The replaceable-compaction recommendation landed.** Strategy lives in a
component, while validation/admission/persistence live in the runner. The
shipped path retains deterministic fallback, bounded recovery, immutable
canonical history and the third-party conformance fixture; some broader
recommendations below remain open research.

The largest overlooked lesson from DSH is not its summarization prompt. It is
that **stored history, the model's current view, external effects, and live
runtime state are different things**. Pi's split-turn summaries, file-operation
tracking, and experimental durable-tool runtime reinforce the same lesson.

Make the smallest explicit contracts connecting those things. Do not import
DSH's DI framework, whole event-sourcing architecture, or a large new core.

## 1. Resolve these compaction blockers before coding the default summarizer

### 1.1 Recall is inaccessible as specified

**Source observation:** `core/dispatch.nim:invokeTool` rejects hidden tools;
hidden tools also do not appear in discovery. COMPACTION §5 calls
`context_recall` hidden while teaching the model to call it. The proposed
`runner: true` flag would make that conflict stronger, not solve it.

**Proposal:** separate the internal compactor from public recall:

- `compaction_propose`: hidden, runner-internal.
- `context_recall`: model-accessible read tool, normally on demand, reached via
  `discover` + `invoke`; direct in profiles that need frequent recall.
- Notices show the actual callable syntax, not a hidden tool's imagined direct
  invocation. Test an allowlisted subagent too: availability must be deliberate,
  not an accidental exemption permitting arbitrary store reads.
- Keep reference resolution independent of the selected summarizer. Removing or
  replacing a compaction strategy must not remove access to canonical history.
  This can be a separate recall peer; it does not require retrieval code in core.

### 1.2 Long-turn cuts need an explicit retained user anchor

**Specification gap:** COMPACTION requires an exact contiguous covered prefix,
`cutBefore`, and preservation of the latest actual user request. For
`user → 40 assistant/tool groups`, that user is *inside* the prefix a mid-turn
cut needs to remove. The response/projection examples cannot represent this
exception. A six-field checkpoint alone does not preserve the verbatim request.

**Proposal:** retain the actual user message as an explicit anchored reference,
with an ordered projection recipe such as:

```text
frozen system + unchanged tools
latest actual user request (canonical reference, original content)
checkpoint of covered work (background history, clearly attributed)
recent complete assistant/tool groups
```

Specify covered ranges excluding retained anchors, ordering, and duplicate
elimination. An earlier real user request can later become summarizable when a
new one supersedes it. Preserve important earlier corrections separately (§3.2).
Do not implement an arbitrary graph editor: one anchor, checkpoint, tail, and
bounded prune substitutions are enough initially.

Also distinguish actual user messages from steer/advice/runtime notices in
storage metadata. Today several of those use `role: user`; role alone cannot
implement “latest actual user request.” Core already owns their injection paths.

### 1.3 A canonical ID must mean an acknowledged, durable record

**Source observation:** `core/conversation.nim:persistMsg` increments `seqNo`,
catches store failures, logs a warning, and continues. The proposed node model
says canonical IDs always resolve and canonical sequence is contiguous. The
current persister does not guarantee either.

**Proposal:** track the durable boundary separately from allocated/live IDs.
Never install a projection covering unacknowledged source messages. For a
conversation using durable compaction, fail recoverably on persistence failure,
or repair/persist the missing span before attempting a cut. Do not quietly
continue with fabricated durable references.

Handle **unknown commit outcomes** too: a store timeout can mean the put landed
but its reply was lost. Give projection commits an attempt ID and digest; read
back and reconcile before retrying, emitting success, or treating a conflict as
another writer. Use idempotent record identities for overflow receipts as well.
SQLite atomicity alone does not solve lost acknowledgments over the bus.

### 1.4 The projection must reload exactly, including old references

**Specification gaps:**

- `files` is required by §4.6 but absent from the six-field checkpoint contract,
  which rejects unknown semantic fields.
- A single overwritten projection cannot resolve `checkpoint #ck3` once #ck4
  lands. The plan explicitly permits this failure, contradicting its durable
  recall goal for advertised checkpoint references.
- `{ref, bytesBefore, bytesAfter}` is not an exact prune recipe. A changed
  default or notice renderer could rebuild different content after restart.
- A canonical `covered` pair does not describe absorption of a previous
  checkpoint or retention of an interior user anchor.

**Proposal:** freeze the v1 representation before implementation. Persist
immutable checkpoint records plus a small current projection record, or stop
advertising old checkpoints as durable references and cite canonical spans only.
The former is more useful for diagnosis. Persist prune content or all versioned
parameters required to reproduce it byte-for-byte. Include deterministic file
facts in an explicitly typed field, separate from model-authored claims.

Keep this schema compatible with a future content-block representation (§3.4),
but do not require that whole refactor to ship text compaction.

### 1.5 Recall itself must not recreate the overflow

**Specification gap:** `context_recall` promises paging but has only `limit`, no
cursor/offset. An array of individually bounded refs can still overflow in
aggregate. A huge `spill` document still exceeds the bus limit when put/get;
calling it a reference does not make the referenced transfer bounded.

**Proposal:** use a shared artifact/reference vocabulary with:

- source/session identity, content digest, media/encoding, length;
- exclusive cursors or byte/line ranges, aggregate byte caps, continuation hints;
- chunk manifests published only after all chunks are acknowledged;
- byte-budgeted store pages, not just “1000 items per page.”

Bound manifests and JSON-encoded envelopes too. Snapshot paging must handle one
oversized message, not only many small messages. Ordinary `chat` requests also
need a serialized-envelope size check: provider token capacity and NATS payload
capacity are independent limits.

If canonical tool content is already acknowledged, pruning needs no duplicate
spill copy. Spill is needed for content *not* kept in the canonical message.
Define “original” precisely: original delivered tool text versus original file
bytes are not interchangeable; current message records use `content`, not `text`.

### 1.6 Price the request being sent, not the last response

**Source observation:** `checkContext` prefers the previous provider usage once
it exists; that count does not include subsequent tool output or a new user
message. It also runs before the current round drains steer/advice. The latest
plan correctly moves admission to the final request, but the estimator needs an
explicit contract to make that work.

**Proposal:** use the resolved adapter's request shape, fixed system/tools cost,
retained reasoning/content, new messages, output reserve and safety margin.
Provider-reported usage is a calibration anchor for that route, not a substitute
for pricing appended content. Re-anchor after projection/route changes. Expose
estimate versus reported usage and unknown capacity explicitly. A chars/4 proxy
cannot guarantee that no real provider request ever overflows; keep the bounded
provider-overflow recovery path even with a green mock-window test.

Tool pairing must validate identities (including duplicates and unmatched
results), not merely reach a zero counter. Also reject requests invalid under
the target adapter's ordering rules; token fit alone is not admissibility.

## 2. The most easily missed regression: component memory outlives model memory

**Source observation:** `components/edit/main.nim:SeenEntry.full` means “the
conversation holds (or can derive) the full content.” `hRead` returns an
`[unchanged]` stub for matching seen bytes. `unchangedText` explicitly claims
“the bytes already in context are current.”

After compaction or pruning, that claim may be false. The file digest remains
valid while the model no longer has the text. A summary listing a filename is
not a substitute for the bytes needed to construct an exact edit.

**Proposal:** separate two concepts:

1. **Observation freshness** — the version used for `E_STALE` safety.
2. **Context visibility** — whether full content is known to be present in the
   model's current projection.

The smallest conservative implementation injects a context generation in
private session metadata and permits read dedup only within the generation in
which full content was delivered. On projection changes, invalidate the
visibility assumption, **not** the staleness digest. Inject it on calls rather
than relying on a best-effort reset event. A later exact reference-based scheme
can avoid unnecessary re-reads of retained files.

The existing `force: true` escape hatch is useful, but not a substitute for
fixing a false automatic claim. Add `read → compact → read same bytes` and
`read → prune that result → read` regressions.

Apply the same distinction to discovered schemas, loaded skills and fabric API
declarations: “loaded once in this session” does not imply “still visible.”
After a cut, a small checkpoint inventory can tell the model what to reload;
do not automatically inflate the frozen direct toolset to compensate.

## 3. Steals that deserve promotion in the roadmap

### 3.1 Crash-tail repair before richer autonomous agents

DSH's `packages/core/session/src/repair.ts` distinguishes `TOOL_NOT_STARTED`
from `TOOL_OUTCOME_UNKNOWN` and supplies missing tool results before closing an
interrupted turn. Pi's **experimental AgentHarness**, not the shipped coding
agent, additionally persists completed out-of-order tool outcomes before their
source-ordered placement (`packages/agent/docs/tool-durability.md`).

Niffler persists assistant calls before dispatch and tool results afterward,
but `loadStoredMessagesEx` does not repair unmatched calls. Killing a runner can
therefore leave provider-invalid history and uncertain external effects. A
compactor must not summarize that uncertainty into “completed work.”

**Smallest proposal:** repair unmatched calls deterministically on reload with
explicit unknown-outcome results and verify-before-retry guidance. Without a
durable start/admission record, do not claim an operation never started. Do not
automatically replay writes. Add a separate replay/idempotency declaration only
when the scheduler actually uses it; read/write scheduling is not a replay
contract. Later add durable invocation receipts and completion-order settlement.

This is a closer dependency of safe continuations than teams or tree navigation.
Process isolation limits crashes; it does not roll back filesystem/API effects.

### 3.2 Preserve authoritative requirements and evidence, not just prose

COMPACTION §11 correctly names objective drift but defers the remedy entirely.
Iteratively summarizing a model's own summaries can turn tentative claims into
facts even when every response passes JSON validation.

**Proposal:** start smaller than DSH's goal/todo system:

- a bounded set of verbatim user constraints/corrections with source IDs;
- observed file operations, with outcome and source tool result;
- verification claims with command/result reference and workspace revision or
  relevant file digest when available;
- explicit uncertainty and unsuccessful approaches, not just next steps.

Structured shape validates syntax, not truth. Keep deterministic evidence
separate from model-authored interpretation; never mark a file modified merely
because an edit was requested. Component-supplied resource/evidence metadata can
provide this generically, without hardcoding language/tool families in core.
Budget the evidence inventory and use paged refs when it grows.

A durable goal component can come later. Its records should be cited by
checkpoints rather than repeatedly rewritten into an increasingly confident
objective. Runtime state needs the same treatment: a server/process ID is a
handle to query, not proof that the process is still running. DSH's explicit
supersession/tombstone notices are worth borrowing when refreshing such facts.

### 3.3 One auxiliary-call contract, with honest cancellation and budgets

Compaction, expert judgment, edit repair and future routing all need auxiliary
inference. Do not make four incompatible conventions.

**Proposal:** retain ordinary calls to the LLM peer but distinguish:
`sourceSessionId`, unique request/attempt identity, cancellation identity,
`purpose`, resolved route, stream visibility, deadline, and usage ownership.
Where a provider uses a cache-affinity key, keep that separate from UI/cancel
routing. Pin the actual provider/model/adapter route for an attempt.

Distinct cancel IDs prevent collisions; they do **not** mean a user Stop should
leave a blocking compaction call spending tokens. Cancellation of the enclosing
turn should explicitly cancel its auxiliary work, while cancelling one auxiliary
attempt must not cancel unrelated requests. Drop stale replies after cancellation.

COMPACTION currently claims runner enforcement of “sum(granted auxiliary calls)”
while the component calls `svc.llm.call` directly. There is no described grant
path to enforce that claim. Either document trusted component-local call/token
limits plus runner timeout/cancel, or have the LLM peer enforce a bounded
auxiliary allowance. Do not claim post-hoc usage validation prevented spending.

Also move the auxiliary plumbing before the default compactor in the delivery
order: §4.7 calls it a prerequisite while §9 currently lists it afterward.

### 3.4 Borrow a small provider-neutral content seam now

Octo's lowering architecture and DSH's adapter-owned replay envelopes are more
relevant than the current “not urgent” IR ranking suggests. Compaction, images,
provider switching and forks all touch persisted message interpretation.

**Source observation:** the resume loader copies a restricted field list and
does not retain per-message provider/model in the replayed context. The
Anthropic request builder emits assistant text/tool calls, not the original
signed thinking blocks. A generic `reasoning` string is not lossless native
replay metadata.

**Proposal:** define versioned message content and source attribution, with
optional opaque replay data owned by an adapter and compatible route. Adapters
lower it and decide when replay metadata must be omitted; core does not parse
provider internals. Preserve retained native blocks intact; dropping a complete
summarized group is different from editing a signed block's contents.

Ship a compatibility wrapper around today's text messages first. Add image
references, normalization, modality fallback and byte/token admission through the
same seam later. Golden fixtures should cover same-provider resume and
cross-provider continuation. This avoids two incompatible transcript migrations.

### 3.5 Build the behavioral eval lane alongside compaction, not afterward

PI-NEXT demotes evals as blocked on compaction. That is backwards for this work:
we need the baseline now, and mock summaries cannot demonstrate real retention.

**Proposal:** keep deterministic contract/crash tests and add a small opt-in,
cost-capped long-horizon eval corpus before changing behavior. Include:

- exact user corrections and constraints after several compactions;
- failed approaches not repeated; unverified work not reported as tested;
- obscure mid-result details recovered through recall;
- same-file re-read after compaction and a changed file after checkpointing;
- one enormous user turn; multiple tool calls; cancellation and restart;
- a provider switch and a derived child using compacted history.

Compare trim-only, prune-only and summarize+recall with matched inputs/routes.
Measure task correctness, unsupported claims, useful recall, repeated work,
latency, total assistant+auxiliary spend, and cache reads/writes. A smaller prompt
is not success if it produces confident wrong work. Repeated samples are needed
for model-backed quality comparisons; deterministic tests remain the CI gate.

## 4. Corrections to the other plans

### Cache: implement write accounting; defer speculative surgery

PI-NEXT's explicit cache markers and separate write accounting are well-grounded
high-value work. Its “cold prefix mutation is free / strictly cheaper” argument
is too strong:

- expiry is uncertain, provider/model-specific, and sometimes partial;
- stable system/tools may still hit after history compaction;
- a warm prefix can make the *summarization call* cheaper;
- summaries cost tokens/latency and may lose useful information;
- zero reported cached tokens is not uniquely proof of expiry (thresholds,
  routing, unsupported caching and serialization changes can also explain it).

Use separate dimensions: **mutation** (`compact`, `trim`, `tools`), **trigger**
(`pressure`, `overflow`, `manual`, perhaps `suspected-expiry`), and **observed
cache outcome**. Do not use `reset:expired` to conceal a tool/profile mutation.
A cold cache is not permission to violate the frozen-prefix contract. Do not
silently defer an explicitly requested sticky promotion until a guessed expiry.

Add hysteresis/headroom between trigger and post-compaction target, so one tool
result does not cause immediate repeated summarization. Prefer execution-time
bounded results before history surgery. Treat prefix-reusing summarization as an
optional measured strategy, not the compulsory first attempt on every cut.

### Store: atomicity is required; a default flip is a deployment decision

SQLite is a reasonable preferred engine. The actual prerequisites are atomic
value+revision updates, acknowledged source persistence, bounded ordered paging,
and read-back reconciliation. They are capabilities of the store contract, not
inherently a database brand. Fixing barrel's record layout is another possible
route; no need to pursue both before shipping SQLite-backed compaction.

Before flipping the default, specify:

- detection of an existing barrel dataset: migrate explicitly or refuse to
  silently start an empty SQLite instance;
- a quiescent/snapshot export, not an evolving live scan;
- kind enumeration (the current `list` requires a kind), bounded pages, count
  and content-digest verification, and preservation of referenced artifacts;
- process-crash versus machine/power-loss durability guarantees;
- rollback limits: switching back does not include new writes made to SQLite.

The 1000-record resume issue is independently urgent: a truncated scan can also
leave the persister at an old sequence and overwrite newer message IDs. Fix all
transcript consumers, deletion and agent scans too, not just projection reload.
Bounded pending mailbox size does not bound lifetime mailbox history.

Add retention/deletion rules for checkpoints, receipts, spill chunks and temporary
snapshots when introducing them. A reference that must survive compaction cannot
be collected merely because it is absent from today's projection. Migration and
forks must preserve its ownership/reachability too.

### Forks: stored source history does not replace branch summaries

PI-NEXT's claim that branch summarization “buys nothing” because Niffler keeps
full history is incorrect. Pi keeps full history too. A branch summary transfers
findings from the branch being left into the target branch's *working context*.
Storage availability is not context inclusion. The UI can still be deferred.

DSH-STEAL's message-count/character-limited forks must round to tool-balanced
boundaries. A parent's currently persisted tail may contain the delegation call
without its result. Do not copy arbitrary last-K records. Prefer one runner-owned
safe snapshot/derivation seam shared with compaction, rather than `agent` writing
raw transcript records before the child's header exists.

Specify canonical versus projected inheritance, reference rebasing, parent
removal behavior, child budget admission and provenance. A branch does not roll
back workspace files: record the workspace/git revision and expose divergence,
or later use isolated worktrees. Cache sharing on forks is provider/request-shape
conditional, neither guaranteed cold (DSH-STEAL) nor guaranteed warm.

### Teams: replace “exactly once” prose with acknowledgments and deduplication

DSH-STEAL describes mark-before-dispatch/drain and admits a loss window, but
labels some lanes exactly-once. Those guarantees are incompatible.

Use durable message IDs, pending/claimed/acknowledged delivery, acknowledgment
after recipient persistence, and deduplication by message ID at admission.
Delivery may be retried; application to the recipient transcript is idempotent.
A destructive inbox read must not acknowledge a reply that was never persisted.
This can use document CAS and sequencing without a distributed transaction.

Likewise, distinguish a resident runner from an active turn. Return `busy` or
queue an explicit activation ID rather than assuming catalog presence means
running and a timed-out queued request cannot later execute. Persist terminal
facts used for reconciliation; `ev.*` is a live hint, not a durable queue.

### Escalation: classify the problem before buying a stronger model

Do not count approval denial, user cancellation, missing tools, store failures,
quota exhaustion, or a deliberately nonzero probe as reasoning failure. Start
with normalized terminal reasons and an allowed-route/cost governor. Never
force three more rounds for an external blocker simply because the ladder has
not been exhausted.

Do not reset failure streaks on compaction by default: forgetting context is not
evidence of progress. Keep counters bound to the task/activation, with explicit
human reset or verified progress. De-escalation should follow evidence, not the
assumption that test/commit/push is always a cheap, safe phase.

The “zero core changes” event-observer prototype is fine as a convenience, not a
durable guarantee. Reconcile missed terminal events from stored outcomes and
reject stale policy actions using turn/selection revisions. Never overwrite a
human's newer model choice. Volatile judge counters belong in appended input,
not the expert's supposedly cache-stable prefix.

### Repair models: unique matching is not proof of preserved intent

OCTOFRIEND-STEAL's repair proposal can find a unique *wrong* region. A similarity
floor does not make wrong-place edits impossible. Preserve the original desired
replacement, bind repair to an observed file version, revalidate after inference,
and surface the actual repaired diff. If approval covered exact arguments, a
semantic retarget needs renewed approval rather than an invisible substitution.
Measure false repairs before promoting rescue rate. Keep this opt-in and behind
continuity/recovery work; do not silently repair truncated mutation tool calls.

### Shell/process work: share launch policy, not necessarily a job framework

Keep the proposed shell provenance variables, but make them explicit child-env
data, not credentials or ambient authorization. Coordinate with SANDBOX-PLAN's
environment allowlist. Background commands delegated from bash to `processes`
must use the same workspace/env/confinement policy; the fast background path
must not become an accidental unguarded path. No need to merge agent jobs and
process jobs into one large runtime just to share IDs, status and output cursors.

## 5. Suggested delivery order

| Lane | Deliverable | Acceptance / stop condition |
|---|---|---|
| Now | Fix store paging and settle durability/migration behavior; baseline long-context evals | No truncation/ID reuse, bounded envelopes, no silent empty-store switch |
| Compaction foundation | Canonical IDs, message origin, projection recipe, anchor, crash-tail repair, admission | Restart produces the same valid request; never imply an unknown effect succeeded |
| First useful release | Deterministic prune/trim, callable bounded recall, read-visibility invalidation | Useful without an LLM summarizer; errors explicit when no safe fit exists |
| Summarization | Auxiliary-call contract, structured candidate, validation, atomic commit/reconciliation | Two compactors pass one conformance fixture; multi-generation continuity measured |
| Parallel small work | Cache markers/write accounting; shell provenance; process launch-policy alignment | Provider request fixtures and regression tests; no broad core dependency |
| Next | Evidence/goal references; neutral content/replay seam and images; safe derivation/continuation | Cross-provider and fork/recall behavior explicit; no new transcript ambiguity |
| Later | Team delivery, escalation policy, ranked history search, optional tree UI | Build on durable identities/outcomes; justify with workload evidence |

Do not postpone the foundation's failure tests until the end: crash before/after
put, lost reply, stale candidate, oversized page/item, missing artifact, Stop,
steer, allowlisted child, multi-generation re-read, and unknown tool outcome all
belong with their respective increments.

**Prompt effect:** the proposed schema/template additions affect new frozen
prefixes only; recall/discovery/runtime notices are append-only history;
compaction/pruning are explicit persisted projection resets. No volatile state
is silently inserted into an existing frozen system prompt or toolset.

## 6. Documentation hygiene

The latest notes have better source discipline than the older ones, but plans
still contradict one another. Examples: DSH-STEAL describes the retired Nim VM
fabric design; OCTOFRIEND-STEAL's opening LSP gap is already shipped;
PLAN.md still proposes store ports that exist; research/README calls MCP
unshipped while PI-VS-NIFFLER describes the installed manager/bridge.

Add a small status/basis/superseded-by header to active proposals and link each
open deliverable to one owning plan. Keep historical findings, but do not let
historical “nothing implemented” statements or optimistic day counts become
implementation requirements. This review proposes amendments; it does not
silently supersede the decisions in COMPACTION or the other plans.
