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
  let self = getAppFilename()
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
  if gGitPath.len == 0 or sameFile(gGitPath, getAppFilename()):
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
  result = %*{"exit_code": code,
              "output": capBytes(
                capLines(o, maxLines, label = "lines",
                         hint = "narrow the scope"),
                maxOutputBytes,
                hint = "scope with path or narrow the ref for the missing part")}

proc refused(msg: string): JsonNode =
  ## Argument refused before any git process runs.
  %*{"exit_code": 2, "output": "[refused] " & msg}

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
      return %*{"exit_code": 0, "output": "[no changes since HEAD]"}
    return finish(code, output, if stat: 500 else: 10_000)

comp.tool(%*{"timeoutMs": 45000, "parallel": true, "onDemand": true,
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
      return %*{"exit_code": 0, "output": "[no commits matched]"}
    return finish(code, output, min(max(max_count, 1), 200) + 1)

comp.tool(%*{"timeoutMs": 45000, "parallel": true, "onDemand": true,
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

comp.tool(%*{"timeoutMs": 45000}):
  proc review_receipt(op: string = "write", findings: string = "", model: string = ""): JsonNode =
    ## Local review receipt for pre-push handoff (CodeWhale borrow,
    ## docs/research/CODEWHALE.md docs/RECEIPTS.md): records WHAT was
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

resolveGit()
comp.run()
