# Worklist slice: Troubleshooting

From `worklist.tsv` (7 rows). `class` is one of
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

## A195 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2320 Troubleshooting "orphaned `nats-server` | only possible when its core was SIGKILLed (the exit defer was skipped) — kill the pid in `var/nats-pid`, else `pkill -f nats-server`"
- CODE: `core/niffler.nim:331-333` (defer + SIGTERM handler), `components/nats/main.go:15-18` (PDEATHSIG on Linux), `core/niffler.nim:176-200` (a stale `var/nats-pid` is re-validated: pid alive *and* still a nats-server)
- FIX: update: on Linux an orphan caused by SIGKILL cannot happen (PDEATHSIG reaps it) — the realistic cases are a manually started `nats-server`, a non-Linux host (no PDEATHSIG equivalent), or a *stale* `var/nats-pid` left by SIGKILL. Reword the fix column to "check `var/nats-pid` (a stale file is ignored — core verifies pid + comm), then `pkill -f nats-server`".

## A770 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:3067 "| two stores fight over the same data file (`var/store.db` or `var/barrel-db`) | single-writer rule — only one core per root; experiment in a temp `NIF_ROOT` copy |"
- CODE: `components/store/main.nim:44-51`, `components/store-sqlite/main.go:32-38`
- FIX: none (verified).

## A771 (doc-edit)
source: `components/store.md`

- MANUAL: MANUAL:3068 "| boot refuses: \"this harness has conversation history in var/barrel-db\" | the default engine changed to SQLite and your history is still in barrel — run `niffler-store-migrate --root <path>` (the error prints it), or set `NIF_STORE_BACKEND=barrel` to keep the old engine |"
- CODE: `core/niffler.nim:462-469`
- FIX: none (verified) — the captured message matches byte for byte, including the `--scan` hint and the exit code.

## A783 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:3069 `| orphaned `nats-server` | a manually started `nats-server`, a non-Linux host (no PDEATHSIG to reap it), or a stale `var/nats-pid` left by SIGKILL — check the pid file (core verifies pid + comm, so a stale file is ignored), then `pkill -f nats-server` |`
- CODE: `components/nats/pdeathsig_linux.go:12-21`, `components/nats/pdeathsig_other.go:4-6` (no-op off Linux), `core/niffler.nim:176-201` (pid + `commOf(pid) == "nats-server"` check), `Makefile:406-413` (`make down` pkills `nats-server`)
- FIX: none — verified accurate.

