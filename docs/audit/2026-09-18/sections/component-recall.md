# Worklist slice: component: recall

From `worklist.tsv` (6 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A633 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: absent (the reachable-through-discovery story for the resolver)
- CODE: `core/catalog.nim:441-446`, `core/catalog.nim:465-475`, `core/dispatch.nim:1252-1257`
- FIX: add one sentence where the notices are described — "`context_recall` is on demand, not hidden: `discover` lists it, `invoke` accepts it, a fabric program may call it directly, and a model that has never discovered anything can still call it by name because exposure is not a dispatch ACL. In a conversation frozen with a `tools` allowlist it is refused at the gate — which is the one case where a prune or spill notice's instruction cannot be followed."

## A638 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: absent (nothing documents the prune/spill notice text or the refs it carries)
- CODE: `core/conversation.nim:727-736`, `core/conversation.nim:1309-1311`, `core/conversation.nim:598-600`
- FIX: add — "Pruning rewrites a tool result over 8192 characters to its first 4096 plus its last 1024 and appends `[tool result middle pruned: N bytes omitted — recall the original with context_recall {"ref": {"source": "spill"|"canonical", "id": "<convId>:<seq>"}}]`; the source is `spill` exactly when the result was spill-backed and the promoted document re-verified. These three numbers are constants, not configuration."

## A639 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: absent (the `mode: match` byte behaviour)
- CODE: `components/recall/main.nim:52-66` vs. `main.nim:47-50`
- FIX: add — "`mode: match` is bounded by `limit` lines only: unlike `full` there is no byte ceiling, so a query that matches one enormous single-line tool result returns that line whole."

## A640 (code-bug?)
source: `components/recall.md`

- MANUAL: MANUAL: absent (searching another conversation)
- CODE: `components/recall/main.nim:257-260`
- FIX: either check that `session` is this conversation or one of its descendants before searching (the `agent` component authorizes continuation by durable lineage, `components/agent/main.nim:493-585`) or document it — today `context_recall {mode: "search", session: "<any conversation id>"}` reads that conversation's canonical history with no ownership check, which is a wider read than every other cross-conversation surface in the harness.

## A641 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: absent (an array of refs)
- CODE: `components/recall/main.nim:266-279`
- FIX: add — "`ref` accepts an array: each item is resolved independently and a failure becomes `{"ref": …, "error": …}` beside the successes, so one broken ref never hides the others."

## A645 (trim)
source: `components/recall.md`

- MANUAL: MANUAL: absent (which test owns the resolver's reachability contract)
- CODE: `tests/t_recall.nim:84-99`, `Makefile:447`, `Makefile:515`, `tests/t_ctxcompact.nim:682-731`, `tests/t_compaction.nim:266-273`
- FIX: add — "`tests/t_recall.nim` pins the registration flags themselves (`onDemand` set, `hidden` absent, `sessionId` declared) as well as ref resolution, `mode: match`, `mode: search`, the role filter and every refusal path; `tests/t_ctxcompact.nim` and `tests/t_compaction.nim` drive the recall round-trip from a real trim and a real compaction. `make test-recall` runs the first alone; all three are in the `make test-server` wildcard set."

