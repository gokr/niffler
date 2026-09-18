# Worklist slice: Background processes (processes)

From `worklist.tsv` (9 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A059 (doc-edit, dup:mechanisms.md for the approvals list.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1042-1046 tool table (`process_start` approval-gated, `process_poll` 25 s cap/read-effect, `process_kill` approval-gated, `process_list` read-effect)
- CODE: `components/processes/main.nim:491-530` (exact four; gates at `:500,521`), `MAX_WAIT_MS = 25_000`, `TAIL_BYTES = 64 * 1024` (`:36,40`)
- FIX: none `[dup]` mechanisms.md for the approvals list.

## A060 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1050-1056 "spool beyond the cap (32 MiB, `NIF_PROCESSES_SPOOL_CAP`) truncated to its tail … one poll returns at most `NIF_PROCESSES_POLL_CHUNK` new bytes per stream (default 64 KiB). Cap: 32 concurrent processes; the 50 most recent finished entries stay in the registry."
- CODE: `:33-43` (`MAX_LIVE = 32`, `KEEP_FINISHED = 50`, `SPOOL_CAP = 32*1024*1024`, poll chunk env with 65536 default) ✔
- FIX: none.

## A061 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 1057-1063 ("A finished process tells its conversation … publishes an exit notice into it (the same lane subagent settlement notices use)")
- CODE: `components/processes/main.nim:446-447` (`svc.session.<id>.steer` with a `{notice: …}` payload), `:71-73` (notified once) ✔
- FIX: none.

## A062 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 1063 "(own process group, stdin from /dev/null…)"
- CODE: `:301-304` (`< /dev/null` in the launched command) ✔
- FIX: none.

## A285 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (`run_in_background` still has a dispatch budget)
- CODE: `main.nim:113-117` ("no timeout applies"), `119`
- FIX: clarify — "no timeout applies" to the *job* (the `processes` component owns it), but the `bash` call that starts it is still bounded by the 60 s dispatch budget and the start request's own 15 s (`main.nim:142`); if `processes` is slow to answer, the call fails with the dispatch error, not `[E_BACKGROUND]`.

## A291 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL:1033-1083 (`processes` interplay)
- CODE: `main.nim:131-152`
- FIX: none — verified accurate, including the owning-session handoff, the exit notice, `[E_BACKGROUND]` when the component is absent, and "no timeout applies" to the job.

## A452 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing number] Kill grace.** `process_kill` = SIGTERM → 300 ms → SIGKILL → 100 ms, hardcoded (`main.nim:183-193`); MANUAL:1044 says only "Terminate the whole process group". → add "(SIGTERM, 300 ms grace, then SIGKILL)".

## A453 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing number] What truncation keeps.** `truncateSpool` keeps `min(SPOOL_KEEP = 2 MiB, cap div 2)` bytes (`main.nim:39, 199-217`) and the truncating poll appends `[spool truncated to its tail — the cap was reached]` (`main.nim:404`). MANUAL:1051-1052 says only "truncated to its tail". → state "keeps the last 2 MiB (or half the cap, whichever is smaller)".

## A572 (doc-edit)
source: `components/cli.md`

- MANUAL: MANUAL: "the internal `process_start` goes straight over NATS and never passes core's approval gate, while a direct `process_start` (e.g. from `cli`) is gated"
- CODE: components/cli/main.nim:112-114 (target `svc.processes.call`), core/dispatch.nim:1630-1633 (gate location), components/processes/main.nim:498-521 (schemas only, no gate)
- FIX: update to "the internal `process_start` goes straight over NATS and never passes core's approval gate, while a direct `process_start` issued by a core-mediated caller (the model, or a tool reached through `svc.core.call`) is gated. A bus client like `cli` addresses `svc.processes.call` directly and is not gated at all — verified: with `NIF_AUTO_APPROVE` unset, `cli call bash '{\"command\": \"echo x\"}'` executes while the same harness denies a core-mediated `spawn`" [wrong]

