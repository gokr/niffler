# Worklist slice: Common tasks

From `worklist.tsv` (6 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A098 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2263-2285 the command list (`make install`, `install-tui`/`WITH_TUI=1`, `install-ui`, `install-lsp`, `test*`, `doctor`, `ram`, `down-here`, `clean`)
- CODE: all present (`Makefile:335,360,363,369,371,385,406,557,565,589,645`) ✔
- FIX: none.

## A099 (doc-edit)
source: `mechanisms-full.md`

- MANUAL: MANUAL: lines 2289-2309 (`make ram` — PSS not RSS, membership by executable path, workload children of `bash` excluded)
- CODE: `Makefile:385` → `scripts/niffler-ram.sh`; the rationale (tui is the parent of an autostarted harness) matches `ui`/plugin lifecycle
- FIX: none (script internals not re-read here).

## A100 (verified)
source: `mechanisms-full.md`

- MANUAL: MANUAL: line 2292-2294 "**Headless service mode** … `NIF_NATS_URL=... NIF_OPENAI_API_KEY=... ./var/bin/niffler < /dev/null` — serves `svc.core.call`; approval-requiring tools are denied unless a UI is attached or `NIF_AUTO_APPROVE=1`"
- CODE: `core/niffler.nim:659` (tty + not autostart ⇒ admin shell), `core/approval.nim:271-296` (auto-approve bypass, tty fallback only when `clientCount()==0`) ✔
- FIX: none.

## A589 (verified)
source: `components/console.md`

- MANUAL: MANUAL: "make install        # PATH entries (niffler, niffler-cli, niffler-console,"
- CODE: scripts/install.sh:84,101,110-111 (`link niffler-console console`), Makefile:253-254
- FIX: fix: none — verified [verified]

## A658 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: "                    # binaries, so PATH cannot shadow grep/git/...)"
- CODE: manifest.yaml:117-118 (`binary: var/bin/grep`); components/grep/main.nim:26-32
- FIX: add — [doc-edit] one clause in the new chapter: "the tool binary is `var/bin/grep`; it shells out to `rg`, never to the host `grep`", because this MANUAL line reads as if a system `grep` binary were the thing being kept off `PATH`.

## A781 (doc-edit)
source: `components/infra-and-examples.md`

- MANUAL: MANUAL:3038-3041 `or start your own nats-server on the default port before core — core reuses a live bus on `127.0.0.1:4222` and only spawns its own (the built `var/bin/nats-server` component) when none answers.`
- CODE: `core/niffler.nim:176-201` (`probeBus` → `bkFree`/`bkOurs`/`bkForeignCore`/`bkBareNats`), `:354-383` (only `bkOurs` reuses; foreign core and bare nats-server both print a WARNING and spawn an isolated bus; a bare bus is reclaimed only when `var/nats-pid` names *our own* live nats-server — `reclaimOwnNats`, `:176-201`)
- FIX: update — "…or start your own nats-server on the default port before core — core reuses a bus on `127.0.0.1:4222` only when a core answering it serves **this root**; a foreign harness or a bare nats-server with no core on it makes core warn and spawn an isolated bus instead (a leftover `var/nats-pid` naming one of this root's own buses is reclaimed first). To force a bus deliberately, set `NIF_NATS_URL`."

