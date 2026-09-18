## Workspace awareness for agents that work in more than one tree.
##
## A conversation starts in one workspace, but real work spans several: a git
## worktree per branch, a second checkout of the same repository (the dev tree
## and the deployed clone, side by side), a plain sibling directory. Components
## used to compare every path against the single workspace root, so anything
## else was "outside" — which meant no LSP diagnostics for those edits, and no
## way for a component to know the two trees were even related.
##
## This module answers the one question they all share: *which directories
## belong to this conversation?* It asks **git**, which is the repo layer — no
## file-type or language knowledge here. The result is data for components
## (path scoping, which root a language server instance belongs to) and for
## core's private per-call context; it is deliberately **never** rendered into
## the frozen system prompt or the frozen tool schemas, so a worktree appearing
## mid-conversation can widen what components accept without changing a byte of
## the request prefix (AGENTS.md, prompt-cache discipline).
##
## Best-effort by construction: no git, no repo, a weird remote — the set is
## just the primary workspace. Awareness is an improvement, never a requirement.

import std/[algorithm, os, osproc, streams, strutils]

const
  maxWorkspaceRoots* = 8
    ## Scope list, not a filesystem walk: the primary, its worktrees and its
    ## sibling checkouts. Past this, the extra roots stop being "the same
    ## project" and start being "the disk".

proc gitLines(dir: string, args: seq[string]): seq[string] =
  ## One best-effort git query. A missing repo, a missing binary or a nonzero
  ## exit all yield nothing — the caller falls back to the primary workspace.
  try:
    let p = startProcess("git", workingDir = dir, args = @["-C", dir] & args,
                         options = {poUsePath, poStdErrToStdOut})
    let outp = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    if code != 0: return @[]
    for line in outp.splitLines():
      let trimmed = line.strip()
      if trimmed.len > 0: result.add(trimmed)
  except CatchableError:
    discard

proc normalizeRoot*(path: string): string =
  ## One spelling per root — absolute, symlinks resolved where possible, no
  ## trailing separator — so a root git reports and the same root typed by hand
  ## compare equal, and duplicates collapse.
  if path.len == 0: return ""
  var p = path
  try: p = expandFilename(absolutePath(p))
  except CatchableError:
    try: p = absolutePath(p)
    except CatchableError: discard
  while p.len > 1 and p[^1] == '/': p.setLen(p.len - 1)
  p

proc sameOrigin(dir, origin: string, known: seq[string]): bool =
  ## Direct siblings only: a directory counts when it is its own checkout of
  ## the *same* remote. Two clones of one repository at different revisions
  ## (the dev tree and the deployed clone) are what this is for — they are the
  ## normal case in this harness, and `git worktree list` cannot see them. A
  ## clone made from a local path (`git clone /path/to/checkout`) records that
  ## path as its origin instead of the remote URL: same project, stated
  ## differently, so a path origin matching a known root counts too.
  for line in gitLines(dir, @["remote", "get-url", "origin"]):
    if line == origin: return true
    if not line.isAbsolute(): continue
    let norm = normalizeRoot(line)
    if norm.len == 0: continue
    for k in known:
      if norm == k or norm.startsWith(k & "/"): return true
  false

proc computeWorkspaceRoots*(primary: string,
                            maxRoots = maxWorkspaceRoots): seq[string] =
  ## The conversation's workspace set: primary first (it is the one relative
  ## paths resolve against), then linked git worktrees in git's order, then
  ## same-origin sibling checkouts sorted by path. Deduped, capped, stable.
  let root = normalizeRoot(primary)
  if root.len == 0: return @[]
  result.add(root)
  for line in gitLines(root, @["worktree", "list", "--porcelain"]):
    if not line.startsWith("worktree "): continue
    let wt = normalizeRoot(line["worktree ".len .. ^1])
    if wt.len > 0 and wt != root and wt notin result and result.len < maxRoots:
      result.add(wt)
  var origin = ""
  for line in gitLines(root, @["remote", "get-url", "origin"]):
    if origin.len == 0: origin = line
  if origin.len > 0:
    var siblings: seq[string]
    try:
      for kind, path in walkDir(root.parentDir()):
        if kind != pcDir: continue
        let cand = normalizeRoot(path)
        if cand.len == 0 or cand in result: continue
        if not dirExists(cand / ".git"): continue
        if sameOrigin(cand, origin, result): siblings.add(cand)
    except CatchableError:
      discard
    sort(siblings)
    for s in siblings:
      if result.len >= maxRoots: break
      result.add(s)
