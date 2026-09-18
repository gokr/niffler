# Worklist slice: component: edit

From `worklist.tsv` (13 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A294 (delta)
source: `components/edit.md`

- MANUAL: MANUAL.md:65 — the shipped-components table row (the only real description).

## A295 (delta)
source: `components/edit.md`

- MANUAL: MANUAL.md:459 — `edit`/`write`/`undo_last_edit` in the approval-gated list.

## A296 (delta)
source: `components/edit.md`

- MANUAL: MANUAL.md:654, 1467-1472, 233-247, 341, 348 — replication caveat, shipped tool-profile policy, state table, the two env rows.

## A297 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 (`edit` (unique `old_string`, guarded fallback cascade, `replace_all`))
- CODE: `main.nim:1285-1298` (an `edits` array), `main.nim:803-810` (`E_OVERLAP`), `main.nim:798-838` (single atomic write)
- FIX: add — `edit` is inherently multi-edit: `edits[]` takes any number of `{old_string,new_string,replace_all?}` pairs, all matched against the *original* file, checked for overlap and no-change before anything is written, then applied in one atomic rename. There is no separate `multi_edit` tool; a stringified or single-object `edits` is accepted (`main.nim:735-741`). A batch that fails any pre-check leaves the file byte-identical.

## A302 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 (read caps incomplete)
- CODE: `main.nim:40-43`, `1128-1153`
- FIX: add — `read` caps a call at 12 files/ranges (`E_BAD_SHAPE` beyond), 2000 lines and 256KB per item, 2KB per line (longer lines are replaced by a "use bash: sed -n …" notice), and 512000 bytes of *aggregate* output; the remainder is reported as a per-item error telling the model to read the rest separately. Per-item errors do not fail the batch (`main.nim:1157-1163`).

## A303 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL absent (lazy instruction loading; the systemprompt section only documents the static ancestor walk at MANUAL.md:1719-1731)
- CODE: `main.nim:430-459`, `943`, `1024-1025`
- FIX: add — a `read` that enters a directory *below* the harness root appends any newly discovered `AGENTS.override.md`/`AGENTS.md`/`AGENTS.MD`/`CLAUDE.md`/`CLAUDE.MD` (+ `AGENTS.local.md`) for the directories on the path, each wrapped in `<lazy_project_instructions path="…">`, once per session. This keeps monorepo subtrees out of the frozen system prompt until the model actually enters them.

## A305 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 ("`write` (atomic whole-file)")
- CODE: `main.nim:1317-1325`, `106-131`, `1210-1241`
- FIX: update — `write` creates the file and its parent directories, follows symlinks, preserves the target's permissions via `fchmod` on the temp file, renames atomically, and truncates on empty content; payload cap is 900000 bytes (`NIF_WRITE_MAX_BYTES`), deliberately under NATS's 1MB limit so oversized writes get a clear component error; it reports path, bytes, lines, digest and `overwrote`.

## A307 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:1467-1470 (shipped policy: `read`/`edit`/`write` direct, `undo_last_edit` on demand)
- CODE: `main.nim:1252` (no `onDemand`), `1282` (none), `1303` (`onDemand: true`), `1317` (none)
- FIX: none — verified accurate, no change.

## A308 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:459 (approval list includes `edit`, `write`, `undo_last_edit`)
- CODE: `main.nim:1300`, `1313`, `1324`
- FIX: none — verified accurate. Note `read` is deliberately *not* approval-gated (`main.nim:1275-1279`), and the MANUAL does not claim otherwise.

## A309 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:341, 348 (env rows for `NIF_READ_OUTLINE_LINES`, `NIF_WRITE_MAX_BYTES`)
- CODE: `main.nim:667`, `1206`
- FIX: none — both accurate; but state explicitly in the new section that these two are the *only* edit knobs (no `NIF_EDIT_*` family exists).

## A310 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL absent (undocumented cap in the write tool's own description)
- CODE: `main.nim:1320` ("Cap 900KB") vs `main.nim:1206` (`NIF_WRITE_MAX_BYTES` overrides)
- FIX: update the *code* doc comment to "cap 900KB by default (`NIF_WRITE_MAX_BYTES`)" — with the env set, the schema description the LLM sees is wrong, which is a real tool-choice hazard, not just a doc wart.

## A311 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL absent (undo store has no retention policy)
- CODE: `main.nim:508-518` (writes every entry, never prunes)
- FIX: add a sentence — the undo store keeps one record per edited file with no size cap or eviction, so it grows with the number of distinct files edited (each record holds whole pre- and post-edit contents); it is safe to delete at any time. Users on small home partitions should know this file exists.

## A312 (code-bug?)
source: `components/edit.md`

- MANUAL: MANUAL:1974-1996 (fabric scheduling) vs CODE (low priority)
- CODE: `main.nim:1274-1280` (`read` sets `parallel: true` but no `"effect": "read"`), `components/fabric/fabric.nim:226-228` (unclassified ⇒ `"write"`)
- FIX: either add `"effect": "read"` to `read`'s schema (accepting that a correcting read persists seen-state) or note in the MANUAL that `read` — like `grep` and `bash` — is classified as a write by the fabric batch host and therefore serializes. As written, the schema advertises parallelism the batch scheduler will not grant.

