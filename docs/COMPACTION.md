# Context compaction — lossy projection, lossless store

[English](COMPACTION.md) · [Manual](MANUAL.md) · [Wire](WIRE.md) · [Features](FEATURES.md)

How Niffler makes room in a conversation's context without losing anything.
This is the *reader-facing* explanation: the model, the ladder, and how it
compares with other harnesses. Three neighbours matter, and none of them
duplicates this file:

| Document | What it is |
|---|---|
| [MANUAL.md § Context window](MANUAL.md#context-window) | the **operating contract** — thresholds, events, limits, env knobs, `/compact` |
| [research/COMPACTION.md](research/COMPACTION.md) | the **design record** — ownership, contract v1, admission/commit/reload, acceptance tests, closed gaps |
| This file | the **model** — why canonical and projection are separate, and where that differs from other harnesses |

Canonical-vs-projection first appears in [research/REASONIX.md](research/REASONIX.md)
§8/§9; the shipped implementation is `core/conversation.nim`
(`pruneContext`, `trimTurns`, `checkContext`, `runFallbackLadder`,
`attemptCompaction`), `core/compaction.nim` (validation and commit),
`components/compaction/main.nim` (the default proposer) and
`components/recall/main.nim` (retrieval).

## 1. Why a separate model at all

Two failures drive it, both from [research/COMPACTION.md §1](research/COMPACTION.md):

- a single enormous autonomous turn — one user request, dozens of tool rounds —
  is the first regression to fix, so compaction must be able to act *mid-turn*,
  before every provider request rather than only at turn boundaries;
- large tool outputs enter context and stay forever, so the fix must be able to
  shrink evidence the model has already seen without pretending it never
  happened.

The response is not "summarize the transcript". It is to separate the record
from the view.

## 2. The two layers

| | **Canonical history** | **The projection** |
|---|---|---|
| What it is | store kind `message`, ids `<convId>:<seq>` | the provider-facing message list, plus a `context_projection` record describing how it was reduced |
| Mutation | **none** — append-only and immutable | edited freely by prune/compaction/trim |
| Lifetime | forever | derived; rebuilt from canonical on every resume |
| Who reads it | the runner, `context_recall`, the store | the model (via `llm`) |

That split is what makes compaction non-destructive. Not the absence of
summaries — Niffler *does* summarize (see the middle rung below) — but the fact
that all lossiness happens in a regenerable view, and every replacement in that
view carries a resolving reference back to the bytes it replaced.

Invariants that hold across every rung:

- canonical `message` documents are never rewritten by any context operation;
- a reduction is **re-measured** by the runner, never taken from a claimant;
- a replacement is committed only if it is *smaller* than what it replaces;
- the **most recent actual user request** is never dropped from the projection;
- nothing that destroys the only copy of a body is allowed — a prune whose body
  cannot first be persisted durably is abandoned and the original stays.

## 3. The pressure ladder

Admission runs before **every** provider request, including each tool-loop
round. The rungs, cheapest and least lossy first:

| # | Rung | When | Mutates | Reversible by |
|---|---|---|---|---|
| 0 | **Spill** | append time, at a size cap | the conversation record only — full body promoted to a `spill` document, transcript keeps a bounded head+tail + pointer | resolving the pointer (`read`, `context_recall`) |
| 1 | **Prune** | pressure, and first rung of the fallback ladder | the **projection**: a tool result over 8 KB becomes 4 KB head + marker + 1 KB tail, at a whole-result boundary, keeping `role`, `tool_call_id`, `name` and all machine fields | `context_recall` (the marker carries the ref verbatim) |
| 2 | **Compaction** | pressure, when a compactor is configured and registered | the **projection**: a covered canonical span is replaced by a structured checkpoint; one `context_projection` doc committed with `expectRev` | reading the `checkpoint` ref; `mode: search` for the covered messages |
| 3 | **Trim** | last lossy rung, when compaction declines or is absent | the **projection**: oldest complete turns dropped, an explicit "history omitted without summary" notice put in their place; `trimThrough` recorded durably in the header | `mode: search` over canonical history |
| — | **`context-recovery-required`** | when even the frozen prefix or the newest indivisible tool group cannot fit | nothing | enlarging the window, a different compactor, or continuing from selected history |

Spill is the execution-time cousin of prune and the purest case of the model: a
big result was *never only in context* to begin with.

**Rung 2 is a summary — a deliberate one.** `compaction_propose` returns a
validateable checkpoint (`objective`, `constraints`, `decisions`,
`completedWork`, `currentBlocker`, `nextSteps`, optional `files`) rather than
free-form Markdown, so a section cannot silently be omitted. Summarization is
**optional and replaceable**: `NIF_COMPACTION_TOOL=""` disables it while
keeping prune/trim/error, and any component registering the contract-v1 tool
name can take its place (`make test-conformance` accepts third-party
implementations; the interchangeability and crash matrices are part of
`make test-server`). So "Niffler does not summarize" is right only as a
*configuration*, never as an architectural fact.

Overflow recovery is separate: a provider-reported `context-overflow` gets
exactly **one** receipt-backed attempt (`contextreceipt`, written before it is
spent), and a second overflow is terminal — never an unbounded retry loop. If a
durable prune succeeded and the summarizer failed, the prune is kept and the
retry uses it.

## 4. Recall: one reference space

Content can leave the model's view at two moments (execution-time spill,
compaction-time prune/checkpoint) and both point into **one** reference space,
which is why a ref names its source:

```
{"source": "canonical",  "id": "conv-…:000090"}    # store kind message
{"source": "spill",      "id": "conv-…:000090"}    # the original bytes
{"source": "checkpoint", "id": "conv-…#ck3"}       # projection generation 3
```

`context_recall` resolves any of them, and adds two ways to search:

- `mode: full` — page one document (default);
- `mode: match` — grep one document's lines (cheap: "which of those 400 error
  lines was the timeout one");
- `mode: search` — grep the conversation's **whole canonical history**, trimmed
  and compacted-away messages included, returning bounded one-line hits whose
  id is then a valid `canonical` ref. This answers the question a ref cannot:
  *which messages mentioned X?* It is deliberately two-step — pulling a dropped
  span back wholesale would re-inflate the window just trimmed.

Two rules keep a broken reference from being worse than the status quo:

- the runner refuses to prune a tool result whose full body it cannot first
  persist as a `spill` document; a storage failure **keeps the original**;
- an unresolvable ref fails loudly, naming what is unavailable — it is never
  answered as an empty success.

Discoverability is runtime, not prompt engineering: every prune, spill and trim
notice carries its own ref and tells the model to pass it back verbatim. The
frozen system-prompt template carries one line teaching the mechanism, so it
costs no cache miss.

## 5. Who owns what

The runner owns budgets, admission, node identity, permitted cuts, validation,
commit/reload, recall resolution and bounded recovery. The component owns only
cut choice, the summarization prompt/model, and quality trade-offs — it never
writes conversation or projection records. A candidate's claim that it used
more auxiliary LLM calls than it was granted is rejected as invalid, because
the runner cannot observe those calls directly.

Deliberately out of scope, and why: **reasoning blocks are never rewritten**
(providers reject modified reasoning on replay — rewriting it would corrupt the
request), the latest user request is never replaced, and tool results are not
rewritten beyond the prune contract.

## 6. Compared with other harnesses

The common design — as it appears in the harnesses the research notes actually
review — is **one live history that auto-compaction rewrites in place**:
older messages are replaced by an LLM summary inside the same transcript that
carries the conversation. [PI-VS-NIFFLER.md](research/PI-VS-NIFFLER.md) §6
describes Pi's structured summaries with iterative update, `/compact
[instructions]`, and auto-compaction on overflow *and* proactively;
[OPENHANDS.md](research/OPENHANDS.md) describes a threshold-triggered
condenser with a user-visible "Compact context" action. Once that rewrite
lands, the originals have left the working history, and recovery is "ask the
model what it remembers". [CODEWHALE.md](research/CODEWHALE.md) contributes
the reset vocabulary (`reset:compaction`) and "we trim with the store as the
source of truth".

The closest prior art — and the one Niffler read **in source** — is DeepSeek
Harness ([research/COMPACTION.md §3](research/COMPACTION.md), which tabulates
`compaction-tool-result-pruner`, `spill-policy`, `spill-local`,
`session-reference`, `compaction-basic/region.ts`, `summarizer.ts` and
`tool-pairing.ts`). Niffler borrowed that shape and changed four things:

| | DeepSeek Harness | Niffler |
|---|---|---|
| Checkpoint | prompted Markdown; a model can omit a section | validated structured fields; unknown semantic fields rejected |
| Recall target | **files** — a cleaned-up spill directory silently breaks recall | `canonical` / `spill` / `checkpoint` **store documents** |
| Overflow retry counters | in-memory `WeakMap`s | durable `contextreceipt`, survives restart |
| Failure modes | assumes summarization succeeds | `declined` / `invalid` / `stale` / `indivisible` / summarizer-overflow all explicit on the bus |

Two more differences are structural rather than corrective. First, **the runner
validates and commits; only the component proposes** — so a replaceable
compactor can never mutate a conversation or a projection directly, and
switching implementations mid-conversation cannot change persisted runner
behaviour ([research/COMPACTION.md §4.1](research/COMPACTION.md)). Second,
compaction is an explicit, attributable prompt-prefix reset (`reset:compact`,
`reset:prune`, `reset:trim`) distinct from a model switch, so a cache miss is
always explainable.

Harnesses outside the notes' review are not characterised here from source; the
comparison above stands on the reviewed ones.

## 7. What is still lossy, and still open

Stated plainly so the two-layer model is not mistaken for "nothing is ever
lost":

- **A checkpoint can drift.** It is a model-written summary of the objective,
  and there is no authoritative goal record for it to cite across generations
  ([research/COMPACTION.md §11](research/COMPACTION.md)). The "never promote a
  guess into completed work" rule bounds the damage; it does not remove it.
- **`mode: search` is a substring scan, not ranked retrieval.** The SQLite
  engine's FTS5 index is the natural substrate for BM25 session query, but that
  remains tracked, not shipped.
- **Trim is lossy in the view.** The bytes survive and `mode: search` reaches
  them, but the model sees only the omission notice until it calls recall.
- Also parked: cross-provider prefix reuse for the summarization call (only the
  same model/provider gets the cache benefit), session-tree/branch
  summarization, and speculative background compaction.

## 8. Reading map

- Operating it, knobs and events: [MANUAL.md § Context window](MANUAL.md#context-window),
  [Environment variables](MANUAL.md#environment-variables)
  (`NIF_COMPACTION_TOOL`, `NIF_COMPACTION_TIMEOUT_MS`,
  `NIF_COMPACTION_MAX_LLM_CALLS`, `NIF_COMPACTION_MAX_SUMMARY_TOKENS`,
  `NIF_CTX_RESERVE`).
- Design, contracts, acceptance: [research/COMPACTION.md](research/COMPACTION.md).
- Wire-level shapes: [WIRE.md](WIRE.md) (events, the store contract's paged
  read, `x-harness.runner`).
- Capability index: [FEATURES.md](FEATURES.md) §
  "Context window, pruning, compaction and recall".
- Tests: `make test-compaction`, `make test-conformance`, `make live-smoke`;
  `t_ctxcompact`, `t_context_drains`, `t_recall`, `t_ctx_accounting`,
  `t_compaction_conformance`, `tests/compaction_contract/`.
