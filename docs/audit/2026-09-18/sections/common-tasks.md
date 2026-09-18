# Worklist slice: Common tasks

From `worklist.tsv` (3 rows). `class` is one of
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

