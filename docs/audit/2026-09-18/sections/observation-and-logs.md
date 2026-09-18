# Worklist slice: Observation and logs

From `worklist.tsv` (7 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A012 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: absent — no row for `components/nats` (the bus binary core spawns) or `components/ctxtest`
- CODE: `components/nats/main.go`, `components/ctxtest/main.nim:1-6`
- FIX: one short paragraph "not a bus citizen: `components/nats` builds `var/bin/nats-server`, the bus core spawns when no URL answers; `ctxtest` is a test-only fixture the nested-call test compiles itself".

## A119 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: **Two source trees that are not bus citizens**: `components/nats` (the `var/bin/nats-server` core spawns) and `components/ctxtest` (test fixture).

## A236 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1746–1757 "Boundary … Observe the bus, not component internals"
- CODE: correct, but the section never states the negative half — none of `observe`, `logfile`, `console` is a durable record of *decisions*: observe keeps a bounded in-memory ring (`components/observe/main.nim:16–20`), logfile is explicitly best-effort (MANUAL:1808 says so), console renders and forgets (`components/console/main.nim:75–105`), hooks keep nothing
- FIX: add a "Not an audit trail" list to §Boundary: "None of these is an audit log: observe is a bounded in-memory ring that dies with the component, logfile is best-effort (at-most-once, `ev.log.>` by default), console prints and forgets, and hooks record nothing. The only durable artefacts of the approval gate are the client-written grant record (store kind `approval`) and the program source core writes to `var/approval-sources/<digest>.nim` — no request/verdict history exists."

## A238 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1785 table row "`observe_monitor` | Read nats-server connection/subscription counts and most-subscribed patterns"
- CODE: the tool carries `approval: always` (`components/observe/main.nim:714`) like `observe_send`/`observe_request`/`observe_dump` — MANUAL says this two paragraphs later (1791–1794) but the table column reads as a plain read
- FIX: add "(approval-gated — it borrows the operator's monitoring endpoint)" to the row, or move the gate marker into the table for all four.

## A239 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1791–1794 "A client talking directly to `svc.observe.call` is already a trusted bus peer and bypasses core policy"
- CODE: matches the design (the gate lives in `core/dispatch.nim:1556–1559`, not in the component)
- FIX: none — but consider one clause: "the component itself enforces only its own input/subject validation (`components/observe/main.nim:366–372,392`)."

## A240 (verified)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1946–1952 "`NIF_OBSERVE_MONITOR_URL` explicitly … `observe_monitor` reads `/subsz` and `/connz` with a fresh HTTP client for each request"
- CODE: `components/observe/main.nim:719` (`NIF_OBSERVE_MONITOR_URL`) and `:727` (`proc fetch` per request)
- FIX: none.

## A241 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL: 1961–1973 Verification section names `tests/t_observe.nim` and `tests/t_logfile.nim`
- CODE: both exist and are wired into `make test-server` (`tests/t_observe.nim`, `tests/t_logfile.nim`, `Makefile:501` for hooks) — but `tests/t_hooks.nim` is not named anywhere in MANUAL
- FIX: add "`tests/t_hooks.nim` covers env→subject mapping, stdin payload delivery and timeout behaviour" to the hooks section or to §Testing.

