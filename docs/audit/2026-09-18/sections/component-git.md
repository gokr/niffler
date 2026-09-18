# Worklist slice: component: git

From `worklist.tsv` (14 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A366 (delta)
source: `components/git.md`

- MANUAL: MANUAL:67 — shipped-components table row (`optional`; names the five tools and the `var/review-receipts/` write/check pair; "On-demand tools…").

## A367 (delta)
source: `components/git.md`

- MANUAL: MANUAL:1471-1472 — shipped policy, "The long tail is on demand: … the git tools".

## A369 (delta)
source: `components/git.md`

- MANUAL: MANUAL:455-470 — approval list: no git tool (correct), and no note that `review_receipt` writes without approval.

## A370 (delta)
source: `components/git.md`

- MANUAL: MANUAL:230-260 — the `var/` state table: **no** `var/review-receipts/` row.

## A371 (doc-edit)
source: `components/git.md`

- MANUAL: **No MANUAL chapter.** Params, caps, timeouts, refusals and exit codes exist only in the component's doc comments (`main.nim:1-19`, `:188-345`); MANUAL coverage is one table row (MANUAL:67) plus one shipped-policy bullet (MANUAL:1471-1472). Fix per §4.

## A374 (doc-edit)
source: `components/git.md`

- MANUAL: **Receipt format/semantics undocumented**: `schema_id: "niffler.review-receipt/v1"`, `id` (`rr-<unix>-<fp8>`), `created_at`, `diff_fingerprint` (lowercase SHA-256 hex), `model`, `findings`, `note` (`main.nim:387-395`, fingerprint `:352-362`); check semantics exit 0/1 with both fingerprints (`:426-434`). MANUAL:67 says only "write/check pair".

## A375 (doc-edit)
source: `components/git.md`

- MANUAL: **Output bounds undocumented**: the 40 000-byte head+tail cap plus the five per-tool line caps and their hints (`main.nim:99`, `:130-134`, `:213`, `:251`, `:288`, `:317`, `:345`; `sdk/niffler/procutil.nim:153-178`) — e.g. a 300-file `git_status` silently stops at 200 lines.

## A376 (doc-edit)
source: `components/git.md`

- MANUAL: **Failure/refusal semantics undocumented**: exit 2 refusals with the `(exit 2 — refused)` prefix, 124 `[timed out]`, 128 `[no git repository at the target directory]`, everything else raw git stderr (`main.nim:119-138`); empty-result markers `[no changes since HEAD]` (`:249-250`) and `[no commits matched]` (`:286-287`).

## A377 (doc-edit)
source: `components/git.md`

- MANUAL: **Detached HEAD and incomplete index get no special handling** — `git_status` shows git's `## HEAD (no branch)` and an index error is raw text + exit 128 with no flag (`main.nim:119-134`; nothing in the file special-cases either). If the new chapter covers failure modes, state this rather than implying coverage.

## A378 (doc-edit)
source: `components/git.md`

- MANUAL: **Doc-comment vs. core resolution mismatch for `repo`**: the parameter doc says relative paths resolve against the harness root (`main.nim:199-200`, `:228-229`, `:268-269`, `:300-301`, `:329-330`) while core resolves a relative `repo` against the conversation workspace (`core/dispatch.nim:1437-1446`). Document both cases (workspace when core-injected; component cwd = harness root for a direct bus call, `main.nim:150-153`).

## A379 (doc-edit)
source: `components/git.md`

- MANUAL: **`x-harness.effect` absent on the five read tools** (`main.nim:185-186` … `:319-320`): the fabric classifier defaults unclassified tools to `"write"` (`components/fabric/fabric.nim:226-228`, `:309`), so `git_status`/`git_diff` are scheduled exclusively instead of alongside other reads — contradicting the read-only framing of MANUAL:1471. Code fix candidate; document the actual class meanwhile.

## A380 (doc-edit)
source: `components/git.md`

- MANUAL: **`parallel: true` on the five read tools, absent on `review_receipt`** (`main.nim:185` … `:319` vs `:364`) — a runner-side batching hint (docs/WIRE.md:632-637) the MANUAL never mentions for git (only MANUAL:665, for lsp/plugins).

## A381 (doc-edit)
source: `components/git.md`

- MANUAL: **No MANUAL note that git must resolve to a real binary via `PATH`** and is skipped when it would be the component's own binary (`main.nim:80-97`); a missing/shadowed git yields exit 127 with an install hint (`main.nim:107-117`). Worth a line in the chapter and in Troubleshooting.

## A382 (wrong)
source: `components/git.md`

- MANUAL: **Dangling doc reference and missing self-test**: the tool comment points at `docs/RECEIPTS.md` (`main.nim:367`), which does not exist (docs/ holds only ARCHITECTURE, FABRIC_GUIDE, MANUAL, WIRE), and the component registers no `selftest` (grep count 0), so `/doctor` lists it as not implementing (MANUAL:1300-1306). Either add the doc/self-test or drop the reference.

