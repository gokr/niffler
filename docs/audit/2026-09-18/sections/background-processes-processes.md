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

## A454 (doc-edit)
source: `components/processes.md`

- MANUAL: **[wrong scope] An LLM-invoked `process_start` is anonymous.** The tool schema has no `x-harness.sessionId` (`main.nim:500`), and only bash passes `session` (`components/bash/main.nim:139`); so `process_start` reached via `discover`/`invoke` never gets an exit notice. MANUAL:1069-1071 lists "a direct `process_start`, e.g. from `cli`" — → widen to "started by anything other than `bash run_in_background` (the model's own `invoke`, `cli`, a script)".

## A455 (doc-edit)
source: `components/processes.md`

- MANUAL: **[imprecise] "Processes die with the harness" (MANUAL:1077).** True for a graceful stop (`onDrain` → `killEntry` on every entry, `main.nim:484-488`, fired on SIGTERM/SIGINT/`ev.sys.drain`, `sdk/niffler/sdk.nim:33, 393-397`), but a SIGKILLed component leaves them running until the **next component start** sweeps them (`main.nim:115-143`). → "die when the `processes` component stops; if it is killed, the next start sweeps the orphans".

