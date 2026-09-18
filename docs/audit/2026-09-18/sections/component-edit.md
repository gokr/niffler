# Worklist slice: component: edit

From `worklist.tsv` (16 rows). `class` is one of
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

## A298 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 (no mention of the read/write staleness gate)
- CODE: `main.nim:786-797` (rationale `main.nim:410-424`)
- FIX: add — when a conversation's last-observed digest of a file differs from disk (external edit, or a `bash` mutation since the read/write), `edit` refuses with `E_STALE` *before* matching, because `old_string` may occur exactly once in text the model has never seen. Fix is to re-read and redo the edit; session-less callers (`cli`, other components) are not tracked and skip the gate.

## A299 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:233-247 (state table; no `niffler-edit` row)
- CODE: `main.nim:474-481`
- FIX: add a row — `| **Home files (edit undo store)** | `$XDG_CONFIG_HOME/niffler-edit/undo.json` (else `~/.config/niffler-edit/undo.json`): last pre-edit bytes per file + per-conversation seen-state digests | durable |`. It is the only durable artifact this component owns; deleting it only loses undo history and unchanged-read stubs, never file content.

## A300 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL absent (undo semantics)
- CODE: `main.nim:864-900`, `522-546`
- FIX: add — `undo_last_edit` is **single-level per file** (the previous edit only, not a stack), **persisted across restarts** and keyed by absolute path, and reverts content, BOM and line endings exactly. It is refused with `E_UNDO_STALE` when the file was modified or deleted after the edit — and in that case the stale record is *discarded*, so the undo is gone for good; the model is told to re-read and edit forward. The undo record is written before the file, so a store failure refuses the edit with `E_UNDO_UNAVAILABLE` rather than losing the ability to revert.

## A301 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 (read description) / absent elsewhere
- CODE: `main.nim:466-472`, `979-985`, `44` (`MIN_STUB_BYTES = 512`), `54-61`
- FIX: add — a *full* re-read of a file ≥512 bytes that this conversation previously read in full and that is byte-identical returns `[unchanged] <path>: N bytes, M lines, digest <sha1>` instead of the text; the model passes `force: true` (or any offset/limit window) to force a re-dump. Windowed reads and small files always re-dump.

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

## A306 (doc-edit)
source: `components/edit.md`

- MANUAL: MANUAL:65 vs CODE (`edit` cannot create files)
- CODE: `main.nim:159-167`
- FIX: add one clause — `edit` only changes *existing* text files: a missing path is `E_NOT_FOUND`, an empty file `E_EMPTY`, both pointing at `write` as the way to create content. This is the most common confusion between the two tools and is currently implied only by the error text.

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

