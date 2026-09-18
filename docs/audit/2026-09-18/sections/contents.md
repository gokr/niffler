# Worklist slice: Contents

From `worklist.tsv` (2 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A153 (trim)
source: `mechanisms.md`

- MANUAL: MANUAL: lines 377–454 ("The bus in one screen" subject table)
- CODE: doc: `docs/WIRE.md` is the normative subject/flag spec (MANUAL itself says "details in WIRE.md")
- FIX: FIX: keep a 5-line subject overview, link WIRE.md for the per-subject payload tables.

## A651 (doc-edit)
source: `components/grep.md`

- MANUAL: MANUAL: "- [Language servers (`lsp`)](#language-servers-lsp) · [Repository inspection (`git`)](#repository-inspection-git) · [Background processes (`processes`)](#background-processes-processes)"
- CODE: docs/MANUAL.md:20
- FIX: add — [doc-edit] a bullet "- [Search (`grep`)](#search-grep)" directly after the `Fetch` bullet on the preceding contents line, so the new chapter is reachable from the table of contents like `Fetch` and `Language servers` are.

