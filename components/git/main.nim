## git component — read-only git inspection as first-class tools:
## `git_status`, `git_diff`, `git_log`, `git_show`, `git_blame`.
##
## Git mutations stay in bash (approval-gated, arbitrary git); these five
## cover the 90% inspection traffic the LLM actually needs — repo state,
## diffs, history, and attribution — without a human prompt on every call
## and without the bash failure class (wrong flags, pager dumps, quotepath
## escapes, 200KB output caps). Every subcommand runs with fixed flags as
## an argv (never through an unquoted shell), scoped to the harness root:
## paths must be relative and stay inside it, refs are validated, output
## is capped (~40KB, plus per-tool line caps) with narrowing hints.
##
## Exit codes follow git (0/1/2, 128 fatal), 124 = timeout, 127 = git
## missing; "not a git repository" is flagged so the LLM knows the
## harness root is not inside a repo. Read-only, so approval-free.

import std/[json, os, sequtils, strutils]
import niffler/sdk

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
    o = "[no git repository at the harness root]\n" & o
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

comp.tool(%*{"timeoutMs": 45000, "parallel": true}):
  proc git_status(path: string = ""): JsonNode =
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
    ## - path: File or directory to scope the status to (default "" = whole repo)
    if not validPath(path):
      return refused("path must stay inside the harness root: no absolute " &
        "paths, no `..` — scope with a relative path instead")
    var args = gitBase & @["status", "--porcelain=v1", "-b"]
    if path.len > 0:
      args.add(["--", path])
    let (code, output) = runGit(args, 30_000)
    return finish(code, output, 200)

comp.tool(%*{"timeoutMs": 45000, "parallel": true}):
  proc git_diff(path: string = "", unified: int = 3, stat: bool = false): JsonNode =
    ## Diff of everything changed since the last commit (staged AND
    ## unstaged — `git diff HEAD`) with context lines. Use it to review
    ## your own edits before reporting done, or to see exactly what
    ## someone else changed. Untracked files are NOT shown here — check
    ## git_status for those. stat: true switches to a compact one-line-
    ## per-file summary (additions/deletions only), much cheaper to read
    ## when you only need the shape of a change. Read-only and
    ## approval-free; prefer over `git diff` in bash (fixed flags, no
    ## pager, capped output). When truncated, scope with path.
    ## - path: File or directory to limit the diff to (default "" = whole repo)
    ## - unified: Context lines around each hunk (default 3, 0..50)
    ## - stat: Compact per-file summary instead of the full diff
    if not validPath(path):
      return refused("path must stay inside the harness root: no absolute " &
        "paths, no `..` — scope with a relative path instead")
    var args = gitBase & @["diff"]
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

comp.tool(%*{"timeoutMs": 45000, "parallel": true}):
  proc git_log(path: string = "", max_count: int = 20, author: string = ""): JsonNode =
    ## Recent commit history, one line per commit: short hash, subject,
    ## and branch/tag decorations. Use it to see what changed recently,
    ## find when something landed, or pick a ref for git_show. Filter by
    ## path (only commits touching one file or directory) or author
    ## (substring match against the author name, e.g. "krampe").
    ## Read-only and approval-free; prefer over `git log` in bash —
    ## max_count caps lines so the history can never page-dump.
    ## - path: Only commits touching this file or directory (default "" = all)
    ## - max_count: Number of commits to list (default 20, max 200)
    ## - author: Only commits whose author name contains this substring
    if not validPath(path):
      return refused("path must stay inside the harness root: no absolute " &
        "paths, no `..` — scope with a relative path instead")
    if not validAuthor(author):
      return refused("author must be a plain substring (no leading -, no " &
        "newlines, under 200 chars)")
    var args = gitBase & @["log", "--oneline", "--decorate", "-n",
                           $min(max(max_count, 1), 200)]
    if author.len > 0:
      args.add("--author=" & author)
    if path.len > 0:
      args.add(["--", path])
    let (code, output) = runGit(args, 15_000)
    if code == 0 and output.strip().len == 0:
      return %*{"exit_code": 0, "output": "[no commits matched]"}
    return finish(code, output, min(max(max_count, 1), 200) + 1)

comp.tool(%*{"timeoutMs": 45000, "parallel": true}):
  proc git_show(rev: string, path: string = ""): JsonNode =
    ## Show one commit in full: metadata, message, and the complete diff
    ## (optionally limited to one path). Use it after git_log to see what
    ## a commit actually did, or with a hash from git_blame to understand
    ## why a line exists. Read-only and approval-free; output is capped —
    ## for very large commits scope with path.
    ## - rev: Commit to show — hash (short ok), branch, tag, or revision
    ##   expression like HEAD or HEAD~2
    ## - path: Limit the shown diff to this file or directory (default "" = whole commit)
    if not validRef(rev):
      return refused("rev must be a plain revision (hash, branch, tag, " &
        "HEAD~N) — no leading -, no spaces, under 256 chars")
    if not validPath(path):
      return refused("path must stay inside the harness root: no absolute " &
        "paths, no `..` — scope with a relative path instead")
    var args = gitBase & @["show", rev]
    if path.len > 0:
      args.add(["--", path])
    let (code, output) = runGit(args, 20_000)
    return finish(code, output)

comp.tool(%*{"timeoutMs": 45000, "parallel": true}):
  proc git_blame(path: string, start_line: int = 1, max_lines: int = 200): JsonNode =
    ## Line-by-line attribution for one file: for each line, the commit
    ## that last touched it, its author, and the line content. Use it to
    ## find out why a line exists (then git_show the hash), or who last
    ## edited a section. Lines changed but not yet committed show
    ## "Not Committed Yet". Read-only and approval-free; output is line-
    ## capped — page through large files with start_line/max_lines.
    ## - path: File to blame (relative to the harness root)
    ## - start_line: First line to show (1-based, default 1)
    ## - max_lines: How many lines to show (default 200, max 500)
    if not validPath(path) or path.len == 0:
      return refused("path is required and must stay inside the harness " &
        "root: a relative file path, no absolute paths, no `..`")
    var args = gitBase & @["blame", "--abbrev", "-L",
                           $min(max(start_line, 1), 1_000_000) & ",+" &
                           $min(max(max_lines, 1), 500),
                           "--", path]
    let (code, output) = runGit(args, 30_000)
    return finish(code, output, min(max(max_lines, 1), 500) + 1)

resolveGit()
comp.run()
