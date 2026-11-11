# Memory — durable facts, scoped per repo

Status: **v1 shipped** (`components/memory`). Vector recall is v2 and gated on
one store-contract change (§7). `docs/research/BACKLOG.md` carried the line
"`memory` component — durable fact memory with subject keys, under the D3/D4
design constraints" with the note that it stays deferred *while its scope and
retrieval authority are researched*; this document is that research, and the
two open questions are answered in §3 and §4.

## Why this is not "another notes file"

Three things make memory different from a notes document a human keeps:

1. **It is written by the agent, at the worst possible moment** — mid-turn,
   under context pressure, about something it just learned the hard way. So
   the write path must be cheap, and a wasted write must be harmless.
2. **It is read without being asked for.** A model cannot ask for a fact it
   does not know exists. Anything only reachable by a tool call the model has
   to think of is memory the model will not use.
3. **It outlives the conversation that learned it** — that is the whole point,
   and it is also the hazard: a wrong fact written once in March poisons every
   conversation in that repo until someone notices.

Point 2 is what makes the retrieval decision load-bearing, and point 3 is why
the scope decision is load-bearing. Everything else is bookkeeping.

## 1. What already exists (checked — do not rebuild)

| Need | Shipped surface | Note |
|---|---|---|
| durable documents of any shape | `store` `put`/`get`/`list`/`search`/`del` | `memory` is just a new kind |
| monotonic revisions | `put {expectRev}` → `rev-conflict` | free optimistic concurrency; a fact's history is its revision trail |
| text search over stored docs | `search {kind, query, idPrefix, rank, snippet}` | **but** see §7: non-message kinds index `id` only today |
| embeddings | `llm.embed` (`{input[]}` → vectors, `x-harness.hidden + runner`) | concurrent, runner-exempt: safe to call from a handler |
| vector kNN | `search {kind:"embedding", vector, model}` | sqlite-vec, partitioned by `kind`+`model` |
| repo identity across worktrees | `sdk/checkout.nim` `checkoutShape().primaryRoot` | already imported by `git`, `agent`, `lsp` |
| path args resolved to the workspace | `x-harness.workspace {pathFields, defaultPathFields}` | core fills a missing `workspace` arg for us |
| a static line in the frozen prompt | `systemprompt.prompt_hint` | aggregate slots, deterministic order |
| append-only runtime context | `svc.session.<id>.map` → `drainMap`; settlement notices | the precedent for §4's recall block |
| human gate on destructive tools | `x-harness.approval: "always"` | used for update/forget |

What does **not** exist and is deliberately not being built: a background
embedder that indexes every conversation (cost, and see §4 — it is the wrong
answer to the retrieval question), and any cross-machine sync (a `tidb`
deployment gets it for free by sharing the store; that is not a memory feature).

## 2. Scope model

Four scopes, resolved by the **component** from the conversation workspace,
never chosen freely by the model:

| Scope | Key | Written by | Read by |
|---|---|---|---|
| `repo` | `<primaryRoot>` of the checkout | conversations in that repo | every conversation in that repo, **including all its worktrees** |
| `dir` | normalized workspace root | non-git workspaces | conversations in that directory |
| `global` | `"global"` | approval only | any conversation, last (see strictest-wins) |
| `conversation` | the conversation id | that conversation | only that conversation |

Three rules, each with a failure it prevents:

- **The key is the PRIMARY root, not the worktree path.** `/worktree add feat`
  creates `repo.wt/feat` — a different path, the same repository. Keying memory
  on the workspace path would give every worktree an amnesiac clone of the repo
  it was cut from, which is precisely backwards: a worktree is where you go to
  apply what the repo already taught you. `checkoutShape` already draws this
  line for the write fence (§`claimRootsFor`), so memory reuses it rather than
  inventing a second notion of "the same tree".
- **Strictest scope wins on read.** A `repo` fact shadows a `global` fact with
  the same subject key. This is CodeWhale's D3 rule verbatim ("project-local
  config must not silently enable broad external-memory reads"); it is also the
  only ordering that makes `global` safe to write.
- **`global` is read-last, written rarely.** Reading it from inside a repo is
  the human's own machine and their own preference, so it is allowed. Writing
  it from inside a repo conversation requires approval, because "this project
  taught me that `make build` needs `-j1`" is a repo fact that will be wrong
  everywhere else.

Reading *another repo's* memory is refused, not filtered: a scoped read may
name only scopes it resolves to. That is the same ownership rule
`context_recall` already enforces for `scope: "all"`.

## 3. The open question, answered: what is a record?

Reasonix's "Context Engine v2" is the closest prior art and it settled this:
**subject keys with one live fact per subject**, not an append-only pile.

```
memory  <scope>:<subject>   {"subject":"build.jobs", "text":"make build needs -j1 on this box",
                             "tags":["build"], "type":"gotcha", "volatility":"slow",
                             "createdAt":…, "updatedAt":…, "verifiedAt":…, "revision":3}
memory-rev <scope>:<subject>#3   the previous text, retained
```

- A second `remember` of the same subject is an **update**, not a second fact.
  Without this, "we use npm" and "we use pnpm" coexist and the model gets both.
- `storePutRev(expectRev)` gives the concurrency for free: a racing update gets
  `rev-conflict` and re-reads, exactly like `updateConversationHeader`.
- The prior text moves to a `memory-rev` doc rather than being overwritten —
  Reasonix's rule that a "forget" is a *higher* revision, never a delete. An
  audit trail is the only thing that makes a wrong fact debuggable after the
  fact.
- `volatility` (`stable` | `slow` | `fast`) plus `verifiedAt`/`expiresAt` make
  staleness a **ranking multiplier, not a delete**. A hit past its window is
  returned with `stale: true` and its age, so the model re-verifies instead of
  trusting or forgetting.

Absent a subject, a record is keyed by a slug of its text — so a careless
double-write still collapses instead of duplicating.

## 4. The open question, answered: what is the retrieval authority?

The three candidates, judged against the prompt-cache invariant (a
conversation's prefix must stay byte-stable; only history may grow):

| Shape | Prefix cost | Does the model find what it didn't know it needed? | Verdict |
|---|---|---|---|
| Tool-only (`memory_search` the model chooses to call) | **zero** (`onDemand` tools are not in the frozen direct set) | no | necessary, not sufficient |
| Tag/index line in the **system prompt** (Maki) | frozen, so it can never reflect a fact written later | partly | **rejected** — our prefix is frozen *for the conversation's lifetime*, so a Maki-style index would be stale by construction; Maki recomposes, we do not |
| Bounded **append** of recalled facts to history (Reasonix) | zero (append, not prefix) | yes | **the primary mechanism** |

So: a hybrid, with each half on a different, existing seam.

**Teaching (frozen prefix, once).** At spawn the component registers one
`prompt_hint` line: *you have a durable memory for this repo; search it before
assuming, and write a gotcha when you learn one the hard way*. That text never
changes, so it is a legitimate part of the frozen prompt — and registering it
once at spawn means it lands in prompts composed afterwards, per the
systemprompt contract.

**Recall (append-only history, bounded).** Facts are appended as a user-role
message at exactly two automatic moments, plus an explicit tool:

1. **the first turn of a conversation** (`ev.workspace.opened`) — the repo's
   standing knowledge, which is what a human would have told you in the first
   thirty seconds;
2. **after a compaction or trim** (`ev.session.<id>.context` with
   `reason: reset:compact|reset:trim`) — the moment memory matters most, and
   Maki's own framing of it ("save important context to memory before it's
   lost") is the mirror image of this. A `reset:tools` rebuild removed no
   history and is deliberately silent;
3. `memory_recall` on request, for a client or a mid-conversation refresh.

Not every turn. Every-turn recall is a token tax on every conversation, and
the harness whose identity is context thrift (`MAKI-STEAL`, `PI_EFFICIENCY_*`)
does not acquire a fixed per-turn cost for a benefit that is concentrated at
two moments. `memory.autoRecall = "birth" | "compaction" | "both" | "off"` is
the declared setting for anyone who disagrees.

The block is capped (`NIF_MEMORY_RECALL_FACTS`, default 6;
`NIF_MEMORY_RECALL_CHARS`, default 2000) and carries each fact's subject and
scope so a reader can see where it came from — the D3 visibility rule, and the
reason a recalled fact is auditable rather than ambient.

The append rides the **map/notice shape**, which is already shipped for
append-only runtime context: a dedicated subject drained by the runner at turn
start, appended with `ctxAppend`. Anything else — rewriting the prompt,
splicing into the head, a synthetic tool result — is a prefix or history
violation and is not done.

## 5. Write policy (fail-closed)

Reasonix's line, adopted because each clause blocks a specific accident:

| Op | Gate | Why |
|---|---|---|
| `memory_remember` (new subject, no credential-shaped text) | none | a new, harmless, reversible fact must not cost a modal; if every write prompts, the model stops writing and memory is dead |
| `memory_remember` over an existing subject | approval (routed as `memory_update`) | it overwrites what the human may have curated |
| `memory_update` / `memory_forget` | `x-harness.approval: "always"` | destroying the record is not the model's call |
| writing `scope: "global"` | `x-harness.approval: "always"` | the blast radius is every repo |
| a credential-shaped write (`sk-…`, `ghp_…`, `AKIA…`, a private key header) | refused with a specific error | memory is a store document, not a secret store; the refusal names the reason so the model stops trying |

Subagents fail closed: a session whose `sessionmeta.parent` is set may read its
parent's repo scope and may not write — a child's half-finished inference is
the least trustworthy thing in the system. The same rule as git's mutation
surface: reads never prompt, writes do.

## 6. Tools

| Tool | Effect | Approval | Notes |
|---|---|---|---|
| `memory_remember {text, subject?, scope?, tags?, type?, volatility?}` | write | conditional (§5) | the write path; returns the resulting `revision` |
| `memory_search {query, scope?, limit?, ranker?}` | read | none | v1 local text ranking over the scope's records |
| `memory_get {id}` | read | none | one record plus its revision trail |
| `memory_list {scope?, tag?, limit?}` | read | none | for a UI/`/memory` view |
| `memory_forget {id}` | write | always | archives to `memory-rev`, does not destroy |
| `memory_scopes {}` | read | none | which scopes resolve here, how many facts each, where they live — the D3 visibility requirement |

Shipped alongside them: `memory.autoRecall` / `recallFacts` / `recallChars` as a
declared `memory` config domain, and the two lane triggers above. Vector
recall is the one deferred piece (§7).

All are `onDemand`, so they cost nothing in the frozen direct toolset until
`discover`/`invoke` reaches them. Every tool's doc comment carries when-to-use
guidance, because that text is the model's only window into the tool.

## 7. Vector recall (v2) and the one store change it needs

`search {kind:"embedding", vector, model}` partitions vec0 by `kind` and
`model` only. A memory vector therefore cannot be filtered by *scope* inside
kNN, and post-filtering "top 20, keep the ones in my scope" returns a shortfall
— the exact bug `components/store-sqlite/vector.go` warns about in its own
comment ("correct k, not a post-filtered shortfall").

Two honest options, and the recommendation:

1. **Add `id_prefix` as a vec0 PARTITION KEY** (recommended). Memory ids are
   already `<scope>:<subject>`, so a kNN with `AND v.id_prefix = '<scope>:'`
   returns correct k within the scope. This is a small, well-shaped extension
   of the existing design — the same reasoning that made `kind` and `model`
   partition keys.
2. Over-fetch in the component with a documented factor and accept a bounded
   shortfall. Cheap, but it puts a silent-truncation bug in the retrieval path.

A second, measured constraint on any vector recall here: nomic-class models
want **task prefixes** (`search_document:` for stored text, `search_query:` for
the query). Measured against Synthetic's endpoint, the separation between a
matching and an unrelated document is 0.406 cosine with prefixes applied. So
whatever embeds memory records must apply the prefix consistently on both
sides — mixing prefixed and bare vectors in one index quietly degrades
retrieval, which is the failure mode with no error anywhere
(docs/research/LOCAL-EMBEDDINGS.md §3).

v1 therefore ships **text ranking only**, computed in the component over the
scope's records — a few hundred documents, so a local BM25 is exact, needs no
store change, and cannot silently truncate. `memory_search` reports
`ranker: "text"` so a caller always knows which ranker answered; when v2 lands
it reports `"vector"` and the field is already in the contract.

Retrieval is deliberately *not* the conversation's own history: that is
`context_recall`'s job (§COMPACTION.md §5.3) and duplicating it would give two
answers to "what did we say about X".

## 8. Failure modes, and what each one does

| Failure | Behaviour |
|---|---|
| store unreachable | reads return `{ok:true, items:[], warning:…}` — memory must never fail a turn; writes report the error to the model |
| no embedding model configured | v1 is unaffected (text ranking); v2 falls back and says `ranker: "text"` |
| a stale fact | returned with `stale: true` and its age, down-ranked, never hidden |
| a wrong fact | `memory_forget` archives a higher revision; the audit trail shows when it was believed |
| two conversations write one subject | `expectRev` conflict → re-read and retry; the loser's text survives in `memory-rev` |
| a worktree conversation | shares the primary's scope by construction (§2) |
| subagent writing | refused with a reason naming the lineage rule |

## 9. Tests

`tests/t_memory.nim` (private NATS + temp `NIF_ROOT`, like every contract
test):

- scope resolution: a git repo and a **linked worktree of it** resolve to the
  same `repo` key; a plain directory resolves to `dir`; a bogus `scope` is a
  `bad-request`;
- a second `remember` of one subject updates it (revision 2) and the prior
  text is readable in `memory-rev`;
- strictest-wins: a `repo` fact shadows the same-subject `global` fact;
- `forget` leaves the record archived, and `list` no longer returns it;
- credential-shaped text is refused with a specific error;
- a store outage degrades to an empty result plus `warning`, never a failure;
- `memory_scopes` reports the resolved key and counts.

## 10. Cache-effect statement (required of every contributor)

- `prompt_hint` line → **frozen prefix**, registered once at spawn; it does not
  change for the conversation's lifetime, which is what makes it legal.
- recall block → **append-only history** on its own `svc.session.<id>.memory`
  lane (pumped by `pumpMemory`, appended by `drainMemory`), at birth /
  post-compaction / on request; capped in facts and characters. Its own lane
  because the repo-map lane keeps at most one message per conversation, so
  sharing it would let a map starve the block.
- tool schemas → **out of the frozen direct set** (`onDemand`); `discover` is
  the only path until a sticky `invoke` appends one, which is the documented,
  explicit, one-time prefix change.
- nothing volatile (a new fact, a file change, a count) is ever spliced into
  the head.

## 11. Prior art, and what was not borrowed

Borrowed: subject keys with revisions and an audit trail, freshness windows
with down-rank-not-delete, fail-closed writes, strictest-scope inheritance and
the visibility requirement (Reasonix §6, CodeWhale D3); the tag-line teaching
mechanism, reshaped from a prompt index into a frozen hint (Maki §8); "save
before it's lost" as the compaction-time recall trigger (Maki §8).

Not borrowed: Maki's prompt-index (our prefix is frozen — see §4); Reasonix's
full recall-trace inspection UI (a client concern, not the harness's);
CodeWhale's RLM kernel-held context and "cached-main overlay" (D4 — a different
feature: querying *this conversation's* body, which is compaction's territory);
any automatic extraction pipeline that writes facts without a model decision
(the failure mode of every "memory" that becomes a transcript copy).
