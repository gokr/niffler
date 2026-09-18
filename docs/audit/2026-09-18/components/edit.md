# Docs audit — `components/edit/` (Nim, 1373 lines: `main.nim` 1327, `diagformat.nim` 46)

Scope: what the component offers, its tools/flags, its configuration, and how
`docs/MANUAL.md` covers it. Read-only audit; every claim below carries file:line.
Component version `0.3.0` (`components/edit/main.nim:1247`).

## 1. What it offers

`edit` is the file-tools component: it registers **four** tools — `read`
(pageable, batched file reading), `edit` (exact-text replacement, several edits
per call), `write` (atomic whole-file create/overwrite/truncate) and
`undo_last_edit` (single-level per-file revert) (`main.nim:1252`, `1282`,
`1303`, `1317`). It is the only component that mutates files for the agent, and
it owns both the in-process undo state and the persisted undo store
(`main.nim:389-397`, `474-481`). Matching is exact-first: an `old_string` that
occurs more than once is *refused* with the occurrence count, never fuzzied
away (`main.nim:600-608`); a guarded fallback cascade only rescues
*not-found* transcription slips (`main.nim:612-651`). Every mutation is
approval-gated and revertible (`main.nim:1300`, `1313`, `1324`). Anchored
block moves deliberately live in the external niffler-hashline plugin
(`main.nim:21-23`).

## 2. Tools

All four are registered with `sessionId: true` and `workspace.pathFields:
["path"]`, so the session runner rewrites relative paths against the
conversation workspace (`main.nim:1275-1279`, `1300-1301`, `1313-1315`,
`1324-1325`; core side: `core/dispatch.nim:1386-1387`; MANUAL.md:562).

| Tool | Purpose (doc comment) | x-harness flags | Exposure |
|---|---|---|---|
| `read` | Read files for editing: canonical `reads` array of 1..12 `{path, offset?, limit?}` items, single-file `path` sugar, verbatim lines | `timeoutMs: 60000`, `parallel: true`, `sessionId`, `workspace.pathFields/pathArrayFields/pathObjectArrayFields`; **no approval**; **no `effect`** | direct (`main.nim:1252-1280`) |
| `edit` | Replace exact text in an existing file; each `old_string` must occur exactly once (or `replace_all`); `undo_last_edit` reverts | `approval: "always"`, `timeoutMs: 300000`, `sessionId`, `workspace.pathFields`; no `effect` | direct (`main.nim:1282-1301`); schema takes `path` + `edits[]` (`old_string`, `new_string`, `replace_all`), so **multi-edit is this one tool** — there is no `multi_edit` |
| `undo_last_edit` | Undo the last edit on a file, restoring exact previous bytes (content, BOM, line endings); per-file, single-level, persisted; refused `E_UNDO_STALE` when the file changed after the edit | `approval: "always"`, `timeoutMs: 120000`, `onDemand: true`, `sessionId`, `workspace.pathFields` | **discover-only** (`main.nim:1303-1315`; MANUAL.md:1469-1470 agrees) |
| `write` | Create or replace a whole file atomically (parent dirs created); cap 900KB | `approval: "always"`, `timeoutMs: 60000`, `sessionId`, `workspace.pathFields`; no `effect` | direct (`main.nim:1317-1325`) |

Handler-side aliases (not in the schema description, but accepted): `edit`
also reads `filePath`/`file_path` for the path and `old_str`/`oldText`,
`new_str`/`newText` for the pair; `edits` may be given as a JSON string or a
single object (`main.nim:724-727`, `760-775`).

## 3. Configuration

- **Env vars — exactly two, plus the XDG base:**
  - `NIF_READ_OUTLINE_LINES` — whole-read line threshold above which `read`
    returns an lsp `documentSymbol` outline instead of raw text; `0` disables;
    parsed per call, invalid values fall back to 1000
    (`main.nim:665-668`, default `OUTLINE_MIN_LINES = 1000`, `main.nim:48`;
    MANUAL.md:341 documents it correctly).
  - `NIF_WRITE_MAX_BYTES` — `write` payload cap, default `900000`, `<= 0`
    falls back to 900000 (`main.nim:1203-1208`; MANUAL.md:348 documents it
    correctly).
  - `XDG_CONFIG_HOME` — moves the undo-store directory (below).
  - **There is no `NIF_EDIT_*` knob** (verified: the only `getEnv` calls in the
    component are `main.nim:475`, `667`, `1206`).
- **Undo store path:** `$XDG_CONFIG_HOME/niffler-edit/undo.json`, else
  `$HOME/.config/niffler-edit/undo.json` (`main.nim:474-481`; doc'd only as a
  directory constant). The doc is `{"version": 1, "undo": {...}, "seen":
  {...}}` (`main.nim:388`, `511-518`), written atomically (`writeAtomic`,
  `main.nim:106-131`), loaded at boot (`main.nim:479-504`).
- **Bounds / retention:** single-level **per file** — one `UndoEntry` per
  absolute path (`main.nim:389-394`, `gUndo` `main.nim:397`). There is **no
  pruning, LRU or size cap** anywhere (no `prune`/`maxEntries` in the file);
  the store grows one entry per edited file, each holding pre- and post-edit
  content + BOM + line ending (`main.nim:508-518`). The record is cleared by
  `undo_last_edit` (`main.nim:890`), by a stale undo (`main.nim:881`, `887`)
  and by any failed write that restores the previous record (`main.nim:530-541`).
  The `seen` half is in-memory for confirming reads and persisted only for a
  read that observed *different* bytes, a mutation, or an undo
  (`main.nim:548-561`, `974`, `1022`, `844`, `894`, `1234`) — it is keyed
  `(session, absolute path)` and also never evicted (`main.nim:411-424`).
- **Undo durability ordering:** the undo record is persisted *before* the file
  write; if the persist fails the edit is refused with `E_UNDO_UNAVAILABLE`
  and the file is untouched; if the write fails the previous record is
  restored (`main.nim:522-546`, `828-836`).
- **Workspace resolution:** `edit` itself resolves relative paths against
  `rootDir()` = `NIF_ROOT` or the process cwd (`sdk/subjects.nim:34-36`),
  follows symlinks to the target (`main.nim:95-102`, `148`), and expands `~`
  (`main.nim:85-90`). The per-conversation `cwd`/workspace rewriting is done
  by the session runner via `x-harness.workspace`, not by this component
  (`core/dispatch.nim:1386-1443`; MANUAL.md:562-565).
- **Stale / ambiguous matches (failure modes, all refused, never guessed):**
  `E_STALE` when the conversation's last-observed digest of that file differs
  — the guard is skipped for session-less callers such as `cli`
  (`main.nim:786-797`, rationale `main.nim:410-424`); `E_AMBIGUOUS` with the
  occurrence count for the exact pass and for each fallback tier
  (`main.nim:604-608`, `621-626`, `634-647`); `E_NOT_FOUND` with the tier list
  tried (`main.nim:650-656`); `E_SPAN_TOO_LARGE` when a fuzzy span is wildly
  larger than `old_string` (`main.nim:249-257`, `585-592`); `E_OVERLAP` when
  two edits in one call touch overlapping text (`main.nim:803-810`);
  `E_NO_CHANGE` when the edits produce identical bytes (`main.nim:822-826`);
  `E_NOT_TEXT`/`E_FILE_TOO_LARGE`/`E_EMPTY`/`E_NOT_FOUND` for directories,
  binaries, UTF-16/32 and >100MB files (`main.nim:36`, `154-178`).
  **Multi-edit atomicity:** all edits resolve against the same *original*
  content, are checked for overlap and for no-change, and only then is the new
  content spliced in reverse span order and written in a single atomic
  rename — a failure at any step leaves the file untouched
  (`main.nim:798-838`; `main.nim:15-16`).
- **Fallback cascade (in order):** per-line trailing whitespace → indentation
  drift (leading *and* trailing forgiven) → unicode punctuation fold → block
  anchors with Levenshtein similarity ≥ 0.65 (needs ≥ 3 lines) → double-escaped
  `old_string` unescaped and retried (`main.nim:612-651`, `278-350`,
  `FUZZY_SIMILARITY` `main.nim:39`, `305-308`). Only the matched original
  bytes are replaced (`main.nim:581-598`).

## 4. MANUAL placement

No dedicated section exists. The component is documented in three places:

- MANUAL.md:65 — the shipped-components table row (the only real description).
- MANUAL.md:459 — `edit`/`write`/`undo_last_edit` in the approval-gated list.
- MANUAL.md:654, 1467-1472, 233-247, 341, 348 — replication caveat, shipped
  tool-profile policy, state table, the two env rows.

**Proposed:** a new `## File tools (\`edit\`)` section inserted after
`## Language servers (\`lsp\`)` (ends at MANUAL.md:1031) and before
`## Background processes (\`processes\`)` (MANUAL.md:1033) — i.e. at line
1033 — with subsections `### The tools`, `### Exact match, no fuzzy rescue`,
`### Undo state and its store`, `### Configuration`. Add it to `## Contents`
(MANUAL.md:10-30) and one state-table row, plus keep line 65 as the summary.

## 5. DELTA list

- MANUAL:65 (`edit` (unique `old_string`, guarded fallback cascade, `replace_all`)) | CODE: `main.nim:1285-1298` (an `edits` array), `main.nim:803-810` (`E_OVERLAP`), `main.nim:798-838` (single atomic write) | FIX: add — `edit` is inherently multi-edit: `edits[]` takes any number of `{old_string,new_string,replace_all?}` pairs, all matched against the *original* file, checked for overlap and no-change before anything is written, then applied in one atomic rename. There is no separate `multi_edit` tool; a stringified or single-object `edits` is accepted (`main.nim:735-741`). A batch that fails any pre-check leaves the file byte-identical.
- MANUAL:65 (no mention of the read/write staleness gate) | CODE: `main.nim:786-797` (rationale `main.nim:410-424`) | FIX: add — when a conversation's last-observed digest of a file differs from disk (external edit, or a `bash` mutation since the read/write), `edit` refuses with `E_STALE` *before* matching, because `old_string` may occur exactly once in text the model has never seen. Fix is to re-read and redo the edit; session-less callers (`cli`, other components) are not tracked and skip the gate.
- MANUAL:233-247 (state table; no `niffler-edit` row) | CODE: `main.nim:474-481` | FIX: add a row — `| **Home files (edit undo store)** | `$XDG_CONFIG_HOME/niffler-edit/undo.json` (else `~/.config/niffler-edit/undo.json`): last pre-edit bytes per file + per-conversation seen-state digests | durable |`. It is the only durable artifact this component owns; deleting it only loses undo history and unchanged-read stubs, never file content.
- MANUAL absent (undo semantics) | CODE: `main.nim:864-900`, `522-546` | FIX: add — `undo_last_edit` is **single-level per file** (the previous edit only, not a stack), **persisted across restarts** and keyed by absolute path, and reverts content, BOM and line endings exactly. It is refused with `E_UNDO_STALE` when the file was modified or deleted after the edit — and in that case the stale record is *discarded*, so the undo is gone for good; the model is told to re-read and edit forward. The undo record is written before the file, so a store failure refuses the edit with `E_UNDO_UNAVAILABLE` rather than losing the ability to revert.
- MANUAL:65 (read description) / absent elsewhere | CODE: `main.nim:466-472`, `979-985`, `44` (`MIN_STUB_BYTES = 512`), `54-61` | FIX: add — a *full* re-read of a file ≥512 bytes that this conversation previously read in full and that is byte-identical returns `[unchanged] <path>: N bytes, M lines, digest <sha1>` instead of the text; the model passes `force: true` (or any offset/limit window) to force a re-dump. Windowed reads and small files always re-dump.
- MANUAL:65 (read caps incomplete) | CODE: `main.nim:40-43`, `1128-1153` | FIX: add — `read` caps a call at 12 files/ranges (`E_BAD_SHAPE` beyond), 2000 lines and 256KB per item, 2KB per line (longer lines are replaced by a "use bash: sed -n …" notice), and 512000 bytes of *aggregate* output; the remainder is reported as a per-item error telling the model to read the rest separately. Per-item errors do not fail the batch (`main.nim:1157-1163`).
- MANUAL absent (lazy instruction loading; the systemprompt section only documents the static ancestor walk at MANUAL.md:1719-1731) | CODE: `main.nim:430-459`, `943`, `1024-1025` | FIX: add — a `read` that enters a directory *below* the harness root appends any newly discovered `AGENTS.override.md`/`AGENTS.md`/`AGENTS.MD`/`CLAUDE.md`/`CLAUDE.MD` (+ `AGENTS.local.md`) for the directories on the path, each wrapped in `<lazy_project_instructions path="…">`, once per session. This keeps monorepo subtrees out of the frozen system prompt until the model actually enters them.
- MANUAL:65 ("guarded fallback cascade" is unnamed) | CODE: `main.nim:612-616`, `249-257`, `588-592` | FIX: update — name the cascade in order: per-line trailing whitespace → indentation drift → unicode punctuation (smart quotes/dashes) → block anchors with Levenshtein similarity ≥ 0.65 (≥ 3 lines) → double-escaped text. Every tier must still match exactly once (ambiguity is an error, never a reason to go fuzzier), and a fuzzy span grossly larger than `old_string` is refused with `E_SPAN_TOO_LARGE`.
- MANUAL:65 ("`write` (atomic whole-file)") | CODE: `main.nim:1317-1325`, `106-131`, `1210-1241` | FIX: update — `write` creates the file and its parent directories, follows symlinks, preserves the target's permissions via `fchmod` on the temp file, renames atomically, and truncates on empty content; payload cap is 900000 bytes (`NIF_WRITE_MAX_BYTES`), deliberately under NATS's 1MB limit so oversized writes get a clear component error; it reports path, bytes, lines, digest and `overwrote`.
- MANUAL:65 vs CODE (`edit` cannot create files) | CODE: `main.nim:159-167` | FIX: add one clause — `edit` only changes *existing* text files: a missing path is `E_NOT_FOUND`, an empty file `E_EMPTY`, both pointing at `write` as the way to create content. This is the most common confusion between the two tools and is currently implied only by the error text.
- MANUAL:1467-1470 (shipped policy: `read`/`edit`/`write` direct, `undo_last_edit` on demand) | CODE: `main.nim:1252` (no `onDemand`), `1282` (none), `1303` (`onDemand: true`), `1317` (none) | FIX: none — verified accurate, no change.
- MANUAL:459 (approval list includes `edit`, `write`, `undo_last_edit`) | CODE: `main.nim:1300`, `1313`, `1324` | FIX: none — verified accurate. Note `read` is deliberately *not* approval-gated (`main.nim:1275-1279`), and the MANUAL does not claim otherwise.
- MANUAL:341, 348 (env rows for `NIF_READ_OUTLINE_LINES`, `NIF_WRITE_MAX_BYTES`) | CODE: `main.nim:667`, `1206` | FIX: none — both accurate; but state explicitly in the new section that these two are the *only* edit knobs (no `NIF_EDIT_*` family exists).
- MANUAL absent (undocumented cap in the write tool's own description) | CODE: `main.nim:1320` ("Cap 900KB") vs `main.nim:1206` (`NIF_WRITE_MAX_BYTES` overrides) | FIX: update the *code* doc comment to "cap 900KB by default (`NIF_WRITE_MAX_BYTES`)" — with the env set, the schema description the LLM sees is wrong, which is a real tool-choice hazard, not just a doc wart.
- MANUAL absent (undo store has no retention policy) | CODE: `main.nim:508-518` (writes every entry, never prunes) | FIX: add a sentence — the undo store keeps one record per edited file with no size cap or eviction, so it grows with the number of distinct files edited (each record holds whole pre- and post-edit contents); it is safe to delete at any time. Users on small home partitions should know this file exists.
- MANUAL:1974-1996 (fabric scheduling) vs CODE (low priority) | CODE: `main.nim:1274-1280` (`read` sets `parallel: true` but no `"effect": "read"`), `components/fabric/fabric.nim:226-228` (unclassified ⇒ `"write"`) | FIX: either add `"effect": "read"` to `read`'s schema (accepting that a correcting read persists seen-state) or note in the MANUAL that `read` — like `grep` and `bash` — is classified as a write by the fabric batch host and therefore serializes. As written, the schema advertises parallelism the batch scheduler will not grant.

Finding count: 18 rows (10 add, 5 update, 3 verified/no-change — of which 2 are code-side nits).

## 6. Not user-facing

Nothing here is hidden infrastructure: all four tools are ordinary catalog
tools, three of them direct. Two things are *effectively* invisible and should
be documented as behaviour rather than as interfaces: the unchanged-read stub
(`main.nim:979-985`) and the lazy project-instruction append
(`main.nim:430-459`, `1024-1025`) both change what the model sees, and the staleness gate
(`main.nim:786-797`) can refuse an edit a user believes is valid — that is the
one place where a user-visible failure needs the MANUAL to explain the fix
(re-read, then edit against current content).
