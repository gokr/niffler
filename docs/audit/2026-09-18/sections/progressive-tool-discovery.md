# Worklist slice: Progressive tool discovery

From `worklist.tsv` (27 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A037 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: absent — `x-harness.runner` (the fifth core-honoured schema extension) is documented nowhere in MANUAL or AGENTS.md
- CODE: `core/dispatch.nim:1455-1473` lets a `hidden` + `runner: true` tool bypass a session's tool allowlist (`components/compaction/main.nim:216`, `components/recall/main.nim:166`)
- FIX: add one sentence to §Progressive discovery: "A tool marked `x-harness.runner: true` **and** `hidden` is exempt from a session's frozen tool allowlist, so a replaced compactor or recall resolver keeps working in an allowlisted (subagent) session without a core edit."

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

## A532 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "A binary under `var/bin` is inert until manifest autostart, `core.spawn`, or a plugin install starts it."
- CODE: `main.nim:104-105` (build returns the path), `core/dispatch.nim:308-346` (spawn), `components/plugins/main.nim:256-263` (install spawns)
- FIX: none [verified] — accurate; the only unstated part is that the build→spawn pair is the documented self-extension step (MANUAL.md:894-899).

## A546 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "- Core lifecycle/status/catalog, builder, plugins, and fetch."
- CODE: `main.nim:49` (`build` onDemand), `main.nim:203` (`info` onDemand)
- FIX: none [verified] — both builder tools are on demand, exactly as listed; no builder tool is direct or hidden.

## A617 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "Hidden takes precedence if both flags are present. A hidden tool that also carries `x-harness.runner: true` is exempt from a subagent's frozen tool allowlist"
- CODE: `core/dispatch.nim:1544-1546`, `components/compaction/main.nim:216`
- FIX: none — verified accurate for this component (the exemption requires `hidden` **and** `runner`, checked at dispatch); but see the recall report: the sentence's example list "(compaction, recall)" is wrong about `recall`.

## A618 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "Internal tools remain hidden: core `session`/`session_prepare`, store"
- CODE: `components/compaction/main.nim:216`
- FIX: add `compaction_propose` to that list (and, for symmetry, the recall resolver is *on demand*, not hidden) — "Internal tools remain hidden: core `session`/`session_prepare`, store `del`, LLM `chat`/`llm_resolve`, the compaction `compaction_propose`, the systemprompt prompt, …".

## A630 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "A hidden tool that also carries `x-harness.runner: true` is exempt from a subagent's frozen tool allowlist"
- CODE: `core/dispatch.nim:1544-1546`, `components/recall/main.nim:238`
- FIX: update — drop `recall` from the example: "A hidden tool that also carries `x-harness.runner: true` is exempt from a subagent's frozen tool allowlist — how replaceable runner machinery (the compactor, and any replacement summarizer) reaches a child whose toolset was frozen before it existed. The two flags are required together: an on-demand tool that carries `runner` without `hidden` is **not** exempt, and is refused in an allowlisted conversation like any other tool outside its `tools` list."  The parenthetical "(compaction, recall)" in the current sentence is wrong about `recall`, which is `onDemand` and therefore refused by `checkToolAllowlist`.

## A631 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "| on demand | `x-harness.onDemand: true` | omitted | hint + schema lookup | `invoke` |"
- CODE: `core/dispatch.nim:288-291`, `core/conversation.nim:2460`
- FIX: update — "... | `invoke`, or a direct call by name: exposure is not an ACL, so a tool the model was never offered still dispatches if the conversation has no tool allowlist".

## A632 (code-bug?)
source: `components/recall.md`

- MANUAL: MANUAL: "`invoke` gateway refuses hidden targets, while components can still request"
- CODE: `core/dispatch.nim:276-291` (`invokeTool` resolves the bare name but dispatches the raw string; `core/dispatch.nim:1615-1618` then finds no component)
- FIX: either dispatch the resolved bare name in `invokeTool` or document that `invoke {tool: "component.tool"}` is rejected — a dotted spelling that `invokeTool` tolerates during lookup ("tolerate \"component.tool\" spellings (the LLM writes them naturally)", `core/dispatch.nim:281-284`) fails afterwards with "no component provides tool 'recall.context_recall'", which is exactly how a model spells the tool a notice just named (code bug, no test covers the dotted path).

## A646 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "The long tail is on demand:"
- CODE: `components/recall/main.nim:238`, `core/catalog.nim:441-446`
- FIX: add `context_recall` to the on-demand inventory's "Search and inspection" bullet — it is the one on-demand tool that notices tell the model to call, and it is the only shipped on-demand tool missing from this list.

## A647 (doc-edit)
source: `components/recall.md`

- MANUAL: MANUAL: "Internal tools remain hidden: core `session`/`session_prepare`, store"
- CODE: `components/recall/main.nim:238`
- FIX: none — verified accurate for this component (it is deliberately *not* in the hidden list; that omission is correct, and `tests/t_recall.nim:94-96` is the guard against re-adding it).

## A654 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: "- Routine work: `bash`, `grep`, and the file tools"
- CODE: components/grep/main.nim:52 (no `onDemand`)
- FIX: none — [verified] `grep` is a direct tool, so the bullet is right as written.

## A655 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: "- Search and inspection: `files` (sorted listing), the git"
- CODE: components/grep/main.nim:100 (`onDemand: true`)
- FIX: none — [verified] `files` is discover-only; this bullet is the MANUAL's only statement of that fact.

## A656 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: "- Search and inspection: `files` (sorted listing), the git"
- CODE: components/grep/main.nim:52 (`parallel: true`), :100 (absent)
- FIX: add — [delta] one clause next to `the observe/logfile diagnostics` bullet (or in the new chapter): "`grep` declares `parallel: true`, so a batched `grep` may run alongside other parallel tools; `files` does not, so an `invoke`d `files` serializes against them" (`core/dispatch.nim:1631-1654` is the runner-side gate).

## A696 (doc-edit)
source: `components/logfile.md`

- MANUAL: MANUAL: "- Search and inspection: `files` (sorted listing), the git"
- CODE: components/logfile/main.nim:292,448
- FIX: update — [doc-edit] replace "the observe/logfile diagnostics" in that bullet with "the `observe_*` diagnostics and logfile's `logfile_search`/`logfile_paths`", so the two discoverable logfile tools are nameable from the on-demand inventory rather than only from their own subsection.

## A727 (doc-edit)
source: `components/observe.md`

- MANUAL: MANUAL: "- Search and inspection: `files` (sorted listing), the git"
- CODE: components/observe/main.nim:297,361,376,419,447,472,494,506,515,591,677,714 (all `onDemand`)
- FIX: none — [verified] every `observe_*` tool is on demand, so the generic "the observe/logfile diagnostics" phrasing is right; naming them individually (or linking the tool table) is the optional improvement.

