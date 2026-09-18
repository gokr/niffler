# Worklist slice: Context window

From `worklist.tsv` (12 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A035 (doc-edit, dup:mechanisms.md.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 570 "the status event also carries `cacheHitTokens` and `cacheHitRatio`"
- CODE: no such fields exist; the event carries a nested `cache {prompt, read, hitRate}` (`core/conversation.nim:2103-2106`) and the header keeps `cachePrompt/cacheRead/cacheHitRate` (`:463`)
- FIX: use the real names (also fix `components/hooks/README.md:35`). `[dup]` mechanisms.md.

## A036 (doc-edit, dup:mechanisms.md.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 596-600 "A successful projection emits `reset:compact`; … `reset:prune`; … `reset:trim`. `reset:tools` remains reserved … **These are the only intentional prompt-prefix rebuilds**"
- CODE: four reset reasons confirmed (`core/conversation.nim:777,793,1228,1613`) and non-reset reasons also exist: `warn:threshold` (`:845`), `compact:failed|declined|invalid|stale` (`:1466-1543`), `context-overflow` (`:1978`)
- FIX: append "other `ev.session.context` reasons (`warn:threshold`, `compact:*`, `context-overflow`) report a decision and never rebuild the prefix". `[dup]` mechanisms.md.

## A037 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: absent — `x-harness.runner` (the fifth core-honoured schema extension) is documented nowhere in MANUAL or AGENTS.md
- CODE: `core/dispatch.nim:1455-1473` lets a `hidden` + `runner: true` tool bypass a session's tool allowlist (`components/compaction/main.nim:216`, `components/recall/main.nim:166`)
- FIX: add one sentence to §Progressive discovery: "A tool marked `x-harness.runner: true` **and** `hidden` is exempt from a session's frozen tool allowlist, so a replaced compactor or recall resolver keeps working in an allowlisted (subagent) session without a core edit."

## A039 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 623-627 "`context_recall` resolves canonical/spill/current-checkpoint refs"
- CODE: `components/recall/main.nim:6-15` names exactly `{source: canonical|spill|checkpoint}` and resolves each (`:74-100`, spill via `storeGet("spill", id)`); the runner's notices point at it (`core/conversation.nim:674,1186-1201`)
- FIX: none — this is accurate.

## A040 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 529-536 "The effective window is resolved by hidden `llm_resolve {model?}` before each turn"
- CODE: `core/conversation.nim:917` (`dispatchToolCall("llm_resolve", …, 10_000)`) ✔
- FIX: none.

## A041 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 548-553 "`maxCalls` (total tool dispatches per turn, 1-500 — every dispatch attempt counts, success or error)"
- CODE: `core/conversation.nim:2204` + `inc toolCallsMade` before dispatch at `:2250` ("every dispatch attempt counts") ✔
- FIX: none.

## A155 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line ~570 "the status event also carries `cacheHitTokens` and `cacheHitRatio`"
- CODE: `core/conversation.nim:2103-2106` emits a nested `cache` object `{prompt, read, hitRate}`; the conversation header carries `cacheHitRate` (`core/conversation.nim:463`), read by the UI at `ui/frontend/src/views/Chat.svelte:314-321,347-351`; no `cacheHitTokens`/`cacheHitRatio` exists anywhere (`grep -rn cacheHitTokens core/ components/ ui/` → only `components/hooks/README.md:35`, also wrong)
- FIX: "the status event carries `cache: {prompt, read, hitRate}`; the conversation header keeps the same numbers as `cachePrompt`/`cacheRead`/`cacheHitRate`" — and fix `components/hooks/README.md:35`.

## A156 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line ~596 "A successful projection emits `reason: \"reset:compact\"`; model-free pruning emits `reset:prune`; lossy fallback emits `reset:trim`. `reset:tools` remains reserved ... These are the only intentional prompt-prefix rebuilds"
- CODE: `core/conversation.nim:777,851` (reset:prune), `:793,877` (reset:trim), `:1228` (reset:tools), `:1613` (reset:compact) ✔; additional non-reset reasons exist (`:845` warn:threshold, `:1466-1543` compact:failed/declined/invalid/stale, `:1978` context-overflow)
- FIX: append "other `ev.session.context` reasons (`warn:threshold`, `compact:*`, `context-overflow`) do not rebuild the prefix".

## A157 (delta)
source: `mechanisms.md`

- MANUAL: MANUAL: lines 596-637 (prune → compactor → trim ladder, calibration offset, `trimThrough`) matches `core/conversation.nim:595-600` (NIF_CTX_RESERVE), `:1302-1315,1424` (`compaction_input` snapshot + del-by-runner), `:1579` (`context_projection`), `core/compaction.nim:47-53` ✔ (no delta).

## A161 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: kind table lists `conversation, message, component, plugin, provider, session, slash, agentjob, agentnotice, sessionmeta, fabricprog`
- CODE: CODE writes more kinds today: `profile` (`core/dispatch.nim:394-402`), `mcp` (`components/mcp/types.go:12`, documented at MANUAL 1099 but absent from the table), `approval` (`core/niffler.nim:580`, `core/session.nim:58` — per-conversation "don't ask again" records), `spill` (`core/conversation.nim:1196`), `contextreceipt` (`:296`), `compaction_input` (`:1424`), `context_projection` (`:1579`)
- FIX: FIX: add rows for `profile`, `mcp`, `approval`, `spill`, `contextreceipt`, `compaction_input`, `context_projection` (the last three marked "runner-internal, transient").

## A368 (delta)
source: `components/git.md`

- MANUAL: MANUAL:563 — workspace bullet, "git tools scope at the workspace repo".

## A393 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:566-573` documents `prompt_tokens_details.cached_tokens` for cache hits
- CODE: `main.go:1037-1052`; `anthropic.go:186-200`; `codex.go:325-331`
- FIX: add the lane definitions: openai-chat forwards the provider's usage verbatim; Anthropic synthesizes `prompt_tokens = input + cache_read + cache_creation` but reports only `cache_read_input_tokens` as cached tokens (cache writes are billed at write rates); Codex maps the Responses usage object. The `usage` object exists only when the provider actually reported non-zero tokens (`usageSeen`).

