# docs-audit: `components/git` (Nim)

Audit target: `/home/gokr/git/nifflerprod/components/git/main.nim` (439 lines, the only file
in the dir). Method: grep + windowed reads; every claim carries a `file:line` I read.
Read-only audit — no builds, no tests, no web.

## 1. What it offers

- Read-only git inspection as first-class, approval-free tools: `git_status`, `git_diff`,
  `git_log`, `git_show`, `git_blame` (`main.nim:1-6`, `:185-345`).
- Every subcommand runs as a fixed argv — never through a shell — via `runArgv`, scoped with
  `-C <repo>`; flags, refs and paths travel byte-for-byte (`main.nim:9-14`, `:101-104`,
  `:106-117`, `:158-161`).
- One write-side extra: `review_receipt` — a local diff-fingerprint write/check pair under
  `var/review-receipts/` for pre-push review handoff; it never calls a model
  (`main.nim:364-436`, `:347-350`).
- All six tools are `onDemand` → **discover-only** (reachable via `discover` + `invoke`):
  `main.nim:185-186`, `:215-216`, `:253-254`, `:290-291`, `:319-320`, `:364`;
  MANUAL:1268-1280.
- Git *mutations* are deliberately not here — they stay in bash, which is approval-gated
  (`main.nim:6-8`; `components/bash/main.nim:119`; MANUAL:457-470).
- Output is bounded twice — 40 000 bytes kept head+tail plus a per-tool line cap, each with a
  narrowing hint (`main.nim:99`, `:119-134`; `sdk/niffler/procutil.nim:153-178`).

## 2. Tools

| Tool | Purpose (doc comment) | `x-harness` flags | Exposure |
|---|---|---|---|
| `git_status` | Cheap repo-state check: current branch + one porcelain line per changed file (XY codes ` M`/`M `/`A`/`D`/`R`/`??`/`U`); untracked listed here, never in `git_diff` (`main.nim:188-202`) | `timeoutMs: 45000`, `parallel: true`, `onDemand: true`, `workspace: {cwdField: "repo"}` (`main.nim:185-186`) | discover-only |
| `git_diff` | Everything changed since HEAD, staged **and** unstaged (`git diff HEAD`); `stat: true` = compact one-line-per-file summary (`main.nim:219-233`) | same as above (`main.nim:215-216`) | discover-only |
| `git_log` | Recent history, one line per commit (`--oneline --decorate`), filterable by `path` and `author` substring (`main.nim:257-269`) | same (`main.nim:253-254`) | discover-only |
| `git_show` | One commit in full: metadata, message, complete diff, optional `path` scope (`main.nim:293-303`) | same (`main.nim:290-291`) | discover-only |
| `git_blame` | Line-by-line attribution (commit, author, content); uncommitted lines read `Not Committed Yet` (`main.nim:323-332`) | same (`main.nim:319-320`) | discover-only |
| `review_receipt` | `op: "write"` records SHA-256 of the working-tree diff + findings/model under `var/review-receipts/` and returns the receipt; `op: "check"` fails when the current diff's fingerprint differs from the newest receipt (`main.nim:366-377`) | `timeoutMs: 45000`, `onDemand: true` — **no** `parallel`, no `approval`, no `effect`, no `workspace` (`main.nim:364`) | discover-only |

Parameters (from the doc comments, defaults/clamps in code):

- `git_status {repo?, path?}` — `repo ""` = active conversation workspace, `path ""` = whole
  repo (`main.nim:187`, `:199-202`, `:209-213`).
- `git_diff {repo?, path?, unified?=3, stat?=false}` — `unified` clamped 0..50
  (`main.nim:217`, `:232-233`, `:241-244`).
- `git_log {repo?, path?, max_count?=20, author?}` — `max_count` clamped 1..200
  (`main.nim:255-256`, `:264-269`, `:276-279`).
- `git_show {repo?, rev, path?}` — `rev` required (`main.nim:292`, `:298-303`, `:307-309`).
- `git_blame {repo?, path, start_line?=1, max_lines?=200}` — `path` required, `start_line`
  clamped ≤1 000 000, `max_lines` ≤500 (`main.nim:321-322`, `:331-334`, `:337-343`).
- `review_receipt {op?="write", findings?, model?}` — any other `op` refused
  (`main.nim:365`, `:375-377`, `:435-436`).
- No `selftest` tool (`grep -c selftest components/git/main.nim` = 0), so `/doctor`'s
  self-test fan-out reports this component as not implementing it (MANUAL:1300-1306;
  `sdk/niffler/sdk.nim:155-167` is the helper it does not call).

## 3. Configuration

**Env vars — none.** The component reads exactly one environment variable, `PATH`
(`main.nim:91`). There is no `NIF_*` knob, so no MANUAL env-table row is owed. Two indirect
couplings: the receipt directory is `NIF_ROOT`-relative (`main.nim:347-350`,
`sdk/subjects.nim:34-35`), and `NIF_GIT_MIRROR` (MANUAL:277) belongs to `plugins` clone
URLs, not to this component — a name-collision hazard for readers.
Manifest: `manifest.yaml:183-190` — `binary: var/bin/git`, `autostart: true`,
`required: false`, `restart: on-failure`.

**Git binary resolution.** `resolveGit()` (`main.nim:80-97`) takes the first `PATH` hit that
is not the component's own binary (else scans `PATH` dirs), because `var/bin/git` can shadow
system git; unresolved or self → exit 127 with an install hint (`main.nim:107-117`).

**Workspace / repo-root resolution.** The component's cwd is the harness root (supervised
children run with `workingDir = NIF_ROOT`, `core/supervisor.nim:160`), and `repo=""` means
that cwd (`repoDir` `main.nim:150-153`; `repoArgs` `:158-161`). For a session turn core
rewrites the argument first: absent/empty/`.` `repo` becomes the conversation workspace's
absolute path, and a relative `repo` resolves against the workspace
(`core/dispatch.nim:1437-1446`). The policy has no `pathFields` (`main.nim:186`), so core
never rewrites `path` — it travels as `-- <path>` and resolves relative to the repo dir via
`-C` (`main.nim:209-211`, `:246-247`). A direct (non-session) bus call resolves a relative
`repo` against the process cwd (`main.nim:150-153`), while the parameter doc claims
"relative paths resolve against the harness root" (`main.nim:199-200`, repeated `:228-229`,
`:268-269`, `:300-301`, `:329-330`).

**Output bounds.** Byte cap `maxOutputBytes = 40_000`, head + tail kept with an exact
"truncated N of M bytes (capped at 40000)" marker (`main.nim:99`, `:130-134`;
`sdk/niffler/procutil.nim:153-165`). Line caps (first N lines kept, tail dropped with a
marker, hint "narrow the scope"): `git_status` 200 (`main.nim:213`), `git_diff` 10 000 full /
500 with `stat` (`main.nim:251`), `git_log` `max_count`+1 ≤201 (`main.nim:288`), `git_show`
10 000 (`main.nim:317`), `git_blame` `max_lines`+1 ≤501 (`main.nim:345`); marker text from
`capLines` (`sdk/niffler/procutil.nim:167-178`). Per-call subprocess timeouts are 15–40 s —
30 s status (`main.nim:212`), 40 s diff (`:248`), 15 s log (`:285`), 20 s show (`:316`),
30 s blame (`:344`), 40 s fingerprint (`:355`) — always below the schema-level
`timeoutMs: 45000` (`main.nim:185`, `:364`).

**Failure reporting.** Argument refusals never start git: `refused()` returns
`{"exit_code": 2, "text": "(exit 2 — refused) …"}` (`main.nim:136-138`). Real git runs
return git's exit code with an `(exit N)` status line plus combined output; 124 is prefixed
`[timed out]`, 128 + "not a git repository" is prefixed
`[no git repository at the target directory]` (`main.nim:119-134`). Everything else is raw
git stderr and nothing more: a **detached HEAD** is just git's own `## HEAD (no branch)` in
`git_status` (no branch/HEAD handling anywhere in the file), and an **incomplete index**
surfaces as git's fatal text with exit 128 and no flag — only empty results get friendly
markers (`[no changes since HEAD]` `main.nim:249-250`, `[no commits matched]` `:286-287`,
and git's own `Not Committed Yet` documented at `:326-327`).

**What it refuses** (all exit 2, before any git process): non-existent `repo` or any `..`
component in it (`validRepo` `main.nim:163-171`; call sites `:203-205`, `:234-236`,
`:270-272`, `:304-306`, `:333-336`); absolute or drive-letter `path`, or `..`
(`validPath` `main.nim:140-148`); panic refs — option-looking, whitespace-bearing, ≥256
chars (`validRef` `main.nim:173-177`); panic authors — leading `-`, newline, ≥200 chars
(`validAuthor` `main.nim:179-183`); `git_blame` without `path` (`main.nim:337-339`);
`review_receipt` with a bad `op` (`main.nim:435-436`), with an empty/failed working-tree diff
(`main.nim:380-381`), or when the receipt dir/receipt file cannot be created or written
(`main.nim:383-386`, `:396-399`). `op: "check"` returns exit 1 with a `detail` (not a
refusal) for: no receipts yet (`main.nim:403-405`), no parseable receipt (`:414-415`), empty
diff (`:417-419`), unreadable receipt (`:421-424`); success is exit 0 + receipt id
(`:426-429`), and staleness is exit 1 plus `receipt_fingerprint` and `current_fingerprint`
(`:430-434`).

**Containment caveat (code vs. its own docs).** `validRepo` checks only `dirExists` + no `..`
(`main.nim:163-171`), so an absolute `repo` **outside** the harness root is accepted — yet
the refusal message says "must be an existing directory inside the harness root"
(`main.nim:204-205`) and the file header says "scoped to the harness root … paths must be
relative and stay inside it" (`main.nim:11-14`). Read-only exposure, but the MANUAL must not
promise absolute-repo containment (tests cover only relative escapes: `tests/t_git.nim:95-99`,
`:180-185`).

**Can it commit?** No. It registers five read tools plus `review_receipt` and nothing else
(`main.nim:185-436`); there is no add/commit/push/checkout/restore tool. Mutations go through
bash, which carries `approval: "always"` (`components/bash/main.nim:119`) and is listed in
the MANUAL approval list (MANUAL:457-470). None of the git schemas carry `x-harness.approval`
(`main.nim:185-186` … `:364`) and the approval list names no git tool — consistent with
MANUAL:67. Note that `review_receipt` *does* write a file without approval
(`main.nim:383-386`, `:396-399`).

## 4. MANUAL placement

Existing coverage is three fragments and no chapter:

- MANUAL:67 — shipped-components table row (`optional`; names the five tools and the
  `var/review-receipts/` write/check pair; "On-demand tools…").
- MANUAL:1471-1472 — shipped policy, "The long tail is on demand: … the git tools".
- MANUAL:563 — workspace bullet, "git tools scope at the workspace repo".
- MANUAL:455-470 — approval list: no git tool (correct), and no note that `review_receipt`
  writes without approval.
- MANUAL:230-260 — the `var/` state table: **no** `var/review-receipts/` row.

Proposed: a new chapter `## Git inspection (\`git\`)` immediately **before**
`## Background processes (\`processes\`)` — that heading is at MANUAL:1033 (the `lsp` chapter
ends at MANUAL:1032) — with subsections mirroring the `lsp` chapter: "The tools" (the §2
table + params/caps), "Failure and refusal semantics" (§3), "Review receipts"
(fingerprint/schema/lifecycle, `var/review-receipts/`), "What it will not do" (no mutations;
bash + approval is the write path). Also: extend the Contents bullet at MANUAL:20 with
`· [Git inspection (\`git\`)](#git-inspection-git)`; add a `var/review-receipts/` row to the
state table (MANUAL:230-260); add one clause to the MANUAL:67 row saying the tools are
read-only and that `review_receipt` is a local file write. Related doc to keep in sync:
`skills/niffler-tools/SKILL.md:44-47`.

## 5. DELTA list

1. **No MANUAL chapter.** Params, caps, timeouts, refusals and exit codes exist only in the
   component's doc comments (`main.nim:1-19`, `:188-345`); MANUAL coverage is one table row
   (MANUAL:67) plus one shipped-policy bullet (MANUAL:1471-1472). Fix per §4.
2. **`var/review-receipts/` missing from the state table** (MANUAL:230-260; directory comes
   from `receiptsDir()` `main.nim:347-350`, files are `rr-<unix>-<fp8>.json`
   `main.nim:387`, `:397`).
3. **`review_receipt` writes without approval and is not named in the approvals chapter**
   (MANUAL:455-470; its schema has neither `approval` nor `effect`, `main.nim:364`). Say so
   instead of letting "read-only, approval-free" (MANUAL:67) cover the write.
4. **Receipt format/semantics undocumented**: `schema_id: "niffler.review-receipt/v1"`,
   `id` (`rr-<unix>-<fp8>`), `created_at`, `diff_fingerprint` (lowercase SHA-256 hex),
   `model`, `findings`, `note` (`main.nim:387-395`, fingerprint `:352-362`); check semantics
   exit 0/1 with both fingerprints (`:426-434`). MANUAL:67 says only "write/check pair".
5. **Output bounds undocumented**: the 40 000-byte head+tail cap plus the five per-tool line
   caps and their hints (`main.nim:99`, `:130-134`, `:213`, `:251`, `:288`, `:317`, `:345`;
   `sdk/niffler/procutil.nim:153-178`) — e.g. a 300-file `git_status` silently stops at 200
   lines.
6. **Failure/refusal semantics undocumented**: exit 2 refusals with the `(exit 2 — refused)`
   prefix, 124 `[timed out]`, 128 `[no git repository at the target directory]`, everything
   else raw git stderr (`main.nim:119-138`); empty-result markers `[no changes since HEAD]`
   (`:249-250`) and `[no commits matched]` (`:286-287`).
7. **Detached HEAD and incomplete index get no special handling** — `git_status` shows git's
   `## HEAD (no branch)` and an index error is raw text + exit 128 with no flag
   (`main.nim:119-134`; nothing in the file special-cases either). If the new chapter covers
   failure modes, state this rather than implying coverage.
8. **Doc-comment vs. core resolution mismatch for `repo`**: the parameter doc says relative
   paths resolve against the harness root (`main.nim:199-200`, `:228-229`, `:268-269`,
   `:300-301`, `:329-330`) while core resolves a relative `repo` against the conversation
   workspace (`core/dispatch.nim:1437-1446`). Document both cases (workspace when
   core-injected; component cwd = harness root for a direct bus call, `main.nim:150-153`).
9. **`x-harness.effect` absent on the five read tools** (`main.nim:185-186` … `:319-320`):
   the fabric classifier defaults unclassified tools to `"write"`
   (`components/fabric/fabric.nim:226-228`, `:309`), so `git_status`/`git_diff` are scheduled
   exclusively instead of alongside other reads — contradicting the read-only framing of
   MANUAL:1471. Code fix candidate; document the actual class meanwhile.
10. **`parallel: true` on the five read tools, absent on `review_receipt`**
    (`main.nim:185` … `:319` vs `:364`) — a runner-side batching hint (docs/WIRE.md:632-637)
    the MANUAL never mentions for git (only MANUAL:665, for lsp/plugins).
11. **No MANUAL note that git must resolve to a real binary via `PATH`** and is skipped when
    it would be the component's own binary (`main.nim:80-97`); a missing/shadowed git yields
    exit 127 with an install hint (`main.nim:107-117`). Worth a line in the chapter and in
    Troubleshooting.
12. **Dangling doc reference and missing self-test**: the tool comment points at
    `docs/RECEIPTS.md` (`main.nim:367`), which does not exist (docs/ holds only
    ARCHITECTURE, FABRIC_GUIDE, MANUAL, WIRE), and the component registers no `selftest`
    (grep count 0), so `/doctor` lists it as not implementing (MANUAL:1300-1306). Either add
    the doc/self-test or drop the reference.

## 6. Not user-facing

- `review_receipt`'s receipt **file format** is local runtime state under `var/`, not a bus
  contract — no WIRE.md chapter is owed (`main.nim:366-367`, `:387-395`). Only its
  `{exit_code, ok, detail}` result shape is model-visible.
- `toSHA256` (`main.nim:22-74`) is a private helper (std/sha1 covers SHA-1 only); the only
  user-relevant fact is that the fingerprint is SHA-256 over the raw `git diff HEAD` output
  (`main.nim:352-362`).
- The fixed flag prefix `--no-optional-locks -c color.ui=false -c core.quotepath=false
  --no-pager` (`main.nim:101-104`) and the temp-file capture in `runGit` (`main.nim:106-117`)
  are implementation detail; their user-visible consequences (no pager, readable non-ASCII
  paths, no lock writes on read-only ops, no pipe deadlock on chatty output) belong in one
  sentence of the new chapter.
