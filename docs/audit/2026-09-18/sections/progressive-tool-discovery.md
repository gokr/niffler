# Worklist slice: Progressive tool discovery

From `worklist.tsv` (13 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A069 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1462-1471 "With the complete shipped manifest, **7 tools are direct**: Core `discover`, `invoke`; `bash`, `grep`, `read`/`edit`/`write`"
- CODE: exactly right — the direct set is every non-hidden, non-onDemand tool: `core/catalog.nim:126,160,175` (`discover`, `invoke`; `profile` is onDemand), `components/bash/main.nim:119` (no onDemand), `components/grep/main.nim:52` (`grep` has no onDemand; `files` does at `:100`), `components/edit/main.nim:1252,1282,1317` (`read`/`edit`/`write`; `undo_last_edit` onDemand at `:1303`)
- FIX: none — but add "(7 with the shipped manifest; a profile can only grow the set, `NIF_PROFILE`/`profile`)" for the case a reader counts more.

## A070 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1404-1407 "Request only the tools needed for the next step, up to 16 at a time"
- CODE: `"maxItems": 16` on `discover.tools` and `catalog.tools` (`core/catalog.nim:105-107,146-148`) ✔
- FIX: none.

## A071 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1343-1350 "An empty query returns the bus directory with tool names only; … descriptions are whitespace-normalized one-line hints capped at 200 characters, and volatile fields such as pid and registration time are excluded"
- CODE: `core/catalog.nim:404` (`if result.len > 200`), `:430-453` (direct/onDemand hint arrays, empty query → names only) ✔
- FIX: none.

## A072 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1412-1416 "`tools` without a `component` searches every live component … names with no discoverable tool are listed in `notFound` (an empty schema set is an error naming the requested tools)"
- CODE: `core/catalog.nim:477-494` (`notFound` array, empty-set error) ✔
- FIX: none.

## A073 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 1395-1399 "Unknown and hidden tool requests have the same error shape so discovery is not a hidden-tool existence oracle"
- CODE: same name-free rule in profiles (`core/catalog.nim:344-348`) and `invoke`; `toolSchema` returns nil for hidden (`:315`) ✔
- FIX: none.

## A074 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1421-1460 (session-snapshot caching, store kind `session` id `<sessionId>:tools`, `{version, direct, discovered, initializedAt, updatedAt}`)
- CODE: `core/conversation.nim:469-513,1167,1228` ✔
- FIX: none.

## A075 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1307-1339 (core tool prose: `profile`, `session_info`, `prompt_preview`, `doctor` incl. deep self-test fan-out and `ask`)
- CODE: `core/catalog.nim:126-183` — all four exist with those semantics (`doctor` at `:113-125`, `prompt_preview` `:136`, `session_info` `:141`, `profile` `:175`) ✔
- FIX: none.

## A076 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1310-1313 "`/components [all|direct|discovered|undiscovered]`, `/discover COMPONENT`, `/profile NAME`"
- CODE: both clients implement them — web UI `ui/frontend/src/lib/slash.ts:73` (`/components` with the all/direct/discovered/undiscovered filter), `ui/frontend/src/lib/slashDispatch.ts:225-240` (`/profile`, `/discover COMPONENT` and `/discover tool=NAME`, the latter sending a content-less `session` call carrying `discovery`); TUI `~/git/niffler-tui/tui/slash.go:172`
- FIX: none.

## A077 (doc-edit, dup:.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 1504 "Deleting a conversation also deletes its exposure document."
- CODE: true for core's `conversation_delete` (`core/dispatch.nim:406-461`), **not** for the shipped web UI, which deletes raw store records (`ui/frontend/src/views/Sessions.svelte:55-67`)
- FIX: apply the `mechanisms-sessions.md` finding (make the SPA call `conversation_delete`, or document the deviation). `[dup]`.

## A170 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line 1106 `observe_request` "... approval-gated and limited to 30 seconds"
- CODE: `components/observe/main.nim:376` `timeoutMs: 35_000`
- FIX: "35 s (`x-harness.timeoutMs`)".

## A203 (code-bug?)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 1504 "Deleting a conversation also deletes its exposure document."
- CODE: `ui/frontend/src/views/Sessions.svelte:55-67` deletes raw store records (`kind: message` per id, `session:<id>:tools`, `conversation`) and never calls core's `conversation_delete` (`core/dispatch.nim:406-461`, which also kills the runner and removes `sessionmeta` + `agentjob`)
- FIX: either make the SPA call `conversation_delete` (preferred: it stops the runner and clears lineage) or document the deviation honestly — as written, a UI-side delete leaves `sessionmeta`/agentjob rows behind and does not stop a live runner.

## A209 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL 465 + 1504 — "Deleting a conversation also deletes its exposure document" holds only for core's `conversation_delete`; the shipped web UI deletes raw store records instead (`Sessions.svelte:55-67`) and leaves `sessionmeta`/agentjob behind.

## A400 (doc-edit)
source: `components/llm.md`

- MANUAL: - MANUAL: `:1482` lists "LLM `chat`/`llm_resolve`" among tools whose registration the catalog projection covers
- CODE: consistent
- FIX: none — recorded as a verified-correct claim (no change).

