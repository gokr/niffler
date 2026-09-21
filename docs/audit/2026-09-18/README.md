# Docs audit — 2026-09-18

Artifacts of the subagent fleet that audited `docs/MANUAL.md` against the code
(parent conversation `conv-7bbc16c8640c`, 2026-09-18 23:49 → 00:20), rescued out
of the gitignored `var/docs-audit/` so they survive a `make clean`.

**The English `docs/MANUAL.md` is the source of truth.** `MANUAL.zh.md` and
`MANUAL.zh-TW.md` are AI translations that deliberately lag (their banner says
so); they are re-synced in a separate pass, not during this consolidation.

## The reports

| report | what it covers |
|---|---|
| `config.md` | every production `NIF_*` env var vs the MANUAL table and `.env.example` |
| `mechanisms-full.md` | the whole MANUAL, section by section (104 findings, 55 already correct) + a proposed outline |
| `mechanisms.md` | partial first attempt at the same (its session hit the 6M-token turn budget; superseded by `mechanisms-full.md`, kept for its `[dup]` cross-references) |
| `mechanisms-sessions.md` | session runners, UI registry, lifecycle/autostart, clients |
| `mechanisms-obs.md` | approvals, plugins, skills, hooks, observe/logfile, store paging, the `ev.*` inventory |
| `components/*.md` | one component each: what it offers, tools, configuration, how the MANUAL covers it, delta list |

Two jobs were budget-killed: the whole-MANUAL audit (retried as
`mechanisms-full.md`) and the sessions slice (continued with a "finish the
slice" message — its report is complete). 16 of ~32 component directories were
audited; the second wave (`builder`, `cli`, `compaction`, `console`, `ctxtest`,
`dialog`, `grep`, `hooks`, `logfile`, `mcp-bridge`, `nats`, `observe`, `recall`,
`store*`, `systemprompt`) is **not** covered here.

## The worklist

`normalize.py` folds all 21 reports into one ledger:

- `worklist.tsv` — one row per finding: `id`, `source`, `group` (report
  section), `target` (MANUAL section, re-anchored on the *current* manual by
  matching the quoted text), `target_line`, `class`, `dup`, `manual`, `code`,
  `fix`.
- `worklist-summary.md` — counts by class and by MANUAL section.
- `sections/<slug>.md` — the same rows grouped per MANUAL section, one file per
  section (that is the unit of work).
- `partition.py` → `batch-1..8.txt` + `batches.md` — the slices split into
  balanced batches, one per consolidation subagent.

Classes: `doc-edit` (MANUAL wording/table/link), `wrong` (claim is false),
`missing` (capability absent from the MANUAL), `trim` (move detail to a pointer),
`code-bug?` (the fix belongs in code, not prose), `delta` (finding stated as
prose), `verified` (auditor confirmed the MANUAL is right — do not re-audit).

Line numbers inside the reports refer to the 2324-line revision; `docs/MANUAL.md`
has since grown (2373 lines and counting), so quotes — not line numbers — anchor
a finding. Re-verify every claim against the current tree before applying it.

## Second wave (same day, later)

Six more children covered the components the first pass did not reach, one
report each: `builder`, `cli`, `console`, `dialog`, `compaction`, `recall`,
`grep`, `hooks`, `logfile`, `observe`, `store` (the three store directories in
one report — the Nim front door, sqlite and tidb engines) and
`infra-and-examples` (`nats`, `ctxtest`, `systemprompt`, `llm-openai`,
`mcp-bridge`). `normalize.py` lists all of their paths, so re-running the
pipeline folds them into the same ledger and `partition.py` re-slices.

In parallel, six children finished the **open** rows of the first wave — the
batches that were cut before writing: `edits/batch-open-1..6.json`, one per
section group, each decided against the current MANUAL and code. `status.py
--open` is the work list; `apply_edits.py` applies those sets exactly like
`batch-N.json` (all-or-nothing, `old_string` must occur exactly once).

## Applying a batch

A consolidation subagent writes `edits/batch-N.json`: for each row it re-reads
the current manual and code and emits `{id, slice, status, reason, evidence,
old_string, new_string}`. The parent applies those with exact-string edits
(rejecting any `old_string` that is missing or ambiguous), then records the
outcome in `applied.md`. Nothing but `docs/MANUAL.md` is edited by this flow;
`code-bug?` rows are collected for separate fixes.

Status legend for the ledger: `apply` (edit is in `edits/batch-N.json`),
`applied`, `already` (docs were right by now), `skip` (belongs elsewhere),
`code` (needs a code change), `unclear` (could not verify).

## Closed (round three, 2026-09-21)

The ledger is closed — `python3 status.py`:

    ledger rows: 822
      applied                439   (incl. the 37 code rows, marked below)
      decided:skip           193
      decided:already        190

Every `code` verdict row is applied — commits `fccbb74` (the 28 pending +
build-gap/b1-b4 follow-through) and `15c1888` (A124/A495/A496, the three
"filed separately" rows whose filing had never happened). The per-row
outcomes, verification commands and live probes (store-migrate 6-kind
barrel→sqlite, hooks dedup, console attribution, store put guard, SDK
session seam) are recorded in `code-bugs.md`, "Round three". Nothing is
open: the X/Y/Z special sections, the (Z) trims and the wave-two coverage
gap (infra-and-examples + the three store engines) are all decided, and
the build-system gap's "check other multi-file components" follow-up
verified every NIM_SRCS/wildcard target covered.

Removal of this directory is tracked in issue #75; the zh-manual re-sync
that must precede it is #74. Issues: #71 closed with the round-three
evidence.
