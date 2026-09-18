# Worklist slice: component: cli

From `worklist.tsv` (4 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A562 (doc-edit)
source: `components/cli.md`

- MANUAL: MANUAL: "**The cli component** (`./var/bin/cli`) drives the same bus from a script or pipeline — non-interactive, CI-friendly (exit 0 on success); it is the scripting face, the tty admin shell is the interactive one:"
- CODE: components/cli/main.nim:103-124 (dispatch target is `svc.<component>.call`), core/dispatch.nim:1630-1633 (the only approval site)
- FIX: add "Every command is a plain bus client: `cli` never goes through `svc.core.call`, so its calls bypass the approval gate, the workspace/session injection, a tool's `x-harness.timeoutMs` and the hidden/on-demand filter — `cli call del …` and `cli call chat …` work. It is an operator tool: give it the trust you give the shell you started the harness from." [missing]

## A569 (verified)
source: `components/cli.md`

- MANUAL: MANUAL: "`cli install` clones, builds via the builder, spawns every component and waits for each service name to appear in core's accepted catalog; interactive components are verified by their build."
- CODE: components/cli/main.nim:160-211 (60 s wait for `plugins`, 600 s `plugin_install`, 60 s per spawned component, `INSTALL OK`/`INSTALL FAILED`)
- FIX: fix: none — the prose matches the code; only the three budgets are unstated [verified]

## A570 (verified)
source: `components/cli.md`

- MANUAL: MANUAL: "CLI catalog and tool lookup also use core's authoritative directory, never raw registration broadcasts."
- CODE: components/cli/main.nim:34-72 (both indexes replaced on every read), :149 (`call` refuses a tool core has not accepted)
- FIX: fix: none — verified, and it is why a component core rejected is unreachable through `cli` even while it answers on the bus [verified]

## A573 (verified)
source: `components/cli.md`

- MANUAL: MANUAL: "they cannot spoof a session, and unattributed calls are only bounded by `timeoutMs`."
- CODE: components/cli/main.nim:103-124 (no `__session`, no `sessionId`, no `x-harness.timeoutMs` applied)
- FIX: fix: none — verified; this sentence is the best existing hint of the bypass and D4's addition should reference it [verified]

