# Worklist slice: The bus in one screen

From `worklist.tsv` (17 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A029 (doc-edit, dup:mechanisms-obs.md.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 386-421 subject/event block presented as the subject inventory
- CODE: CODE: omits `ev.log.<component>`, `ev.workspace.opened`, `ev.lsp.warm`, `ev.agent.*`, the `ev.fabric.*` family (file:line in `mechanisms-obs.md` "Events")
- FIX: FIX (Z + update): reduce to a 6-line overview — `reg.*`, `svc.*`, `ev.*`, `cancel.*`, `llm.cancel.*` — and link `docs/WIRE.md` for the normative per-subject tables; the complete event table belongs in WIRE, not MANUAL. `[dup]` mechanisms-obs.md.

## A030 (delta)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 398 stray `#` comment markers inside the subject block
- CODE: FIX: cosmetic; drop them when trimming.

## A212 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 491–492 "if the driver does not ack within **a short window**, the request is rebroadcast on `ev.approval.request` with `fallback: true`"
- CODE: the window is `ackTimeoutSecs = 1.5` (`core/approval.nim:48`) and the rebroadcast is skipped entirely when no client is registered — that path logs "has no reachable client — denying", publishes `ev.approval.resolved {ok:false}` and denies (`core/approval.nim:216–227`)
- FIX: replace "a short window" with "1.5 s (`ackTimeoutSecs`)", and add "with no interactive client registered the rebroadcast is skipped and the call is denied immediately."

## A248 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 386–421 subject block
- CODE: the block omits events that are live today — `ev.log.<component>` (structured logs; `sdk/go/component.go:302`, Nim/TS equivalents), `ev.workspace.opened` (`core/conversation.nim:2388`), `ev.lsp.warm` (`components/lsp/main.nim:1049`), `ev.agent.started`/`ev.agent.done`/`ev.agent.notice` (`components/agent/main.nim:1237,958,183`), and the fabric family `ev.fabric.started`/`phase`/`log`/`call.started`/`call.done`/`done` (`components/fabric/fabric.nim:770,354,362,292,368,794`)
- FIX: add those six groups to the block (or to a compact table, see below), noting that `ev.session.*` is emitted dynamically from one helper (`core/conversation.nim:2701–2703`), so the list is the contract, not the code path.

## A249 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 388–395 `ev.session.*` rows
- CODE: all seven exist, emitted from `onEvent("…")` in `core/conversation.nim` (e.g. `context` at `:776,789,841`, `advice` at `:999`), and `ev.session.turn`/`assistant`/`token` are the UI's live-bubble inputs (MANUAL:415–421 streaming paragraph matches `ev.llm.token` → `ev.session.token`)
- FIX: none (verified), but the rows would read better with an emitting-component column (core / llm / agent / fabric).

## A250 (delta)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 189 typo "plus an `nextAfter` id cursor"; MANUAL:398–400 block formatting (a stray `#` in a comment column)
- CODE: FIX: "a `nextAfter` id cursor"; drop the stray comment markers.

## A270 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:412-419 — the bus table's `cancel.<component>` row (bash kills the command group).

## A414 (doc-edit)
source: `components/lsp.md`

- MANUAL: MANUAL: `docs/MANUAL.md:981-987` "runs a bounded extension census (stops at 5 000 files or a 2 s budget) and pre-starts servers for the most prevalent languages"
- CODE: `main.nim:741-744`, `:1049-1054`
- FIX: add "(at most two servers; `node_modules`, `vendor`, `dist`, `build`, `target` and other junk dirs are skipped) and publishes `ev.lsp.warm` with `{workspace, warmed, skipped}` so UIs can show which servers came up."

## A481 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:396 (`ev.session.context …` is the last line of the bus block, MANUAL:389-405)
- CODE: `core/conversation.nim:2839-2846` (`mapSubject`), `:2388` (`ev.workspace.opened` publish), `components/repomap/main.nim:303-306`
- FIX: add two lines to the subject block: `svc.session.<id>.map   repomap → runner: the workspace map to append once` and `ev.workspace.opened {workspace, conversationId} core → components: a conversation's workspace, for pre-warm and the repo-map append`.

## A563 (doc-edit)
source: `components/cli.md`

- MANUAL: MANUAL: "non-interactive, CI-friendly (exit 0 on success);"
- CODE: components/cli/main.nim:146, 236, 239, 242 (exit 2 = usage or bad JSON), :126-138, :151-158 (exit 1 = failure)
- FIX: update to "non-interactive, CI-friendly (exit 0 on success, 1 on failure, 2 on usage errors or bad JSON)" [doc-edit]

## A564 (doc-edit)
source: `components/cli.md`

- MANUAL: MANUAL: "./var/bin/cli catalog                        # components + their tools"
- CODE: components/cli/main.nim:126-138
- FIX: add "`catalog` prints a leading `# harness: <root> @ <gitHash>` line naming which clone's core answered, then one `component: tool, tool` line per component (unordered); it exits 1 when core does not answer or the catalog is empty." [doc-edit]

## A565 (doc-edit)
source: `components/cli.md`

- MANUAL: MANUAL: "./var/bin/cli wait <component> [secs]        # wait for registration"
- CODE: components/cli/main.nim:261-268 (`secs` defaults to 60), :74-95 (each poll is a bounded snapshot read; `0` = one read)
- FIX: update to "`wait <component> [secs]` polls core's accepted catalog (default 60 s; `0` performs a single read)" [doc-edit]

## A566 (doc-edit)
source: `components/cli.md`

- MANUAL: MANUAL: "./var/bin/cli call <tool> '<json args>'      # dispatch, print the result"
- CODE: components/cli/main.nim:140-158 (waits ≤60 s for acceptance, then its own 30 s reply budget), :223, :231-236
- FIX: add "`call` first waits up to 60 s for core to have accepted the tool, then waits `--timeout=<secs>` (default 30 s) for the reply — the cli's own budget, not the tool's `x-harness.timeoutMs`, so extend it for slow tools (`--timeout=600 call build …`)." [doc-edit]

## A567 (code-bug?)
source: `components/cli.md`

- MANUAL: MANUAL: "./var/bin/cli call <tool> '<json args>'      # dispatch, print the result"
- CODE: components/cli/main.nim:220-241 (Nim `parseopt` does not consume the next argument, so `p.val` is empty for `--timeout 5`)
- FIX: code bug — accept the space-separated form (`--timeout 5`) or refuse it with a message pointing at `--timeout=<secs>`; the usage string `cli [--timeout <secs>]` promises the broken one [code-bug?]

## A568 (code-bug?)
source: `components/cli.md`

- MANUAL: MANUAL: "./var/bin/cli wait <component> [secs]        # wait for registration"
- CODE: components/cli/main.nim:263 (`parseInt(positional[2])`, unguarded — the `--timeout` path at :232-236 is guarded)
- FIX: code bug — guard the parse and exit 2 with the usage block, as the option path does [code-bug?]

## A581 (doc-edit)
source: `components/console.md`

- MANUAL: MANUAL: "./var/bin/console    # in a separate terminal while the harness runs"
- CODE: components/console/main.nim:64-100, 101-107 (retry loop; no flags, no filtering, truncation 300/500/2000 chars, colors only on a tty)
- FIX: add "It has no options: everything on the bus, one line per message, args/result/event payloads truncated to 300/500/500 characters (assistant text 2000), colors only on a tty. For a bounded, filterable, persistent view use `observe`/`logfile`." [doc-edit]

## A611 (doc-edit)
source: `components/compaction.md`

- MANUAL: MANUAL: "conversation (compaction passes `emitTokens: false`; the expert judge's call is"
- CODE: `components/compaction/main.nim:286-287` (`"emitTokens": false, "purpose": "compaction"`)
- FIX: none — verified accurate.

