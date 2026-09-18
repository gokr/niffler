# Worklist slice: component: bash

From `worklist.tsv` (22 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A267 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:55 — the shipped-components table row (the only real description, and a good one).

## A268 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:39, 2265 — `--minimal` profile includes `bash`.

## A269 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:457-459 — `bash` is the first entry in the approval-gated list; MANUAL.md:330, 495-502 the bypasses.

## A271 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:268 — `NIF_ROOT`, cwd = root.

## A272 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:556-565 — conversation workspace / `cwd` pinning and the runner's path rewriting.

## A273 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:1033-1083 — `processes`, with three bash cross-references (1037, 1058-1065, 1079-1083).

## A274 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:1440, 1466 — tool-profile JSON and the "routine work" policy.

## A275 (delta)
source: `components/bash.md`

- MANUAL: MANUAL.md:1810-1811 (its logs), 2308-2310 (bench measurement excludes bash workload children).

## A276 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (no section)
- CODE: `main.nim:1-222`
- FIX: add the section above — four prose cross-references exist, but nothing states the schema, the two timeouts, the caps, the spill directory or the exit-code table in one place. The table row (MANUAL.md:55) is a summary, not a chapter.

## A278 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (cap numbers and their non-configurability)
- CODE: `main.nim:12`, `16`
- FIX: add — the hard capture bound is **2,000,000 bytes** and the transcript cap **12,000 bytes**, both compile-time constants with **no env knob** (the component's only `getEnv` is `NIF_ROOT`, `main.nim:31`). A user who wants a bigger transcript budget must rebuild the component; a user hitting the 2 MB bound gets a marker telling the *model* to narrow the command, not the human a setting to raise.

## A280 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (parse/start failure output)
- CODE: `procutil.nim:28-40`
- FIX: add — when nothing could be captured (unterminated heredoc, unbalanced quote) the transcript shows `[no output captured — the command failed to parse or start; check quoting and heredoc termination]` instead of a bare code. Also worth one clause: a command containing `<<` is wrapped with the redirection on its own line (`procutil.nim:82-88`), i.e. heredocs are supported and tested (tests/t_bash.nim:49-53).

## A281 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (truncation marker)
- CODE: `procutil.nim:153-166`
- FIX: add the literal marker shape `[... truncated <omitted> of <total> bytes (capped at <max>) — <hint> ...]` with head+tail kept, since the model's recovery behaviour (re-run narrower, or `read` the spill) depends on it, and `bash` passes two different hints (`main.nim:161-162`, `181-183`).

## A282 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (30 s cancel-freshness window, stashed cancels)
- CODE: `main.nim:60-102`, `124-126`
- FIX: add — a `cancel.bash` is only honoured within **30 s** of its timestamp (`cancelFreshSeconds`, `main.nim:65`); a cancel for a *different* session is stashed and later turns that queued request into a synthetic `(exit 130 — cancelled by request)` **without running the command**. This is the only place the MANUAL/WIRE pair (296-319) understates the mechanism: the "components opt in by matching `sessionId`" wording describes the running case and misses the queued case.

## A283 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL:412-419 / WIRE docs (cancellation)
- CODE: `main.nim:156`, `procutil.nim:119-122`
- FIX: none needed beyond the above — exit 130 and the process-group kill are stated correctly in both docs; optionally add "the probe is polled every 50 ms, so cancellation is prompt but not instantaneous".

## A284 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (two timeouts could be conflated)
- CODE: `main.nim:112`, `119`, `128`; `core/dispatch.nim:151`, `1564-1567`
- FIX: add one sentence — the argument (`timeoutMs`, default 30 s) controls the *command*; the schema's `x-harness.timeoutMs: 60000` controls how long *core* waits for the reply (core default 120 s). With `timeoutMs: 120000` the command can legally outlive the dispatch budget and the caller sees a dispatch timeout, not a tidy 124.

## A286 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (one approval, not two)
- CODE: `main.nim:119`, `142`; `core/dispatch.nim:1556-1563`
- FIX: add — a background start is approved once (the `bash` call); the component's internal `process_start` request goes straight over NATS and never passes core's approval gate. Correspondingly, `process_start` called *directly* (e.g. from `cli` or another component) **is** gated (MANUAL.md:1041). Note: reasoned from the dispatch path, not executed in this audit.

## A287 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (no `effect`, therefore write-class)
- CODE: `main.nim:119-120` (no `"effect"` key); `components/fabric/fabric.nim:218-233` (unclassified ⇒ `"write"`)
- FIX: add — `bash` declares no `x-harness.effect`, so fabric's batch host classifies it as a **write** and runs it exclusively (never inside the read concurrency cap). Same note as the `edit` audit makes for `read`/`grep`; for `bash` the classification is the conservative and correct one, but the MANUAL's fabric chapter (MANUAL.md:1974-1996) never says which common tools serialize.

## A288 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL absent (shell, env, stdin)
- CODE: `procutil.nim:82-101`; MANUAL.md:268
- FIX: add — the shell is always `bash -c` (`$PATH`-resolved, no override), stdout and stderr are merged in arrival order, the child inherits the component's environment (`NIF_ROOT`, `.env`, everything core exported) and stdin, and fds above stderr are `FD_CLOEXEC`-scrubbed before spawn. "Fresh shell per call: `cd` does not persist" (`main.nim:118`) is the one part already visible to the model.

## A289 (code-bug?)
source: `components/bash.md`

- MANUAL: MANUAL absent (`self_test`)
- CODE: `main.nim:192-220`
- FIX: optional — `bash` implements `comp.selfTest` (real exec + a 1 s timeout kill expecting 124) and `deep` is accepted with the same probes; no MANUAL or WIRE mention exists. Low value for users, useful for an operator verifying a fresh build.

## A290 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL:457-459, 330, 495-502 (approval gate)
- CODE: `main.nim:119`
- FIX: none — verified accurate: `bash` is gated on every call, denied when no human is reachable, bypassed only by `/approvals auto` or `NIF_AUTO_APPROVE=1`, with no per-command allowlist and no read-only path.

## A292 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL:268, 556-565 (workspace/cwd)
- CODE: `main.nim:154-155`, `core/dispatch.nim:1437-1446`
- FIX: none required — accurate. A one-line addition would help: the workspace arrives in the `cwd` argument and the component realizes it as `cd -- <cwd> || exit $?`, so a missing workspace directory surfaces as a failed call rather than as output from the wrong directory.

## A293 (doc-edit)
source: `components/bash.md`

- MANUAL: MANUAL:39, 2265 (`--minimal`) and MANUAL.md:55 (manifest column)
- CODE: `manifest.yaml:22-27`
- FIX: none — `bash` is `required: true`, `autostart: true`; consistent with the MANUAL.

