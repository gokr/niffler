# Worklist slice: Could not determine

From `worklist.tsv` (1 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A266 (delta)
source: `config.md`

- MANUAL: MANUAL:36 lists `dialog` as a component source; components/dialog/dialog.sh exists and is built by niffler.nimble:46 + Makefile:285 but is not in manifest.yaml — whether it counts as "shipped" is a docs-intent question, not verifiable from code.

