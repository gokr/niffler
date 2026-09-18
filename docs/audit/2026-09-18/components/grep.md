# Audit — `components/grep/` (Nim, `main.nim`, 131 lines, component v0.1.0)

Scope: `components/grep/main.nim` (the only file in the dir — no README, no
`niffler.json`), `manifest.yaml:116-124`, `sdk/niffler/procutil.nim:70-187`,
`tests/t_grep.nim`, `Makefile:524` (`test-grep`), and `docs/MANUAL.md` —
coverage checked with `grep -n 'grep\|ripgrep'` (rows 76, 793, 1907-ish shipped
policy, 2795-ish PATH note). Read-only audit: no builds, no source or MANUAL
edits; the rg behaviour claims were re-verified by running the exact argv the
component builds.

> **Line-number drift:** the numbers below are `docs/MANUAL.md` as it stood
> while this report was written (2850 lines); the concurrent consolidation pass
> kept editing it (3072 lines by the end). The quotes are the durable anchor —
> every row's quote was re-verified against the file — so re-resolve a number by
> searching its quote, never by trusting the digit.

## 1. What it offers

- Two tools over one ripgrep backend: `grep` (contents) and `files`
  (sorted listing) — the component header states this pairing and why it
  exists alongside `bash` (`main.nim:1-11`), component name/version
  `grep 0.1.0` (`main.nim:16`).
- No shell anywhere: the pattern is one argv element after a `--` separator, and
  `runArgv` `quoteShell`s every element (`main.nim:32`, `:74-96`;
  `sdk/niffler/procutil.nim:135-144`), so quotes/backslashes/spaces need no
  escaping by the model. This is the component's stated reliability win over
  `bash grep -rn` (`main.nim:7-10`).
- Ignore semantics: `--no-require-git` (works outside a repo), `.gitignore`
  still applies, hidden files skipped by default, `-I` skips binary files,
  `hidden: true` adds `--hidden` (`main.nim:74-77`, `:104-119`). A positive `-g`
  glob is paired with `-g '!.*'` because rg's gitignore-style glob matching
  would otherwise let `*.nim` match `.hidden.nim` (`main.nim:80-86`, `:115-119`).
- Glob semantics: the component chdirs into the search root and passes the root
  absolutely, so a slash-glob (`dir/file.py`) is matched relative to `path`
  instead of rg's cwd, and results stay absolute (`main.nim:88-96`, `:120-124`;
  regression-tested at `tests/t_grep.nim:76-90`). Re-running the exact argv
  confirms absolute `path:line:match` lines.
- Two output bounders, both with narrowing hints: `capLines` (per-tool line cap
  derived from `max_results`) and `capBytes` (32 KB head+tail, `main.nim:18-22`,
  `:45-50`; `sdk/niffler/procutil.nim:153-187`).
- `--max-columns 300`: a single line longer than 300 columns is printed by rg as
  `path:line:[Omitted long matching line]` (reproduced by running the argv) — a
  third, silent truncation the MANUAL never mentions.
- Stateless queue-group replicas: `replicas: 4` (`manifest.yaml:124`) with the
  rationale in the manifest comment; nothing in `main.nim` holds process-local
  state (every `var` in the file is a local of `finish` at `main.nim:37`, `:42`
  or of one of the two handlers at `:74`, `:113`).
- Missing rg is a first-class, non-fatal outcome: exit 127 with an apt install
  hint and a `bash` fallback suggestion (`main.nim:26-31`, `:43-44`).

## 2. Tools

| Tool | Registered at | Purpose (doc-comment text) | `x-harness` flags verbatim | Exposure |
|---|---|---|---|---|
| `grep` | `main.nim:52-98` | "Search file contents with ripgrep (path:line:match). Prefer it over bash grep: the pattern is an argument (no shell escaping), it skips gitignored/hidden/binary files, and globs narrow without un-hiding. Rust regex, no lookarounds (use bash grep -P for those). Narrow with path/glob — broad patterns are capped (max_results lines, 32KB)." (`main.nim:59-63`) | `{"timeoutMs": 60000, "parallel": true, "workspace": {"pathFields": ["path"], "defaultPathFields": ["path"]}}` (`main.nim:52-54`) — **no** `approval`, **no** `onDemand`, **no** `hidden`, **no** `effect` | **direct** (frozen toolset) |
| `files` | `main.nim:100-129` | "List repo files sorted, one path per line — survey before searching or editing. Respects .gitignore; hidden only with hidden: true." (`main.nim:105-107`) | `{"timeoutMs": 60000, "onDemand": true, "workspace": {"pathFields": ["path"], "defaultPathFields": ["path"]}}` (`main.nim:100-102`) — **no** `approval`, **no** `hidden`, **no** `parallel`, **no** `effect` | discover-only (`discover` + `invoke`) |

Parameters, defaults and clamps (from the code, not the prose):

- `grep {pattern, path=".", glob="", context=0, case_insensitive=false, hidden=false, max_results=200, timeoutMs=30000}`
  (`main.nim:55-58`). `path` empty/`.` is rewritten by core to the conversation
  workspace (`defaultPathFields`, `core/dispatch.nim:1482-1489`); a *relative*
  non-empty `path` is resolved against the workspace too
  (`core/dispatch.nim:1476-1481`). A direct (non-session) call uses the component
  cwd, which is `NIF_ROOT` (`core/supervisor.nim:160`).
- `context` clamped to ≤50 (`main.nim:78-79`); `max_results` clamped to
  1..10 000 (`main.nim:98`, `:129`) although the parameter docs say "default 200,
  max 10000" (`main.nim:72`) and "default 500, max 10000" (`main.nim:111`).
- `timeoutMs` is clamped to 1 000..120 000 (`main.nim:96`, `:125`) while the
  tool's schema declares `"timeoutMs": 60000` (`main.nim:52`, `:100`). Core
  enforces the schema value as the call deadline
  (`core/dispatch.nim:1638-1645`), so any `timeoutMs` above 60 000 is
  unreachable in practice.
- Result shape (both tools): `{"exit_code": int, "text": string}`; `text` starts
  with `(exit N)`, `(exit 124 — timed out)` or `(exit 127 — ripgrep not
  installed)` and then the capped output, which is `[no matches]` for an empty
  exit-1 result (`main.nim:34-50`) and `[no files]` for an empty exit-0 `files`
  result (`main.nim:127-128`).
- Exit-code contract: 0 match, 1 none, 2 rg error (e.g. bad regex — asserted at
  `tests/t_grep.nim:105-108`), 124 timeout, 127 rg missing.

## 3. Configuration

**Env vars: none — the component reads no `NIF_*` variable.** The only
environment it depends on is `PATH`, through `findExe("rg")` (`main.nim:26`); the
harness root/workspace is applied *to* the arguments by core's
`x-harness.workspace` rewriting, and the component itself calls no `getEnv` at
all (`grep -c getEnv components/grep/main.nim` → 0). So no MANUAL
environment-table row is owed, and the table is correct in not having one.

Manifest entry (`manifest.yaml:116-124`): `build {lang: nim, src:
components/grep/main.nim}`, `binary: var/bin/grep`, `autostart: true`,
`required: false`, `restart: on-failure`, `replicas: 4` — the manifest's own
comment is the only statement of *why* ("Stateless: queue-group replicas let
parallel grep/files calls execute concurrently while every SDK process remains
simple and serial").

Host dependency: ripgrep must be on `PATH`; `make setup`/`make doctor` are the
scripted places that check it.

## 4. How `docs/MANUAL.md` covers it today

There is **no `## Grep` chapter** — no heading in MANUAL mentions this component
(`grep -n '^#.*[Gg]rep' docs/MANUAL.md` → nothing). Coverage is four scattered
mentions, quoted with the line numbers they had while this report was written
(the quotes themselves are the anchor and were re-verified):

- **MANUAL:76** — the shipped-components row:
  > `| `grep` | Nim | optional (4 replicas) | ripgrep-backed search: `grep` (contents, path:line:match, direct, output capped) and `files` (sorted listing, on demand); .gitignore-aware, no shell quoting needed; stateless queue-group replicas overlap same-component searches |`

  Accurate as far as it goes: `grep` is direct, `files` is on demand,
  `.gitignore` is respected, no shell quoting is needed, and the replica count
  matches `manifest.yaml:124`. It names no parameter, cap or exit code.
- **MANUAL:722** (workspace bullet, `## Context window`):
  > `at dispatch: bash runs with `cwd` set to the workspace, edit/grep/read
  > resolve relative paths there, and git tools scope at the workspace repo.`

  Correct: `grep`/`files` declare `pathFields` + `defaultPathFields`
  (`main.nim:52-54`, `:100-102`; `core/dispatch.nim:1476-1489`).
- **MANUAL:1905-1908** (shipped policy, `## Progressive tool discovery`):
  > `- Routine work: `bash`, `grep`, and the file tools
  >   `read`/`edit`/`write` (the `edit` component).`

  Correct (7 direct tools; `grep` is one).
- **MANUAL:1911-1912** (same section):
  > `- Search and inspection: `files` (sorted listing), the git
  >   tools, `undo_last_edit`, `repo_map` (the ranked workspace map the model
  >   asks for explicitly), and the observe/logfile diagnostics.`

  Correct; it is also the only place that says `files` is discover-only.

Undocumented in MANUAL (explicit list): the `grep`/`files` parameters and their
defaults/clamps; the 32 KB byte cap and the line-cap marker text; the
`--max-columns 300` per-line omission; the exit-code table (0/1/2/124/127) and
the `[no matches]` / `[no files]` markers; the rg-missing hint; the `timeoutMs`
60 s schema ceiling vs 120 s parameter clamp; that results are absolute paths;
that `files` is not `parallel`; and — the one place MANUAL has a standing
convention — that neither tool declares `x-harness.effect`, so the fabric batch
host classifies both as **writes** (stated for `bash` at MANUAL:129 and for
`fetch` at MANUAL:1222, absent here). `docs/WIRE.md` never mentions this
component (`grep -rn grep docs/WIRE.md` → nothing).

Proposed home: a new `## Search (``grep``)` chapter directly **before**
`## Language servers (``lsp``)` (MANUAL:1225 in the revision read), i.e. after
`## Fetch`, plus a `Contents` bullet. Suggested chapter text (the FIX wording in
§5 refers back to this):

> `ripgrep-backed search, two tools. `grep` is direct (the routine search path
> alongside `bash`); `files` is on demand. Both run rg as a fixed argv — the
> pattern is an argument after `--`, never interpolated into a shell — so quotes,
> backslashes and spaces need no escaping. rg resolves via `PATH`; when it is
> missing both tools return exit 127 with an install hint. `.gitignore` and
> hidden/binary files are skipped by default; `hidden: true` adds hidden files
> while `.gitignore` still applies, and a `glob` narrows without un-hiding.
> `path` is workspace-relative at dispatch (`.` = the conversation workspace,
> else the harness root). `grep {pattern, path?, glob?, context? ≤50,
> case_insensitive?, hidden?, max_results? 200 (max 10000), timeoutMs?}` returns
> `path:line:match` lines; `files {path?, glob?, hidden?, max_results? 500 (max
> 10000)}` returns sorted paths. Both cap output at `max_results` lines (marker
> `[... N more result lines — raise max_results or narrow pattern/path/glob ...]`)
> and at 32 KB head+tail, and rg truncates any single line longer than 300
> columns to `[Omitted long matching line]`. `exit_code` is the contract: 0 match,
> 1 none (`[no matches]`/`[no files]`), 2 bad regex, 124 timeout, 127 rg missing.
> Neither tool declares `x-harness.effect`, so the fabric batch host schedules
> both as writes; `grep` declares `parallel: true`, `files` does not. Both are
> read-only and carry no approval gate. Four stateless manifest replicas serve
> them through one queue group, so concurrent searches overlap.`

## 5. DELTA list

Rows below are the findings in the audit's machine-parsed shape, grouped by the
current MANUAL section they land in (`[class]` marks the ledger class; `FIX`
starts with the verb). Evidence and the proposed wording are in the row itself;
§1–§4 hold the long-form reasoning.

## Layout of a running system

- MANUAL: "| `grep` | Nim | optional (4 replicas) | ripgrep-backed search: `grep` (contents, path:line:match, direct, output capped) and `files` (sorted listing, on demand); .gitignore-aware, no shell quoting needed; stateless queue-group replicas overlap same-component searches |" | CODE: components/grep/main.nim:52,100; manifest.yaml:116-124 | FIX: update — [doc-edit] append "; params, caps, exit codes and the effect classification are in [Search (``grep``)](#search-grep)". The row is otherwise verified correct (direct `grep`, on-demand `files`, .gitignore-aware, 4 replicas), but it must gain the two facts a reader cannot derive from it: `grep` is the *direct* tool while `files` is discover-only, and neither declares `x-harness.effect`, so the fabric batch host schedules both as writes (`components/fabric/fabric.nim:226-228`, `:309`, `:327`) exactly as the MANUAL already warns for `bash` and `fetch`.
- MANUAL: absent | CODE: components/grep/main.nim:1-131; manifest.yaml:116-124 | FIX: add — [missing] a new chapter titled `Search (grep)` before the `Language servers (lsp)` chapter, with the text proposed in §4 of this report, plus a Contents bullet. It is the only place that can explain what `ripgrep-backed search` really costs: Nothing in the MANUAL documents the parameters and clamps (`main.nim:55-58`, `:96`, `:98`, `:103-104`, `:125`), the 32 KB head+tail byte cap (`main.nim:18`, `:45-50`; `sdk/niffler/procutil.nim:153-165`), the line-cap marker (`sdk/niffler/procutil.nim:167-187`; asserted at `tests/t_grep.nim:113-116`), rg's `--max-columns 300` omission (`main.nim:75`), the exit-code contract and empty-result markers (`main.nim:34-50`, `:127-128`), absolute result paths (`main.nim:88-96`) or the ignore/glob rules (`main.nim:80-86`, `:115-119`).
- MANUAL: absent | CODE: components/grep/main.nim:26-31,43-44 | FIX: add — [missing] one sentence in the `ripgrep-backed search` component row (or the new chapter): "rg resolves through `PATH`; when it is missing both tools answer exit 127 with an install hint and suggest falling back to `bash grep -rn`" — the component returns exactly that text (`main.nim:28-30`) and only `make setup`/`make doctor` install ripgrep today.

## Contents

- MANUAL: "- [Language servers (`lsp`)](#language-servers-lsp) · [Repository inspection (`git`)](#repository-inspection-git) · [Background processes (`processes`)](#background-processes-processes)" | CODE: docs/MANUAL.md:20 | FIX: add — [doc-edit] a bullet "- [Search (`grep`)](#search-grep)" directly after the `Fetch` bullet on the preceding contents line, so the new chapter is reachable from the table of contents like `Fetch` and `Language servers` are.

## Context window

- MANUAL: "at dispatch: bash runs with `cwd` set to the workspace, edit/grep/read" | CODE: components/grep/main.nim:52-54,100-102; core/dispatch.nim:1476-1489 | FIX: none — [verified] `grep`/`files` declare `workspace {pathFields: ["path"], defaultPathFields: ["path"]}`, so `.`/empty/relative `path` resolves at the conversation workspace exactly as the bullet says; the only nuance is that core's substitution happens for session-driven calls, while a direct `cli call grep grep` resolves against the component cwd (`core/supervisor.nim:160`), which the new chapter can state.

## Environment variables

- MANUAL: "All components load `.env` (from the harness root and cwd, existing shell" | CODE: components/grep/main.nim (no `getEnv`; only a `findExe("rg")` call at :26) | FIX: none — [verified] the master table owes this component no row: the component reads no NIF_* variable at all, so the `.env` resolution this sentence describes applies to it unchanged, and its only host dependency (PATH to rg) belongs in the new chapter rather than the table.

## Progressive tool discovery

- MANUAL: "- Routine work: `bash`, `grep`, and the file tools" | CODE: components/grep/main.nim:52 (no `onDemand`) | FIX: none — [verified] `grep` is a direct tool, so the bullet is right as written.
- MANUAL: "- Search and inspection: `files` (sorted listing), the git" | CODE: components/grep/main.nim:100 (`onDemand: true`) | FIX: none — [verified] `files` is discover-only; this bullet is the MANUAL's only statement of that fact.
- MANUAL: "- Search and inspection: `files` (sorted listing), the git" | CODE: components/grep/main.nim:52 (`parallel: true`), :100 (absent) | FIX: add — [delta] one clause next to `the observe/logfile diagnostics` bullet (or in the new chapter): "`grep` declares `parallel: true`, so a batched `grep` may run alongside other parallel tools; `files` does not, so an `invoke`d `files` serializes against them" (`core/dispatch.nim:1631-1654` is the runner-side gate).

## Approvals

- MANUAL: absent (no grep tool in the approval list) | CODE: components/grep/main.nim:52-54,100-102 | FIX: none — [verified] neither schema carries `x-harness.approval` and both tools are read-only, so the approvals chapter's list is correct to omit them; the shipped row should keep saying "approval-free" if it is ever expanded.

## Common tasks

- MANUAL: "                    # binaries, so PATH cannot shadow grep/git/...)" | CODE: manifest.yaml:117-118 (`binary: var/bin/grep`); components/grep/main.nim:26-32 | FIX: add — [doc-edit] one clause in the new chapter: "the tool binary is `var/bin/grep`; it shells out to `rg`, never to the host `grep`", because this MANUAL line reads as if a system `grep` binary were the thing being kept off `PATH`.

## Testing

- MANUAL: "`/doctor deep` additionally fans out to each component's own self test over" | CODE: tests/t_grep.nim:1-149; Makefile:524 (`test-grep`); `grep -c selftest components/grep/main.nim` → 0 | FIX: add — [missing] a Verification note in the new chapter: "`tests/t_grep.nim` (`make test-grep`) covers matches, gitignore/hidden handling, globs, case folding, bad-regex exit 2, result caps and the `files` tool; the component registers no `selftest`, so `/doctor deep` reports it as not implementing one."

Finding count for this component: 12 rows — 3 `doc-edit`, 3 `missing`, 1 `delta`, 5 `verified` (the component has no prose chapter at all, so the chapter row plus the four verified rows are what a consolidation pass should treat as the same finding: extend the row, write the chapter, leave the rest alone).

## 6. Not user-facing

- `runRg`/`finish` (private helpers `main.nim:24-50`) and the `capLines`/`capBytes`
  byte arithmetic are SDK detail; only the marker *text* is user-visible.
- The fixed flag prefix (`--color never -n -I --with-filename --no-require-git
  --max-columns 300`) belongs in one sentence, not a table.
- The parameter clamp arithmetic (`max(1000, min(timeoutMs, 120_000))`) is
  implementation detail *except* for the dead 60–120 s range, which the chapter
  should name once.
