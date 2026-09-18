# Worklist slice: Testing

From `worklist.tsv` (7 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A095 (doc-edit, dup:mechanisms.md)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2202-2209 "`make test-bash # … or just one: test-store, test-builder, … test-smoke`"
- CODE: `Makefile:431-434` (`TEST_BINS := tests/smoke.nim $(wildcard tests/t_*.nim)`) and ~25 named targets
- FIX: replace the hand-list with "`make help` lists every target; the full bus suite is `make test-server`". `[dup]` mechanisms.md / mechanisms-sessions.md.

## A096 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2216 "drives them over a private NATS server whose loopback ports are allocated by NATS"
- CODE: accurate — `tests/helpers.nim:36-91` starts a test-owned `nats-server` with `--ports_file_dir` in a temp dir and reads the client/monitoring ports back from the `*.ports` files, preferring the in-repo `var/bin/nats-server` (`:45-51`)
- FIX: none; consider adding "(the test reads the port back from nats-server's ports file)" for someone debugging a stuck test.

## A097 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2221-2230 network opt-ins (`NIF_TEST_INSTALL=1`, `NIF_TEST_NETWORK=1`)
- CODE: `tests/` honors both names (`grep -rl NIF_TEST_*`) ✔
- FIX: none.

## A163 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: lines 2186-2190 "or just one: test-store, test-builder, test-console, test-plugins, test-skills, test-fetch, test-models, test-observe, test-logfile, test-core, test-cli, test-autostart, test-smoke"
- CODE: `Makefile:431-434` `TEST_BINS := tests/smoke.nim $(wildcard tests/t_*.nim)` — the suite is *every* `tests/t_*.nim` (t_agent/t_agentnotice/t_agentcont included, no `test-agent` target), plus ~40 named targets: `test-bash`, `test-edit`, `test-expert`, `test-fabric`, `test-git`, `test-grep`, `test-hooks`, `test-lsp`, `test-mcp`, `test-nested`, `test-parallel`, `test-processes`, `test-profile`, `test-repomap`, `test-systemprompt`, `test-uireg`, `test-approval`, `test-controls`, `test-compaction`, `test-store-sqlite`, `test-store-tidb`, `test-discover`, `test-retry-unit`, `test-ctx-accounting`, `test-ui`
- FIX: replace the hand-list with "`make help` lists every target; the full set is `make test-server`".

## A164 (doc-edit)
source: `mechanisms.md`

- MANUAL: MANUAL: line ~2192 "Each test boots the real component binaries (Nim, Go *and* TypeScript ...)" ✔ but "whose loopback ports are allocated by NATS"
- CODE: `Makefile:458-463` runs `$(TEST_BINS)` under one build lock; each `t_*` spawns its own nats (AGENTS.md says so too)
- FIX: reword to "each test starts a private nats-server (`NIF_NATS_SPAWN`-style isolation)".

## A205 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2211-2214 (one-test list: "test-store, test-builder, test-console, test-plugins, test-skills, test-fetch, test-models, test-observe, test-logfile, test-core, test-cli, test-autostart, test-smoke")
- CODE: `Makefile:433-434,476-528` also defines `test-uireg` (`tests/t_uireg.nim` — the only contract test for the client registry), plus `test-agent*`, `test-fabric*`, `test-nested`, `test-edit`, `test-git`, `test-grep`, `test-lsp`, `test-processes`, `test-hooks`, `test-expert`, `test-repomap`, `test-approval`, `test-controls`, `test-compaction`
- FIX: replace the inline list with "`make test-<component>` (see `make help` for the full set)" so it cannot drift, and mention `make test-uireg` and `make test-autostart` explicitly since they are this slice's contracts.

## A206 (doc-edit)
source: `mechanisms-sessions.md`

- MANUAL: MANUAL: line 2205-2209 "Core-based tests snapshot their required binaries into a unique temporary `NIF_ROOT`"
- CODE: `Makefile:433-434,458-460` (`TEST_BINS` loop, one test-owned bus each), `scripts/with-build-lock.sh:25-27` (`flock -s`)
- FIX: accurate in substance; the passing mention of `test-autostart` is fine.

