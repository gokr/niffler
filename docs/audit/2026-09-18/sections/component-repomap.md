# Worklist slice: component: repomap

From `worklist.tsv` (16 rows). `class` is one of
verified/doc-edit/wrong/missing/trim/delta/code-bug?. The `MANUAL`
text is the report's quote; its line numbers are the OLD (2324-line)
revision and are hints only.

## A481 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:396 (`ev.session.context …` is the last line of the bus block, MANUAL:389-405)
- CODE: `core/conversation.nim:2839-2846` (`mapSubject`), `:2388` (`ev.workspace.opened` publish), `components/repomap/main.nim:303-306`
- FIX: add two lines to the subject block: `svc.session.<id>.map   repomap → runner: the workspace map to append once` and `ev.workspace.opened {workspace, conversationId} core → components: a conversation's workspace, for pre-warm and the repo-map append`.

## A482 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:342-346 (env rows)
- CODE: `main.nim:19, 42-43, 282-284` — the row for `NIF_REPOMAP_AUTOAPPEND` says the tool is unaffected, but the four `MIN_*` rows never say the gates are append-only
- FIX: append to each of the four rows: "append-only; `repo_map` is never gated — a small map is a fine answer to an explicit question." (same sentence for all four, so add once as a lead-in sentence above the block).

## A483 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:244 (`var/repomap-tags/` map cache)
- CODE: `main.nim:40, 72-96` — the directory holds a per-file **tags** cache (`{mtime, tags}` JSON named by the sha1 of the absolute path), not rendered maps
- FIX: "`repomap-tags/` per-file tree-sitter/Nim tags cache (mtime-keyed; empty results are never cached)".

## A484 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:251-253 ("The repomap, lsp and skills components additionally treat `config.nims`, `tsconfig.json`, `package.json` and `go.mod` as repo *markers* (where to walk from)")
- CODE: `main.nim:121-147` — repomap never uses markers as walk roots; its census walks the whole workspace and these files ride along as **bare map entries** (`main.nim:142-144`)
- FIX: split the sentence — keep markers for lsp/skills and say repomap "lists marker files (`Makefile`, `package.json`, `go.mod`, …) as bare entries in the map".

## A485 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:56 (shipped table row)
- CODE: `main.nim:244-263` — the row lists the param names only and omits the language tiers and the tool's defaults
- FIX: keep the row, but move detail to the proposed section and make the row end with "see [Repository map](#repository-map-repomap)"; there, state the default budget (1024 tokens, max 4096, `main.nim:34-36, 217-218`) and that the tool is discover-only, read-effect and approval-free.

## A486 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL: absent (no language-coverage statement anywhere)
- CODE: CODE: `tags.nim:57-78, 224-233`, `main.nim:121-141`
- FIX: FIX (in the proposed section): "Tag coverage is two tiers: tree-sitter for Go, Python, TypeScript, JavaScript, C, C++, Rust and Ruby (grammars vendored under `components/repomap/csrc/`, queries in `components/repomap/queries/`), and a native Nim tagger for `.nim`/`.nims` because the Nim grammar's generated parser is 40 MB. Unlisted extensions contribute no symbols."

## A487 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:996-1031 (`### How the user adds a language`, lsp)
- CODE: CODE: `tags.nim:3-4, 57-78, 223-233`, `ts.nim:19-45`, `Makefile:158-167` — the MANUAL's "adding a language is a config entry, never code" promise is true for lsp, but a repomap language needs a vendored grammar and component edits
- FIX: FIX (proposed section): "Adding a language to the map is a component change, not a config entry: vendor the grammar's C under `csrc/`, register it in `ts.nim`'s `{.compile.}` list and `REPOMAP_CSRC`, add `queries/<lang>-tags.scm`, and add its extensions to `tags.nim`. The tier list is the seam's current limit, not a policy."

## A488 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:1471-1474 ("Search and inspection: `files` …, the git tools, `undo_last_edit`, and the observe/logfile diagnostics")
- CODE: `main.nim:262` (`onDemand: true`) — `repo_map` is not named in the shipped on-demand policy
- FIX: add "`repo_map` (the ranked workspace map)" to that bullet.

## A489 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:1314-1326 (`doctor` deep-probe paragraph names only lsp and store)
- CODE: `main.nim:311-357` (`selfTest`: tiny workspace must fail both gates, a padded one must pass)
- FIX: add a clause — "the repomap deep check maps a throwaway workspace and asserts both append gates fire".

## A490 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL:2199-2205 (`make test` target list)
- CODE: `Makefile:515-516` (`test-repomap` builds and runs `t_repomap_tags`, `t_repomap_score`, `t_repomap`), `tests/t_repomap*.nim`
- FIX: add `test-repomap` to the list.

## A491 (code-bug?)
source: `components/repomap.md`

- MANUAL: MANUAL:373 (".env.example in the repo root is the complete reference: every `NIF_*` variable")
- CODE: CODE/CFG: `.env.example:227` carries only `#NIF_REPOMAP_AUTOAPPEND=1`; the four `NIF_REPOMAP_MIN_*` knobs (`main.nim:178, 184-186`) are absent
- FIX: FIX: either add the four commented lines to `.env.example` or soften MANUAL:373 to "the reference copy of the documented variables".

## A492 (trim)
source: `components/repomap.md`

- MANUAL: MANUAL: absent (nothing documents what the append actually injects)
- CODE: CODE: `core/conversation.nim:959-978`
- FIX: FIX (proposed section): "The appended entry is one user-role message: a short preamble naming the workspace and warning it is a snapshot, then the map. It is appended once per conversation, stays in history (compaction may trim it — `repo_map` re-creates it), and emits `ev.session.map {sessionId, workspace, bytes}`."

## A493 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL: absent (nothing documents `focus`/`mentionedIdents` semantics beyond the schema)
- CODE: CODE: `main.nim:247-250`, `score.nim:89-91, 104-118`
- FIX: FIX (proposed section, one sentence): "`focus` ranks the graph around the files you are editing — and drops their own definitions, since you already have them — while `mentionedIdents` boosts files whose path or definitions match the symbols the task names."

## A494 (doc-edit)
source: `components/repomap.md`

- MANUAL: MANUAL: absent (nothing documents the census exclusions/caps)
- CODE: CODE: `main.nim:36-37, 66-70, 115-147`
- FIX: FIX (proposed section, one sentence): "The map never walks `docs/`, `var/`, `.git`, `node_modules`, build outputs and the other junk directories, and stops at 5000 files or 5 s — a docs-only or tiny workspace therefore maps to nothing (the append logs it). "

## A495 (delta)
source: `components/repomap.md`

- MANUAL: MANUAL: absent; CODE defect, not a doc gap: `main.nim:38` (`BUILD_TIMEOUT_MS = 90_000  # per-build cap inside the tool's 120s`) — the constant is never used (`grep -n BUILD_TIMEOUT_MS components/repomap/*.nim` → the definition only) and the schema timeout is 300 000 ms (`main.nim:262`)
- CODE: FIX: drop the dead constant (or wire it) and correct the comment — else the MANUAL would document a 120 s cap that does not exist.

## A496 (delta)
source: `components/repomap.md`

- MANUAL: MANUAL: absent; CODE defect: `main.nim:113` (census doc comment) and `main.nim:232-234` (the "No map" answer) both say the tiers cover only `.nim/.nims/.go/.py/.ts`, while the code covers 14 tree-sitter extensions plus Nim (`tags.nim:224-233`, `main.nim:124-141`)
- CODE: FIX: update both strings to "tree-sitter (Go, Python, TS/JS, C/C++, Rust, Ruby) + native Nim" before the MANUAL quotes a language list.

