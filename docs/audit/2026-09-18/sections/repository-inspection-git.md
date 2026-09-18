# Worklist slice: Repository inspection (git)

From `worklist.tsv` (3 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A374 (doc-edit)
source: `components/git.md`

- MANUAL: **Receipt format/semantics undocumented**: `schema_id: "niffler.review-receipt/v1"`, `id` (`rr-<unix>-<fp8>`), `created_at`, `diff_fingerprint` (lowercase SHA-256 hex), `model`, `findings`, `note` (`main.nim:387-395`, fingerprint `:352-362`); check semantics exit 0/1 with both fingerprints (`:426-434`). MANUAL:67 says only "write/check pair".

## A376 (doc-edit)
source: `components/git.md`

- MANUAL: **Failure/refusal semantics undocumented**: exit 2 refusals with the `(exit 2 — refused)` prefix, 124 `[timed out]`, 128 `[no git repository at the target directory]`, everything else raw git stderr (`main.nim:119-138`); empty-result markers `[no changes since HEAD]` (`:249-250`) and `[no commits matched]` (`:286-287`).

## A377 (doc-edit)
source: `components/git.md`

- MANUAL: **Detached HEAD and incomplete index get no special handling** — `git_status` shows git's `## HEAD (no branch)` and an index error is raw text + exit 128 with no flag (`main.nim:119-134`; nothing in the file special-cases either). If the new chapter covers failure modes, state this rather than implying coverage.

