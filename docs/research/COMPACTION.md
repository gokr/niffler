# Replaceable compaction — continuity, recall, and bounded context recovery

Status: **shipped** on `main`. This is the design and implementation record;
the operating contract is [MANUAL.md](../MANUAL.md#context-window). It
supersedes the first draft of this file (2026-09); the changes are listed in §10.

The three deliverables landed:

1. **Store default: barrel → SQLite** (§2) — selectable engines retain one
   document-store contract.
2. **Compaction** (§3–§7): a replaceable `compaction` component proposes while
   the runner validates, applies and persists.
3. **Recall** (§5): replaced content keeps a durable link back to the original
   record, and the model is told it can retrieve it.

The runner also classifies provider context overflow and performs one bounded,
receipt-backed recovery attempt; a second overflow is terminal. Tests and the
manual define the shipped behavior where this historical design text is less
specific.

## 1. Decision

Ship a `compaction` peer component with two hidden tools:

- `compaction_propose` — returns a **candidate** (structured checkpoint + cut).
- `context_recall` — returns **original content** that a checkpoint or a prune
  replaced, addressed by its stable reference.

The runner never delegates mutation of its conversation. Other components
implement the same versioned contract under their own globally unique tool
names.

Compaction is primarily continuity and reliability. Its auxiliary summarization
call may reuse a cached prefix; the next compacted conversation request normally
needs a cache rebuild. Neither lower immediate cost nor a cache hit is promised.

This refines [PI_EFFICIENCY_PLAN.md](PI_EFFICIENCY_PLAN.md) A1:

- Do **not** defer mid-turn cuts: one enormous autonomous turn is the first
  regression to fix.
- Replace "current trim behavior as fallback" with deterministic pruning, then
  bounded tool-balanced trimming, then an explicit recoverable error.
- Checkpoints are background history, **not new system instructions**.
- Summarization strategy stays replaceable; validation, persistence and final
  request admission belong to the runner.

## 2. Prerequisite — SQLite becomes the default store ☑ LANDED

**Status: implemented on `main`.** `NIF_STORE_BACKEND` unset now means sqlite;
barrel and tidb remain selectable;
an un-migrated `var/barrel-db` makes core refuse to boot with the migration
command. The `list` cursor shipped for all three engines, and every core
full-kind read moved to `storeListAll`. `niffler-store-migrate` (a separate
offline binary) moves a root between engines — verified against a real 43 MB
production barrel (4309 documents, counts confirmed with sqlite3, harness
booted on the migrated store). The sections below retain the implementation
choices and evidence.

The original store plan set the switch condition: "barrel stays the default
until comparison data says otherwise". Compaction supplied that data. The
projection record is the one artifact whose half-written state would silently
corrupt a conversation's context, and it is exactly where the engines differ:

| | barrel | SQLite |
|---|---|---|
| `put` | two `db.set` calls (doc key, then rev key) — a crash between them updates content without its revision | one atomic statement; doc and rev move together |
| context-window read | `list` only: prefix + limit, no range cursor | same contract today, but `SELECT … ORDER BY id` makes a range/`after` read a one-line addition |
| introspection | `strings` carving | `sqlite3 var/store.db 'select …'`, DuckDB attach |

The second row mattered as much as the first: §4.4's projection reload must read
"messages after a boundary", and the old `list` contract could not express it —
the 1000-item cap silently truncated the oldest tail, which was not latent at
all but a live bug: `loadStoredMessagesEx` resumed a long conversation with the
first 1000 messages only, and because `lastSeqNo` came from the ids it actually
saw, the next write targeted an id that already held history and overwrote it.
That is fixed in this same change (tests/t_resume_long.nim demonstrates both
failures), and the cursor is documented in `docs/WIRE.md` as part of the store
contract.

### 2.1 Surface of the change

One-line core change plus docs and tests:

- `core/niffler.nim:400` — default becomes `sqlite`:
  `case getEnv("NIF_STORE_BACKEND", "sqlite")`, still accepting
  `barrel`/`sqlite`/`tidb` explicitly. Unknown values keep refusing to boot.
- `var/bin/store` (barrel) is still built and still selectable — the engine is
  not deleted, only demoted.
- Docs: `docs/MANUAL.md` store-engine section and its two default tables,
  `AGENTS.md` (store bullet, barrel-db references, the `make down` note about
  `var/barrel-db.lock`), `README.md` milestone line, `docs/research/README.md`
  entry for STORE_V2, and the Makefile comment above `test-store`.
- `make test-store` keeps testing barrel via `NIF_STORE_BIN`; the default test
  path (`test-server`) picks up SQLite automatically because the sandbox core
  resolves the manifest through `NIF_STORE_BACKEND`. `tests/helpers.nim`
  sandboxes must copy `store-sqlite` alongside `store`.

### 2.2 One-shot importer (historical design sketch)

The shipped `niffler-store-migrate` tool performs the offline export/import
between engines. The original one-process `cli store-import` sketch below is
retained for its data-integrity decisions, but is not the command to run:

1. Boot (or attach to) a harness with the **old** engine; `list` every kind in
   pages of 1000 using the id cursor, writing JSONL `{kind, id, value}` records
   to a file. Kinds are discovered from the data, not a hardcoded list.
2. Refuse to import into a non-empty target by default; `--force` overlays.
3. Boot with `NIF_STORE_BACKEND=sqlite` and `put` each record with no
   `expectRev` (fresh target) so revs start at 1 in insertion order. `id`
   ordering is preserved because document ids already sort correctly.
4. Report counts per kind and fail loudly on the first mismatch (a `get` of
   every imported id, counted).

The importer is deliberately dumb — it copies documents, not semantics. It
carries no revs (a fresh store's revs are its own), and it does not translate
`var/toolout` spill files or migration state; those are runtime state, not
documents.

Rollback is `NIF_STORE_BACKEND=barrel` plus the untouched `var/barrel-db`.

### 2.3 Order

Land §2 (default + importer + docs) **before** any compaction code. Compaction
must not be built on an engine whose crash window the design depends on being
closed.

## 3. Evidence — what dsh actually ships

Reviewed the local `../deepseek-harness` source, not only our older notes:

| Source (paths below `packages/`) | Mechanism | LLM? | Borrow |
|---|---|---|---|
| `compaction/compaction-tool-result-pruner/src/index.ts` | tool-result text → head + `[... tool result middle pruned ...]` + tail at whole-result boundaries, tool metadata preserved (defaults: 8192/4096/1024 chars) | no | §5.2 deterministic prune |
| `spill/spill-policy/src/index.ts` | result over `maxInlineBytes` → preview + locator + **retrieval hint**; the notice's cost is reserved *inside* the cap before sizing the preview; storage failure keeps the original; `read` exempt | no | §5.1 execution-time spill |
| `spill/spill-local/src/store.ts` | session-scoped, private (0700), unpredictable leaf names, owner-only writes | no | §5.3 spill privacy |
| `context/session-reference/src/spill.ts` | truncated transcript → bounded preview + full snapshot saved under the **receiving** session; omission notice carries exact `omittedMessages`/`omittedBytes` + locator + hint | no | §5's recall notice shape |
| `compaction/compaction-basic/src/region.ts` | priced tail, cuts rounded to tool-pairing boundaries, snapshot-then-verify-before-replace, hard "summary must be smaller" gate | yes | §4.2 cut rules, §4.5 admission |
| `compaction/compaction-basic/src/summarizer.ts` | structured checkpoint, merge prior checkpoint, reject empty/truncated output; optional prefix-reusing call | yes | §4.6 checkpoint contract |
| `compaction/compaction-basic/src/index.ts` | pressure check between steps; separate bounded overflow recovery, retry only after durable progress | yes | §6 |
| `compaction/compaction/src/tool-pairing.ts` | balance fold over surface order: a cut is legal only where in-progress tool calls = 0 | – | §4.3 boundary validation |

**Limits of that source, verified:** dsh's checkpoint structure is *prompted
Markdown*, not validated fields, so a model can omit a section — we validate
instead. Its overflow retry counters are in-memory `WeakMap`s. Its one-shot
summarizer can itself overflow (there is no bounded chunked consolidation), and
range selection can legitimately decline an indivisible tool pair — both need
explicit behavior here, not an assumption that compaction succeeds. Its spill
locators point at **files**, so a cleaned-up spill directory silently breaks
recall; §5.3 fixes that by pointing at canonical records.

Niffler-side context: [REASONIX.md §8/§9](REASONIX.md) (canonical vs projection;
trimmed history stays reachable),
[CODEWHALE.md](CODEWHALE.md) (reset vocabulary; §D-family notes already name the
"large tool outputs enter context and stay forever" failure class),
[PI_EFFICIENCY_FINDINGS.md §2.1](PI_EFFICIENCY_FINDINGS.md) (iterative update,
file-op tracking), [OCTOFRIEND-STEAL.md §3](OCTOFRIEND-STEAL.md) (same-provider
summarization, "resume where you left off"). [DSH-STEAL.md](DSH-STEAL.md) is
orchestration, not compaction.

## 4. Compaction design

### 4.1 Ownership

**Runner owns:** budgets and admission, the context representation, stable node
identity, valid cut boundaries, validation, projection commit/reload, recall
resolution, bounded recovery, cancellation.

**Component owns:** choosing among valid cuts, summarization prompt/model,
serialization, consolidation of prior checkpoints, bounded internal chunking,
and quality/efficiency tradeoffs. It never writes conversation or projection
records and never executes tools described in the supplied history.

Configuration (harness-level; explicit session overrides persist in the
conversation header):

```json
{
  "compaction": {
    "tool": "compaction_propose",
    "timeoutMs": 60000,
    "maxLlmCalls": 4,
    "maxSummaryTokens": 2048
  }
}
```

Selecting `acme_compact` routes to that tool through the catalog. Selection may
change at a safe step boundary, including mid-conversation, without touching the
frozen tool schemas. Snapshot the selection per attempt; never switch
implementation underneath a call. An empty selection disables summarization, not
the runner's context guard.

Every implementation advertises `x-harness.hidden: true`. The runner-internal
tools below must reach an allowlisted conversation — `core/dispatch.nim:1076-1080`
today exempts a **hardcoded** list (`chat`/`put`/`get`/`list`/`del`), and a
subagent conversation frozen with `tools: [...]` is exactly the long-turn case
that most needs compaction. A hardcoded name list cannot hold for a tool set
that is *configurable* (the whole point of §4.1), so v1 generalizes the
exemption to a schema flag:

```json
"x-harness": {"hidden": true, "runner": true}
```

`runner: true` means "dispatched only by the runner; exempt from per-session
allowlists". `chat` becomes the first user of it (preserving today's behavior),
and every configured compaction/recall tool carries it. This keeps core free of
component-name knowledge — the same rule AGENTS.md applies to every other
extension point — and it makes plugging in a differently-named compactor work
in allowlisted sessions without a core edit.

This is a correctness seam, not a security sandbox: peer processes carry the
repository's existing bus/store privileges. Validation protects against
malformed proposals, not a malicious component.

### 4.2 Context representation (the missing piece)

Today the runner's context is a flat `seq[JsonNode]` built at
`core/conversation.nim:1328`; live appends carry no id. Nodes/generations/
digests are meaningless until that is fixed. Concrete mapping:

- **Node.** One in-memory message entry. Each node carries
  `(source, id, projectionIndex)`:
  - `source = "canonical"` → `id` = the persisted message key
    (`<convId>:<6-digit seq>`, `core/conversation.nim:186`); always resolvable.
  - `source = "checkpoint"` → `id` = `<convId>#ck<generation>`, backed by the
    projection record; resolvable until the projection is superseded.
  - `source = "notice"` → an omission/prune notice; not independently
    resolvable, but it always names the ids it replaced.
- **Canonical boundary.** `canonicalHigh` = the highest canonical seq loaded
  into context, maintained by the persister. Appends continue after it. Nodes
  are contiguous **in canonical seq**, not just in array order.
- **Generation.** An integer in the projection record, bumped on every
  commit (compaction or fallback). Not stored on nodes; snapshots copy it.
- **Digest.** `sha256` over the canonical id list + content hashes of the
  covered range. Recomputed by the runner, compared to the candidate's claim.
  Cheap to verify, and it is what makes "the surface changed under you"
  detectable without keeping a second copy of the content.
- **id-preserving persistence.** `persistMsg` gains the source id alongside
  the seq id so that, after a restart, the rebuilt context knows which messages
  the projection covered and which were appended later. Bodies are not stored
  again (the store already has them).
- **Error-role records.** Still excluded from context but still consuming ids
  (`loadStoredMessagesEx` already continues `seqNo` past them): a covered
  boundary must be expressed in canonical ids, which are unaffected.

### 4.3 Cut rules

A cut is legal only when:

1. it sits at a **tool-pairing balanced** boundary — no unanswered tool call
   crosses it (dsh's balance fold, `compaction/src/tool-pairing.ts`, simplified
   to a counter over the in-memory list plus the pending-call set);
2. the retained tail is non-empty and within budget;
3. the checkpoint itself is not the first thing after the system message without
   a tether (a checkpoint must always keep the *most recent actual user request*
   visible — otherwise a cut can hide the task being worked on).

Cuts are otherwise free: **no minimum user-turn count**. One enormous
autonomous turn must be cuttable, which is the whole point.

### 4.4 Contract v1 — request

Ordinary envelopes; this is the *payload*, not a new wire shape. The input is
written to the store and referenced, never inlined (a compaction request must
never itself blow the bus `max_payload`):

```json
{
  "version": 1,
  "sessionId": "conv-…",
  "attemptId": "a7",
  "trigger": "pressure",
  "snapshot": {
    "ref": {"kind": "compaction_input", "id": "conv-…:a7"},
    "generation": 3,
    "canonicalHigh": 123,
    "digest": "sha256:…"
  },
  "budget": {
    "targetInputTokens": 12000,
    "fixedPrefixTokens": 2000,
    "preferredTailTokens": 3000,
    "maxSummaryTokens": 2048,
    "maxLlmCalls": 4,
    "maxTotalInputTokens": 64000,
    "maxTotalOutputTokens": 8192,
    "timeoutMs": 60000
  }
}
```

`trigger` ∈ `pressure | overflow | manual`. The runner derives the target from
model capacity, output reserve and a safety margin; unknown capacity is
reported as **unknown**, never zero.

Snapshot contents: manifest (`nodes`: `{index, source, id, role, tokens,
canonicalSeq?}`), the previous checkpoint (if any), frozen system prompt, frozen
direct tool schemas, resolved target metadata, permitted cut positions, and
paged content. Pages stay under the connected bus's `max_payload`; each page
carries length + digest and a missing/incomplete page fails the attempt.
Snapshot docs are cleaned up after settlement (grace period for timed-out
readers, orphan sweep at runner startup). They are temporary inputs, never a
second canonical transcript.

### 4.5 Contract v1 — response

```json
{
  "version": 1,
  "status": "candidate",
  "attemptId": "a7",
  "baseGeneration": 3,
  "snapshotDigest": "sha256:…",
  "cutBefore": {"source": "canonical", "id": "conv-…:000090"},
  "covered": {
    "from": {"source": "canonical", "id": "conv-…:000001"},
    "to":   {"source": "canonical", "id": "conv-…:000089"}
  },
  "checkpoint": {
    "objective": "Implement bounded context recovery",
    "constraints": ["Keep canonical history unchanged"],
    "decisions": ["Runner validates before installing a candidate"],
    "completedWork": ["Added the long-turn fixture"],
    "currentBlocker": null,
    "nextSteps": ["Test restart after checkpoint commit"]
  },
  "provenance": {"model": "configured-summary-model", "llmCalls": 1}
}
```

Rules:

- All six checkpoint fields required; lists may be empty; `currentBlocker` may
  be `null`. Bound field lengths, array counts, total encoded size, nesting.
  Reject unknown semantic fields in v1 rather than render them.
- `provenance`/diagnostics never enter model context. Unknown usage is
  `unknown`, never zero. Claimed savings are advisory; the runner re-measures.
- `cutBefore` must be one of the runner's permitted boundaries, and `covered`
  must be exactly the contiguous span newly absorbed. Prefix cuts include a
  prior checkpoint node directly. An autonomous-turn middle cut keeps the
  latest user request outside that span; the snapshot supplies the prior
  normalized checkpoint separately and the new generation supersedes it, so
  checkpoints never stack. A component may not pick a boundary the runner did
  not offer, replace the latest actual user request, edit the system prompt or
  tool schemas, or fabricate tool results.
- `status: "declined"` with a stable reason (`no-useful-cut`,
  `input-budget-exceeded`, `indivisible`) is a first-class answer. Exceptions,
  malformed replies, timeouts and no-responders all enter the same bounded
  fallback path (§6.3).

### 4.6 Default component algorithm

1. Read and verify the snapshot. Choose a permitted cut leaving a priced recent
   tail (~15–20% of the usable input budget, clamped by the budget's
   `preferredTailTokens`). Ordinarily this replaces an old prefix before the
   latest user request. In a single autonomous turn, the runner may instead
   offer a balanced middle span of completed tool groups after that request;
   retained canonical ids then contain the verbatim request prefix plus the
   recent tail.
2. Merge the previous checkpoint with the newly covered span. Preserve exact
   requirements, user corrections, decisions with rationale, file paths,
   verification results and unresolved uncertainty. Never promote a guess into
   completed work. **Track file operations** (`read`/`edit`/`write` targets)
   into a `files` list on the checkpoint — the PI §2.1 steal; it is cheap and it
   is what makes a resumed conversation able to act without re-reading.
3. Try the **prefix-reusing** call: replay frozen system + tools + the covered
   messages, append only the compaction instruction (dsh's cache trick). Only
   when the target model/provider matches the conversation's own — a different
   provider eliminates the prefix benefit and this becomes an expensive
   detour. Reject empty, tool-call, malformed or truncated output.
4. Otherwise serialize the covered span as attributed data for a dedicated
   summarization request, bounded per-message (large tool bodies replaced with
   explicit omission markers + canonical ids — the summarizer is told what was
   omitted, so it can say "content omitted" rather than invent it).
5. If it still exceeds input capacity, consolidate in bounded sequential chunks
   at whole-message/tool-group boundaries: each call takes the previous
   structured checkpoint plus the next chunk. All calls share
   `maxLlmCalls`/`maxTotalInputTokens`/`maxTotalOutputTokens`/`timeoutMs`.
   Exhaustion or an indivisible oversized unit produces a **decline**, never
   recursion.
6. Return one candidate. No self-triggered agent turns, no arbitrary tools, no
   writes to conversation records. Auxiliary calls use a **distinct
   correlation id**, never the conversation's own `sessionId`, so cancelling a
   turn cannot be confused with cancelling compaction, and compaction tokens
   never appear as assistant output.

### 4.7 Auxiliary LLM call — the plumbing that must exist first

The compactor needs to call `chat`. Three facts constrain how, and one of them
rules out the obvious mechanism:

- `llm`'s `chat` is registered `ToolConcurrent` (`components/llm/main.go:909`,
  documented at `sdk/go/component.go:164-174`), so **concurrent assistant calls
  do not serialize behind the live turn's request** — a tool loop's `chat` and
  a compaction `chat` can be in flight together.
- `chat` is *hidden* (`x-harness.hidden`), and hidden tools are unreachable
  through `invoke` (`core/dispatch.nim:174`).
- The nested-call proxy **denies `chat` explicitly**
  (`core/dispatch.nim:872-875`: "chat/session are core wiring"), because
  `handleNestedCall` admits program-dispatched calls and `chat` is runner
  machinery by design.

So a `sessionContext`-leased compactor **cannot** call `chat` through the
proxy, and `x-harness.parallel` does not apply either (it marks tools safe to
run alongside *other tools in one assistant message* — a scheduling hint for
model-issued calls, not a licence for a component to open its own nested
request; passing `parallel: true` to a model with this schema would also let the
model invoke the compactor directly).

**Chosen mechanism:** the compactor calls `svc.llm.call` **directly** from its
own process, using the ordinary `Component.request` path — `chat` is
`ToolConcurrent`, so this is exactly the case that flag exists for, and it needs
no change to `handleNestedCall` and no new core surface. This is a genuine
divergence from the `sessionContext` pattern and is recorded as such: fabric
and agent need the lease because their nested calls must re-enter *runner*
admission (approval, timeouts, workspace resolution); the compactor needs
none of that, because its only nested call is to a concurrent, hidden,
non-approved LLM tool.

The default component now uses the following explicit auxiliary-call fields
(they are part of the `chat` contract, not hidden conventions):

- `cancelId` (string, optional) — subscribe `llm.cancel.<cancelId>` instead of
  `llm.cancel.<sessionId>`; the compactor passes
  `compaction.<sessionId>.<attemptId>` so a user's stop does not kill compaction
  and a compaction cancel does not kill the turn.
- `emitTokens: false` — stream internally, publish no `ev.llm.token` frames.
  (`sessionId: ""` is *not* sufficient: token framing keys off `sessionId`, so
  an empty id would already silence them — but then the frames vanish for the
  wrong reason and `cancelId` has no anchor. An explicit flag plus a distinct
  `sessionId` is what makes both behaviors intentional.)
- `purpose: "compaction"` — telemetry/accounting only; the runner's budget
  check stays authoritative.

The default compactor streams internally so cancellation can interrupt the
provider request, but sets `emitTokens: false`; its request loop relays
`cancel.compaction` to the distinct `llm.cancel.<cancelId>` subject. Ordinary
turns retain the old `cancelId` fallback and publish tokens by default.

`tests/compaction_contract/fixture.nim` is the interchangeability fixture. It
reads only the verified input metadata, returns a deterministic contract-v1
candidate under `fixture_compaction_propose`, and never writes a projection.
The integration test first commits with the default compactor, restarts with
the fixture selected, then compacts the same conversation again. This proves
that implementation identity is not persisted as runner behavior: the new
component reloads and advances the prior projection through the same validator,
renderer, optimistic commit, and canonical-retention rules.

Deadlines are the runner's; the compactor may request a *smaller* one, never a
larger one.

Runner side: compaction dispatches through `dispatchSubjectCall` with an
absolute deadline, and the idle slot keeps pumping `svc.core.call`, the catalog,
the token stream, steer/advise and the nested proxy while it blocks. The
compactor answers no `svc.session.<id>.tool` surface; the proxy stays
runner-internal.

## 5. Recall — replaced content stays retrievable

### 5.1 Two entry points, one reference space

Content leaves the model's context in two ways, and both must be recoverable:

- **At execution time** (spill): a tool result that exceeds the transcript cap
  is replaced *in the transcript* by a bounded head+tail plus a notice naming a
  durable reference. `bash` already spills to `var/toolout/<session>/` and
  points at `read` — v1 promotes that pointer to a **store document**
  (`kind: spill`, id `<convId>:<seq>`), so it survives runner restarts and is
  addressable by `context_recall` rather than only by file path.
- **At compaction time** (prune/checkpoint): covered content is replaced in the
  **projection** by a checkpoint or a prune notice. Canonical records are never
  touched, so the reference always resolves.

Both point at the same reference space, which is why the reference type is
explicit:

```
{"source": "canonical", "id": "conv-…:000090"}   # store kind message
{"source": "checkpoint", "id": "conv-…#ck3"}     # projection generation 3
{"source": "spill", "id": "conv-…:000090"}       # store kind spill (original bytes)
```

### 5.2 Model-free prune (deterministic, no LLM)

Before any summarization, and as the fallback when summarization fails, the
runner itself can prune:

- Applies to **tool results only**. Reasoning is replayed from the transcript
  into requests, and providers do not accept a *modified* reasoning field on
  replay — rewriting it would corrupt the request, so it is out of scope.
- Whole-result boundary: replace the text with head + marker + tail, keeping
  `role`, `tool_call_id`, `name` and all machine fields intact (dsh's pruner
  contract). Defaults adapted to our units (chars, not code points needed):
  threshold 8 KB, head 4 KB, tail 1 KB, exactly dsh's ratios.
- The marker states the omission **and** the recall path, e.g.
  `[tool result middle pruned: 41,203 bytes omitted — recall original with context_recall {ref: {"source":"canonical","id":"conv-…:000090"}}]`.
- Pruning is a **projection edit**, recorded in the projection record as a list
  of `{ref, bytesBefore, bytesAfter}`, and re-applied on load. It never rewrites
  `message` docs. This is what makes it safe: a prune can be "undone" by
  reloading from canonical, and a wrongly-pruned result costs one recall call.

### 5.3 `context_recall` (hidden tool)

```
context_recall {ref, mode?: "full" | "match", query?: string, limit?: number}
```

- `ref` accepts any of the three reference shapes above, or an array of refs.
  Resolves server-side:
  - `canonical` → `store.get message <id>`; result is the original `text`.
  - `spill` → `store.get spill <id>`; result is the original bytes (bounded by
    the same read caps as `read`, with paging).
  - `checkpoint` → the projection record's checkpoint (so the model can re-read
    what was summarized, including the files list).
- `mode: "match"` with `query` returns only matching lines/ranges (a cheap
  grep over the recalled document) — useful for "which of the 400 error lines
  was the timeout one".
- **Failure is never worse than the status quo.** If the reference cannot be
  resolved (store down, projection superseded, spill document missing), the
  tool returns a clear error naming what is unavailable, and the **spill/prune
  path must have kept the original if it was the only copy**. Concretely: the
  runner refuses to prune a tool result whose full body it cannot first persist
  as a `spill` document; if the persistence fails, the prune is abandoned and
  the original stays. That is dsh's "a storage failure keeps the original"
  rule, made stronger by pointing at the store rather than a directory.
- **Disclosure.** One line is added to the runner's frozen system prompt
  *template* (systemprompt component), stating: earlier content may have been
  replaced by checkpoints or prunes; original content is retrievable with
  `context_recall`; call it when exact wording or a large result matters. This
  is not a per-conversation injection — it is part of the same frozen prompt
  every conversation already has, so it costs no cache miss.
- The runtime notice is what makes recall *discoverable* in practice: every
  prune/spill/checkpoint carries its own `ref` in the message the model reads.
  The prompt line only teaches the mechanism.

### 5.4 What must not happen

- Never replace the **most recent actual user request**.
- Never replace reasoning/thinking blocks (see §5.2).
- Never replace a tool result with a notice larger than what it replaced
  (dsh's within-cap invariant; the runner checks `bytesAfter < bytesBefore`).
- Never leave a reference that resolves to nothing while destroying the only
  copy.
- Never let a notice itself be the thing that overflows (a tiny budget must
  abandon the prune, not emit a huge notice).

## 6. Runner: admission, commit, reload, recovery

### 6.1 Admission (every provider request)

Run before **every** provider request, not just at user-turn entry — a single
turn with 40 tool rounds must be compacted mid-turn.

Admission computes the whole candidate request: frozen system + frozen tools +
projection nodes + output reserve (the resolved catalog output cap; a fixed
16K fallback when the catalog says nothing). A proposal is accepted only if:

- version/types/limits valid, attempt id and `snapshotDigest` match, generation
  unchanged;
- covered nodes still present and byte-identical (recomputed digest);
- boundaries tool-pairing balanced **and** no dispatch is in flight across them
  (compaction runs between complete tool batches, never while tools run);
- the rendered checkpoint, framed by one runner-owned versioned template,
  strictly reduces the request and fits `targetInputTokens`;
- the candidate's reported `provenance.llmCalls` does not exceed the granted
  `maxLlmCalls` — the runner cannot observe the component's calls directly,
  so the claim is the enforceable boundary (a candidate claiming more is
  `compact:invalid`); the deadline is honored by the request timeout.

Steering/advice arriving during the attempt is queued, appended **after**
commit/decline, and the budget re-checked before the request goes out.

### 6.2 Commit and reload

One `context_projection` record per conversation, written with `expectRev` on
the previous generation (optimistic concurrency — available in every engine and
now atomic on the default one). Content:

```json
{
  "version": 1, "generation": 4, "canonicalHigh": 187,
  "renderer": "checkpoint-v1",
  "checkpoint": { … structured fields … },
  "covered": {"from": "…:000001", "to": "…:000123"},
  "retained": ["…:000124", "…:000187"],
  "prunes": [{"ref": {"source":"spill","id":"…:000130"}, "bytesBefore": 51234, "bytesAfter": 4096}],
  "measurements": {"promptTokensBefore": 91000, "promptTokensAfter": 22000},
  "provenance": {"tool": "compaction_propose", "model": "…", "llmCalls": 1}
}
```

Commit order: **validate → single acknowledged store put → replace in-memory
context → emit event.** A failed put leaves the old projection installed. A
crash after the put reloads the new projection even if no event was published.

Candidate coverage names **projection nodes**; persisted `covered` endpoints
name **canonical messages**. When an endpoint is a prior checkpoint, the
runner substitutes that checkpoint's persisted canonical endpoint before
rendering and pricing the replacement. This also permits a strictly smaller
checkpoint-only replacement without persisting a dangling superseded `#ckN`
reference. The conformance fixture exercises this with
`NIF_FIXTURE_CHECKPOINT_ONLY=1`, including another restart after generation 2.

Reload (runner startup and after any context rebuild):

1. read the projection record (absent → ordinary resume);
2. validate it (version, renderer, refs resolve, `canonicalHigh` ≤ store's
   highest message id);
3. rebuild the context: system + rendered checkpoint node + pruned nodes +
   retained canonical nodes **in canonical order**;
4. append canonical messages **after `canonicalHigh`** — via the new paged
   read (§6.4), not `list`'s 1000-item window.

A corrupt/unresolvable projection produces an explicit recoverable error
(`context-recovery-required`) naming what is wrong — never a silent fall back
to replaying the covered span into a request that will be rejected.

### 6.3 Fallback ladder (no component required)

In order, all deterministic, all bounded:

1. **Prune** (§5.2) — tool results only, whole-result boundaries, bytes
   preserved in `spill` docs first.
2. **Trim** — drop the oldest complete tool groups from the **projection**
   (keeping the checkpoint, the latest user request, and a valid tail), with an
   explicit "history omitted without summary" notice naming covered ids.
   `reset:trim` attribution stays, distinguished from `reset:compact`.
3. **Error** — if the frozen prefix, the latest request, or the newest
   indivisible tool group alone cannot fit, return `context-recovery-required`
   with cause, known sizes, attempt counts and the available actions (larger
   context model, another compactor, explicit continuation from selected
   history).

**Durability addendum (implemented 2026-09-16, prod finding
conv-b33207f94a47):** the trim cut was originally in-memory only — a runner
restart rebuilt the full pre-trim projection from canonical history while the
meter restored post-trim usage from the last assistant message, so admission
under-reported the real candidate by the trimmed amount and could wave a
doomed request straight to the provider. The trim now records the highest
dropped canonical seqNo in the conversation header (`trimThrough`, written at
the moment of the cut) and the ordinary resume path excludes canonical
messages at or below it. Dropped turns remain in canonical history for
`context_recall`; a later committed compaction supersedes the watermark
entirely (the projection path ignores it).

**Calibration addendum (same finding):** the ladder's trigger measures
candidates with a chars/4 estimate that can lag a denser tokenizer by ~4-5%
of the window (observed: ~22k tokens on a 524K window), which turns the 90%
line into a ~99% line and lets requests the provider refuses leave the door.
Every successful response re-measures an offset (reported `prompt_tokens`
minus the estimate of the same request); admission, warnings and the ladder
price candidates as estimate + offset. Model-scoped, resume-seeded, clamped
to `[0, window]`, never persisted.

### 6.4 Store contract addition — paged read

`list` gains `after` (exclusive id cursor) and `first`/`last` semantic clarity,
returning `{items, nextAfter?, hasMore}`; `limit` stays capped at 1000 per
page, so a long transcript is read in pages. All three engines implement it
(barrel's `keysByPrefix` already takes a cursor, `barrel.nim:813`; SQLite/TiDB
gain `AND id > ?`). This is a `docs/WIRE.md` change and must be documented as
such — the alternative (the current silent 1000-item truncation on resume) is
the bug this section exists to remove.

### 6.5 Overflow recovery

- Classify provider failures in the **adapter**, not by substring: emit a
  stable `context-overflow` code (normalized across OpenAI/Anthropic/Codex
  protocols) alongside the existing retryable/permanent distinction in
  `core/retry.nim`. Today `core/retry.nim` matches phrases, and "400" is in the
  *permanent* list — an overflow is a 400-family failure and currently never
  retries. This classification lands before overflow recovery can work.
- At most **one overflow-recovery attempt per logical request**, independent of
  the transient retry budget. Retry only after a validated, durably installed
  reduction.
- A small **request-scoped receipt** (`kind: contextreceipt`, id
  `<convId>:<requestId>`) is written before spending that attempt, binding
  request id, projection generation, failure class and outcome. A recovery
  interrupted by a crash stays consumed on restart; a *successful* request
  starts a new logical request, which starts a new counter. Terminal failure is
  persisted so an automatic resume cannot retry forever.
- If recovery fails after a durable prune (the common case: prune succeeded,
  summarizer failed), the prune is kept and the retry uses it — dsh's
  "durable progress authorizes retry" rule.

## 7. Observability and cache

Frozen prefix stays byte-stable; ordinary facts stay append-only. Compaction is
an explicit projection reset: emit `reset:compact` (fallback `reset:trim`),
and update the documented reset vocabulary in `docs/MANUAL.md` and `AGENTS.md`
(the two-vs-three miss list). Events carry: trigger, before/after token
estimates, covered range, checkpoint/fallback/prune counts, component+model,
latency, auxiliary usage when known, overflow attempt count, and recall
availability per replaced node. Never publish checkpoint inputs.

Cache honesty: the summarization call may hit the warm prefix; the next
conversation request is a rebuild. `ev.session.status`'s `cacheHitRatio`
measures exactly that, per turn, as it does today.

**Cache relation** (see [../PI-NEXT.md](PI-NEXT.md) §3.4): compaction is the
one place Niffler gets real cache leverage, and step 3 above is the mechanism —
the summarization call replays the conversation's exact prefix and appends only
the instruction, so a second full-context request arrives as a near-total cache
hit (dsh does exactly this, `compaction-basic/src/region.ts:518`). Note this
works for automatic-caching providers too (DeepSeek and every OpenAI-compatible
endpoint), which is why it is worth more than the explicit-breakpoint work in
PI-NEXT §3.1.

An earlier revision of this note also proposed scheduling compaction cuts at
cache-expiry boundaries (`reset:expired`). That was **cut**: a compaction trigger
is context pressure, and Niffler's other prefix resets are likewise forced or
model-requested, so there is no population of deferrable mutations to schedule —
and expiry is only knowable after the fact.

## 8. Tests and acceptance

Deterministic first: a `t_ctxcompact` sandbox test extending the existing
fixture family (`tests/mock_llm.nim` pattern, `newCoreSandbox`):

1. **Long-turn regression (the headline).** One user turn, many tool rounds,
   small fake-provider context window; the fake provider **rejects** requests
   over its window (no live API). Assert: the turn completes, no request ever
   exceeds the window, and the objective+constraints survive into the final
   answer.
2. **Fallback with no component.** Same fixture, no `compaction` registered:
   prune → trim → explicit error; assert the error names the reason and that
   no request was ever sent over the window.
3. **Indivisible overflow.** One user turn whose single tool result cannot fit
   even after prune+trim: assert `context-recovery-required`, exactly one
   recovery attempt, no second provider call with identical context.
4. **Durability.** Crash the runner between projection put and event; restart;
   assert the compacted context (not the oversized original) is what the next
   request carries. Same for crash *before* the put (old context).
5. **Recall.** Prune a large tool result; assert the notice carries a resolving
   ref, `context_recall` returns byte-identical original content, and a
   deliberately broken spill doc yields a clear error with the original still
   present in canonical history.
6. **Second compaction.** Compact, then compact again across the first
   checkpoint; assert the tail's tool pairs stay intact and the previous
   checkpoint is absorbed, not lost.
7. **Interchangeability, enforced by a published conformance fixture.**
   `tests/compaction_contract/` ships a fixture compactor (trivial, deterministic,
   LLM-free) **plus** the assertions as a reusable runner,
   `tests/t_compaction_conformance.nim` (`make test-conformance`, or
   `--bin:PATH --tool:NAME` for a third-party implementation), so an author
   can run their implementation against the same contract without reading
   `core/`: propose → strict validation → checkpoint-v1 commit → canonical
   immutability → snapshot cleanup → restart reload → second generation.
   `t_compaction` runs the fixture under a different tool name, asserts a
   projection stored by the default compactor reloads when the fixture is
   configured, and closes the §8 negative cases `maxLlmCalls` exhaustion
   (the fixture reports an over-budget call count and the runner rejects the
   candidate), steering during compaction (a real steer is folded after
   settlement and stays outside the cut), and the store-put conflict (a
   concurrent projection writer wins; the runner declines without
   overwrite and finishes the turn on the trim rung). This fixture is the
   actual guarantee behind "alternative
   compactors plug in easily" — without it, the contract is prose.
8. **Allowlisted subagent.** A conversation frozen with `tools: [...]` still
   compacts (the §4.1 exemption).
9. **Paged reload.** A conversation longer than 1000 messages resumes without
   truncation (the §6.4 fix), with and without a projection.

Negative cases required: non-shrinking, truncated, malformed and stale-digest
candidates; forged cut boundary; store put conflict; missing projection refs;
prune without spill persistence (must keep original); notices larger than what
they replace; auxiliary call exceeding `maxLlmCalls`; cancellation during
compaction; steering during compaction.

Gate: `make build && make test` (server suite mirrors the engine matrix), plus
a live long-turn smoke test. Measure continuity, recovery success, recall
correctness, latency and cache rebuilds — not just token reduction.

The opt-in `make live-smoke` runs real components against Synthetic
`hf:openai/gpt-oss-120b`. The [2026-09-15 live report](COMPACTION_LIVE_SMOKE.md)
records two compactions in one ten-batch turn, no lossy trim, exact direct
spill recall and continuity after restart. Its artificial 16000-token window
is distinct from the model's native 131072-token limit. The run exposed and
verified a fix for auxiliary tool-schema formatting.

## 9. Delivery order

| # | Step | Why first |
|---|---|---|
| 0 | SQLite default + paged-read contract + importer + docs (§2, §6.4) | compaction's durability and reload depend on both — ☑ LANDED (merged with feat/store-sqlite-default) |
| 1 | Context representation nodes/ids/generation + `persistMsg` ids + reload via pages (§4.2) | everything else addresses nodes — ☑ LANDED (CtxNode ledger 1:1 with the projection, ctxAppend growth path, canonicalHigh, loadStoredMessagesEx nodes + `after` cursor, ctxDigest; t_ctxcompact) |
| 2 | Long-turn regression test + admission + prune + trim + bounded overflow receipt, **no component** (§6.1–6.5, test 1–4) | fixes the stated failure with zero new components — ☑ LANDED (admission before every request; prune → trim → context-recovery-required ladder; stable context-overflow classification in the adapter + receipt-bounded recovery; §8 fixtures 1–3 + end-to-end overflow recovery) |
| 3 | `context_recall` + spill documents + prompt-template disclosure + bash spill pointer promotion (§5) | recall is useful before summarization exists — ☑ LANDED (components/recall; spill docs keyed by the canonical id; prune gate verifies the durable copy; baseprompt disclosure line) |
| 4 | Compaction contract + default component + snapshot/validation (§4.4–4.6) | the replaceable seam — ☑ LANDED (contract-v1 snapshots/pages/digests, strict candidate validator, runner-owned checkpoint renderer, optimistic `context_projection` commit/reload, `x-harness.runner` allowlist seam, shipped `compaction_propose`; restart/second-generation/recall/corrupt-projection fixtures) |
| 5 | Auxiliary `chat` additions: `cancelId`, suppressed token frames, `purpose` (§4.7) | only step 4 needs it — ☑ LANDED (distinct cancellation relay, internal streaming with suppressed token frames, purpose telemetry, end-to-end cancellation fixture) |
| 6 | Interchangeability + crash matrix + docs (WIRE.md, MANUAL.md, AGENTS.md) | prove the seam — ☑ LANDED (LLM-free fixture under a second tool name, projection reload across implementations, reusable conformance runner `make test-conformance`, maxLlmCalls/steering/put-conflict negative cases) |

Steps 0–3 are shippable independently and already improve reliability; step 4
is the summarization upgrade; step 5 is the plumbing that makes the default
component's multi-call path possible.

## 10. Changes from the first draft

- **Store default switched to SQLite**, with an importer and a paged-read
  contract addition (§2, §6.4) — the first draft asserted durability and
  "reload after a high-water mark" without an engine or a contract that could
  deliver either.
- **Recall added** (§5): `context_recall`, store-backed spill documents, the
  prune notice carrying a resolving ref, and the system-prompt disclosure line.
  The first draft's `cutBefore` node names and retained-node lists were also
  grounded in the actual `Persister`/store representation (§4.2), which did not
  exist before.
- **Prune is now first-class** (§5.2, §6.3): deterministic, model-free, applied
  at execution time and at compaction time, never rewriting canonical records.
- **Auxiliary LLM plumbing is explicit** (§4.7): `chat` carries a distinct
  `cancelId`, suppressible token frames and a `purpose` field, so compactor
  calls cannot publish partial output into the live turn or share its cancel
  subject.
- **Overflow classification named as a prerequisite** (§6.5): `core/retry.nim`
  treats `400` as permanent, so overflow recovery cannot work until the adapter
  emits a stable code.
- **dsh's "summarizer itself overflows" and "indivisible pair" cases** get
  explicit bounded behavior (§4.6 step 5, §6.3 step 3) instead of an assumption
  that compaction succeeds.
- **Dropped silently before, now explicit:** Pi/Octo first-class checkpoints
  (`~/.pi`-style "first-class checkpoint message") are realized by the
  projection record rather than a new message role; Octo's "resume exactly where
  you left off" framing becomes the runner-owned renderer template; Pi's file-op
  tracking is a checkpoint field (`files`).
- **Three corrections from review** (2026-09-13): the allowlist exemption is
  generalized to `x-harness.runner` instead of a hardcoded name list (§4.1);
  the compactor reaches `chat` by calling `svc.llm.call` **directly** (it is
  `ToolConcurrent`) rather than through a nested lease, because
  `handleNestedCall` denies `chat` by design (§4.7); and the interchangeability
  test ships a runnable conformance fixture rather than asserting pluggability
  in prose (§8).

## 11. What this plan does *not* reach parity on

Stated plainly so the gap is a decision, not an accident:

- **No ranked history search.** `context_recall` resolves an explicit ref; it
  cannot answer "where did we discuss the retry policy?" dsh ships
  `session-query` + `session-query-sqlite` (FTS5/BM25 over transcripts, with
  status only pages), and REASONIX §9 names the same thing. Our store contract
  is exactly the substrate for it (SQLite + FTS5, or a `kind: message` index),
  but it is a separate deliverable — track it, do not smuggle it in here.
- **No authoritative objective record.** dsh keeps goal/todo/plan services that
  survive compaction *by construction*; our checkpoint is a model-written
  summary of the objective, which can drift across generations. The §4.6 rule
  ("never promote a guess into completed work") bounds the damage but does not
  remove it. A durable goal record is the honest fix; the checkpoint should
  eventually cite it rather than restate it.
- **No manual `/compact`.** Deliberately out of scope (§12) and cheap to add
  later once the projection record exists — the command is a thin client of the
  same commit path.
- **No session tree / branch summarization.** PI_EFFICIENCY_PLAN C1 stays open;
  it reuses this machinery when it lands.

## 12. Out of scope for v1

Retrieval/memory databases, event sourcing, speculative background compaction,
automatic model switching, **rewriting reasoning blocks** (providers do not
accept modified reasoning on replay), tool-result rewriting beyond the prune
contract, manual UI commands (`/compact`), and distributed projection writers
(one runner per session remains the invariant). Future strategies may improve
internals freely; new mutation powers require a new contract version and runner
validation, not opaque component-supplied messages.
