# Audit — `components/grep/` (Nim, `main.nim`, 131 lines, component v0.1.0)

Scope: `components/grep/main.nim` (the only file in the dir — no README, no
`niffler.json`), `manifest.yaml:116-123`, `sdk/niffler/procutil.nim:70-187`,
`tests/t_grep.nim`, and the current `docs/MANUAL.md` (2850 lines) — coverage
checked with `grep -n 'grep\|ripgrep'` (rows 76, 722, 1907, 1912, 2795).
Read-only audit: no builds, no source or MANUAL edits. Facts about rg's own
output were re-verified by running the exact argv the component builds.

## 1. What it offers

- Two tools over one ripgrep backend: `grep` (contents) and `files`
  (sorted listing) — the component header states this pairing and why it
  exists alongside `bash` (`main.nim:1-11`), component name/version
  `grep 0.1.0` (`main.nim:16`).
- No shell anywhere: the pattern is one argv element after a `--` separator, and
  `runArgv` `quoteShell`s every element (`main.nim:32`, `:74-96`;
  `sdk/niffler/procutil.nim:136-144`), so quotes/backslashes/spaces need no
  escaping by the model. This is the component's stated reliability win over
  `bash grep -rn` (`main.nim:7-10`).
- Ignore semantics: `--no-require-git` (works outside a repo), `.gitignore`
  still applies, hidden/binary skipped by default (`-I` skips binary files),
  `hidden: true` adds `--hidden` (`main.nim:74-77`, `:104-110`). A positive `-g`
  glob is paired with `-g '!.*'` because rg's gitignore-style glob matching
  would otherwise let `*.nim` match `.hidden.nim` (`main.nim:80-86`, `:110-117`)
  — verified by reading rg's behaviour, not just the comment.
- Glob semantics: the component chdirs into the search root and passes the root
  absolutely, so a slash-glob (`dir/file.py`) is matched relative to `path`
  instead of rg's cwd, and results stay absolute
  (`main.nim:88-96`, `:118-124`; regression-tested at `tests/t_grep.nim:76-90`).
  I re-ran the exact argv: with an absolute root rg prints absolute
  `path:line:match` / `path` lines.
- Two output bounders, both with narrowing hints: `capLines` (per-tool line cap
  derived from `max_results`) and `capBytes` (32 KB head+tail,
  `main.nim:18-22`, `:45-50`; `sdk/niffler/procutil.nim:153-187`).
- `--max-columns 300`: a single line longer than 300 columns is printed by rg as
  `path:line:[Omitted long matching line]` (verified by running the argv) — a
  third, silent truncation the MANUAL never mentions.
- Stateless queue-group replicas: `replicas: 4` with the rationale in the
  manifest comment (`manifest.yaml:116-123`); nothing in `main.nim` holds
  process-local state (`grep -c 'var ' components/grep/main.nim` → the only
  mutable state is the per-call locals inside the two handlers).
- Missing rg is a first-class, non-fatal outcome: exit 127 with an apt install
  hint and a `bash` fallback suggestion (`main.nim:26-31`, `:43-44`).

## 2. Tools

| Tool | Registered at | Purpose (doc-comment text) | `x-harness` flags verbatim | Exposure |
|---|---|---|---|---|
| `grep` | `main.nim:52-98` | "Search file contents with ripgrep (path:line:match). Prefer it over bash grep: the pattern is an argument (no shell escaping), it skips gitignored/hidden/binary files, and globs narrow without un-hiding. Rust regex, no lookarounds (use bash grep -P for those). Narrow with path/glob — broad patterns are capped (max_results lines, 32KB)." (`main.nim:59-63`) | `{"timeoutMs": 60000, "parallel": true, "workspace": {"pathFields": ["path"], "defaultPathFields": ["path"]}}` (`main.nim:52-54`) — **no** `approval`, **no** `onDemand`, **no** `hidden`, **no** `effect` | **direct** (frozen toolset; MANUAL:1907) |
| `files` | `main.nim:100-125` | "List repo files sorted, one path per line — survey before searching or editing. Respects .gitignore; hidden only with hidden: true." (`main.nim:105-107`) | `{"timeoutMs": 60000, "onDemand": true, "workspace": {"pathFields": ["path"], "defaultPathFields": ["path"]}}` (`main.nim:100-102`) — **no** `approval`, **no** `hidden`, **no** `parallel`, **no** `effect` | discover-only (`discover` + `invoke`) |

Parameters, defaults and clamps (all from the code, not the prose):

- `grep {pattern, path=".", glob="", context=0, case_insensitive=false, hidden=false, max_results=200, timeoutMs=30000}`
  (`main.nim:55-58`). `path` empty/`.` is rewritten by core to the conversation
  workspace (`defaultPathFields`, `core/dispatch.nim:1482-1489`); a *relative*
  non-empty `path` is resolved against the workspace too
  (`core/dispatch.nim:1476-1481`). Direct (non-session) calls use the component
  cwd, which is `NIF_ROOT` (`core/supervisor.nim` sets `workingDir`).
- `context` clamped to ≤50 (`main.nim:78-79`); `max_results` clamped to
  1..10 000 (`main.nim:98`) although the parameter doc says "default 200, max
  10000" (`main.nim:72`).
- `timeoutMs` is clamped to 1 000..120 000 (`main.nim:96`) while the tool's
  schema declares `"timeoutMs": 60000` (`main.nim:52`). Core enforces the
  schema value as the call deadline (`core/dispatch.nim:1638-1645`), so any
  `timeoutMs` above 60 000 is unreachable in practice — a code-side
  inconsistency (see delta 6).
- `files {path=".", glob="", hidden=false, max_results=500, timeoutMs=30000}` —
  `max_results` clamped 1..10 000 (`main.nim:103-104`, `:125`); doc says "Cap
  (default 500, max 10000)" (`main.nim:109`).
- Result shape (both tools): `{"exit_code": int, "text": string}`; `text` starts
  with `(exit N)`, `(exit 124 — timed out)` or `(exit 127 — ripgrep not
  installed)` and then the capped output, which is `[no matches]` for an empty
  exit-1 result (`main.nim:34-50`) and `[no files]` for an empty exit-0 `files`
  result (`main.nim:119-120`).
- Exit-code contract: 0 match, 1 none, 2 rg error (e.g. bad regex — asserted at
  `tests/t_grep.nim:105-108`), 124 timeout, 127 rg missing.

## 3. Configuration

**Env vars: none — the component reads no `NIF_*` variable.** The only
environment it depends on is `PATH`, through `findExe("rg")`
(`main.nim:26`); the harness root/workspace is applied *to* the arguments by
core's `x-harness.workspace` rewriting, the component itself never reads
`NIF_ROOT` (no `getEnv` call at all: `grep -c getEnv components/grep/main.nim` → 0).
So no MANUAL environment-table row is owed, and the table is correct in not
having one.

Manifest entry (`manifest.yaml:116-123`): `build {lang: nim, src:
components/grep/main.nim}`, `binary: var/bin/grep`, `autostart: true`,
`required: false`, `restart: on-failure`, `replicas: 4` — the manifest's own
comment is the only statement of *why* (`"Stateless: queue-group replicas let
parallel grep/files calls execute concurrently while every SDK process remains
simple and serial."`).

Host dependency: ripgrep must be on `PATH`; `make setup`/`make doctor` are the
documented places that check it (see `docs/MANUAL.md` Troubleshooting).

## 4. How `docs/MANUAL.md` covers it today

There is **no `## Grep` chapter** — no section heading in MANUAL mentions this
component (`grep -n '^#.*[Gg]rep' docs/MANUAL.md` → nothing). Coverage is four
scattered mentions:

1. Shipped-components table, MANUAL:76 (exact quote):

   > `| `grep` | Nim | optional (4 replicas) | ripgrep-backed search: `grep` (contents, path:line:match, direct, output capped) and `files` (sorted listing, on demand); .gitignore-aware, no shell quoting needed; stateless queue-group replicas overlap same-component searches |`

   Accurate as far as it goes: `grep` is direct, `files` is on demand,
   `.gitignore` is respected, no shell quoting is needed, and the replica count
   matches `manifest.yaml:123`. It does not name the params, caps or exit codes.
2. MANUAL:722 (workspace bullet, exact quote):

   > `at dispatch: bash runs with `cwd` set to the workspace, edit/grep/read
   > resolve relative paths there, and git tools scope at the workspace repo.`

   Correct: `grep`/`files` declare `pathFields` + `defaultPathFields`
   (`main.nim:52-54`, `:100-102`; `core/dispatch.nim:1476-1489`).
3. MANUAL:1905-1908 (shipped policy, exact quote):

   > `- Routine work: `bash`, `grep`, and the file tools
   >   `read`/`edit`/`write` (the `edit` component).`

   Correct (7 direct tools; `grep` is one).
4. MANUAL:1911-1912 (shipped policy, exact quote):

   > `- Search and inspection: `files` (sorted listing), the git
   >   tools, `undo_last_edit`, `repo_map` ...`

   Correct.

Undocumented in MANUAL (explicit list): the `grep`/`files` parameters and their
defaults/clamps; the 32 KB byte cap and the line-cap marker text; the
`--max-columns 300` per-line omission; the exit-code table (0/1/2/124/127) and
the `[no matches]` / `[no files]` markers; the rg-missing hint; the
`timeoutMs` 60 s schema ceiling vs 120 s parameter clamp; that results are
absolute paths; that `files` is not `parallel`; and — the one place MANUAL has a
standing convention — that neither tool declares `x-harness.effect`, so the
fabric batch host classifies both as **writes** (stated for `bash` at MANUAL:129
and for `fetch` at MANUAL:1222, absent here). `docs/WIRE.md` never mentions this
component (`grep -rn grep docs/WIRE.md` → nothing).

Proposed home: a new `## Search (``grep``)` chapter directly **before**
`## Language servers (``lsp``)` (currently MANUAL:1225, i.e. after `## Fetch`,
which ends at MANUAL:1224), plus a `Contents` bullet. It should mirror the
`git` chapter's shape: "The tools" (the §2 table), "Bounds and exit codes",
"Ignore and glob semantics", "Not a shell". Suggested new chapter text:

> `## Search (`grep`)`
>
> `ripgrep-backed search, two tools. `grep` is direct (it is the routine search
> path alongside `bash`); `files` is on demand. Both run rg as a fixed argv —
> the pattern is an argument after `--`, never interpolated into a shell — so
> quotes, backslashes and spaces need no escaping. rg resolves via `PATH`; when
> it is missing both tools return exit 127 with an install hint`.gitignore` and
> hidden/binary files are skipped by default; `hidden: true` adds hidden files
> while `.gitignore` still applies, and a `glob` narrows without un-hiding.
> `path` is workspace-relative at dispatch (`.` = the conversation workspace,
> else the harness root). `grep {pattern, path?, glob?, context? ≤50,
> case_insensitive?, hidden?, max_results? 200 (max 10000), timeoutMs?}`
> returns `path:line:match` lines; `files {path?, glob?, hidden?,
> max_results? 500 (max 10000)}` returns sorted paths. Both cap output at
> `max_results` lines (marker `[... N more result lines — raise max_results or
> narrow pattern/path/glob ...]`) and at 32 KB head+tail, and rg truncates any
> single line longer than 300 columns to `[Omitted long matching line]`.
> `exit_code` is the contract: 0 match, 1 none (`[no matches]`/`[no files]`),
> 2 bad regex, 124 timeout, 127 rg missing. Neither tool declares
> `x-harness.effect`, so the fabric batch host schedules both as writes; `grep`
> declares `parallel: true`, `files` does not. Both are read-only and carry no
> approval gate. Four stateless manifest replicas serve them through one queue
> group, so concurrent searches overlap.`

## 5. DELTA list (classed)

Findings against the current tree; each is expanded into the machine-parsed row
list in §6.

1. **[missing] No chapter for the two tools.** Params, caps, markers, exit codes
   and the rg dependency live only in doc comments (`main.nim:1-11`, `:34-50`,
   `:59-73`, `:105-113`); MANUAL coverage is one table row (76) plus three
   passing mentions (722, 1907, 1912). Fix: the chapter proposed in §4.
2. **[missing] Output bounds.** `maxOutputBytes = 32_000` head+tail
   (`main.nim:18`, `:45-50`; `sdk/niffler/procutil.nim:153-165`), the per-tool
   line cap with its exact marker (`sdk/niffler/procutil.nim:167-187`, asserted
   at `tests/t_grep.nim:113-116`), and rg's `--max-columns 300`
   (`main.nim:75`, verified live: `path:line:[Omitted long matching line]`).
   MANUAL:76 says only "output capped".
3. **[missing] Exit-code contract and empty-result markers.** 0/1/2/124/127
   (`main.nim:35-36`, `:42-44`), `[no matches]` (`:40-41`), `[no files]`
   (`:119-120`), `(exit 124 — timed out)`, `(exit 127 — ripgrep not installed)`;
   the 127 path also prints the "ripgrep is not installed … or fall back to
   bash: grep -rn" hint (`main.nim:26-31`). Nothing in the MANUAL.
4. **[missing] Parameter clamps and defaults.** `context` ≤50 (`main.nim:79`),
   `max_results` 200/500 defaults and the 10 000 ceiling (`main.nim:57`, `:98`,
   `:104`, `:125`), `timeoutMs` (`main.nim:96`). MANUAL names no parameter.
5. **[missing] Absolute result paths.** When `path` is a directory the component
   chdirs into it and passes it absolutely, so output lines are absolute
   (`main.nim:88-96`; re-verified by running the argv). Only the doc comment's
   glob note mentions it (`main.nim:91-92`).
6. **[code-bug?] `timeoutMs` parameter can exceed the tool's own deadline.**
   The schema declares `"timeoutMs": 60000` (`main.nim:52`, `:100`) and core
   enforces it as the call deadline (`core/dispatch.nim:1638-1645`), yet the
   `grep` parameter is clamped up to 120 000 (`main.nim:96`) and documented as
   "Kill after this many ms (default 30000)" (`main.nim:73`). Either clamp the
   parameter at 60 000 or raise the schema value; the MANUAL should state the
   effective ceiling.
7. **[delta] `files` declares no `parallel`.** `grep` has `"parallel": true`
   (`main.nim:52`) but `files` (`main.nim:100`) does not, so batching an
   `invoke` of `files` with other parallel tools serializes it. Worth one clause
   in the chapter (the MANUAL documents parallel scheduling for lsp/plugins at
   MANUAL:845).
8. **[delta] Neither tool declares `x-harness.effect`.** Fabric classifies
   anything undeclared as `"write"` and schedules it exclusively
   (`components/fabric/fabric.nim:226-228`, `:309`, `:327`) even though both are
   read-only. The MANUAL states this consequence for `bash` (129) and `fetch`
   (1222) but not for grep. Either add `"effect": "read"` (code) or one sentence
   (doc) — the MANUAL row below proposes the sentence, matching house style.
9. **[missing] rg is a host dependency.** `findExe("rg")` + the 127 path
   (`main.nim:26-31`). Troubleshooting/MANUAL never mentions installing
   ripgrep; `make setup`/`make doctor` cover it only as script behaviour.
10. **[doc-edit] `binary: var/bin/grep` is not on `PATH`.** MANUAL:2795 explains
    that `make install` never puts component binaries on `PATH` "so PATH cannot
    shadow grep/git/..." — the sentence reads as if `grep` were a system binary
    name collision; it is the component binary that is withheld. Not a defect,
    but the pairing (component `grep` vs host `grep`/`rg`) deserves one clause
    in the new chapter ("the tool is `var/bin/grep`; it shells out to `rg`,
    never to `grep`").
11. **[verified] MANUAL:76 is factually right.** Direct `grep`, on-demand
    `files`, `.gitignore`-aware, no shell quoting, 4 replicas — all re-checked
    against `main.nim:52`, `:100` and `manifest.yaml:123`. The row needs
    *extension*, not correction.
12. **[verified] MANUAL leaves grep out of the approval list.** Neither schema
    carries `x-harness.approval` (`main.nim:52-54`, `:100-102`) — matching the
    approvals chapter's list, which names no grep tool.
13. **[missing] Tests.** `tests/t_grep.nim` (149 lines) and `make test-grep`
    (`Makefile:524`) exist; the MANUAL Verification subsections name only
    `t_observe`/`t_logfile` (2441, 2447) and the Testing section keeps a
    hand-written target list. One clause in the new chapter's Verification note
    is enough.

## 6. Machine-parsed rows

### Shipped components

- MANUAL: "| `grep` | Nim | optional (4 replicas) | ripgrep-backed search: `grep` (contents, path:line:match, direct, output capped) and `files` (sorted listing, on demand); .gitignore-aware, no shell quoting needed; stateless queue-group replicas overlap same-component searches |" | CODE: components/grep/main.nim:52,100; manifest.yaml:116-123 | FIX: update — append "; params, caps, exit codes and the effect classification are in [Search (`grep`)](#search-grep). Neither tool declares `x-harness.effect`, so the fabric batch host schedules both as writes"
- MANUAL: "| `grep` | Nim | optional (4 replicas) | ripgrep-backed search: `grep` (contents, path:line:match, direct, output capped) and `files` (sorted listing, on demand); .gitignore-aware, no shell quoting needed; stateless queue-group replicas overlap same-component searches |" | CODE: components/grep/main.nim:26-31,35-44,119-120 | FIX: add a sentence naming the ripgrep host dependency: "rg resolves through PATH; when it is missing both tools return exit 127 with an install hint"

### Layout of a running system

- MANUAL: absent | CODE: components/grep/main.nim:1-131 | FIX: add a `## Search (\`grep\`)` chapter before `## Language servers (\`lsp\`)` (MANUAL:1225) with the text proposed in §4 of this report (tools table, parameter clamps, 32 KB/line caps, `--max-columns 300`, exit-code contract, ignore/glob semantics, absolute paths, effect/parallel flags, 4 replicas)
- MANUAL: "- [Language servers (`lsp`)](#language-servers-lsp) · [Repository inspection (`git`)](#repository-inspection-git) · [Background processes (`processes`)](#background-processes-processes)" | CODE: docs/MANUAL.md:20 | FIX: add a Contents bullet "- [Search (`grep`)](#search-grep)" directly after the `Fetch` bullet on the previous line

### Context window

- MANUAL: "at dispatch: bash runs with `cwd` set to the workspace, edit/grep/read\n  resolve relative paths there, and git tools scope at the workspace repo." | CODE: components/grep/main.nim:52-54,100-102; core/dispatch.nim:1476-1489 | FIX: none — verified: `grep`/`files` declare `workspace {pathFields: ["path"], defaultPathFields: ["path"]}`, so `.`/empty/relative `path` resolves at the conversation workspace

### Environment variables

- MANUAL: absent | CODE: components/grep/main.nim (no `getEnv`; only `findExe("rg")` at :26) | FIX: none — verified: no `NIF_*` variable is read, so the table owes no row

### Progressive tool discovery (`discover`/`invoke`)

- MANUAL: "- Routine work: `bash`, `grep`, and the file tools\n  `read`/`edit`/`write` (the `edit` component)." | CODE: components/grep/main.nim:52 (no onDemand) | FIX: none — verified: `grep` is a direct tool
- MANUAL: "- Search and inspection: `files` (sorted listing), the git\n  tools, `undo_last_edit`, `repo_map` (the ranked workspace map the model\n  asks for explicitly), and the observe/logfile diagnostics." | CODE: components/grep/main.nim:100 (`onDemand: true`) | FIX: none — verified: `files` is discover-only
- MANUAL: "server-side choice is independent of the runner-facing `x-harness.parallel`\nhint." | CODE: components/grep/main.nim:52 (`parallel: true`), :100 (absent) | FIX: add one clause to the new Search chapter: "`grep` declares `parallel: true`; `files` does not, so a batched `files` call serializes against other parallel tools"

### Approvals

- MANUAL: absent (no grep tool in the approval list) | CODE: components/grep/main.nim:52-54,100-102 | FIX: none — verified: neither tool declares `x-harness.approval`, and both are read-only

### Common tasks

- MANUAL: "                    # binaries, so PATH cannot shadow grep/git/...)" | CODE: manifest.yaml:117-118 (`binary: var/bin/grep`), components/grep/main.nim:26-32 | FIX: add a clause in the new Search chapter: "the tool binary is `var/bin/grep`; it shells out to `rg`, never to the host `grep`"

### Testing

- MANUAL: "`/doctor deep` additionally fans out to each component's own self test over\nthe bus (`comp.selfTest`): `bash`, for example, really execs a command through\nits process-group path and then proves the timeout kill at a 1 s budget,\nexpecting exit 124." | CODE: tests/t_grep.nim:1-149, Makefile:524 (`test-grep`); `grep -c selftest components/grep/main.nim` → 0 | FIX: add to the new chapter's Verification note: "`tests/t_grep.nim` (`make test-grep`) covers matches, gitignore/hidden handling, globs, case folding, bad-regex exit 2, result caps and `files`; the component registers no `selftest`, so `/doctor deep` reports it as not implementing one"

### Observation and logs

- MANUAL: "All bounds are validated at startup; invalid configuration exits non-zero\nrather than silently substituting a default." | CODE: components/grep/main.nim (no config at all) | FIX: none — verified: no `NIF_*` bound exists for this component, so the sentence neither covers nor contradicts it

## 7. Not user-facing

- `runRg`/`finish` (private helpers `main.nim:24-50`) and the `capLines`/`capBytes`
  markers' exact byte arithmetic are SDK detail; only the marker *text* is
  user-visible.
- The fixed flag prefix (`--color never -n -I --with-filename --no-require-git
  --max-columns 300`) belongs in one sentence, not a table.
- `hookEnvFor`-style env mapping, `atomicWrite` and other SDK internals do not
  exist here.
- `clamp`ed parameter arithmetic (`max(1000, min(timeoutMs, 120_000))`) is
  implementation detail *except* for the dead 60–120 s range (delta 6).

**Finding count: 13** (1 code-vs-schema inconsistency to fix or document, 8
MANUAL gaps, 1 table-row extension, 3 verified-correct claims).
