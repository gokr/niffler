# Worklist slice: component: processes

From `worklist.tsv` (9 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A451 (wrong)
source: `components/processes.md`

- MANUAL: **[wrong claim] The 50-finished-entry cap does not exist.** `KEEP_FINISHED = 50` (`main.nim:34`) is declared and **never referenced**; `gProcs` has no eviction path (`main.nim:76, 323`, only `clear()` at shutdown `main.nim:487`), so finished entries accumulate for the component's lifetime and `process_list` returns all of them (`main.nim:421-436`). MANUAL:1055-1056 asserts "the 50 most recent finished entries stay in the registry". → either implement the cap (evict oldest terminal entries past 50) **or** replace the claim with "the registry keeps every process of this component's lifetime, running and finished; only running ones are persisted to `registry.json`".

## A454 (doc-edit)
source: `components/processes.md`

- MANUAL: **[wrong scope] An LLM-invoked `process_start` is anonymous.** The tool schema has no `x-harness.sessionId` (`main.nim:500`), and only bash passes `session` (`components/bash/main.nim:139`); so `process_start` reached via `discover`/`invoke` never gets an exit notice. MANUAL:1069-1071 lists "a direct `process_start`, e.g. from `cli`" — → widen to "started by anything other than `bash run_in_background` (the model's own `invoke`, `cli`, a script)".

## A455 (doc-edit)
source: `components/processes.md`

- MANUAL: **[imprecise] "Processes die with the harness" (MANUAL:1077).** True for a graceful stop (`onDrain` → `killEntry` on every entry, `main.nim:484-488`, fired on SIGTERM/SIGINT/`ev.sys.drain`, `sdk/niffler/sdk.nim:33, 393-397`), but a SIGKILLed component leaves them running until the **next component start** sweeps them (`main.nim:115-143`). → "die when the `processes` component stops; if it is killed, the next start sweeps the orphans".

## A456 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing] Per-tool timeouts**: start 20 s, poll 30 s, kill 15 s, list 10 s (`main.nim:500, 514, 521, 526`). MANUAL:1043 documents only the 25 s `waitMs` cap. → one line in the table or Details.

## A457 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing] `workdir` fallback.** Schema says "default: workspace" (`main.nim:497`); core substitutes the conversation workspace when the field is empty or relative (`core/dispatch.nim:1437-1446`), so that default holds only for calls that go through core dispatch; a bare `cli call process_start` leaves it empty and the child inherits the component's cwd (`NIF_ROOT`). A non-existent `workdir` fails with `E_BAD_SHAPE` (`main.nim:291`). → one sentence.

## A459 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing] Error codes**: `E_LIMIT` (≥32 live) `main.nim:283`, (fork failure) `main.nim:319`; `E_NOT_FOUND` `main.nim:270`; `E_BAD_SHAPE` (empty command `main.nim:277`, missing workdir `main.nim:291`, invalid filter regex `main.nim:256`). MANUAL lists none. → optional, low priority.

## A461 (doc-edit)
source: `components/processes.md`

- MANUAL: **[missing] Must not be replicated.** `manifest.yaml:176-181` sets no `replicas` (→ 1), which is required: the registry is in-memory and this process is the single writer of `registry.json` and the spools. MANUAL never says so. → one sentence in Details (cross-ref AGENTS.md's stateless-only rule for replicas).

## A462 (doc-edit)
source: `components/processes.md`

- MANUAL: **[attribution] The peek UI is the niffler-tui plugin.** `process_list` + `process_poll {tail: "1"}` and the `bg N` status line live in `var/plugins/niffler-tui@main/tui/processes.go:5-10, 54, 77` and `…/tui/main.go:2741-2743`; nothing in `ui/frontend` or `core/tty.nim` references the process tools. MANUAL:1072 shows `bg 1 (7m)` without saying where it is rendered. → name the plugin (or drop the example).

## A463 (doc-edit)
source: `components/processes.md`

- MANUAL: **[verified, no change]** These MANUAL claims are exactly right and were re-checked: four tools + on-demand/discover-only (1079); 32 concurrent cap (1055, `main.nim:33, 283`); drain semantics and filter-cursor behaviour (1043, `main.nim:250-262, 383-392`); 64 KiB raw tail (1043, `main.nim:36, 346`); per-stream cursors and O_APPEND spools (1047-1052); exit notice text and its two lanes (1055-1071, `core/conversation.nim:1005-1075`); `E_BACKGROUND` fallback (1080-1083, `components/bash/main.nim:149-153`); boot sweep + pid-reuse guard (1074-1077, `main.nim:93-143`); env defaults (299-300).

