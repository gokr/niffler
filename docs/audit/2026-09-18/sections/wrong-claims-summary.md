# Worklist slice: Wrong claims (summary)

From `worklist.tsv` (7 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A251 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:457–467 presents the approval-gated tool list as complete ("currently …") — ten gated tools are missing (see §Approvals, finding 1).

## A252 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:491–492 "a short window" — it is 1.5 s, and the fallback is skipped when no client is registered (core/approval.nim:48,216–227).

## A253 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:496 makes the 5-minute timeout universal — the `/limit` keep-going question times out at 120 s (core/approval.nim:50–51).

## A254 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:771–772 "invalid = … or no `name`" — a missing `name:` falls back to the directory name and is accepted (components/skills/main.nim:120,133).

## A255 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:459 (`core.spawn`, `core.kill`, `core.remove`) names tools that do not exist under those names (`spawn`/`kill`/`remove`, core/catalog.nim:68,81,89) and does not say core gates them by name rather than by schema (core/dispatch.nim:273–276).

## A256 (doc-edit)
source: `mechanisms-obs.md`

- MANUAL: MANUAL:190 "capped at 1000 items" without the `limit` default of 100, which is what a caller omitting `limit` actually gets (components/store/main.nim:130,151).

## A259 (wrong)
source: `mechanisms-obs.md`

- MANUAL: Not a MANUAL claim but code-side wrong pointer: `components/hooks/main.nim:2` cites `docs/HOOKS.md`, which does not exist.

