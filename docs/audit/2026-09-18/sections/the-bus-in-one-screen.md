# Worklist slice: The bus in one screen

From `worklist.tsv` (6 rows). `class` is one of
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

## A270 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:412-419 — the bus table's `cancel.<component>` row (bash kills the command group).

