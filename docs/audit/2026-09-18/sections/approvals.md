# Worklist slice: Approvals

From `worklist.tsv` (19 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A031 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 502-505 (per-tool "don't ask again") and 455-467 (the gated-tool list)
- CODE: `mechanisms-obs.md` found ten missing gated tools plus the store-kind/key shape
- FIX: apply that finding; no new delta here.

## A032 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 511-514 "`/limit rounds=N tokens=N seconds=N` — soft budgets for a turn: LLM rounds, cumulative tokens, and wall-clock seconds (**checked before every tool dispatch, not only between rounds**)"
- CODE: only **seconds** is checked before every dispatch (`core/conversation.nim:2190-2196`); rounds and tokens are checked at round boundaries (`:1817`, `:1823`)
- FIX: "…and wall-clock seconds, which is checked before every tool dispatch (one `bash` call can outlast a whole round); rounds and tokens are checked before the next LLM round."

## A033 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 511-519 "a *yes* extends that limit by one more step … A *no*, no answer, or no reachable client ends the turn with a distinct `limit-<dimension>` record that names the limit and the command that raises it. `/limit clear` removes all three."
- CODE: exact — `softRounds += max(limitRounds,1)` per grant (`core/conversation.nim:1757-1759`), `"error": "limit-" & dimension` + "raise it with /limit rounds=<n>" (`:1768-1778`), all-zero `limits` object clears (`:2651,2694`); the ask rides the approval transport as tool `turn-limit` (`:1736-1741`)
- FIX: none — consider naming the pseudo-tool `turn-limit` so an operator can grep the approval log.

## A034 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 538 (in §Context window) `session {… tools?, maxRounds?, maxCalls?, maxTokens?}`
- CODE: accepted (`core/conversation.nim:2427-2457`), but **not declared** in the `session` tool schema (`core/catalog.nim:184-196` lists only sessionId/content/title/model/thinking/cwd/profile) and the allowlist silently stops at 32 names (`:2429`)
- FIX: document the 32-name allowlist cap and file the schema gap as a code fix; a client reading the schema cannot discover these arguments.

## A148 (wrong)
source: `mechanisms.md`

- MANUAL: MANUAL: line ~459 approval list "`bash`, `builder.build`, `core.spawn`, `core.kill`, `core.remove`, `edit`, `write`, `undo_last_edit`, `fabric`, `agent_run`, `agent_spawn`, `expert_follow`, `plugin_install`, `plugin_update`, `plugin_remove`, `skill_install`, `skill_remove`, `provider_add`, `provider_update`, `provider_export`, `provider_import`, `provider_use_environment`, `observe_send`, `observe_request`, `observe_dump`, `observe_monitor`"
- CODE: CODE adds **`process_start`** (`components/processes/main.nim:500`), **`process_kill`** (`:521`), **`lsp_registry`** (`components/lsp/main.nim:1098`), **`mcp_add`/`mcp_edit`/`mcp_remove`** (`components/mcp/main.go:98,123,134`), **`agent_ask`** (`components/agent/main.nim:1416`), plus every mcp-bridge tool of a server configured `approval: always` (`components/mcp-bridge/operations.go:341`)
- FIX: FIX: add those names and "any `mcp_<server>_<tool>` whose server sets `approval: always`"; drop `provider_update`/`provider_use_environment` from the *LLM* list (they are `hidden`, so only reachable as client calls — they still gate).

## A210 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 457–467 "Tools whose schema carries `x-harness.approval: "always"` — **currently** `bash`, `builder.build`, `core.spawn`, … `observe_monitor` — are gated"
- CODE: the list is incomplete as a closed set — also gated: `process_start` (`components/processes/main.nim:500`), `process_kill` (`:521`), `lsp_registry` (`components/lsp/main.nim:1098`), `mcp_add`/`mcp_edit`/ `mcp_remove` (`components/mcp/main.go:98,123,134`), `agent_ask` (`components/agent/main.nim:1416`), `expert_follow` (assigned after registration, `components/expert/main.nim:831–832`)
- FIX: update — the list should read "…`agent_run`, `agent_spawn`, `agent_ask`, `expert_follow`, `fabric`, `process_start`, `process_kill`, `lsp_registry`, `mcp_add`, `mcp_edit`, `mcp_remove`, …" and the sentence should end "— and any plugin tool that sets it, so the list is not closed". `[dup]` (mechanisms.md §X found the tool-name gap independently).

## A213 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 496 "Unanswered UI requests time out after 5 minutes and are denied."
- CODE: 5 minutes is the *tool* approval timeout (`core/approval.nim:55` default `timeoutMs = 300000`, used by `core/niffler.nim:539` and `core/session.nim:44`); the `/limit` keep-going question uses its own 120 s (`core/approval.nim:50–51 continueTimeoutMs = 120_000`)
- FIX: "A tool approval that no client answers times out after 5 minutes (`timeoutMs`, 300 s) and is denied; a `/limit` keep-going question has its own shorter window (120 s). Both log `… timed out after Ns — denying` (`core/approval.nim:243–245`)."

## A214 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (MANUAL:493–495 says only "the call is **denied** with a clear error")
- CODE: the exact strings differ by path — component tools raise `approval denied for tool '<tool>'` (`core/dispatch.nim:1559`), core's own tools return `{"error": "approval denied for <tool>"}` (`core/dispatch.nim:276`), the unreachable-client path logs `core: <tool> needs a human but no interactive client is attached — denying` (`core/approval.nim:203–205`), and a granted/denied verdict logs `core: approval GRANTED|DENIED for <tool>` (`:239–241`)
- FIX: quote the error text the model actually sees, so an operator can grep for it: "the caller sees `approval denied for tool '<name>'` (core tools: `approval denied for <name>`) as a normal tool error — the turn continues, nothing is retried silently."

## A215 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: absent (nothing about program-shaped approvals)
- CODE: any gated args carrying a string `code` get a digest-keyed manifest — digest over source + sorted `tools` + `maxCalls` (`core/approval.nim:69–96`), the full source written 0600 to `$NIF_ROOT/var/approval-sources/<digest>.nim` (`:99–121`), and the tty/UI prompt shows digest, selected tools, `maxCalls`/`timeoutMs` and the source path (`:139–160`)
- FIX: add a short paragraph to §Approvals: "A program-shaped call (`fabric`, `agent_run`/`agent_spawn` with `code`) is approved by *content*, not by tool name: core hashes source + selected tools + `maxCalls` into a digest, writes the full source to `var/approval-sources/<digest>.nim` (mode 0600) and shows that path in the prompt, so the approver reads everything rather than a truncated excerpt. `tests/t_approval_manifest.nim` covers it."

## A216 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 502–505 "the per-tool 'don't ask again' record is still available for narrower trust"
- CODE: it is store kind `approval`, id `<sessionId>:<key>` (`core/niffler.nim:580`, `core/session.nim:58`) — **written by clients, not core** (e.g. `niffler-tui/tui/approvals.go:151`) — and for program-shaped calls the key is `tool:<digest>`, deliberately never the tool name alone (`core/approval.nim:126–133`)
- FIX: name the record and its key: "A client's 'auto approve' action writes a durable record (store kind `approval`, id `<sessionId>:<tool>`); for program-shaped calls the key is `<tool>:<digest>`, so a blanket 'always approve fabric' never covers newly written source. The gate never flashes a dialog when such a record matches."

## A217 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 516 "`NIF_AUTO_CONTINUE=1` answers every keep-going question with yes"
- CODE: `askContinue` returns true when `NIF_AUTO_APPROVE == "1"` **or** `NIF_AUTO_CONTINUE == "1"` (`core/approval.nim:263`)
- FIX: "`NIF_AUTO_CONTINUE=1` answers every keep-going question with yes; `NIF_AUTO_APPROVE=1` implies it." `[dup]`

## A218 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 499–501 quotes the auto-grant log line as `core: approval auto-granted for <tool>`
- CODE: the emitted text is `core: approval auto-granted for <tool> (this conversation is in approval mode: auto)` (`core/approval.nim:277–280`), and the mode itself is persisted in the conversation header field `approvals` (`core/conversation.nim:2421,2658,2792`)
- FIX: fix the quote and add "(persisted in the conversation header as `approvals`, so a resumed conversation keeps it — hence the same `auto` grant happens in a session runner, not only in the terminal harness)".

## A472 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:857-859 names only `NIF_OAUTH_CALLBACK_HOST`; the environment-fallback nickname/defaults are missing.
- CODE: `environmentProvider()` returns nickname `"default"` (main.go:127-136), base URL default `https://api.openai.com/v1` (main.go:120-121), model default `deepseek-chat` (main.go:123-125); switch-to-environment announces nickname `"default"` (main.go:1012).
- FIX: extend 857 → "The fallback backend presents itself as nickname `default` (`source: environment`) with `NIF_OPENAI_BASE_URL` default `https://api.openai.com/v1` and `NIF_OPENAI_MODEL` default `deepseek-chat`; `provider_use_environment` clears the marker, it does not delete stored providers."

## A474 (doc-edit)
source: `components/provider.md`

- MANUAL: MANUAL:881 calls `provider:active` "a plain store doc — remove or overwrite it"; shape and self-healing are unstated.
- CODE: `{nickname, updatedAt}` (main.go:203-206), written with `expectRev` 0 (main.go:990); an empty/dangling marker is auto-deleted when read (main.go:964-967).
- FIX: append "{nickname, updatedAt}; a dangling or empty marker is cleaned up automatically on the next read, so `provider_remove`/`provider_use_environment` need no manual repair."

## A541 (doc-edit)
source: `components/builder.md`

- MANUAL: MANUAL: "Tools whose schema carries `x-harness.approval: "always"` — currently `bash`, `build` (the `builder` component), core's `spawn`, `kill` and `remove`, …"
- CODE: `main.nim:49` (gate), `core/dispatch.nim:1636-1640` (enforcement), `components/plugins/main.nim:256` (a peer component calls `svc.builder.call` directly — no gate, no `timeoutMs`), `components/plugins/main.nim:628` (`plugin_install` carries its own)
- FIX: update [doc-edit] — add a sentence after the list: "The gate is enforced by core's dispatcher, so it covers LLM/session calls; a component that calls `svc.builder.call` directly (the `plugins` install path) is not gated — that caller carries its own approval."

## A571 (doc-edit)
source: `components/cli.md`

- MANUAL: MANUAL: "Tools whose schema carries `x-harness.approval: "always"` — currently `bash`, `build` (the `builder` component), core's `spawn`, `kill` and `remove`,"
- CODE: core/dispatch.nim:1630-1633 (the only gate), components/cli/main.nim:112-114 (the cli never enters core's dispatch)
- FIX: add "The gate sits in core's dispatch, so it protects core-mediated callers only (the model, and anything reached through `svc.core.call`). A bus client — `./var/bin/cli call bash …`, `dialog`, a test calling `svc.<component>.call` directly — runs an `approval: "always"` tool unasked; treat such a component as the trust level of the shell that started the harness." [missing]

## A619 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "automatic pressure ladder: core asks the configured compaction component for"
- CODE: `core/conversation.nim:2957-2986`
- FIX: none — verified accurate (no LLM turn, no user message, a decline never degrades to the lossy rung).

## A620 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "before/after token counts, or `compacted: false` with the reason (no"
- CODE: `core/conversation.nim:2965-2969`, `core/conversation.nim:2983-2986`
- FIX: update — "The reply reports `compacted: true` with `beforeTokens`, `afterTokens` and `generation`, or `compacted: false` with exactly two possible reasons: `no compaction component available (NIF_COMPACTION_TOOL=<value>)` (empty or unregistered) or `nothing to compact: the compactor declined or no permitted cut exists yet` — the second also covers a failed, invalid or stale candidate attempt."

## A657 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: absent (no grep tool in the approval list)
- CODE: components/grep/main.nim:52-54,100-102
- FIX: none — [verified] neither schema carries `x-harness.approval` and both tools are read-only, so the approvals chapter's list is correct to omit them; the shipped row should keep saying "approval-free" if it is ever expanded.

