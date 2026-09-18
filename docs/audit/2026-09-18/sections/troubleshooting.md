# Worklist slice: Troubleshooting

From `worklist.tsv` (5 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A101 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2316 "`core: WARNING missing binary for <name>` on boot | run `make build`"
- CODE: `core/niffler.nim` emits the warning on the manifest restore path; combined with `core/conversation.nim:2869-2872` ("session runner binary missing: … run `make build`") there are **two** distinct missing-binary messages
- FIX: list both, since the session-runner one is the one users actually hit (it breaks every conversation, not the boot).

## A102 (doc-edit, dup:.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2320 orphaned `nats-server` row
- CODE: wrong cause on Linux — PDEATHSIG reaps the bus (`components/nats/main.go:15-18`, `sdk/go/pdeathsig_linux.go:17`)
- FIX: apply the `mechanisms-sessions.md` wording. `[dup]`.

## A103 (doc-edit, dup:.)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2322 "component crashes on boot, restarts in a backoff loop | `core.remove` it"
- CODE: only `on-failure` components loop; `never` components stay down (`core/supervisor.nim:14-16,200-212`)
- FIX: apply the `mechanisms-sessions.md` scoping. `[dup]`.

## A104 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2323 "agent-modified sources | `git restore components/ core/ sdk/` then `make build`"
- CODE: consistent with Recovery ✔, but the same caveat as Recovery applies (a modified `manifest.yaml` or `Makefile` is not restored by that command)
- FIX: extend to `git restore components/ core/ sdk/ manifest.yaml Makefile` (or `git checkout -- .` as the Recovery section already says).

## A195 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2320 Troubleshooting "orphaned `nats-server` | only possible when its core was SIGKILLed (the exit defer was skipped) — kill the pid in `var/nats-pid`, else `pkill -f nats-server`"
- CODE: `core/niffler.nim:331-333` (defer + SIGTERM handler), `components/nats/main.go:15-18` (PDEATHSIG on Linux), `core/niffler.nim:176-200` (a stale `var/nats-pid` is re-validated: pid alive *and* still a nats-server)
- FIX: update: on Linux an orphan caused by SIGKILL cannot happen (PDEATHSIG reaps it) — the realistic cases are a manually started `nats-server`, a non-Linux host (no PDEATHSIG equivalent), or a *stale* `var/nats-pid` left by SIGKILL. Reword the fix column to "check `var/nats-pid` (a stale file is ignored — core verifies pid + comm), then `pkill -f nats-server`".

