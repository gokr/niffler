# Worklist slice: Context window

From `worklist.tsv` (26 rows). `class` is one of
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

## A390 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:242` mentions `/effort`; no `reasoning_effort` value set or lane behavior anywhere (grep `reasoning_effort` in MANUAL = 0 hits)
- CODE: `main.go:437-440`, `:1147-1149`; `anthropic.go:231-234`; `codex.go:208-212`
- FIX: document that `thinking`/`reasoning_effort` accepts `low|medium|high|max` (empty = provider default) and is **only sent when non-empty**, so providers that do not support it never see the field; openai-chat forwards the field verbatim, Codex converts it to `reasoning {effort, summary: "auto"}`, Anthropic to `thinking {type: adaptive, display: summarized}` + `output_config.effort` (plus the interleaved-thinking beta on OAuth). Add that the `session` schema enum lists only `low/medium/high` while the description and core's validation accept `max` (`core/catalog.nim:198`, `core/conversation.nim:2646`) — a real inconsistency.

## A393 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:566-573` documents `prompt_tokens_details.cached_tokens` for cache hits
- CODE: `main.go:1037-1052`; `anthropic.go:186-200`; `codex.go:325-331`
- FIX: add the lane definitions: openai-chat forwards the provider's usage verbatim; Anthropic synthesizes `prompt_tokens = input + cache_read + cache_creation` but reports only `cache_read_input_tokens` as cached tokens (cache writes are billed at write rates); Codex maps the Responses usage object. The `usage` object exists only when the provider actually reported non-zero tokens (`usageSeen`).

## A605 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "tool-result prune → configured compactor → oldest complete-turn trim →"
- CODE: `core/conversation.nim:879-924` (admission prune), `:1983-1986` (pressure rung), `:926-947` (trim), `:2084-2087` (overflow rung)
- FIX: none — verified accurate.

## A606 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "The shipped `compaction_propose` is replaceable: set"
- CODE: `core/compaction.nim:47`, `core/conversation.nim:1447`, `core/conversation.nim:2965`
- FIX: add the selection mechanics — "The value is a **tool name**, not a component name: the runner resolves it in the catalog and dispatches to whichever component registered it, so a replacement can live in any component (`manifest.yaml:79-80`). An empty or unregistered value skips the rung in the automatic ladder and makes `/compact` answer `compacted: false` with `reason: "no compaction component available (NIF_COMPACTION_TOOL=<value>)"`."

## A607 (code-bug?)
source: `components/compaction.md`

- MANUAL: MANUAL: "`NIF_COMPACTION_TOOL=<tool>` to select another contract-v1 implementation,"
- CODE: `components/compaction/main.nim:207-303`
- FIX: add a contract summary a replacement must satisfy — "A contract-v1 candidate tool receives `{version: 1, sessionId, attemptId, trigger, snapshot, budget}` and answers either `{version, status: "declined", attemptId, reason}` with one of the three stable reasons (`no-useful-cut`, `input-budget-exceeded`, `indivisible`) or `{version, status: "candidate", attemptId, baseGeneration, snapshotDigest, cutBefore, covered, checkpoint, provenance:{model, llmCalls}}`, where `checkpoint` carries exactly `objective`, `constraints`, `decisions`, `completedWork`, `currentBlocker`, `nextSteps` and optional `files`. The runner rejects anything else as invalid and falls through to trim; `provenance.llmCalls` above the granted `NIF_COMPACTION_MAX_LLM_CALLS` is invalid too."

## A608 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "temporary paged `compaction_input` snapshot, validates the candidate's"
- CODE: `core/compaction.nim:22`, `core/compaction.nim:29-33`, `core/compaction.nim:296-324`, `core/conversation.nim:1533-1538`
- FIX: add the bounds — "Snapshot pages are 512000 bytes, so one huge message cannot oversize a bus message; the checkpoint is bounded (objective and list items ≤ 4000 characters, ≤ 32 list items, ≤ 64 files, ≤ 65536 bytes encoded) and is rendered by the runner-owned `checkpoint-v1` template — a candidate stored by one compactor reloads identically under another."

## A609 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "generation/digest/cut/schema/size and strict reduction, then commits one"
- CODE: `core/compaction.nim:143-148` (`strictlyReduces`), `core/conversation.nim:1649-1656`
- FIX: add — "Strict reduction is measured by the runner (the rendered checkpoint's *estimated* tokens must be below the covered span's), never taken from the component's claim; the covered nodes are also re-hashed against the snapshot before the projection is committed (`core/conversation.nim:1618-1630`)."

## A610 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "never writes conversation or projection records."
- CODE: `components/compaction/main.nim:66`, `main.nim:82` (the only store calls are two `storeGet`s of `compaction_input`)
- FIX: none — verified accurate.

## A612 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "reserved for an actual sticky tool-schema promotion. These are the only"
- CODE: `core/conversation.nim:1720-1726` (event fields `generation`, `covered`, `beforeTokens`, `afterTokens`), `:1575`, `:1597`, `:1603`, `:1616`, `:1629`, `:1652`
- FIX: add — "The compaction rung also emits non-reset `ev.session.context` reasons: `compact:failed` (dispatch error or timeout), `compact:declined` (with `detail` = the stable reason), `compact:invalid` (schema/bounds/claimed-call-budget/strict-reduction), and `compact:stale` (the covered span changed under the attempt). None of them rebuilds the prompt prefix; the successful event carries `generation`, `covered`, `beforeTokens` and `afterTokens`."

## A627 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "or set it to empty to disable summarization while keeping the deterministic"
- CODE: `core/conversation.nim:1447-1449`, `:1984`, `:2965`
- FIX: none — verified accurate (empty name ⇒ the rung returns false immediately).

## A634 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "`context_recall` resolves canonical/spill/current-checkpoint refs, and its"
- CODE: `components/recall/main.nim:186-217`
- FIX: add — "A `checkpoint` ref returns the projection's structured checkpoint plus its `generation` (not paged text), ignores `mode`/`offset`/`limit`, and is refused when the ref names a superseded generation (`{"source":"checkpoint","id":"<convId>#ckN"}`): the state has been absorbed into the current checkpoint, which is the one to read."

## A635 (trim)
source: `components/recall.md`

- MANUAL: MANUAL: "`mode: search` greps the whole canonical history — including the span a trim"
- CODE: `components/recall/main.nim:103`
- FIX: update — "`mode: search` greps the conversation's whole canonical `message` history — every message, including the span a trim or compaction dropped (spill documents and checkpoints are *not* searched; their refs resolve them)". The current wording ("the whole canonical history") invites the reading that spill bodies are searched too.

## A636 (trim)
source: `components/recall.md`

- MANUAL: MANUAL: "post-trim usage. Dropped turns remain in canonical history for"
- CODE: `core/conversation.nim:2761-2774` (resume skips the dropped span), `core/conversation.nim:806-809` (`nsNotice` is projection-only), `core/conversation.nim:801-804` (the notice names no ref)
- FIX: add — "The trim notice itself is a projection-only node: a resumed runner rebuilds the trimmed projection from `trimThrough` and does **not** re-create it, so after a restart nothing tells the model the span exists. `mode: search` is the only way back into trimmed history — the notice never names a ref because a whole-turn drop covers many messages."

## A637 (code-bug?)
source: `components/recall.md`

- MANUAL: MANUAL: "A lossy trim is **durable**: it records the canonical seqNo it cut"
- CODE: `core/conversation.nim:801-804`, `core/conversation.nim:2761-2774`
- FIX: either re-insert the omission notice on the `trimThrough` reload path (so the model keeps a durable pointer to what it lost) or say in the MANUAL that a trimmed-and-restarted conversation carries no trace of the dropped span — the advice "the originals remain in canonical history" is only useful while the run that trimmed is still alive (code bug: the notice is the sole carrier of that fact).

## A652 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: "at dispatch: bash runs with `cwd` set to the workspace, edit/grep/read"
- CODE: components/grep/main.nim:52-54,100-102; core/dispatch.nim:1476-1489
- FIX: none — [verified] `grep`/`files` declare `workspace {pathFields: ["path"], defaultPathFields: ["path"]}`, so `.`/empty/relative `path` resolves at the conversation workspace exactly as the bullet says; the only nuance is that core's substitution happens for session-driven calls, while a direct `cli call grep grep` resolves against the component cwd (`core/supervisor.nim:160`), which the new chapter can state.

## A676 (code-bug?)
source: `components/hooks.md`

- MANUAL: MANUAL: "ev.session.status      {sessionId, turnId?, provider?, model?, context?, usedTokens?}"
- CODE: components/hooks/README.md:35; core/conversation.nim:2240-2243
- FIX: update the README, not the MANUAL (code bug) — [wrong] `README.md:35` lists `cacheHitTokens`/`cacheHitRatio` under `ev.session.status`; core publishes a nested `cache {prompt, read, hitRate}` object instead. (The MANUAL's own sentence about the cache economy carries the same wrong names — tracked separately as a `## Context window` finding.)

