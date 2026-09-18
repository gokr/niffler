# Batch 7 — consolidation summary

Slices: `proposed-top-level-outline-for-manual-as-a-reference-manual` (16),
`progressive-tool-discovery` (13), `the-store` (12), `language-servers-lsp` (7),
`hooks` (6), `recovery` (4) — **58 rows**, all resolved (`edits/batch-7.json`).

Re-verified against `docs/MANUAL.md` as it stands now (**2399 lines**) and the
current tree. `evidence` is the file:line read *now*, not the report's stale
line number.

## Counts

| status | n | ids |
|---|---|---|
| apply | 15 | A056, A069, A091, A092, A093, A094, A111, A230, A231, A232, A233, A234, A243, A247, A405 |
| code | 2 | A203, A235 |
| already | 5 | A015, A016, A055, A170, A373 |
| skip | 36 | A054, A057, A058, A070–A077, A090, A125–A140, A162, A204, A209, A244, A245, A246, A258, A400 |
| unclear | 0 | — |

All 15 `old_string`s were checked to occur exactly once in the current manual,
and the whole apply set was replayed in id order against it: 15/15 apply
cleanly, no collision between neighbouring edits (A093 was re-anchored on the
`expectRev` sentence alone so it cannot fight A247's caption edit).

## The apply set

- **the-store** — A092 (extend the kind table with `profile`, `approval`,
  `contextreceipt`, `compaction_input`, `context_projection`, `spill`, `mcp`,
  `selftest`), A093 (write rules: session-bound callers may only `put`
  `fabricprog`, `get`/`list` on-demand, `del` hidden), A094 (name the TiDB
  engine in the backend sentence), A243 (paging pointer + `storeListAll` rule
  in §The store), A247 (the table is the complete list).
- **recovery** — A091 (never `rm -rf var`; a store that refuses to start means
  a live flock holder, not a stale lock file — `make down`), A111 (the sources
  recipe now restores `manifest.yaml`/`Makefile` too).
- **hooks** — A230 (256 KB payload cap + temp-file hand-off), A231 (clamp floor
  100 ms, exit 124), A232 (first-match-wins; unset `NIF_HOOKS_<SUBJECT>`
  ignored), A233 (off-by-default is autostart only — enabling needs no
  rebuild), A234 (failures land in `var/logs/hooks.log`, never logfile's
  JSONL).
- **lsp** — A056 (`~16 000 characters`, not 16 KiB), A405 (registered signature
  `lsp {operation, path, query?, line?, character?, workspaceRoot?}`).
- **progressive tool discovery** — A069 (`7 tools are direct` — the row's
  suggested caveat was reworded: the report's "a profile can only grow the set"
  is false, `resolveProfile` selectors can also exclude).

## Needs a human decision

1. **A125–A140 (16 rows, the proposed Part I/II outline)** — a whole-document
   restructuring; there is no exact-string edit to apply, so all 16 are
   `skip`. They should be decided as one editorial act, not per row. This is
   the largest single block in the batch (~28%).
2. **A203 (`code`)** — `ui/frontend/src/views/Sessions.svelte:55-67` still
   deletes raw store records and never calls core's `conversation_delete`, so a
   UI-side delete leaves `sessionmeta`/`agentjob` behind and does not stop a
   live runner. The manual's sentence ("Deleting a conversation also deletes
   its exposure document") is true for the exposure document the SPA does
   delete, so A077/A209 are `skip` *pending this decision* — a deviation note
   in the manual would become wrong the moment the SPA is fixed.
3. **A235 (`code`)** — `components/hooks/main.nim:2` cites `docs/HOOKS.md`,
   which does not exist (the manual already points at
   `components/hooks/README.md`); fix the header comment.
4. **A247 code note** — the store tool docstrings still advertise a three-kind
   list (`components/store/main.nim:118-135`). The manual edit only fixes the
   docs side.

## Already fixed by a sibling batch while this one ran

The manual grew 2373 → 2399 lines during this pass, and two rows were fixed
under me:

- **A015** — §Store engines now says "The file-backed engines (`sqlite`,
  `barrel`) enforce single-writer the same way" (`docs/MANUAL.md:200`).
- **A016** — the paging paragraph now carries `limit` default 100 / cap 1000,
  `after` is exclusive, `nextAfter` absent when `hasMore` is false, and the
  "an `nextAfter`" typo is gone (`docs/MANUAL.md:205-210`).

Three further rows were *already correct*, not stale:

- **A055** — the missing `WARM_MAX_SERVERS` number is now documented in the
  "Warmup budgets" paragraph (`NIF_LSP_WARM_MAX` default 2, cheap/total
  budgets) — better than the proposed clause.
- **A170** — "limited to 30 seconds" is the tool's *argument* clamp
  (`observe` rejects `timeoutMs > 30000`); the 35 s the report found is the
  schema's `x-harness.timeoutMs` dispatch ceiling, a different limit. No edit.
- **A373** — the git row already names `review_receipt` as a write/check pair
  under `var/review-receipts/`, and the Approvals chapter's list is explicitly
  scoped to `x-harness.approval: always` tools (which it deliberately is not).

## Duplicates folded into another row's edit

A092 absorbs A244, A245 and A258; A093 absorbs A162 and A246; A203 absorbs
A077 and A209. Those rows are `skip` with the pointer in `reason`, so nothing
is applied twice. Verified rows (A054, A057, A058, A070–A076, A090, A204,
A400) are `skip` / "verified by the auditor" as instructed.

## Rows I could not verify

None (`unclear`: 0). Every row was re-anchored on its quoted text in the
current manual; the two `code` rows and the `already` rows carry the
file:line read now.
