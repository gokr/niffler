# Docs audit — `components/recall/` (Nim, 292 lines: `main.nim`)

Scope: what the component offers, its tool and flags, its configuration, and how
`docs/MANUAL.md` covers it. Read-only audit; every claim carries file:line.
Component version `0.1.0` (`components/recall/main.nim:220`), registered tool
`context_recall` (`main.nim:241`).

Audited revision: `docs/MANUAL.md` @ `a66dbfa` (3072 lines). The audit set's
rule applies — the quoted text is the durable anchor; the line numbers are that
revision's, and the manual was still being edited by the parallel consolidation
pass while this report was written.

## 1. What it offers

`recall` is the resolver for the *replaced-content reference space*: content
leaves a conversation's context in two ways — execution-time spills and
compaction-time prunes/checkpoints — and both must stay retrievable
(`main.nim:1-25`). Every prune and spill notice names a ref; this tool resolves
it:

| ref source | document read | returns |
|---|---|---|
| `canonical` | store kind `message`, id `<convId>:<seq>` (`main.nim:143-161`) | the stored message body (never edited after the fact, so it is the un-pruned original whenever canonical is the full copy) as `{ref, text, bytes, totalLines?}` |
| `spill` | store kind `spill`, same id (`main.nim:162-185`) | the full original capture, byte-identical to what the tool produced |
| `checkpoint` | store kind `context_projection`, id `<convId>` (`main.nim:186-217`) | the normalized checkpoint object plus its `generation` |

Three modes (`main.nim:222-236`, `main.nim:243-287`):

- **`full`** (default) — page a ref's document: `offset`/`limit` lines with a hard
  256 KB byte ceiling that keeps head+tail and says what was cut
  (`main.nim:33-50`; the ceiling helper is `sdk/niffler/procutil.nim:153-165`).
- **`match`** — grep one document's lines for a substring, up to `limit` hits,
  with an explicit "narrow the query" marker when capped (`main.nim:52-66`).
- **`search`** — grep the conversation's *whole canonical history*
  (`storeListAll("message", conv & ":")`, `main.nim:103`), including every
  message a trim or compaction removed from the projection, which no ref points
  at. One bounded one-line hit per match, ids included so the body can be
  fetched as a ref afterwards (`main.nim:86-124`).

The declared failures are all explicit and never worse than the status quo
(`main.nim:19-25`): an unresolvable ref names what is missing (`main.nim:150-152`,
`main.nim:166-171`), an empty/malformed spill document is refused rather than
answered with an empty success (`main.nim:171-177`), a missing projection says
"nothing has been compacted yet" (`main.nim:193-199`), a superseded checkpoint
refuses and says which generation is current (`main.nim:205-210`), and an array
of refs degrades per item instead of hiding the good ones (`main.nim:270-279`).

**Read-only by construction.** The component's only store calls are three
`storeGet`s and one `storeListAll` (`main.nim:103`, `145`, `164`, `195`); there
is no `put`/`del` anywhere in the file. It is not a writer, so it can never be
the thing that loses the last copy of anything — the runner's prune gate
re-verifies the spill document before it prunes (`core/conversation.nim:713-726`)
and keeps the original when the check fails.

**Where the component is live.** `manifest.yaml:61-72`: `autostart: true`,
`required: false`, `restart: on-failure`, binary `var/bin/recall`. Absent,
nothing else changes: notices keep their refs, they just cannot be resolved.

## 2. Tools

One tool, `context_recall` (`main.nim:241`), component `recall` `0.1.0`
(`main.nim:220`).

| Field | Value |
|---|---|
| `x-harness` (verbatim) | `{"onDemand": true, "runner": true, "sessionId": true, "timeoutMs": 15_000, "effect": "read"}` (`main.nim:238-239`) |
| Description (first sentence) | "Retrieve original content that was replaced in this conversation's context (pruned tool results, spilled command output, compaction checkpoints). Every notice naming replaced content carries its ref verbatim — pass it back here unchanged." (`main.nim:237`) |
| Parameters | `ref` (one `{source, id}` object **or** an array of them — declared as `oneOf`, `main.nim:223-224`), `mode` (`full`\|`match`\|`search`, `main.nim:225-226`), `query` (`main.nim:227-228`), `session` (`main.nim:229-230`), `role` (`main.nim:231-232`), `offset` (integer, `minimum: 1`, `main.nim:233-234`), `limit` (integer, `minimum: 1`, `main.nim:235-236`) |
| Required | none declared — a bare call fails at runtime with "context_recall needs ref" (`main.nim:267-268`) |
| Approval / workspace / parallel | none: no `approval`, no `workspace` (there are no path arguments), no `parallel` (so a recall call serializes with the rest of the turn even though its `effect` is `read`) |

**The three flags that decide whether the notices' advice is actionable.**

- **(1)** `onDemand`, never `hidden` (`main.nim:238`). This is deliberate and pinned
   by a regression test: `tests/t_recall.nim:5-10` states that the component
   "shipped with hidden: true and no test at all", and `tests/t_recall.nim:94-99`
   asserts `onDemand` is true and `hidden` is absent, with the detail string
   "the notices tell the model to call it; hidden makes that impossible".
   Reachability follows from that pair:
   * not in a conversation's frozen direct set — `promptTools` skips
     `onDemand` (`core/catalog.nim:329-337`);
   * `discover` lists it as an on-demand hint (`core/catalog.nim:441-446`) and
     returns its full schema when named explicitly, because only `hidden` is
     filtered out (`core/catalog.nim:465-475`);
   * `invoke` accepts it, since only `hidden` targets are refused
     (`core/dispatch.nim:288-291`);
   * the fabric nested-call proxy accepts it too (`core/dispatch.nim:1252-1257`
     refuses hidden tools and the wiring names only), and `dispatchToolCall`
     re-injects `__session` for it (`core/dispatch.nim:1652-1657`), so
     `mode: search` works from inside a fabric program;
   * a model can also call it **directly by name** without any prior
     discovery, because exposure is not a dispatch ACL: the turn loop dispatches
     `it.name` with no check against the frozen direct set
     (`core/conversation.nim:2460`; MANUAL.md:1867-1870 states this).
   So the advice *is* actionable — the model need not have discovered anything
   first. But nothing in the MANUAL says so, and nothing tells the model the
   `invoke` hop is available (MANUAL.md:1864 documents it only as a table row).
- **(2)** `sessionId: true` (`main.nim:238`) — the runner injects
   `__session: {session: <live conversation>}` on both dispatch paths
   (`core/dispatch.nim:1652-1657`; parallel path `core/dispatch.nim:1791-1794`).
   The component uses it only in `search`, and only as a *fallback*: an explicit
   `session` argument wins (`main.nim:257-260`). Direct bus callers (tests, `cli`)
   get `""` and the tool refuses with a message naming the missing argument
   (`main.nim:92-96`; `tests/t_recall.nim:170-174`).
- **(3)** `runner: true` is inert here, and that is the finding. The allowlist
   exemption at dispatch requires `hidden` **and** `runner`
   (`core/dispatch.nim:1522-1548`, in particular `core/dispatch.nim:1544-1546`).
   `context_recall` is not hidden, so it is *not* exempt: in a conversation
   frozen with a `tools` allowlist (`agent_run`/`agent_spawn {tools: [...]}`,
   `components/agent/main.nim:894-895`; frozen into the header at
   `core/conversation.nim:2640-2648` and enforced at
   `core/dispatch.nim:1522-1548`), dispatching `context_recall` is refused with
   "tool 'context_recall' is not in this session's tool allowlist" — even though
   `discover` advertises it to that same model. `invoke {sticky: true}` cannot
   help either: promotion is deliberately deferred under an allowlist
   (`core/conversation.nim:1258-1261`). **Consequence:** in exactly those
   subagent sessions, every prune/spill notice's instruction is unactionable,
   and the MANUAL's claim that runner-flagged machinery such as "recall" reaches
   an allowlisted child (MANUAL.md:1867) is false. Either the component drops a
   flag nothing consults (`runner` without `hidden`), or core's gate extends the
   exemption to a non-hidden tool that declares `runner`; leaving both as they
   are ships a schema flag that promises a seam the harness does not implement.

**How the runner finds the component.** It does not call it. Core only *names*
the tool in prose: the prune notice ends "recall the original with context_recall
{...ref...}" (`core/conversation.nim:734-736`), the spill promotion appends
"retrievable with context_recall {...}" (`core/conversation.nim:1309-1311`), the
rendered checkpoint carries a "Recall ref: {..." line
(`core/compaction.nim:168-170`), and the shipped product prompt teaches the name
and the ref-passing rule (`components/systemprompt/baseprompt.txt:44-48`). The
model then reaches the component through the catalog: tool name → owning
component via `catalog.toolIndex` → `svc.recall.call`. `grep -rn 'recall'
core/` finds no dispatch reference to the component name, so renaming the
*component* is safe while renaming the *tool* breaks every already-issued notice
and the product prompt.

## 3. Configuration

**No environment variable is read.** `grep -n 'getEnv\|NIF_'
components/recall/main.nim` returns nothing, and there is no `NIF_RECALL_*`
anywhere in the tree. Every capability knob is either a compile-time constant or
a per-call argument:

- `recallMaxBytes = 262_144` — hard byte ceiling per `full` page, enforced with
  `capBytes` (head+tail plus a marker naming the omitted byte count) so a paging
  model is told exactly what it lost (`main.nim:28`, `main.nim:33-50`,
  `sdk/niffler/procutil.nim:153-165`).
- `recallDefaultLines = 2000` — `full` mode's default `limit`, described in the
  schema as "read's cap" (`main.nim:29`, `main.nim:235-236`). Unlike `read` it is
  not a maximum: the schema declares `minimum: 1` and no maximum, so the byte
  ceiling is the only real bound.
- `matchDefaultLines = 50` — default `limit` for `match`; the response appends
  "[context_recall: match list capped at N lines — narrow the query]" when it
  stops early (`main.nim:30`, `main.nim:52-66`). `match` has **no byte ceiling** —
  only `full` pages are capped, so one enormous matching line is returned whole
  (`main.nim:52-66` vs. `main.nim:47-50`).
- `searchDefaultMatches = 20` — default `limit` for `search`; each hit is a
  ≤200-byte snippet with `id`, `role`, `seq`, the walk stops at `limit` and
  reports `capped: true`, and the result also carries `scanned` (role-passing
  messages examined) and `count` (`main.nim:31`, `main.nim:69-84`,
  `main.nim:103-124`).
- Per-call arguments: `offset`, `limit`, `mode`, `query`, `role`, `session`
  (`main.nim:243-260`).
- `oneOf` on `ref` is decorative: the only validator in core
  (`validateToolArgs`, used for nested/fabric calls at
  `core/dispatch.nim:1271`) ignores unknown keywords, and model calls are not
  schema-validated at all — the component itself accepts an object or an array
  (`main.nim:266-279`).
- Runner-side knobs that decide *what* there is to recall (read in core, not
  here): `NIF_CTX_RESERVE` (`core/conversation.nim:605-619`), the prune
  thresholds 8192 chars with 4096/1024 kept (`core/conversation.nim:598-600`) —
  these are compile-time constants — and the 0.75 warn / 0.9 trim ratios
  (`core/conversation.nim:595-596`).
- Store kinds read: `message`, `spill`, `context_projection` (`main.nim:145`,
  `main.nim:164`, `main.nim:195`), paged to exhaustion through the SDK
  (`sdk/niffler/sdk.nim:355-390`).

## 4. How the MANUAL covers it today

The component is described in four places and documented in none of them in
detail:

* MANUAL.md:79 — the shipped-components row: "on-demand `context_recall`
  resolver for canonical messages, full spill documents, and the current durable
  checkpoint — plus `mode: search`, a grep over the conversation's whole
  canonical history (trimmed/compacted-away messages included)". Accurate, and
  the only place the tool's name appears next to its exposure.
* MANUAL.md:856-864 ("## Context window") — "Canonical `message` documents are
  immutable and append-only. Prune and compaction change only the provider
  projection; a restarted runner validates and reloads the durable checkpoint
  plus retained canonical tail, while `context_recall` resolves
  canonical/spill/current-checkpoint refs, and its `mode: search` greps the whole
  canonical history — including the span a trim dropped, where no notice names
  individual refs."
* MANUAL.md:876-881 — the durable-trim bullet, ending "Dropped turns remain in
  canonical history for `context_recall`."
* MANUAL.md:1863-1870 — the exposure table plus the `x-harness.runner` sentence,
  which names "(compaction, recall)" as the machinery that reaches an allowlisted
  child.
* MANUAL.md:2895 — the `spill` store row: "an oversized tool result promoted out
  of the context window, addressable with `context_recall {"ref": {"source":
  "spill", "id": "…"}}"`.

**Missing entirely:** the tool's parameters and return shape (there is no tool
table for it, unlike `git`, `lsp`, `processes`, `mcp`, `models`), the four caps,
the fact that `mode: match`/`offset`/`limit` are ignored for a `checkpoint` ref
(which returns a structured object, not text, `main.nim:186-217`), the
superseded-checkpoint refusal, that `search` walks canonical `message` documents
only (never spill bodies or checkpoints), that `search` may name *another*
conversation with no lineage check, that `session` is the only argument the
`sessionId` injection feeds, that `context_recall` is not in the "Internal tools
remain hidden" list (correct) but is also absent from the on-demand inventory at
MANUAL.md:2048-2059, that a resumed runner does **not** recreate the trim's
"history omitted without summary" notice, and how to invoke it
(`invoke {tool: "context_recall", arguments: {ref: {...}}}`, optionally
`sticky: true`).

**Wrong:** the "recall" example at MANUAL.md:1867 (the exemption requires
`hidden`). See the flag analysis above.

**Also note (system prompt, not MANUAL):** the guidance the model actually gets
lives in the product prompt, `components/systemprompt/baseprompt.txt:44-48`:
"Earlier content in this conversation may have been replaced to fit the model
window (pruned tool results, spilled command output, compaction checkpoints): the
original is retrievable with context_recall — pass it the ref quoted in the
notice verbatim — and is worth calling when exact wording or the full body of a
large result matters." The MANUAL's `systemprompt` section (MANUAL.md:2328-2333)
describes `baseprompt.txt`'s provenance but not this sentence, which is the only
place outside the notices where the model learns the tool exists.

### The three notices, and what each one leaves behind

The correctness of this component is inseparable from the text core injects, so
the audit checked what each notice actually promises:

* **Prune notice** — `[tool result middle pruned: N bytes omitted — recall the
  original with context_recall {"ref": {"source": "spill"|"canonical", "id":
  "<convId>:<seq>"}}]` (`core/conversation.nim:727-736`). Names the tool and the
  exact ref; the ref's source is `spill` only when the result was spill-backed
  and the document re-verified, else `canonical` (`core/conversation.nim:713-733`).
  Durable: the rewritten body is persisted, and a resumed runner re-applies the
  identical prune from the projection's `prunes` list
  (`core/conversation.nim:2819-2838`). Actionable in any conversation without a
  frozen allowlist.
* **Spill notice** — `[recall: the full N-byte output is retrievable with
  context_recall {"ref": {"source": "spill", "id": "<convId>:<seq>"}} — this
  transcript holds a capped copy]` (`core/conversation.nim:1309-1311`), appended
  at append time only when the promotion into the `spill` kind succeeded
  (`core/conversation.nim:1287-1314`). Durable, ref-exact, actionable.
* **Trim notice** — `[history omitted without summary: dropped N earlier messages
  (<from> .. <to>) to fit the model window — the originals remain in canonical
  history]` (`core/conversation.nim:801-804`). It names **no tool and no ref**;
  `mode: search` is the only route back, and the model has to remember that the
  tool exists. Worse, it is a *projection-only* node (`nsNotice`,
  `core/conversation.nim:806-809`) and the resume path that honors the durable
  `trimThrough` watermark simply skips the pre-trim canonical messages without
  re-inserting it (`core/conversation.nim:2761-2774`; `nsNotice` is created in
  exactly one place in the file, `core/conversation.nim:806`). After a runner
  restart, nothing in the conversation tells the model that the dropped span
  exists at all.

## 5. DELTA list

## Layout of a running system

- MANUAL: "on-demand `context_recall` resolver for canonical messages, full spill documents, and the current durable checkpoint" | CODE: `components/recall/main.nim:143-217` (three ref sources), `main.nim:238` (`onDemand`) | FIX: none — verified accurate, including "on-demand" and the three sources.
- MANUAL: "on-demand `context_recall` resolver for canonical messages, full spill documents, and the current durable checkpoint" | CODE: `components/recall/main.nim:222-236` (parameters), `main.nim:28-31` (caps), `main.nim:243-287` (modes) | FIX: add a tool table to the Context window section — "`context_recall {ref?, mode?, query?, session?, role?, offset?, limit?}` — `ref` is one `{source, id}` object or an array of them (`source` is `canonical`, `spill` or `checkpoint`); `mode: full` (default) pages the document (`offset`/`limit`, 256 KB per page), `mode: match` greps one document's lines, `mode: search` greps the conversation's whole canonical `message` history and returns up to `limit` one-line hits whose `id` can then be read in full as a `canonical` ref. Defaults: 2000 lines (full), 50 matches (match), 20 hits (search)."

## Progressive tool discovery

- MANUAL: "A hidden tool that also carries `x-harness.runner: true` is exempt from a subagent's frozen tool allowlist" | CODE: `core/dispatch.nim:1544-1546`, `components/recall/main.nim:238` | FIX: update — drop `recall` from the example: "A hidden tool that also carries `x-harness.runner: true` is exempt from a subagent's frozen tool allowlist — how replaceable runner machinery (the compactor, and any replacement summarizer) reaches a child whose toolset was frozen before it existed. The two flags are required together: an on-demand tool that carries `runner` without `hidden` is **not** exempt, and is refused in an allowlisted conversation like any other tool outside its `tools` list."  The parenthetical "(compaction, recall)" in the current sentence is wrong about `recall`, which is `onDemand` and therefore refused by `checkToolAllowlist`.
- MANUAL: "| on demand | `x-harness.onDemand: true` | omitted | hint + schema lookup | `invoke` |" | CODE: `core/dispatch.nim:288-291`, `core/conversation.nim:2460` | FIX: update — "... | `invoke`, or a direct call by name: exposure is not an ACL, so a tool the model was never offered still dispatches if the conversation has no tool allowlist".
- MANUAL: "`invoke` gateway refuses hidden targets, while components can still request" | CODE: `core/dispatch.nim:276-291` (`invokeTool` resolves the bare name but dispatches the raw string; `core/dispatch.nim:1615-1618` then finds no component) | FIX: either dispatch the resolved bare name in `invokeTool` or document that `invoke {tool: "component.tool"}` is rejected — a dotted spelling that `invokeTool` tolerates during lookup ("tolerate \"component.tool\" spellings (the LLM writes them naturally)", `core/dispatch.nim:281-284`) fails afterwards with "no component provides tool 'recall.context_recall'", which is exactly how a model spells the tool a notice just named (code bug, no test covers the dotted path).
- MANUAL: absent (the reachable-through-discovery story for the resolver) | CODE: `core/catalog.nim:441-446`, `core/catalog.nim:465-475`, `core/dispatch.nim:1252-1257` | FIX: add one sentence where the notices are described — "`context_recall` is on demand, not hidden: `discover` lists it, `invoke` accepts it, a fabric program may call it directly, and a model that has never discovered anything can still call it by name because exposure is not a dispatch ACL. In a conversation frozen with a `tools` allowlist it is refused at the gate — which is the one case where a prune or spill notice's instruction cannot be followed."

## Context window

- MANUAL: "`context_recall` resolves canonical/spill/current-checkpoint refs, and its" | CODE: `components/recall/main.nim:186-217` | FIX: add — "A `checkpoint` ref returns the projection's structured checkpoint plus its `generation` (not paged text), ignores `mode`/`offset`/`limit`, and is refused when the ref names a superseded generation (`{"source":"checkpoint","id":"<convId>#ckN"}`): the state has been absorbed into the current checkpoint, which is the one to read."
- MANUAL: "`mode: search` greps the whole canonical history — including the span a trim" | CODE: `components/recall/main.nim:103` | FIX: update — "`mode: search` greps the conversation's whole canonical `message` history — every message, including the span a trim or compaction dropped (spill documents and checkpoints are *not* searched; their refs resolve them)". The current wording ("the whole canonical history") invites the reading that spill bodies are searched too.
- MANUAL: "post-trim usage. Dropped turns remain in canonical history for" | CODE: `core/conversation.nim:2761-2774` (resume skips the dropped span), `core/conversation.nim:806-809` (`nsNotice` is projection-only), `core/conversation.nim:801-804` (the notice names no ref) | FIX: add — "The trim notice itself is a projection-only node: a resumed runner rebuilds the trimmed projection from `trimThrough` and does **not** re-create it, so after a restart nothing tells the model the span exists. `mode: search` is the only way back into trimmed history — the notice never names a ref because a whole-turn drop covers many messages."
- MANUAL: "A lossy trim is **durable**: it records the canonical seqNo it cut" | CODE: `core/conversation.nim:801-804`, `core/conversation.nim:2761-2774` | FIX: either re-insert the omission notice on the `trimThrough` reload path (so the model keeps a durable pointer to what it lost) or say in the MANUAL that a trimmed-and-restarted conversation carries no trace of the dropped span — the advice "the originals remain in canonical history" is only useful while the run that trimmed is still alive (code bug: the notice is the sole carrier of that fact).
- MANUAL: absent (nothing documents the prune/spill notice text or the refs it carries) | CODE: `core/conversation.nim:727-736`, `core/conversation.nim:1309-1311`, `core/conversation.nim:598-600` | FIX: add — "Pruning rewrites a tool result over 8192 characters to its first 4096 plus its last 1024 and appends `[tool result middle pruned: N bytes omitted — recall the original with context_recall {"ref": {"source": "spill"|"canonical", "id": "<convId>:<seq>"}}]`; the source is `spill` exactly when the result was spill-backed and the promoted document re-verified. These three numbers are constants, not configuration."
- MANUAL: absent (the `mode: match` byte behaviour) | CODE: `components/recall/main.nim:52-66` vs. `main.nim:47-50` | FIX: add — "`mode: match` is bounded by `limit` lines only: unlike `full` there is no byte ceiling, so a query that matches one enormous single-line tool result returns that line whole."
- MANUAL: absent (searching another conversation) | CODE: `components/recall/main.nim:257-260` | FIX: either check that `session` is this conversation or one of its descendants before searching (the `agent` component authorizes continuation by durable lineage, `components/agent/main.nim:493-585`) or document it — today `context_recall {mode: "search", session: "<any conversation id>"}` reads that conversation's canonical history with no ownership check, which is a wider read than every other cross-conversation surface in the harness.
- MANUAL: absent (an array of refs) | CODE: `components/recall/main.nim:266-279` | FIX: add — "`ref` accepts an array: each item is resolved independently and a failure becomes `{"ref": …, "error": …}` beside the successes, so one broken ref never hides the others."

## The store

- MANUAL: "an oversized tool result promoted out of the context window, addressable with" | CODE: `core/conversation.nim:1287-1314`, `components/recall/main.nim:162-185` | FIX: add — "Promotion is best-effort at append time: when it succeeds the notice names the `spill` ref; when it fails the message keeps only the temp-file pointer. A missing, empty or malformed spill document is refused loudly (never answered as an empty success), and the prune gate re-verifies the document before pruning, so a broken spill can never cost the last copy."
- MANUAL: "the committed context projection (cut, checkpoint, generation) a runner reuses after compaction" | CODE: `components/recall/main.nim:195-217` | FIX: add — "the resolver reads this record's `checkpoint` and `generation` when a notice names a `checkpoint` ref".

## System prompt (`systemprompt`)

- MANUAL: "1. `components/systemprompt/baseprompt.txt` — the product prompt" | CODE: `components/systemprompt/baseprompt.txt:44-48` | FIX: add — "The product prompt is also where the model is taught the replaced-content recourse: it states that pruned tool results, spilled command output and compaction checkpoints are retrievable with `context_recall` by passing the ref quoted in the notice verbatim. Change that sentence and this component's notices stop being followed."

## Testing

- MANUAL: absent (which test owns the resolver's reachability contract) | CODE: `tests/t_recall.nim:84-99`, `Makefile:447`, `Makefile:515`, `tests/t_ctxcompact.nim:682-731`, `tests/t_compaction.nim:266-273` | FIX: add — "`tests/t_recall.nim` pins the registration flags themselves (`onDemand` set, `hidden` absent, `sessionId` declared) as well as ref resolution, `mode: match`, `mode: search`, the role filter and every refusal path; `tests/t_ctxcompact.nim` and `tests/t_compaction.nim` drive the recall round-trip from a real trim and a real compaction. `make test-recall` runs the first alone; all three are in the `make test-server` wildcard set."

## Self-extension and component lifecycle

- MANUAL: "The long tail is on demand:" | CODE: `components/recall/main.nim:238`, `core/catalog.nim:441-446` | FIX: add `context_recall` to the on-demand inventory's "Search and inspection" bullet — it is the one on-demand tool that notices tell the model to call, and it is the only shipped on-demand tool missing from this list.
- MANUAL: "Internal tools remain hidden: core `session`/`session_prepare`, store" | CODE: `components/recall/main.nim:238` | FIX: none — verified accurate for this component (it is deliberately *not* in the hidden list; that omission is correct, and `tests/t_recall.nim:94-96` is the guard against re-adding it).

Finding count: 20 rows — 10 `doc-edit`, 5 `missing` (a capability absent from the MANUAL), 3 `code-bug?` (`invoke`'s dotted spelling, the trim notice's disappearance on a resume, and the unchecked cross-conversation `session` argument), 2 `verified`. One of the `doc-edit` rows corrects a claim that is simply wrong — MANUAL.md:1867 names `recall` as allowlist-exempt when the exemption requires `hidden` — so it can also be read as a `wrong`.

## 6. Not user-facing, but load-bearing

Two mechanisms are invisible to a user and both are about *reachability* rather
than retrieval: the `onDemand` + `sessionId` flag pair (the notices are prose
that names a tool the model was never offered, so the flags are what make that
prose executable) and the `runner` flag that looks like it makes the tool
allowlist-exempt and does not. A user-visible failure needs the MANUAL to explain
one thing only: when a notice names `context_recall` and the call comes back
"tool 'context_recall' is not in this session's tool allowlist", the conversation
is a subagent scoped with `tools` — the content is still in the store, and a
conversation without that allowlist can read it.
