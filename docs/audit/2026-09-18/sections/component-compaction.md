# Worklist slice: component: compaction

From `worklist.tsv` (3 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A621 (trim)
source: `components/compaction.md`

- MANUAL: MANUAL: "ev.session.context     {sessionId, turnId?, promptTokens, usedTokens, context, warning?|trimmed?}"
- CODE: `core/conversation.nim:1720-1726`, `:839-841`, `:850-857`
- FIX: update — "`ev.session.context {sessionId, turnId?, promptTokens, usedTokens, context, reason?, warning?|trimmed?, bytesSaved?, pruned?, trimAt?, reserveTokens?, generation?, covered?, beforeTokens?, afterTokens?}` — `reason` is one of `warn:threshold`, `reset:prune`, `reset:trim`, `reset:compact`, `compact:failed|declined|invalid|stale`, `context-overflow`".

## A624 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: absent (a candidate that names a generation/digest the runner no longer holds)
- CODE: `components/compaction/main.nim:229-232`
- FIX: add — "A snapshot whose `attemptId`, `digest` or `generation` does not match the request is refused with a stale-snapshot error rather than summarized; the runner drops the attempt."

## A626 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: absent (nothing in the manual says which test owns this component's behaviour)
- CODE: `tests/t_compaction.nim:123-215`, `tests/t_ctxcompact.nim`, `tests/compaction_live_smoke.nim:105-159`
- FIX: add — a one-line coverage note in the new component section: "Coverage: `tests/t_compaction.nim` (snapshot/validation/commit/restart/second generation), `tests/t_ctxcompact.nim` (ladder, lossy-fallback durability, recall round-trip), `tests/compaction_live_smoke.nim` (real provider)."

