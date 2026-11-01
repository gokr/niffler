## Git checkout shape — one answer to "what kind of tree is this directory?"
##
## A repository can be present on disk in several shapes, and the differences
## decide real behaviour: a linked `git worktree` shares another checkout's
## object store while having its own working tree and branch; a submodule also
## has `gitDir != commonDir` but is a *different* repository; a plain clone is
## its own everything. Three places in this tree answered those questions by
## hand, differently:
##
##   core/workspace.nim           shells `git worktree list --porcelain` and
##                                keeps a same-origin sibling heuristic
##   components/systemprompt      parses the `.git` *file* for `.git/worktrees/<n>`
##                                to avoid applying the main tree's AGENTS.md twice
##   components/lsp/roots.nim     walks language markers independently
##
## Each is correct enough alone; together they are three ways to be wrong about
## one repository. This module is the single answer, so a worktree, its primary
## and a submodule cannot be classified differently by two callers.
##
## Deliberately NOT part of the wire contract: unlike `envelope.nim` and
## `subjects.nim` (which the Go and TS SDKs mirror 1:1), this is a local
## filesystem/git convenience. A client in another language may compute the same
## facts however it likes; nothing crosses the bus because of this file.
##
## Best-effort by construction, like the workspace set it feeds: no git, no
## repo, a weird remote — every query degrades to `ckNone` and the caller falls
## back to its own default rather than failing.

import std/[os, osproc, streams, strutils]

type
  CheckoutKind* = enum
    ckNone             ## not inside a git repository (or git is unavailable)
    ckRepo             ## the primary checkout of its repository
    ckLinkedWorktree   ## a `git worktree` of another checkout (own branch/tree,
                       ## shared object store)
    ckSubmodule        ## a submodule: gitDir differs from commonDir, but it is
                       ## a repository of its own (see `superproject`)

  Checkout* = object
    kind*: CheckoutKind
    root*: string          ## working-tree root containing the queried path
    gitDir*: string        ## this checkout's git dir (absolute; differs in a
                           ## worktree: <common>/worktrees/<name>)
    commonDir*: string     ## the shared git dir (absolute)
    primaryRoot*: string   ## the primary checkout's working tree; "" when it
                           ## cannot be determined
    branch*: string        ## short branch name; "" when detached
    superproject*: string  ## non-empty inside a submodule: its parent tree

  Worktree* = object
    ## One entry of `git worktree list`, including the primary checkout (which
    ## git reports first). `locked`/`prunable` carry git's own facts so callers
    ## do not have to re-parse porcelain.
    path*: string
    head*: string
    branch*: string         ## short name; "" when detached
    detached*: bool
    bare*: bool
    locked*: bool
    lockReason*: string
    prunable*: bool

const gitTimeoutMs* = 15_000
  ## One git query is a local operation; a number this large only covers a
  ## cold filesystem. Callers on a latency-sensitive path (a dispatch gate)
  ## should use `checkoutShape` with `cache` rather than re-running these.

# ---------------------------------------------------------------------------
# one best-effort git invocation

proc gitQuery*(dir: string, args: openArray[string],
               timeoutMs = gitTimeoutMs): tuple[code: int, output: string] =
  ## Run `git -C <dir> <args>` and return its combined output. A missing
  ## binary, a missing repo or a nonzero exit all come back as a code the
  ## caller can test; nothing raises.
  if dir.len == 0: return (127, "")
  let exe = findExe("git")
  if exe.len == 0: return (127, "")
  var argv = @["-C", dir]
  for a in args: argv.add(a)
  try:
    let r = startProcess(exe, args = argv,
                         options = {poUsePath, poStdErrToStdOut})
    let outp = r.outputStream.readAll()   # drain BEFORE waiting: a chatty
    let code = r.waitForExit(timeoutMs)   # child deadlocks a pipe otherwise
    r.close()
    result = (code, outp)
  except CatchableError:
    result = (127, "")

proc gitLines*(dir: string, args: openArray[string],
               timeoutMs = gitTimeoutMs): seq[string] =
  ## The trimmed non-empty lines of one git query; empty on any failure.
  let (code, outp) = gitQuery(dir, args, timeoutMs)
  if code != 0: return @[]
  for line in outp.splitLines():
    let trimmed = line.strip()
    if trimmed.len > 0: result.add(trimmed)

proc normalizeRoot*(path: string): string =
  ## One spelling per root — absolute, symlinks resolved where possible, no
  ## trailing separator — so a root git reports and the same root typed by hand
  ## compare equal, and duplicates collapse. Identical in behaviour to
  ## core/workspace.nim's and components/lsp/roots.nim's copies; this is the
  ## definition the other two now delegate to.
  if path.len == 0: return ""
  var p = path
  try: p = expandFilename(absolutePath(p))
  except CatchableError:
    try: p = absolutePath(p)
    except CatchableError: discard
  while p.len > 1 and p[^1] == '/': p.setLen(p.len - 1)
  p

# ---------------------------------------------------------------------------
# shape

proc branchShortName(gitRef: string): string =
  ## "refs/heads/feat" -> "feat"; anything else (a tag, a raw sha) passes
  ## through unchanged, because inventing a name would be worse than an odd one.
  const prefix = "refs/heads/"
  if gitRef.len == 0: return ""
  if gitRef.startsWith(prefix): gitRef[prefix.len .. ^1] else: gitRef

proc parseWorktrees*(porcelain: string): seq[Worktree] =
  ## Parse `git worktree list --porcelain`. Records are blank-line separated,
  ## start with `worktree <path>`, and carry optional `bare`/`detached`/
  ## `locked [reason]`/`prunable [reason]` lines. Tolerant by design: an
  ## unknown attribute is ignored rather than failing the parse, so a future
  ## git that adds a line cannot break worktree awareness.
  ##
  ## Note `locked`/`prunable` MAY carry a reason after the keyword
  ## (verified: `git worktree lock --reason "..."` produces
  ## `locked niffler conversation abc`, and a lost dir produces
  ## `prunable gitdir file points to non-existent location`).
  # Accumulate into a local seq: a nested proc capturing `result` violates
  # Nim's memory-safety rules for seq returns.
  var trees: seq[Worktree]
  var current = Worktree()
  var haveCurrent = false
  proc flush() =
    if haveCurrent and current.path.len > 0:
      trees.add current
    current = Worktree()
    haveCurrent = false
  for rawLine in porcelain.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      flush()
      continue
    if line.startsWith("worktree "):
      flush()
      current.path = line["worktree ".len .. ^1].strip()
      haveCurrent = true
    elif line.startsWith("HEAD "):
      current.head = line["HEAD ".len .. ^1].strip()
    elif line.startsWith("branch "):
      current.branch = branchShortName(line["branch ".len .. ^1].strip())
    elif line == "detached":
      current.detached = true
    elif line == "bare":
      current.bare = true
    elif line == "locked" or line.startsWith("locked "):
      current.locked = true
      if line.len > "locked".len:
        current.lockReason = line["locked ".len .. ^1].strip()
    elif line == "prunable" or line.startsWith("prunable "):
      current.prunable = true
  flush()
  result = trees

proc worktrees*(repoDir: string, timeoutMs = gitTimeoutMs): seq[Worktree] =
  ## Every working tree of the repository containing `repoDir`, primary first
  ## (git's own order). Empty when the directory is not a repository.
  let (code, outp) = gitQuery(repoDir, ["worktree", "list", "--porcelain"],
                              timeoutMs)
  if code != 0: return @[]
  parseWorktrees(outp)

proc gitDirs*(dir: string, timeoutMs = gitTimeoutMs):
              tuple[gitDir, commonDir: string] =
  ## This checkout's git dir and the shared one, both absolute. Empty when the
  ## directory is not inside a repository. One invocation (git's rev-parse
  ## accepts several queries and answers one line each), which is why the two
  ## are resolved together: comparing them IS the worktree test.
  let lines = gitLines(dir, ["rev-parse", "--git-dir", "--git-common-dir"],
                       timeoutMs)
  if lines.len < 2: return ("", "")
  # A relative answer is relative to the queried directory (git prints ".git"
  # in the primary checkout), so resolve against it before comparing.
  proc resolveOne(p: string): string =
    if p.len == 0: return ""
    normalizeRoot(if p.isAbsolute(): p else: dir / p)
  (resolveOne(lines[0]), resolveOne(lines[1]))

proc primaryRootOf*(checkout: Checkout): string =
  ## The primary checkout's working tree, derived from the shared git dir:
  ## the parent of `…/.git`. Uniform by design — in a plain clone the primary
  ## checkout IS the clone, so the answer is the clone itself, and a caller
  ## never needs a special case for "am I already the primary". Use `kind` /
  ## `isLinkedWorktree` to tell the two apart.
  ##
  ## Refused ("") when it cannot be proven: a bare repository (the shared dir
  ## is not named `.git`) or a layout that does not look like `…/.git`.
  if checkout.commonDir.len == 0: return ""
  if checkout.kind notin {ckRepo, ckLinkedWorktree, ckSubmodule}: return ""
  let name = checkout.commonDir.splitFile().name
  if name != ".git": return ""
  let parent = checkout.commonDir.parentDir()
  if parent.len == 0 or not dirExists(parent): return ""
  normalizeRoot(parent)

proc checkoutShape*(dir: string, timeoutMs = gitTimeoutMs): Checkout =
  ## Classify the tree containing `dir`. Three git queries at most
  ## (`rev-parse`, `superproject`, `abbrev-ref`), all local, and only on a miss.
  ##
  ## `ckLinkedWorktree` is decided the way git decides it: this checkout's git
  ## dir differs from the shared one, AND the checkout is not a submodule.
  ##
  ## Measured on git 2.43, because the folklore is wrong in both directions:
  ##
  ##   plain clone   git-dir .git                       common-dir .git
  ##   linked tree   git-dir .git/worktrees/<name>      common-dir .git
  ##   submodule     git-dir .git/modules/<name>        common-dir .git/modules/<name>
  ##
  ## So a submodule does NOT differ today, and the superproject guard is
  ## defence rather than necessity (an older git, or a `GIT_DIR` exported by a
  ## caller, can make the pair report differently — both re-measured here).
  ## The guard is kept because the classification is cheap and being wrong
  ## would report a submodule as a worktree of its parent, which changes what
  ## an agent believes it may edit.
  result = Checkout(kind: ckNone)
  if dir.len == 0 or not dirExists(dir): return
  let (gitDir, commonDir) = gitDirs(dir, timeoutMs)
  if gitDir.len == 0 or commonDir.len == 0: return
  result.gitDir = gitDir
  result.commonDir = commonDir
  # The working-tree root: `--show-toplevel` (a submodule answers its own
  # tree, which is what we want — the file lives in that tree).
  let tops = gitLines(dir, ["rev-parse", "--show-toplevel"], timeoutMs)
  result.root = if tops.len > 0: normalizeRoot(tops[0]) else: normalizeRoot(dir)
  let supers = gitLines(dir, ["rev-parse", "--show-superproject-working-tree"],
                        timeoutMs)
  if supers.len > 0: result.superproject = normalizeRoot(supers[0])
  # Submodule first: it is a repository of its own, and reporting it as a repo
  # is right, but reporting it as a WORKTREE of its parent would be wrong.
  # Deciding on the superproject rather than on the dir comparison keeps that
  # true however a particular git reports the two dirs.
  if result.superproject.len > 0:
    result.kind = ckSubmodule
  elif gitDir == commonDir:
    result.kind = ckRepo
  else:
    result.kind = ckLinkedWorktree
  let br = gitLines(dir, ["rev-parse", "--abbrev-ref", "HEAD"], timeoutMs)
  if br.len > 0 and br[0] != "HEAD": result.branch = br[0]
  result.primaryRoot = primaryRootOf(result)

proc isLinkedWorktree*(dir: string, timeoutMs = gitTimeoutMs): bool =
  ## The one question most callers actually ask.
  checkoutShape(dir, timeoutMs).kind == ckLinkedWorktree

# ---------------------------------------------------------------------------
# workspace-set membership (shared by core and components)

proc pathInRoots*(path: string, roots: openArray[string]): bool =
  ## True when `path` is one of `roots` or below one, compared on normalized
  ## absolute spellings with a separator boundary — so `/repo2` never matches
  ## `/repo`, and a sibling `<repo>.wt/x` is NOT contained by `<repo>` (the
  ## byte after `repo` is `.`, not `/`). That boundary is what makes the
  ## sibling worktree layout disjoint from the primary's opaque write claim.
  let target = normalizeRoot(path)
  if target.len == 0: return false
  for root0 in roots:
    let root = normalizeRoot(root0)
    if root.len == 0: continue
    if target == root or target.startsWith(root & "/"):
      return true
  false

proc containingRoot*(path: string, roots: openArray[string]): string =
  ## The DEEPEST root containing `path`, or "" when none does. "Deepest" keeps
  ## the answer meaningful if a nested layout reappears (an in-repo worktree
  ## inside the primary's root): the more specific tree wins, which is the one
  ## a write actually lands in.
  let target = normalizeRoot(path)
  if target.len == 0: return ""
  for root0 in roots:
    let root = normalizeRoot(root0)
    if root.len == 0: continue
    if (target == root or target.startsWith(root & "/")) and
       root.len > result.len:
      result = root
