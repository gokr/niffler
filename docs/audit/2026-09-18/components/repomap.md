# Docs audit — `components/repomap/`

Scope: `components/repomap/` (Nim, 1113 LOC: `main.nim` 358, `tags.nim` 233,
`score.nim` 222, `ts.nim` 152, `repomap.nim` 148 + vendored tree-sitter C in
`csrc/` and 8 tags queries in `queries/`). Docs checked: `docs/MANUAL.md`
(line numbers below are from the current file), `docs/research/REPOMAP.md`,
`docs/research/REPOMAP-GATES.md`, `bench/reports/repomap-ab-*.md`,
`CHANGELOG.md`, `.env.example`, `manifest.yaml`. Read-only audit; no builds run.

## 1. What it offers

One job — orient a conversation in a workspace — through two surfaces
(`components/repomap/main.nim:1-24`): (a) the `repo_map` tool, the model's
explicit pull and the only surface on by default; (b) a workspace-open
auto-append that ships **OFF** (`NIF_REPOMAP_AUTOAPPEND`,
`main.nim:287`) and stays gated even when opted in. The map is a
ranked, budget-capped list of files and their key definitions (~1KB default),
built from a tree-sitter + native-Nim tag graph with personalized PageRank
(`score.nim:1-12`), rendered as one-line rows `rel:line:col symKind name`
(`repomap.nim:1-8`). Deterministic for identical repo state — the
append's cache-stability requirement (`main.nim:145-149`). Every failure is
silent or degraded (no grammar, unreadable file, missing queries dir), so no
conversation can be broken by it (`main.nim:21-24`).

## 2. Tools

| Tool | Purpose (doc comment / description) | Flags | Exposure |
|---|---|---|---|
| `repo_map` | "A ranked map of a workspace: the load-bearing files and their key definitions, in ~1KB. Use it to orient in an unfamiliar repo or to re-orient after a big refactor … call this when you need orientation." (`main.nim:253-256`) | `onDemand: true`, `effect: "read"`, `timeoutMs: 300000`, `workspace: {pathFields: ["workspace"]}` (`main.nim:262-263`); no approval flag → approval-free | discover-only (`x-harness.onDemand`); never in a frozen direct set |

Params (`main.nim:244-252`): `workspace` (string; relative → resolved against
the conversation workspace, `defaultPathFields` not set so an omitted value
falls back in-handler to `rootDir()`, `main.nim:207-211`), `focus` (array of
files; ranks around them and *omits their own definitions*, `main.nim:247-248`,
`score.nim:89-91`), `mentionedIdents` (array of symbol names, boosted in the
Rank personalization, `main.nim:249-250`, `score.nim:104-118`), `budget`
(integer tokens; schema says `minimum 32, maximum 4096`; code default 1024 and
clamps the max only — `main.nim:34-36, 217-218`). Returns `{ok, text, budget,
buildMs, note}` and a friendly empty-text answer when nothing supported is
found (`main.nim:228-240`). It also registers the standard `selftest` used by
`/doctor deep` (`main.nim:311-357`).

## 3. Configuration

Env vars read by the component (all via `intEnv`/`getEnv`; `intEnv` ignores
garbage or non-positive values so a zeroed gate can never admit everything —
`main.nim:55-64`):

| Env | Effect | Default | Code |
|---|---|---|---|
| `NIF_REPOMAP_AUTOAPPEND` | the gate itself: `1`/`true`/`yes` opts the workspace-open append in; anything else returns early | `"0"` (off) | `main.nim:287` |
| `NIF_REPOMAP_MIN_CENSUS` | size floor (gate 4): covered source files in the workspace; below it the append never even builds the map | `50` (`MIN_WORKSPACE_CENSUS`) | `main.nim:52, 175-179` |
| `NIF_REPOMAP_MIN_BYTES` | content gate (gate 3): rendered map bytes; below → `stub` | `800` | `main.nim:49, 184-189` |
| `NIF_REPOMAP_MIN_SYMBOLS` | content gate: rendered symbol rows | `25` | `main.nim:50, 185-191` |
| `NIF_REPOMAP_MIN_FILES` | content gate: symbol-bearing files | `5` | `main.nim:51, 186-192` |

No other env var is read: `grep -rn 'getEnv' components/repomap/*.nim` →
`main.nim:58, 287` only. Threshold provenance and the bench that calibrated
them (stub class 4–9 symbols / 1–4 files / 100–3100 B; healthy maps 59–119
symbols / 19–48 files / 3.5–4.6 KB) live in `docs/research/REPOMAP-GATES.md`
and `CHANGELOG.md:62-73`.

- **Admission gates apply to the append only** — "the repo_map tool is never
  gated" (`main.nim:19, 42-43, 282-284`); withholding logs
  `repo map withheld … (<reason>)` through `c.log` (`main.nim:293-295,
  300-302`), with reasons `stub: <n>B < <min>B`,
  `stub: <n> syms < <min>`, `stub: <n> files < <min>`, `empty`
  (`main.nim:188-193`).
- **Append mechanics**: on `ev.workspace.opened {workspace, conversationId}`
  (published by core, `core/conversation.nim:2383-2391`) the component
  publishes `svc.session.<id>.map` (`main.nim:303-306`); the session runner
  drains it (`core/dispatch.nim:1093-1110`) and appends it **once** as a
  user-role message prefixed `[repo map of <ws> — a ranked snapshot … call
  repo_map for a fresh one.]` (`core/conversation.nim:959-978`), emitting
  `ev.session.map {sessionId, workspace, bytes}` (`core/conversation.nim:2703,
  976`). Append-only history, never the frozen prefix.
- **Tag cache**: `var/repomap-tags/<sha1 of absolute path>.json`, one file per
  source file holding `{mtime, tags}` (`main.nim:40, 72-96`); an mtime
  mismatch or corrupt entry is a miss, an empty result is *never* cached, and
  any cache failure degrades to in-memory (`main.nim:90-96, 155-163`).
- **Census/scan shape**: walks the workspace with `skipDirs` excluded —
  `node_modules`, `vendor`, `dist`, `build`, `target`, `__pycache__`, `.venv`,
  `venv`, `nimcache`, `obj`, `.gradle`, `.next`, `.cache`, `.tox`,
  `site-packages`, `.git`, `var`, `logs`, `scratch`, `.worktrees`, `docs`,
  `website` — plus hidden dirs (`main.nim:66-70, 128-130`); caps at 5000 files
  / 5 s (`main.nim:36-37, 115-121`).
- **Language coverage (tiers)**: tree-sitter tier for `.go .py .ts .js .c .h
  .cpp .hpp .cc .hh .cxx .hxx .rs .rb` (`tags.nim:57-78, 224-233`, grammars
  compiled from `csrc/` via `ts.nim:19-45` and `Makefile:158-167`) with queries
  `queries/{go,python,typescript,javascript,c,cpp,rust,ruby}-tags.scm`
  (aider's Apache-2.0 queries for go/python, upstream for the rest —
  `tags.nim:7-12`); a **native regex Nim tier** for `.nim/.nims` because the
  alaviss grammar's generated `parser.c` is 40 MB (`tags.nim:12-15, 145-231`);
  everything else yields zero tags (`tags.nim:230-233`). The census also
  admits `.cc/.hh/.cxx/.hxx` sources and rides `README`, `README.md`,
  `Makefile`, `package.json`, `Cargo.toml`, `go.mod`, `config.nims` along as
  bare heading entries (`main.nim:121-147`).
- **Adding a language is *code*, not data** (contrast the `lsp` section,
  MANUAL:937-940, 996+): vendor the grammar's C under
  `components/repomap/csrc/<lang>/`, add it to the `{.compile.}` list
  (`ts.nim:19-45`) and to `REPOMAP_CSRC` (`Makefile:158-167`), drop a
  `<lang>-tags.scm` in `queries/`, and add two `case ext` lines in
  `tags.nim:57-78` (or a new `extractTags` branch for a native tier,
  `tags.nim:223-233`). `tags.nim:3-4` calls this the provider seam — one
  grammar + one query + one registry line — but it is still a component edit,
  so per AGENTS.md it is a plugin/provider seam rather than a config entry.
- **Build**: `manifest.yaml:165-170` — Nim, `autostart: true`,
  `required: false`, `restart: on-failure` (so a full boot spawns it;
  `--minimal` does not).

## 4. MANUAL placement

- The component has **no section of its own**; it appears only in the shipped
  table (MANUAL:56), the `var/` inventory (MANUAL:244), a repo-markers
  sentence (MANUAL:251-253) and the env table (MANUAL:342-346), plus one
  incidental mention in the `lsp` warmup paragraph (MANUAL:986).
- Proposed heading: `## Repository map (\`repomap\`)`, inserted between the
  `lsp` section and `## Background processes (\`processes\`)` — i.e. after
  MANUAL:1030 ("Set `NIF_LSP_REGISTRY` …", the last lsp line) and before
  MANUAL:1033 (`## Background processes`). Add `· [Repository map (\`repomap\`)](#repository-map-repomap)`
  to the TOC line 22 next to the lsp entry.
- Suggested subsections mirroring the `lsp` section: **Status** (one line:
  optional Nim component, append off by default) — **The tool** (the param
  table from §2 + the discover-only/read-effect/approval-free note) — **The
  auto-append** (opt-in, `ev.workspace.opened` → `svc.session.<id>.map` →
  one user-role entry, why it ships off, pointer to bench reports) — **The
  gates** (the four env vars, append-only scope, the `repo map withheld`
  log line, pointer to REPOMAP-GATES.md) — **Language coverage** (tier list +
  the three-step add-a-language recipe) — **Cache and determinism**
  (`var/repomap-tags/`, mtime-keyed tags, byte-identical maps).
- **Do not restate what the research docs own.** `docs/research/REPOMAP.md`
  owns the algorithm and the port plan (`:42 "The algorithm, stage by stage"`,
  `:88 "Niffler port analysis"`, `:191 "Port plan"`);
  `docs/research/REPOMAP-GATES.md` owns why gates are needed, the threshold
  derivation (`:47`, `:101`), what they do not solve (`:134`), the
  implementation sketch (`:156`) and the verification plan/open questions
  (`:190`, `:207`); `bench/reports/repomap-ab-*.md` +
  `repomap-gates-full30.md` own the A/B numbers and the 30/30-withheld
  verification. MANUAL should point (`docs/research/REPOMAP.md`,
  `docs/research/REPOMAP-GATES.md`) and keep only user-facing behaviour.

## 5. DELTA list

- MANUAL:396 (`ev.session.context …` is the last line of the bus block,
  MANUAL:389-405) | CODE: `core/conversation.nim:2839-2846` (`mapSubject`),
  `:2388` (`ev.workspace.opened` publish), `components/repomap/main.nim:303-306`
  | FIX: add two lines to the subject block:
  `svc.session.<id>.map   repomap → runner: the workspace map to append once`
  and `ev.workspace.opened {workspace, conversationId} core → components:
  a conversation's workspace, for pre-warm and the repo-map append`.
- MANUAL:342-346 (env rows) | CODE: `main.nim:19, 42-43, 282-284` — the row
  for `NIF_REPOMAP_AUTOAPPEND` says the tool is unaffected, but the four
  `MIN_*` rows never say the gates are append-only | FIX: append to each of
  the four rows: "append-only; `repo_map` is never gated — a small map is a
  fine answer to an explicit question." (same sentence for all four, so add
  once as a lead-in sentence above the block).
- MANUAL:244 (`var/repomap-tags/` map cache) | CODE: `main.nim:40, 72-96` —
  the directory holds a per-file **tags** cache (`{mtime, tags}` JSON named by
  the sha1 of the absolute path), not rendered maps | FIX: "`repomap-tags/`
  per-file tree-sitter/Nim tags cache (mtime-keyed; empty results are never
  cached)".
- MANUAL:251-253 ("The repomap, lsp and skills components additionally treat
  `config.nims`, `tsconfig.json`, `package.json` and `go.mod` as repo
  *markers* (where to walk from)") | CODE: `main.nim:121-147` — repomap never
  uses markers as walk roots; its census walks the whole workspace and these
  files ride along as **bare map entries** (`main.nim:142-144`) | FIX: split
  the sentence — keep markers for lsp/skills and say repomap "lists marker
  files (`Makefile`, `package.json`, `go.mod`, …) as bare entries in the
  map".
- MANUAL:56 (shipped table row) | CODE: `main.nim:244-263` — the row lists the
  param names only and omits the language tiers and the tool's defaults |
  FIX: keep the row, but move detail to the proposed section and make the row
  end with "see [Repository map](#repository-map-repomap)"; there, state the
  default budget (1024 tokens, max 4096, `main.nim:34-36, 217-218`) and that
  the tool is discover-only, read-effect and approval-free.
- MANUAL: absent (no language-coverage statement anywhere) | CODE:
  `tags.nim:57-78, 224-233`, `main.nim:121-141` | FIX (in the proposed
  section): "Tag coverage is two tiers: tree-sitter for Go, Python,
  TypeScript, JavaScript, C, C++, Rust and Ruby (grammars vendored under
  `components/repomap/csrc/`, queries in `components/repomap/queries/`), and a
  native Nim tagger for `.nim`/`.nims` because the Nim grammar's generated
  parser is 40 MB. Unlisted extensions contribute no symbols."
- MANUAL:996-1031 (`### How the user adds a language`, lsp) | CODE:
  `tags.nim:3-4, 57-78, 223-233`, `ts.nim:19-45`, `Makefile:158-167` — the
  MANUAL's "adding a language is a config entry, never code" promise is true
  for lsp, but a repomap language needs a vendored grammar and component edits
  | FIX (proposed section): "Adding a language to the map is a component
  change, not a config entry: vendor the grammar's C under `csrc/`, register
  it in `ts.nim`'s `{.compile.}` list and `REPOMAP_CSRC`, add
  `queries/<lang>-tags.scm`, and add its extensions to `tags.nim`. The tier
  list is the seam's current limit, not a policy."
- MANUAL:1471-1474 ("Search and inspection: `files` …, the git tools,
  `undo_last_edit`, and the observe/logfile diagnostics") | CODE:
  `main.nim:262` (`onDemand: true`) — `repo_map` is not named in the shipped
  on-demand policy | FIX: add "`repo_map` (the ranked workspace map)" to that
  bullet.
- MANUAL:1314-1326 (`doctor` deep-probe paragraph names only lsp and store) |
  CODE: `main.nim:311-357` (`selfTest`: tiny workspace must fail both gates, a
  padded one must pass) | FIX: add a clause — "the repomap deep check maps a
  throwaway workspace and asserts both append gates fire".
- MANUAL:2199-2205 (`make test` target list) | CODE: `Makefile:515-516`
  (`test-repomap` builds and runs `t_repomap_tags`, `t_repomap_score`,
  `t_repomap`), `tests/t_repomap*.nim` | FIX: add `test-repomap` to the list.
- MANUAL:373 (".env.example in the repo root is the complete reference: every
  `NIF_*` variable") | CODE/CFG: `.env.example:227` carries only
  `#NIF_REPOMAP_AUTOAPPEND=1`; the four `NIF_REPOMAP_MIN_*` knobs
  (`main.nim:178, 184-186`) are absent | FIX: either add the four commented
  lines to `.env.example` or soften MANUAL:373 to "the reference copy of the
  documented variables".
- MANUAL: absent (nothing documents what the append actually injects) | CODE:
  `core/conversation.nim:959-978` | FIX (proposed section): "The appended
  entry is one user-role message: a short preamble naming the workspace and
  warning it is a snapshot, then the map. It is appended once per
  conversation, stays in history (compaction may trim it — `repo_map`
  re-creates it), and emits `ev.session.map {sessionId, workspace, bytes}`."
- MANUAL: absent (nothing documents `focus`/`mentionedIdents` semantics beyond
  the schema) | CODE: `main.nim:247-250`, `score.nim:89-91, 104-118` | FIX
  (proposed section, one sentence): "`focus` ranks the graph around the files
  you are editing — and drops their own definitions, since you already have
  them — while `mentionedIdents` boosts files whose path or definitions match
  the symbols the task names."
- MANUAL: absent (nothing documents the census exclusions/caps) | CODE:
  `main.nim:36-37, 66-70, 115-147` | FIX (proposed section, one sentence):
  "The map never walks `docs/`, `var/`, `.git`, `node_modules`, build outputs
  and the other junk directories, and stops at 5000 files or 5 s — a
  docs-only or tiny workspace therefore maps to nothing (the append logs it).
  "
- MANUAL: absent; CODE defect, not a doc gap: `main.nim:38`
  (`BUILD_TIMEOUT_MS = 90_000  # per-build cap inside the tool's 120s`) — the
  constant is never used (`grep -n BUILD_TIMEOUT_MS components/repomap/*.nim`
  → the definition only) and the schema timeout is 300 000 ms
  (`main.nim:262`) | FIX: drop the dead constant (or wire it) and correct the
  comment — else the MANUAL would document a 120 s cap that does not exist.
- MANUAL: absent; CODE defect: `main.nim:113` (census doc comment) and
  `main.nim:232-234` (the "No map" answer) both say the tiers cover only
  `.nim/.nims/.go/.py/.ts`, while the code covers 14 tree-sitter extensions
  plus Nim (`tags.nim:224-233`, `main.nim:124-141`) | FIX: update both strings
  to "tree-sitter (Go, Python, TS/JS, C/C++, Rust, Ruby) + native Nim" before
  the MANUAL quotes a language list.

## 6. Not user-facing

The tool *doc comment* itself (`main.nim:253-256`) is the model's only
window and is accurate — no MANUAL rewrite needed for it. Internals that the
MANUAL should not carry: the C ABI wrapper (`ts.nim`), the scoring port
(`score.nim:58-92` — alpha 0.85, 1e-8, ≤100 iterations, aider's x10
snake/Camel weight), the renderer's binary-searched token budget
(`repomap.nim:65-105`, chars/4 estimate) and the `csrc/` vendoring. These are
`docs/research/REPOMAP.md`'s subject. The component's own `/doctor` deep
self-test (`main.nim:311-357`) is user-visible only through the `doctor`
report and needs at most the one clause in DELTA #10.

## Verification notes

- I could not find any MANUAL statement contradicting the **env defaults**:
  `50 / 800 / 25 / 5` at MANUAL:343-346 match `main.nim:178, 184-186`, and
  `NIF_REPOMAP_AUTOAPPEND` unset/off matches `main.nim:287`.
- I did not run `make test-repomap` (read-only audit); the claims above come
  from source, `Makefile` and `manifest.yaml` only.
- Findings count: 17 DELTA entries (15 doc deltas, 2 code-side defects that
  would otherwise be mis-documented).
