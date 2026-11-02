## git component — read-only git inspection as first-class tools:
## `git_status`, `git_diff`, `git_log`, `git_show`, `git_blame`, plus the
## local `review_receipt` write/check pair (diff fingerprint handoff,
## never calls a model).
##
## Git mutations stay in bash (approval-gated, arbitrary git); these five
## cover the 90% inspection traffic the LLM actually needs — repo state,
## diffs, history, and attribution — without a human prompt on every call
## and without the bash failure class (wrong flags, pager dumps, quotepath
## escapes, 200KB output caps). Every subcommand runs with fixed flags as
## an argv (never through an unquoted shell), scoped to the harness root
## or — core-injected — the conversation's workspace repo: paths must be
## relative and stay inside it, refs are validated, output is capped
## (~40KB, plus per-tool line caps) with narrowing hints.
##
## Exit codes follow git (0/1/2, 128 fatal), 124 = timeout, 127 = git
## missing; "not a git repository" is flagged so the LLM knows the target
## directory is not inside a repo. Read-only, so approval-free.

import std/[json, os, sequtils, strutils, times]
import niffler/sdk
import niffler/configowner
import checkout

proc toSHA256(s: string): string =
  ## Minimal SHA-256 for diff fingerprints (std/sha1 covers SHA-1 only).
  ## FIPS-180-4 over the raw bytes; hex output.
  let msg = s
  var bitLen = uint64(msg.len) * 8
  var data = msg
  data.add('\x80')
  while data.len mod 64 != 56:
    data.add('\x00')
  for i in countdown(7, 0):
    data.add(chr(uint8((bitLen shr (i * 8)) and 0xFF)))
  var h: array[8, uint32] = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32,
    0xa54ff53a'u32, 0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  const k: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32,
    0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32,
    0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32,
    0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32, 0x983e5152'u32,
    0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
    0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32,
    0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32,
    0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32, 0x19a4c116'u32, 0x1e376c08'u32,
    0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32,
    0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]
  var w: array[64, uint32]
  for chunk in 0 ..< data.len div 64:
    let base = chunk * 64
    for i in 0 ..< 16:
      w[i] = uint32(data[base + i*4]) shl 24 or uint32(data[base + i*4 + 1]) shl 16 or
             uint32(data[base + i*4 + 2]) shl 8 or uint32(data[base + i*4 + 3])
    for i in 16 ..< 64:
      let s0 = (w[i-15] shr 7 or w[i-15] shl 25) xor
               (w[i-15] shr 18 or w[i-15] shl 14) xor (w[i-15] shr 3)
      let s1 = (w[i-2] shr 17 or w[i-2] shl 15) xor
               (w[i-2] shr 19 or w[i-2] shl 13) xor (w[i-2] shr 10)
      w[i] = w[i-16] + s0 + w[i-7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
    for i in 0 ..< 64:
      let s1 = (e shr 6 or e shl 26) xor (e shr 11 or e shl 21) xor (e shr 25 or e shl 7)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + s1 + ch + k[i] + w[i]
      let s0 = (a shr 2 or a shl 30) xor (a shr 13 or a shl 19) xor (a shr 22 or a shl 10)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = s0 + maj
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
  for v in h:
    result.add(toHex(v, 8))

let comp = newComponent("git", "0.1.0")

var gGitPath = ""  ## absolute path to a git binary that is not ourselves

proc resolveGit() =
  ## The component binary is var/bin/git — if that directory ever precedes
  ## the system git in PATH, findExe would return ourselves and every call
  ## would recurse into the component. Resolve once: first PATH hit that
  ## is not our own binary; fall back to the plain findExe result (which
  ## runGit rejects when it is still ourselves).
  # selfBinaryPath: after a rebuild this binary's own name is "<path>
  # (deleted)", and comparing against that would never match the real git.
  let self = selfBinaryPath()
  let found = findExe("git")
  if found.len > 0 and not sameFile(found, self):
    gGitPath = found
    return
  for dir in getEnv("PATH").split(PathSep):
    let cand = dir / "git"
    if not fileExists(cand) or sameFile(cand, self): continue
    gGitPath = cand
    return
  gGitPath = found  # "" = missing, or ourselves — runGit reports either way

const
  maxOutputBytes = 40_000
    ## Byte cap (head + tail kept) — a monorepo diff must not flood context.
  gitBase = @["--no-optional-locks", "-c", "color.ui=false",
              "-c", "core.quotepath=false", "--no-pager"]
    ## Fixed flags: no lock writes on read-only ops, no ANSI colors,
    ## readable non-ASCII paths, no pager regardless of tty.

proc runGit(args: seq[string], timeoutMs: int): tuple[code: int, output: string] =
  ## argv through runArgv: the absolute git path, flags, refs and paths
  ## travel byte-for-byte (every argument quoteShell'd; the shell only
  ## joins words) and combined output is captured to a temp file — osproc
  ## pipes deadlock chatty children (sdk/procutil).
  if gGitPath.len == 0 or sameFile(gGitPath, selfBinaryPath()):
    result.code = 127
    result.output = "git is not installed on this machine (or cannot be " &
      "resolved past the git component's own binary) — install it " &
      "(e.g. `sudo apt install git`) or use bash for git operations"
    return
  runArgv(gGitPath, args, timeoutMs)

proc finish(code: int, output: string, maxLines = 10_000): JsonNode =
  ## Shared result shape: git exit code + line-capped, byte-capped output;
  ## timeouts and not-a-repo fatals are flagged up front.
  var o = output
  if code == 124:
    o = "[timed out]\n" & o
  if code == 128 and o.contains("not a git repository"):
    o = "[no git repository at the target directory]\n" & o
  var status = "(exit " & $code & ")"
  if code == 124: status = "(exit 124 — timed out)"
  result = %*{"exit_code": code,
              "text": status & "\n" & capBytes(
                capLines(o, maxLines, label = "lines",
                         hint = "narrow the scope"),
                maxOutputBytes,
                hint = "scope with path or narrow the ref for the missing part")}

proc refused(msg: string): JsonNode =
  ## Argument refused before any git process runs.
  %*{"exit_code": 2, "text": "(exit 2 — refused) " & msg}

proc validPath(path: string): bool =
  ## "" = the whole repo. Otherwise relative, no .. escapes, no absolute
  ## paths (git tools are scoped to the harness root).
  if path.len == 0: return true
  if path.startsWith("/"): return false
  if path.len >= 2 and path[1] == ':': return false
  for part in path.split({'/', '\\'}):
    if part == "..": return false
  return true

proc repoDir(repo: string): string =
  ## Directory every subcommand runs in via -C. Empty = the component's own
  ## cwd (the harness root); core injects the conversation workspace so
  ## secondary repos need no path juggling.
  if repo.len == 0: return getCurrentDir()
  if repo.isAbsolute(): return repo
  getCurrentDir() / repo

proc repoArgs(repo: string): seq[string] =
  ## -C prefix scoping every subcommand at the chosen repo dir; omitted =
  ## the component's own cwd (the harness root).
  if repo.len > 0: @["-C", repoDir(repo)] else: @[]

proc validRepo(repo: string): bool =
  ## repo must be an existing directory, relative to the harness root or
  ## absolute inside it (core injects the workspace as an absolute path); no
  ## `..` escapes.
  if repo.len == 0: return true
  if not dirExists(repoDir(repo)): return false
  for part in repo.split({'/', '\\'}):
    if part == "..": return false
  return true

proc validRef(rev: string): bool =
  ## No option-looking revs (git would interpret them as flags), no
  ## whitespace (one argv, and a revision can never contain it).
  rev.len > 0 and rev.len < 256 and
    not rev.startsWith("-") and not rev.anyIt(it in Whitespace)

proc validAuthor(author: string): bool =
  ## A --author= substring travels as a single argv, so anything but
  ## newlines and option-looking values is safe.
  author.len < 200 and not author.startsWith("-") and
    not author.contains('\n') and not author.contains('\r')

comp.tool(%*{"timeoutMs": 45000, "parallel": true, "onDemand": true,
              "effect": "read",
              "workspace": {"cwdField": "repo"}}):
  proc git_status(repo: string = "", path: string = ""): JsonNode =
    ## Cheap repo state check — run it whenever you are unsure what
    ## changed: before starting work, after your own edits, or to detect
    ## whether someone else edited files while you worked. Shows the
    ## current branch and one line per changed file in git's porcelain
    ## format; the two-character XY code in front of each file means:
    ## " M" modified (unstaged), "M " staged, "A" added, "D" deleted,
    ## "R" renamed, "??" untracked (never committed), "U" conflicted.
    ## Read-only and approval-free — prefer this over `git status` in
    ## bash (same information, no prompt, no pager). Untracked files are
    ## listed here but never appear in git_diff. Output is capped; scope
    ## with path to narrow.
    ## - repo: Repository directory (defaults to the active conversation
    ##   workspace; relative paths resolve against the harness root)
    ## - path: File or directory to scope the status to, relative to the
    ##   repo (default "" = whole repo)
    if not validRepo(repo):
      return refused("repo must be an existing directory inside the " &
        "harness root (no `..` escapes)")
    if not validPath(path):
      return refused("path must stay inside the repo: a relative path, no " &
        "absolute paths, no `..` — scope with a relative path instead")
    var args = gitBase & repoArgs(repo) & @["status", "--porcelain=v1", "-b"]
    if path.len > 0:
      args.add(["--", path])
    let (code, output) = runGit(args, 30_000)
    return finish(code, output, 200)

comp.tool(%*{"timeoutMs": 45000, "parallel": true, "onDemand": true,
              "effect": "read",
              "workspace": {"cwdField": "repo"}}):
  proc git_diff(repo: string = "", path: string = "", unified: int = 3,
                stat: bool = false): JsonNode =
    ## Diff of everything changed since the last commit (staged AND
    ## unstaged — `git diff HEAD`) with context lines. Use it to review
    ## your own edits before reporting done, or to see exactly what
    ## someone else changed. Untracked files are NOT shown here — check
    ## git_status for those. stat: true switches to a compact one-line-
    ## per-file summary (additions/deletions only), much cheaper to read
    ## when you only need the shape of a change. Read-only and
    ## approval-free; prefer over `git diff` in bash (fixed flags, no
    ## pager, capped output). When truncated, scope with path.
    ## - repo: Repository directory (defaults to the active conversation
    ##   workspace; relative paths resolve against the harness root)
    ## - path: File or directory to limit the diff to, relative to the
    ##   repo (default "" = whole repo)
    ## - unified: Context lines around each hunk (default 3, 0..50)
    ## - stat: Compact per-file summary instead of the full diff
    if not validRepo(repo):
      return refused("repo must be an existing directory inside the " &
        "harness root (no `..` escapes)")
    if not validPath(path):
      return refused("path must stay inside the repo: a relative path, no " &
        "absolute paths, no `..` — scope with a relative path instead")
    var args = gitBase & repoArgs(repo) & @["diff"]
    if stat:
      args.add("--stat")
    else:
      args.add("-U" & $min(max(unified, 0), 50))
    args.add("HEAD")
    if path.len > 0:
      args.add(["--", path])
    let (code, output) = runGit(args, 40_000)
    if code == 0 and output.strip().len == 0:
      return %*{"exit_code": 0, "text": "(exit 0)\n[no changes since HEAD]"}
    return finish(code, output, if stat: 500 else: 10_000)

comp.tool(%*{"timeoutMs": 45000, "parallel": true, "onDemand": true,
              "effect": "read",
              "workspace": {"cwdField": "repo"}}):
  proc git_log(repo: string = "", path: string = "", max_count: int = 20,
               author: string = ""): JsonNode =
    ## Recent commit history, one line per commit: short hash, subject,
    ## and branch/tag decorations. Use it to see what changed recently,
    ## find when something landed, or pick a ref for git_show. Filter by
    ## path (only commits touching one file or directory) or author
    ## (substring match against the author name, e.g. "krampe").
    ## Read-only and approval-free; prefer over `git log` in bash —
    ## max_count caps lines so the history can never page-dump.
    ## - path: Only commits touching this file or directory, relative to
    ##   the repo (default "" = all)
    ## - max_count: Number of commits to list (default 20, max 200)
    ## - author: Only commits whose author name contains this substring
    ## - repo: Repository directory (defaults to the active conversation
    ##   workspace; relative paths resolve against the harness root)
    if not validRepo(repo):
      return refused("repo must be an existing directory inside the " &
        "harness root (no `..` escapes)")
    if not validPath(path):
      return refused("path must stay inside the repo: a relative path, no " &
        "absolute paths, no `..` — scope with a relative path instead")
    if not validAuthor(author):
      return refused("author must be a plain substring (no leading -, no " &
        "newlines, under 200 chars)")
    var args = gitBase & repoArgs(repo) & @["log", "--oneline", "--decorate", "-n",
                           $min(max(max_count, 1), 200)]
    if author.len > 0:
      args.add("--author=" & author)
    if path.len > 0:
      args.add(["--", path])
    let (code, output) = runGit(args, 15_000)
    if code == 0 and output.strip().len == 0:
      return %*{"exit_code": 0, "text": "(exit 0)\n[no commits matched]"}
    return finish(code, output, min(max(max_count, 1), 200) + 1)

comp.tool(%*{"timeoutMs": 45000, "parallel": true, "onDemand": true,
              "effect": "read",
              "workspace": {"cwdField": "repo"}}):
  proc git_show(repo: string = "", rev: string, path: string = ""): JsonNode =
    ## Show one commit in full: metadata, message, and the complete diff
    ## (optionally limited to one path). Use it after git_log to see what
    ## a commit actually did, or with a hash from git_blame to understand
    ## why a line exists. Read-only and approval-free; output is capped —
    ## for very large commits scope with path.
    ## - rev: Commit to show — hash (short ok), branch, tag, or revision
    ##   expression like HEAD or HEAD~2
    ## - repo: Repository directory (defaults to the active conversation
    ##   workspace; relative paths resolve against the harness root)
    ## - path: Limit the shown diff to this file or directory, relative to
    ##   the repo (default "" = whole commit)
    if not validRepo(repo):
      return refused("repo must be an existing directory inside the " &
        "harness root (no `..` escapes)")
    if not validRef(rev):
      return refused("rev must be a plain revision (hash, branch, tag, " &
        "HEAD~N) — no leading -, no spaces, under 256 chars")
    if not validPath(path):
      return refused("path must stay inside the repo: a relative path, no " &
        "absolute paths, no `..` — scope with a relative path instead")
    var args = gitBase & repoArgs(repo) & @["show", rev]
    if path.len > 0:
      args.add(["--", path])
    let (code, output) = runGit(args, 20_000)
    return finish(code, output)

comp.tool(%*{"timeoutMs": 45000, "parallel": true, "onDemand": true,
              "effect": "read",
              "workspace": {"cwdField": "repo"}}):
  proc git_blame(repo: string = "", path: string, start_line: int = 1,
                 max_lines: int = 200): JsonNode =
    ## Line-by-line attribution for one file: for each line, the commit
    ## that last touched it, its author, and the line content. Use it to
    ## find out why a line exists (then git_show the hash), or who last
    ## edited a section. Lines changed but not yet committed show
    ## "Not Committed Yet". Read-only and approval-free; output is line-
    ## capped — page through large files with start_line/max_lines.
    ## - repo: Repository directory (defaults to the active conversation
    ##   workspace; relative paths resolve against the harness root)
    ## - path: File to blame, relative to the repo
    ## - start_line: First line to show (1-based, default 1)
    ## - max_lines: How many lines to show (default 200, max 500)
    if not validRepo(repo):
      return refused("repo must be an existing directory inside the " &
        "harness root (no `..` escapes)")
    if not validPath(path) or path.len == 0:
      return refused("path is required and must stay inside the repo: a " &
        "relative file path, no absolute paths, no `..`")
    var args = gitBase & repoArgs(repo) & @["blame", "--abbrev", "-L",
                           $min(max(start_line, 1), 1_000_000) & ",+" &
                           $min(max(max_lines, 1), 500),
                           "--", path]
    let (code, output) = runGit(args, 30_000)
    return finish(code, output, min(max(max_lines, 1), 500) + 1)

proc receiptsDir(): string =
  ## Review receipts live under var/ (disposable runtime state): they are
  ## local pre-push handoff artifacts, not durable records.
  rootDir() / "var" / "review-receipts"

proc diffFingerprint(): tuple[fp, diffText: string, empty: bool] =
  ## SHA-256 of the full working-tree diff (git diff HEAD). The fingerprint
  ## is the whole receipt idea: a check against a stale diff must fail.
  let (code, output) = runGit(gitBase & @["diff", "HEAD"], 40_000)
  if code != 0:
    return ("", "", true)
  let d = output
  if d.strip().len == 0:
    return ("", d, true)
  result.fp = toLowerAscii($toSHA256(d))
  result.diffText = d

comp.tool(%*{"timeoutMs": 45000, "onDemand": true}):
  proc review_receipt(op: string = "write", findings: string = "", model: string = ""): JsonNode =
    ## Local review receipt for pre-push handoff (CodeWhale borrow,
    ## docs/research/CODEWHALE.md; user-facing docs: docs/MANUAL.md,
    ## "Repository inspection (`git`)"): records WHAT was
    ## reviewed (SHA-256 fingerprint of the working-tree diff) and what the
    ## review reported, never the diff body itself. op="write" stores a
    ## receipt under var/review-receipts/ and returns it; op="check"
    ## compares the CURRENT diff's fingerprint against the latest receipt —
    ## fails when the diff changed since the review (re-run review first).
    ## Never calls a model: the review judgment is yours (or an agent
    ## turn's); this only makes the handoff honest about its staleness.
    ## - op: "write" to record, "check" to gate on staleness
    ## - findings: free-text review summary recorded in the receipt (write)
    ## - model: reviewer model id, when a model produced the findings (write)
    if op == "write":
      let (fp, _, empty) = diffFingerprint()
      if empty:
        return refused("no working-tree diff to review (git diff HEAD is empty or failed)")
      let dir = receiptsDir()
      try:
        createDir(dir)
      except CatchableError as e:
        return refused("cannot create " & dir & ": " & e.msg)
      let id = "rr-" & $int(toUnixFloat(now().toTime())) & "-" & fp[0 ..< 8]
      let receipt = %*{
        "schema_id": "niffler.review-receipt/v1",
        "id": id,
        "created_at": $now(),
        "diff_fingerprint": fp,
        "model": model,
        "findings": findings,
        "note": "re-run write after changing the diff; check fails on fingerprint mismatch"}
      try:
        writeFile(dir / (id & ".json"), receipt.pretty)
      except CatchableError as e:
        return refused("cannot write receipt: " & e.msg)
      return receipt
    elif op == "check":
      let dir = receiptsDir()
      if not dirExists(dir):
        return %*{"exit_code": 1, "ok": false,
                  "detail": "no review receipts exist yet — review the diff, then write a receipt"}
      var newest = ("", 0.0)
      for f in walkDirRec(dir):
        if f.extractFilename.endsWith(".json"):
          try:
            let t = toUnixFloat(getLastModificationTime(f))
            if t > newest[1]: newest = (f, t)
          except CatchableError:
            discard
      if newest[0].len == 0:
        return %*{"exit_code": 1, "ok": false, "detail": "no parseable receipts"}
      let (fp, _, empty) = diffFingerprint()
      if empty:
        return %*{"exit_code": 1, "ok": false,
                  "detail": "working-tree diff is empty or failed — nothing matches the receipt"}
      var receipt: JsonNode
      try:
        receipt = parseJson(readFile(newest[0]))
      except CatchableError as e:
        return %*{"exit_code": 1, "ok": false, "detail": "unreadable receipt: " & e.msg}
      let stored = receipt{"diff_fingerprint"}.getStr("")
      if stored == fp:
        return %*{"exit_code": 0, "ok": true,
                  "receipt": receipt{"id"}.getStr(""),
                  "detail": "diff matches the latest review receipt"}
      return %*{"exit_code": 1, "ok": false,
                "receipt": receipt{"id"}.getStr(""),
                "receipt_fingerprint": stored,
                "current_fingerprint": fp,
                "detail": "diff changed since the latest review — re-review and write a fresh receipt"}
    else:
      refused("op must be \"write\" or \"check\"")


# ===========================================================================
# Mutation surface (WORKTREES.md §4.3)
#
# The read tools above stay exactly as they are and never prompt. These are a
# second, separately declared surface: `onDemand: true` (not in a
# conversation's frozen toolset — reachable through `discover` + `invoke`),
# `effect: write`, and `approval: "always"` on every op that changes a tree.
#
# The gate: a declared SETTING (domain `git.mutations`, env fallback
# `NIF_GIT_MUTATIONS`, application `component restart`). Off means the verbs
# are never registered, which is the honest way to keep today's read-only
# contract by configuration rather than by trust (CONFIG-CONTRACT.md: an env
# var a component enforces is a setting; the env spelling stays only as the
# migration fallback).
#
# One declaration per CLAIM SHAPE, not per taste: `x-harness.writes` is static
# per tool, so the read half (`git_worktree_list`) cannot ride in the same
# schema as `add`.
# ===========================================================================

let ownerStore* = OwnerStore(kind: "git-settings", id: "main")
let gitSettings = newOwnerSnapshot(ownerStore)

# The domain is declared, not just read: an env var a component enforces is a
# setting (CONFIG-CONTRACT.md), and NIF_GIT_MUTATIONS stays only as the
# migration fallback that settingBool consults behind a stored value.
#
# `application: component restart` is the honest floor: the verbs are
# REGISTERED at boot, so flipping this off cannot unregister them in a running
# process. Saying "immediate" would be a claim the component cannot keep.
let gitDecl = declaration(
  "git.mutations", "git", "git_config", "Git mutation verbs",
  "Whether the git component registers its write verbs (worktrees, commit, " &
  "merge). Off keeps the component read-only — the honest way to hold today's " &
  "read-only contract by configuration rather than by trust.",
  ownerStore.kind, appComponentRestart,
  %*{"type": "object", "properties": {
       "mutations": {"type": "boolean", "default": true, "x-config": {
         "title": "Enable git write verbs",
         "application": "component restart"}}},
     "additionalProperties": false})

proc mutationsEnabled(): bool =
  ## Read from the config snapshot (refreshed by ev.config.updated), env as the
  ## migration fallback, default ON — a harness that never configures this
  ## keeps the full surface.
  gitSettings.flag("mutations", "NIF_GIT_MUTATIONS", true)

proc wtLedgerKind(): string = "worktree"

proc ledgerGet(path: string): JsonNode =
  ## The ledger document for one tree, or nil. The ledger is the fact git
  ## cannot know: WHICH conversation owns a tree.
  try:
    return comp.storeGet(wtLedgerKind(), normalizeRoot(path), 5_000).value
  except CatchableError:
    return nil

proc ledgerPut(path: string, doc: JsonNode): string =
  ## Persist the ledger entry. Returns "" on success, else the failure text.
  ## Deliberately NOT fatal: the git-level lock is the durable half, so a
  ## conversation must not lose the ability to start work because a metadata
  ## write failed (WORKTREES.md §4.3 step 3).
  try:
    discard comp.storePut(wtLedgerKind(), normalizeRoot(path), doc,
                          timeoutMs = 10_000)
    return ""
  except CatchableError as e:
    return e.msg

proc ledgerAll(repo: string): seq[JsonNode] =
  ## Every ledger doc for a repo. Best effort: a store outage yields none.
  ##
  ## storeListAll, not storeList: a single list is a PAGE (capped at 1000 with
  ## a cursor), and the ledger is the authority for "whose tree is this" — a
  ## silently truncated view would report an owned tree as unowned, which is
  ## the one answer this must never give.
  try:
    for it in comp.storeListAll(wtLedgerKind()):
      if it.value != nil and it.value{"repo"}.getStr("") == normalizeRoot(repo):
        result.add it.value
  except CatchableError:
    discard

proc combined(action: string, primary: string, branch: string): string =
  ## The `git worktree lock --reason` text. git quotes it back in `remove`'s
  ## refusal and in `worktree list --porcelain` as `locked <reason>`, so this
  ## is how a human (and `remove` itself, when the store is down) learns whose
  ## tree it is WITHOUT the store.
  "niffler " & action & (if branch.len > 0: " (" & branch & ")" else: "") &
    " — conversation " & primary

proc worktreeContainer(primary: string): string =
  ## The ONE container per repository: `<primary>.wt`, a sibling of the repo.
  ##
  ## Hangs off the PRIMARY, never off the current workspace. Measured why: a
  ## conversation already in ~/git/repo.wt/feat that computed a sibling from
  ## its own path would create ~/git/repo.wt/feat.wt/<name> — one level deeper
  ## on every hop, a container per tree instead of one per repository, and a
  ## path nobody can predict.
  normalizeRoot(primary) & ".wt"

proc ensureDir(path: string): bool =
  try:
    if not dirExists(path): createDir(path)
    true
  except CatchableError:
    false

proc publishWorktreeChanged(primary: string) =
  ## Fire-and-forget notice that a repository's checkout graph moved, so a
  ## client (and any future subscriber) can refresh without polling. Core's
  ## dispatch cache does NOT depend on this: `graphSignature` notices the
  ## change on its own, which is why a tree made by bash or by hand in another
  ## terminal is picked up either way. This is the courtesy, not the mechanism.
  comp.emit("ev.worktree.changed",
            %*{"repo": normalizeRoot(primary), "at": epochTime()})

# --- the read half ---------------------------------------------------------

proc worktreeListImpl(repo: string): JsonNode =
  let target = repoDir(repo)
  let shape = checkoutShape(target)
  if shape.kind == ckNone:
    return %*{"exit_code": 128, "ok": false,
              "detail": "[no git repository at the target directory]"}
  var trees = newJArray()
  let ledger = ledgerAll(if shape.primaryRoot.len > 0: shape.primaryRoot
                         else: target)
  let current = normalizeRoot(target)
  for t in worktrees(target):
    let p = normalizeRoot(t.path)
    var entry = %*{"path": p, "branch": t.branch, "head": t.head,
                   "locked": t.locked, "prunable": t.prunable,
                   "bare": t.bare, "detached": t.detached,
                   "isCurrent": p == current}
    if t.lockReason.len > 0: entry["lockReason"] = %t.lockReason
    for d in ledger:
      if d{"path"} != nil and normalizeRoot(d{"path"}.getStr("")) == p:
        entry["owner"] = %*{"sessionId": d{"sessionId"}.getStr(""),
                            "state": d{"state"}.getStr(""),
                            "createdAt": d{"createdAt"}.getFloat(0.0)}
        break
    trees.add entry
  %*{"exit_code": 0, "ok": true,
     "primary": (if shape.primaryRoot.len > 0: shape.primaryRoot else: current),
     "container": worktreeContainer(
        if shape.primaryRoot.len > 0: shape.primaryRoot else: current),
     "trees": trees}

# --- op: add ---------------------------------------------------------------

proc worktreeAddImpl(repo, path, name, branch, base: string): JsonNode =
  let start = repoDir(repo)
  let shape = checkoutShape(start)
  if shape.kind == ckNone:
    return refused("not a git repository: " & start)
  # Orientation: always the primary's container, from the primary OR from a
  # worktree (so a conversation in a tree cuts the next tree beside itself
  # rather than a container per hop).
  let primary = if shape.primaryRoot.len > 0: shape.primaryRoot else: start
  let container = worktreeContainer(primary)
  var wtName = name.strip()
  var target: string
  if path.strip().len > 0:
    target = normalizeRoot(path.strip())
  else:
    if wtName.len == 0:
      return refused("add needs a name (or an explicit path)")
    target = normalizeRoot(container / wtName)
  if wtName.len == 0: wtName = target.lastPathPart()
  # Refusals that exist because getting them wrong is expensive.
  if not target.startsWith(normalizeRoot(container) & "/"):
    return refused("a worktree must live in the repository's worktree container " &
      container & " — got " & target & ". The sibling layout is what keeps a " &
      "tree's write claims disjoint from the primary's (an in-repo tree would be " &
      "inside the primary's opaque claim, serializing every write).")
  if dirExists(target) or fileExists(target):
    return refused("path already exists: " & target & " — refusing to adopt an " &
      "existing directory (grafting a checkout into our git metadata is not " &
      "reversible). Pick another name, or remove it yourself.")
  # A path inside an EXISTING worktree of the same repo is the mistake the
  # orientation rule exists to prevent.
  for t in worktrees(primary):
    let tp = normalizeRoot(t.path)
    if tp.len > 0 and tp != normalizeRoot(primary) and
        (target == tp or target.startsWith(tp & "/")):
      return refused(target & " is inside the existing worktree " & tp &
        " — a worktree is never nested in another")
  if not ensureDir(container):
    return refused("cannot create the worktree container " & container)
  var gargs = @["worktree", "add"]
  var br = branch.strip()
  if br.len == 0: br = wtName
  if not validRef(br):
    return refused("invalid branch name: " & br)
  var b = base.strip()
  if b.len == 0:
    let cur = runGit(repoArgs(primary) & gitBase & @["rev-parse",
                                                     "--abbrev-ref", "HEAD"],
                     15_000)
    if cur.code != 0: return finish(cur.code, cur.output)
    b = cur.output.splitLines()[0].strip()
  if not validRef(b):
    return refused("invalid base ref: " & b)
  # -b refuses an existing branch (git errors); that is the right behaviour —
  # silently attaching to someone else's branch is worse than an error.
  gargs.add @["-b", br, target, b]
  let r = runGit(repoArgs(primary) & gitBase & gargs, 120_000)
  if r.code != 0: return finish(r.code, r.output)
  # Ownership, in two layers: git's own lock (durable, readable without the
  # store) and the ledger (which conversation, which base).
  let session = comp.sessionContext
  let reason = combined("worktree", if session.len > 0: session else: "unknown",
                        br)
  let lock = runGit(repoArgs(primary) & gitBase &
                    @["worktree", "lock", "--reason", reason, target], 30_000)
  let doc = %*{"repo": normalizeRoot(primary), "path": normalizeRoot(target),
               "branch": br, "base": b,
               "sessionId": session, "createdAt": epochTime(),
               "state": "live"}
  let ledgerErr = ledgerPut(target, doc)
  var res = %*{"exit_code": 0, "ok": true, "path": normalizeRoot(target),
               "branch": br, "base": b, "primary": normalizeRoot(primary),
               "container": container,
               "locked": lock.code == 0}
  if lock.code != 0:
    # The tree exists; say so rather than pretend the lock worked.
    res["lockError"] = %capBytes(lock.output, 2000)
  if ledgerErr.len > 0:
    # Store down: the tree is created and git-locked (the durable half); the
    # ledger miss is reported, and `remove` falls back to the lock reason.
    res["ledgerError"] = %ledgerErr
    res["detail"] = %("worktree created and git-locked, but the ownership " &
      "ledger could not be written (" & ledgerErr & ") — removal will fall " &
      "back to the git lock reason")
  publishWorktreeChanged(primary)
  let ignored = runGit(repoArgs(primary) & gitBase &
                       @["status", "--porcelain"], 30_000)
  if ignored.code == 0 and ignored.output.strip().len > 0:
    res["statusClean"] = %false
    res["detail"] = %("worktree created outside the repository — no ignore rule " &
      "is needed (a sibling is not in the repo); the primary's own working " &
      "tree was already dirty")
  else:
    res["statusClean"] = %true
  res

# --- op: remove ------------------------------------------------------------

proc branchMergedInto(primary, branch, base: string): bool =
  ## Is `branch` fully merged into `base`? Best effort: an error reads as NOT
  ## merged, so the refusal stands and the override flag is the way through.
  if branch.len == 0 or base.len == 0: return false
  let r = runGit(repoArgs(primary) & gitBase &
                 @["merge-base", "--is-ancestor", branch, base], 20_000)
  r.code == 0

proc worktreeRemoveImpl(repo, path: string, force,
                        deleteBranch: bool): JsonNode =
  let start = repoDir(repo)
  let shape = checkoutShape(start)
  if shape.kind == ckNone: return refused("not a git repository: " & start)
  let primary = if shape.primaryRoot.len > 0: shape.primaryRoot else: start
  var target = normalizeRoot(path.strip())
  if target.len == 0:
    return refused("remove needs the path of the worktree")
  if target == normalizeRoot(primary):
    return refused("that is the primary checkout, not a worktree — refusing to " &
      "remove the repository itself")
  # Find the git record: its branch and lock reason.
  var found = false
  var branch = ""
  var lockReason = ""
  for t in worktrees(primary):
    if normalizeRoot(t.path) == target:
      found = true
      branch = t.branch
      lockReason = t.lockReason
      break
  if not found:
    return refused("no worktree of " & normalizeRoot(primary) & " at " & target &
      " — `git_worktree {op: prune}` clears trees that were deleted by hand")
  # (i) another LIVE conversation pinned here. git cannot know this; the
  # ledger is the whole reason it exists. Fall back to the lock reason when
  # the ledger is unreadable (a store-down `add` still wrote the lock).
  let entry = ledgerGet(target)
  let owner = if entry != nil: entry{"sessionId"}.getStr("") else: ""
  let mine = comp.sessionContext
  if owner.len > 0:
    if owner != mine and not force:
      return refused("the worktree " & target & " belongs to conversation " &
        owner & " (ledger) — that conversation may still be working there. " &
        "Pass force: true only if you know it is finished.")
  elif lockReason.len > 0 and not force:
    # The ledger is gone but git's lock names an owner: same guard, less detail.
    # Parse by SEARCHING for the marker, not by slicing a fixed prefix — the
    # reason is "<action> (<branch>) — conversation <id>", so the marker's
    # offset varies with the branch name (slicing produced "tree (feat) —
    # conversation x", which then named a conversation that does not exist).
    let marker = "conversation "
    let at = lockReason.find(marker)
    let named = if at >= 0: lockReason[at + marker.len .. ^1].strip(chars = {'"'})
                else: ""
    # "unknown" is what `add` writes when no session was injected (a direct
    # bus call, e.g. the cli). It is not an owner to protect: treating it as
    # one would block every scripted call.
    if named.len > 0 and named != "unknown" and named != mine:
      return refused("the worktree " & target & " is locked for conversation " &
        named & " (git lock) — pass force: true only if you know it is " &
        "finished.")
  # (ii) an unmerged branch.
  if branch.len > 0 and not force:
    let base = if entry != nil: entry{"base"}.getStr("") else: ""
    let into = if base.len > 0: base else: "HEAD"
    if not branchMergedInto(primary, branch, into):
      return refused("branch " & branch & " has commits not merged into " & into &
        " — the work would be lost. Merge it first, or pass force: true to " &
        "remove the tree anyway (the branch itself is kept).")
  # We are past the ownership guard, so the lock is ours to drop. It must be
  # dropped explicitly: git refuses to remove a LOCKED tree without -f -f
  # (measured), and passing -f -f unconditionally would also bulldoze a DIRTY
  # tree — which git refuses on purpose ("contains modified or untracked
  # files") and which the caller should see verbatim rather than have us
  # override. Unlock first, then remove with the force the caller asked for.
  if lockReason.len > 0:
    discard runGit(repoArgs(primary) & gitBase &
                   @["worktree", "unlock", target], 30_000)
  # A dirty tree is git's own refusal (measured: exit 128, "contains modified
  # or untracked files"); surface it verbatim rather than re-implementing it.
  var gargs = @["worktree", "remove"]
  if force: gargs.add @["--force", "--force"]
  gargs.add target
  let r = runGit(repoArgs(primary) & gitBase & gargs, 60_000)
  if r.code != 0: return finish(r.code, r.output)
  publishWorktreeChanged(primary)
  var res = %*{"exit_code": 0, "ok": true, "path": target, "branch": branch}
  if deleteBranch and branch.len > 0:
    let d = runGit(repoArgs(primary) & gitBase & @["branch", "-D", branch], 30_000)
    res["branchDeleted"] = %(d.code == 0)
    if d.code != 0: res["branchDeleteError"] = %capBytes(d.output, 2000)
  # Retire the ledger entry: the record survives as history (state), which is
  # what makes "this conversation's tree was removed" answerable later.
  if entry != nil:
    var doc = entry
    doc["state"] = %"removed"
    doc["removedAt"] = %epochTime()
    let err = ledgerPut(target, doc)
    if err.len > 0: res["ledgerError"] = %err
  res

# --- op: prune -------------------------------------------------------------

proc worktreePruneImpl(repo: string): JsonNode =
  let start = repoDir(repo)
  let shape = checkoutShape(start)
  if shape.kind == ckNone: return refused("not a git repository: " & start)
  let primary = if shape.primaryRoot.len > 0: shape.primaryRoot else: start
  # `git worktree prune` SKIPS LOCKED trees (measured: it exits 0 and leaves
  # the record in place). Every tree `add` creates is locked, so without this
  # step prune could never clean up a tree of ours — the exact case it exists
  # for. Unlock only records whose directory is GONE: a live tree keeps its
  # lock, so prune still cannot touch work that is actually there.
  var unlocked: seq[string]
  for t in worktrees(primary):
    let p = normalizeRoot(t.path)
    if p.len == 0 or p == normalizeRoot(primary): continue
    if t.locked and not dirExists(p):
      let u = runGit(repoArgs(primary) & gitBase &
                     @["worktree", "unlock", p], 30_000)
      if u.code == 0: unlocked.add p
  let r = runGit(repoArgs(primary) & gitBase & @["worktree", "prune", "-v"],
                 60_000)
  if r.code != 0: return finish(r.code, r.output)
  # The signature the dispatch cache uses must move, or a pruned tree stays in
  # the workspace set until the runner restarts.
  publishWorktreeChanged(primary)
  var res = %*{"exit_code": 0, "ok": true,
               "pruned": %(r.output.strip().len > 0)}
  if unlocked.len > 0:
    var arr = newJArray()
    for u in unlocked: arr.add(%u)
    res["unlocked"] = arr
  let detail = r.output.strip()
  res["detail"] = %(if detail.len > 0: detail
                   elif unlocked.len > 0:
                     "removed the records of " & $unlocked.len &
                     " hand-deleted tree(s)"
                   else: "nothing to prune")
  res

comp.watchConfig(gitSettings, "git.mutations")

# ===========================================================================
# Merge + commit (WORKTREES.md §4.3). The verbs that make a worktree flow a
# flow: cut a tree, work, commit there, merge back — without dropping to bash,
# which loses the message the conversation just spent a turn composing.
# ===========================================================================

proc isTreeOid(line: string): bool =
  ## A 40- or 64-hex tree OID (SHA-1 / SHA-256 repositories).
  if line.len != 40 and line.len != 64: return false
  for ch in line:
    if ch notin {'0'..'9', 'a'..'f', 'A'..'F'}: return false
  true

proc mergeTreeVerdict(code: int, output: string):
    tuple[kind, detail: string, paths: seq[string], tree: string] =
  ## Classify `git merge-tree --write-tree --name-only` output.
  ##
  ## exit 1 means TWO different things, and mapping it to one verdict is the
  ## trap (WORKTREES.md §4.3, measured):
  ##
  ##   clean      exit 0, stdout = tree OID
  ##   conflict   exit 1, stdout = tree OID, then paths, then CONFLICT lines
  ##   bad ref    exit 1, stdout EMPTY, stderr "merge-tree: <ref> - not
  ##              something we can merge"
  ##
  ## So a conflict is claimed only on a POSITIVE discriminator: the first line
  ## must be a tree OID. Otherwise the answer is an error carrying git's own
  ## message — never a fabricated conflict list, which would send the model off
  ## to resolve conflicts in a branch that does not exist.
  ##
  ## runGit combines stderr into stdout (runCmd does `2>&1`), so the streams
  ## cannot be told apart; the discriminator is therefore the CONTENT, which
  ## separates cleanly: a bad ref's first line is prose, a conflict's is hex.
  if code == 0:
    let first = output.splitLines()[0].strip()
    return (kind: "clean", detail: first, paths: @[], tree: first)
  if code == 124:
    return (kind: "timeout", detail: "merge-tree timed out", paths: @[],
            tree: "")
  if code == 127:
    return (kind: "nogit", detail: output.strip(), paths: @[], tree: "")
  if code == 1:
    let lines = output.splitLines()
    if lines.len > 0 and isTreeOid(lines[0].strip()):
      var paths: seq[string]
      var sawConflict = false
      # Layout after the OID: one path per line, a blank line, then the
      # informational messages (which include the CONFLICT lines).
      for i in 1 ..< lines.len:
        let line = lines[i].strip()
        if line.len == 0: continue
        if line.startsWith("CONFLICT") or line.startsWith("Auto-merging") or
            line.startsWith("Auto-merging ") or line.contains("Merge conflict"):
          sawConflict = true
          continue
        if line.contains(" "): continue      # prose, not a path
        paths.add line
      if sawConflict or paths.len > 0:
        return (kind: "conflict", detail: lines[0].strip(), paths: paths,
                tree: lines[0].strip())
      # OID but nothing else: refs identical / already merged.
      return (kind: "clean", detail: lines[0].strip(), paths: @[],
              tree: lines[0].strip())
    # exit 1 without a tree OID: git refused the request (a bad ref, usually).
    return (kind: "error", detail: output.strip(), paths: @[], tree: "")
  return (kind: "error", detail: output.strip(), paths: @[], tree: "")

proc dirtyPaths(repo: string): seq[string] =
  ## Paths with local changes in `repo` (porcelain, first field stripped).
  let r = runGit(repoArgs(repo) & gitBase & @["status", "--porcelain"], 30_000)
  if r.code != 0: return @[]
  for line in r.output.splitLines():
    if line.len < 4: continue
    var path = line[3 .. ^1].strip()
    # "R  old -> new" / "C  old -> new": the target is what matters.
    let arrow = path.find(" -> ")
    if arrow >= 0: path = path[arrow + 4 .. ^1]
    if path.len > 0: result.add path

proc mergePreviewImpl(repo, into, srcBranch: string): JsonNode =
  ## What merging `from` into `into` would do, WITHOUT touching a working tree.
  let start = repoDir(repo)
  let shape = checkoutShape(start)
  if shape.kind == ckNone: return refused("not a git repository: " & start)
  let primary = if shape.primaryRoot.len > 0: shape.primaryRoot else: start
  var intoRef = into.strip()
  if intoRef.len == 0:
    let cur = runGit(repoArgs(primary) & gitBase &
                     @["rev-parse", "--abbrev-ref", "HEAD"], 15_000)
    if cur.code != 0: return finish(cur.code, cur.output)
    intoRef = cur.output.splitLines()[0].strip()
  var fromRef = srcBranch.strip()
  if fromRef.len == 0:
    # "merge this back" from a worktree means its own branch.
    fromRef = shape.branch
  if fromRef.len == 0:
    return refused("merge_preview needs `from` (no branch is checked out here)")
  if not validRef(intoRef): return refused("invalid target ref: " & intoRef)
  if not validRef(fromRef): return refused("invalid source ref: " & fromRef)
  let mt = runGit(repoArgs(primary) & gitBase &
                  @["merge-tree", "--write-tree", "--name-only", intoRef,
                    fromRef], 120_000)
  let v = mergeTreeVerdict(mt.code, mt.output)
  case v.kind
  of "clean":
    # Divergence and the shape of the change, for the model's next decision.
    let counts = runGit(repoArgs(primary) & gitBase &
                        @["rev-list", "--left-right", "--count",
                          intoRef & "..." & fromRef], 30_000)
    var ahead, behind = 0
    if counts.code == 0:
      let parts = counts.output.strip().splitWhitespace()
      if parts.len >= 2:
        try:
          behind = parseInt(parts[0])
          ahead = parseInt(parts[1])
        except ValueError: discard
    let stat = runGit(repoArgs(primary) & gitBase &
                      @["diff", "--stat", intoRef & "..." & fromRef], 30_000)
    %*{"exit_code": 0, "ok": true, "clean": true, "into": intoRef,
       "from": fromRef, "tree": v.tree, "ahead": ahead, "behind": behind,
       "stat": capBytes(stat.output, 4000),
       "detail": fromRef & " merges cleanly into " & intoRef}
  of "conflict":
    var arr = newJArray()
    for p in v.paths: arr.add(%p)
    %*{"exit_code": 0, "ok": true, "clean": false, "into": intoRef,
       "from": fromRef, "tree": v.tree, "conflicts": arr,
       "detail": "merging " & fromRef & " into " & intoRef & " conflicts in " &
         $v.paths.len & " file(s) — resolve them, or merge differently"}
  of "timeout":
    %*{"exit_code": 124, "ok": false, "error": v.detail}
  of "nogit":
    %*{"exit_code": 127, "ok": false, "error": v.detail}
  else:
    # NEVER a conflict list here: git refused, it did not merge.
    %*{"exit_code": 2, "ok": false,
       "error": "cannot preview " & intoRef & "..." & fromRef & ": " & v.detail}

proc mergeStartImpl(repo, into, srcBranch, strategy: string,
                    allowDirty: bool): JsonNode =
  # Required, not defaulted: writePathsFor derives the claim from ARGUMENT
  # VALUES, so a component-side default would take the lease over one tree and
  # write another (WORKTREES.md §4.3, measured). Checked BEFORE resolving the
  # directory, so the refusal can still describe where you are.
  if repo.strip().len == 0:
    let here = getCurrentDir()
    let shape = checkoutShape(here)
    let hint = if shape.primaryRoot.len > 0 and shape.kind != ckRepo:
                 " — you are in " & normalizeRoot(here) & "; the primary is " &
                 shape.primaryRoot
               else: ""
    return refused("merge needs `repo` (the tree to merge INTO)" & hint)
  let start = repoDir(repo)
  let shape = checkoutShape(start)
  if shape.kind == ckNone: return refused("not a git repository: " & start)
  if not validRepo(repo): return refused("invalid repo: " & repo)
  let primary = if shape.primaryRoot.len > 0: shape.primaryRoot else: start
  # `into` defaults to the branch checked out in THIS tree (not the shape of
  # the caller's directory, which may be a different tree entirely).
  var intoRef = into.strip()
  if intoRef.len == 0:
    let cur = runGit(repoArgs(primary) & gitBase &
                     @["rev-parse", "--abbrev-ref", "HEAD"], 15_000)
    if cur.code != 0: return finish(cur.code, cur.output)
    intoRef = cur.output.splitLines()[0].strip()
  var fromRef = srcBranch.strip()
  if fromRef.len == 0:
    # No source named: the branch checked out WHERE THE CALLER IS, which for a
    # worktree conversation is the branch it wants to merge back.
    let callerShape = checkoutShape(getCurrentDir())
    fromRef = if callerShape.branch.len > 0: callerShape.branch else: shape.branch
  if fromRef.len == 0:
    return refused("merge needs `from` (no branch is checked out in " &
                   normalizeRoot(primary) & ")")
  if not validRef(intoRef): return refused("invalid target ref: " & intoRef)
  if not validRef(fromRef): return refused("invalid source ref: " & fromRef)
  if intoRef != "HEAD":
    let cur = runGit(repoArgs(primary) & gitBase &
                     @["rev-parse", "--abbrev-ref", "HEAD"], 15_000)
    if cur.code != 0: return finish(cur.code, cur.output)
    let head = cur.output.splitLines()[0].strip()
    if head != intoRef:
      return refused("the tree at " & normalizeRoot(primary) & " has \"" & head &
        "\" checked out, so it cannot merge INTO \"" & intoRef &
        "\" — check that branch out first, or pass into: \"" & head & "\"")
  # Refuse up front when the target has local changes to a path the merge
  # touches, so the refusal NAMES the paths instead of quoting git's abort.
  if not allowDirty:
    let preview = mergePreviewImpl(primary, intoRef, fromRef)
    if preview{"ok"}.getBool(false) and
        not preview{"clean"}.getBool(true):
      return %*{"exit_code": 2, "ok": false,
                "error": "merging " & fromRef & " into " & intoRef &
                  " would conflict in " & $preview{"conflicts"}.len &
                  " file(s) — preview it with git_merge_preview and resolve " &
                  "the overlap first",
                "conflicts": preview{"conflicts"}}
    var touching: seq[string]
    if preview{"clean"}.getBool(false):
      let changed = runGit(repoArgs(primary) & gitBase &
                           @["diff", "--name-only", intoRef & "..." & fromRef],
                           30_000)
      if changed.code == 0:
        for line in changed.output.splitLines():
          let p = line.strip()
          if p.len > 0: touching.add p
    let dirty = dirtyPaths(primary)
    var overlap: seq[string]
    for p in dirty:
      if p in touching: overlap.add p
    if overlap.len > 0:
      return %*{"exit_code": 2, "ok": false,
                "error": "the target tree has local changes to " &
                  $overlap.len & " path(s) this merge touches: " &
                  overlap.join(", ") & " — commit or stash them, or pass " &
                  "allow_dirty: true",
                "paths": %overlap}
  var gargs = @["merge", "--no-ff", "--no-edit"]
  let st = strategy.strip()
  if st == "ff" or st == "ff-only":
    gargs = @["merge", "--ff-only", "--no-edit"]
  elif st.len > 0 and st != "no-ff":
    return refused("unknown strategy \"" & st & "\" (no-ff | ff | ff-only)")
  gargs.add fromRef
  let r = runGit(repoArgs(primary) & gitBase & gargs, 180_000)
  if r.code != 0:
    let conflicted = runGit(repoArgs(primary) & gitBase &
                            @["diff", "--name-only", "--diff-filter=U"], 30_000)
    var arr = newJArray()
    if conflicted.code == 0:
      for line in conflicted.output.splitLines():
        let p = line.strip()
        if p.len > 0: arr.add(%p)
    if arr.len > 0:
      return %*{"exit_code": 1, "ok": false, "merged": false,
                "conflicts": arr,
                "error": "merge of " & fromRef & " into " & intoRef &
                  " stopped with conflicts in " & $arr.len & " file(s) — " &
                  "resolve them and commit, or git_merge {op: abort}",
                "detail": capBytes(r.output, 3000)}
    return %*{"exit_code": r.code, "ok": false, "merged": false,
              "error": capBytes(r.output, 3000)}
  publishWorktreeChanged(primary)
  let head = runGit(repoArgs(primary) & gitBase & @["rev-parse", "HEAD"],
                    15_000)
  let files = runGit(repoArgs(primary) & gitBase &
                     @["diff", "--name-only", "HEAD@{1}", "HEAD"], 30_000)
  var arr = newJArray()
  if files.code == 0:
    for line in files.output.splitLines():
      let p = line.strip()
      if p.len > 0: arr.add(%p)
  %*{"exit_code": 0, "ok": true, "merged": true, "into": intoRef,
     "from": fromRef,
     "head": (if head.code == 0: head.output.strip() else: ""),
     "files": arr}

proc mergeAbortImpl(repo: string): JsonNode =
  let start = repoDir(repo)
  let shape = checkoutShape(start)
  if shape.kind == ckNone: return refused("not a git repository: " & start)
  if repo.strip().len == 0:
    return refused("merge abort needs `repo` — refusing to guess which tree " &
      "to unwind")
  let primary = if shape.primaryRoot.len > 0: shape.primaryRoot else: start
  # Is a merge actually in progress? git's own marker, not a guess.
  let marker = runGit(repoArgs(primary) & gitBase &
                      @["rev-parse", "--git-path", "MERGE_HEAD"], 15_000)
  if marker.code == 0:
    let path = marker.output.strip()
    let abs = if path.isAbsolute(): path else: primary / path
    if not fileExists(abs):
      return %*{"exit_code": 2, "ok": false,
                "error": "no merge is in progress in " &
                  normalizeRoot(primary)}
  let r = runGit(repoArgs(primary) & gitBase & @["merge", "--abort"], 60_000)
  if r.code != 0: return finish(r.code, r.output)
  %*{"exit_code": 0, "ok": true, "aborted": true,
     "repo": normalizeRoot(primary), "detail": "the merge was unwound"}

proc commitImpl(repo, message: string, paths: seq[string], all,
                amend: bool): JsonNode =
  let start = repoDir(repo)
  let shape = checkoutShape(start)
  if shape.kind == ckNone: return refused("not a git repository: " & start)
  # Required for the same reason merge's is (see mergeStartImpl).
  if repo.strip().len == 0:
    return refused("commit needs `repo` (the tree to commit in)")
  if not validRepo(repo): return refused("invalid repo: " & repo)
  let primary = if shape.primaryRoot.len > 0: shape.primaryRoot else: start
  let msg = message.strip()
  if msg.len == 0: return refused("commit needs a message")
  if msg.contains('\0'): return refused("invalid message")
  # Stage exactly what was named. The point of the verb over `bash git commit`
  # is that the model cannot silently commit an unrelated ignore edit it made
  # an hour ago: unstaged paths OUTSIDE the named set are left alone.
  if paths.len > 0:
    var addArgs = @["add", "--"]
    for p in paths:
      if p.strip().len == 0: continue
      addArgs.add p.strip()
    if addArgs.len == 2: return refused("commit paths were all empty")
    let a = runGit(repoArgs(primary) & gitBase & addArgs, 60_000)
    if a.code != 0: return finish(a.code, a.output)
  elif not all and not amend:
    # Nothing named and not -a: stage tracked modifications only, which is
    # git's own "-u" scope (no surprise untracked files).
    let a = runGit(repoArgs(primary) & gitBase & @["add", "-u"], 60_000)
    if a.code != 0: return finish(a.code, a.output)
  if all and paths.len > 0:
    return refused("pass either `paths` or `all`, not both")
  if all:
    let a = runGit(repoArgs(primary) & gitBase & @["add", "-A"], 60_000)
    if a.code != 0: return finish(a.code, a.output)
  var cargs = @["commit", "-m", msg]
  if amend: cargs.add "--amend"
  let c = runGit(repoArgs(primary) & gitBase & cargs, 180_000)
  if c.code != 0:
    # "nothing to commit" is a normal answer, not a failure to report as a
    # crash. git phrases it several ways; all of them mean the same thing.
    if c.output.contains("nothing to commit") or
        c.output.contains("nothing added to commit") or
        c.output.contains("no changes added"):
      return %*{"exit_code": 1, "ok": false, "committed": false,
                "detail": "nothing to commit"}
    return %*{"exit_code": c.code, "ok": false, "committed": false,
              "error": capBytes(c.output, 3000)}
  let head = runGit(repoArgs(primary) & gitBase & @["rev-parse", "HEAD"],
                    15_000)
  # The receipt the merge step, review_receipt and activity can point at.
  let stat = runGit(repoArgs(primary) & gitBase &
                    @["show", "--stat", "--oneline", "--format=%H", "HEAD"],
                    30_000)
  %*{"exit_code": 0, "ok": true, "committed": true,
     "commit": (if head.code == 0: head.output.strip() else: ""),
     "repo": normalizeRoot(primary),
     "branch": shape.branch,
     "stat": capBytes(stat.output, 3000)}

if mutationsEnabled():
  # The owner tool config_patch calls. Registered only with the surface it
  # configures: an operator who disabled mutations has nothing to patch here.
  discard comp.tool("git_config",
    ownerToolSchema("git.mutations", "git write-verb enablement"),
    proc(c: Component, args: JsonNode): JsonNode =
      c.ownerOp(ownerStore, args))

  comp.tool(%*{"timeoutMs": 45000, "parallel": true, "onDemand": true,
                "effect": "read",
                "workspace": {"cwdField": "repo"},
                "hint": "List this repository's git worktrees, including which conversation owns each one — use before creating or removing a tree, or to see whether your work should happen in a separate tree."}):
    proc git_worktree_list(repo: string = ""): JsonNode =
      ## List every worktree of this repository: path, branch, HEAD, whether
      ## it is locked (and why), whether it is prunable, whether it is the
      ## tree you are calling from, and — from the ownership ledger — which
      ## conversation created it. Use it before `git_worktree add` to see the
      ## container path and existing names, and before `remove` to confirm
      ## nobody else is working in a tree.
      ##
      ## The worktree flow this belongs to: cut a tree for experimental or
      ## parallel work, work there (its writes do not collide with the
      ## primary's), then merge back with `git_merge` and retire it. A tree is
      ## always a SIBLING of the repository (`<repo>.wt/<name>`), never inside
      ## it.
      worktreeListImpl(repo)

  comp.tool(%*{"timeoutMs": 120_000, "onDemand": true, "effect": "write",
                "approval": "always", "sessionId": true,
                "workspace": {"cwdField": "repo"},
                "writes": {"paths": ["repo", "path"]},
                "hint": "Manage git worktrees: cut an isolated sibling tree for experimental or parallel work (add), retire one (remove), or clear records for trees deleted by hand (prune). A tree is a sibling of the repo (<repo>.wt/<name>), never inside it."}):
    proc git_worktree(op: string, repo: string = "", name: string = "",
                      path: string = "", branch: string = "", base: string = "",
                      force: bool = false, delete_branch: bool = false): JsonNode =
      ## Create, remove or prune git worktrees of this repository.
      ##
      ## `add` cuts an isolated SIBLING tree (`<repo>.wt/<name>`, branching
      ## from `base`, default the primary's current branch). Work there when a
      ## task is experimental, threatens uncommitted work, or should run in
      ## parallel: writes in a tree never collide with the primary's, and the
      ## tree leaves no ignore rule behind because it is outside the repo.
      ## `remove` deletes a tree and refuses when another live conversation
      ## owns it or its branch has unmerged commits — both refusals name the
      ## flag that overrides them. The branch is KEPT unless delete_branch is
      ## set. A dirty tree is refused by git itself (its message is surfaced
      ## verbatim).
      ##
      ## To merge the work back, use `git_merge` (or `git_merge_preview`
      ## first); removing a tree does not merge it.
      if op == "add": return worktreeAddImpl(repo, path, name, branch, base)
      if op == "remove":
        return worktreeRemoveImpl(repo, path, force, delete_branch)
      if op == "prune": return worktreePruneImpl(repo)
      refused("op must be \"add\", \"remove\" or \"prune\"")

  # --- merge + commit -----------------------------------------------------
  # The read half is its own tool because x-harness.writes is static per tool.
  comp.tool(%*{"timeoutMs": 120_000, "parallel": true, "onDemand": true,
                "effect": "read",
                "workspace": {"cwdField": "repo"},
                "hint": "Preview what merging one branch into another would do — clean, or which files conflict — without touching any working tree. Use before git_merge."}):
    proc git_merge_preview(repo: string = "", into: string = "",
                           from_ref: string = ""): JsonNode =
      ## What would merging `from` into `into` do? Answers clean/conflicting
      ## and names the conflicting files, WITHOUT touching a working tree
      ## (`git merge-tree`). Use it before `git_merge` to decide whether the
      ## merge is safe, and to see which files need attention when it is not.
      ##
      ## `from` defaults to the branch checked out here (a worktree
      ## conversation previews merging its own branch back); `into` defaults to
      ## the primary's current branch. A bad ref is reported as an ERROR naming
      ## it — never as a conflict list.
      mergePreviewImpl(repo, into, from_ref)

  comp.tool(%*{"timeoutMs": 300_000, "onDemand": true, "effect": "write",
                "approval": "always", "sessionId": true,
                "workspace": {"cwdField": "repo"},
                "writes": {"paths": ["repo", "paths"]},
                "hint": "Merge a branch into a tree (start), or unwind a conflicted merge (abort). Merges the branch you worked in back into the primary — run git_merge_preview first to see whether it conflicts."}):
    proc git_merge(op: string, repo: string = "", into: string = "",
                   from_ref: string = "", strategy: string = "",
                   allow_dirty: bool = false): JsonNode =
      ## Merge one branch into another: the step that brings a worktree's work
      ## home. `repo` is REQUIRED — it is the tree the merge lands in, and the
      ## write lease is taken over exactly what you name (a component-side
      ## default would lock one tree and write another).
      ##
      ## `start` refuses up front when the target has local changes to a path
      ## the merge touches, naming those paths instead of quoting git's abort;
      ## it reports conflicts with the file list, leaving the merge in progress
      ## so it can be resolved and committed. `abort` unwinds a conflicted
      ## merge. Run `git_merge_preview` first when unsure.
      if op == "start":
        return mergeStartImpl(repo, into, from_ref, strategy, allow_dirty)
      if op == "abort": return mergeAbortImpl(repo)
      refused("op must be \"start\" or \"abort\"")

  comp.tool(%*{"timeoutMs": 300_000, "onDemand": true, "effect": "write",
                "approval": "always", "sessionId": true,
                "workspace": {"cwdField": "repo"},
                "writes": {"paths": ["repo", "paths"]},
                "hint": "Commit in a tree with the message you already composed, staging only the paths you name. Prefer this over `bash git commit`: the conversation knows what changed and why, and naming paths keeps an unrelated edit out of the commit."}):
    proc git_commit(repo: string, message: string, paths: seq[string] = @[],
                    all: bool = false, amend: bool = false): JsonNode =
      ## Commit work in a tree, with the message the conversation just
      ## composed. `paths` stages exactly those files (so an unrelated edit you
      ## made earlier is NOT swept in); with neither `paths` nor `all` it stages
      ## tracked modifications only. `all` stages everything including
      ## untracked files. Returns the commit id and a stat receipt, which the
      ## merge step and review_receipt can point at.
      ##
      ## `repo` is REQUIRED: it is the tree the commit lands in.
      commitImpl(repo, message, paths, all, amend)

# The declaration rides the idle seam, like every other owner: it must not
# block boot, and it must survive a config component that is not up yet.
var gitConfigDeclared = false
discard comp.onIdle(1000) do (c: Component):
  if not gitConfigDeclared:
    gitConfigDeclared = c.declareConfig(gitDecl) or gitConfigDeclared

resolveGit()
comp.run()
