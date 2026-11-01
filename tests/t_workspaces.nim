## workspace-set tests — which trees does a conversation consider its own?
##
## Hermetic: real git repositories in a temp dir, no bus, no harness. The set is
## what lets a component accept work in a sibling checkout or a worktree instead
## of refusing it as "outside the workspace" (components/lsp used to refuse
## exactly that, so an agent editing another clone got no diagnostics), and it
## is deliberately data only — never rendered into the frozen prompt, so a new
## worktree cannot invalidate a conversation's cache.

import std/[os, osproc, sequtils, strutils]
import helpers
import ../core/workspace
import ../sdk/checkout

proc git(dir: string, args: varargs[string]): string =
  var cmd = @["-C", dir]
  for a in args: cmd.add(a)
  let (outp, code) = execCmdEx("git " & cmd.mapIt(quoteShell(it)).join(" ") &
                               " 2>&1")
  if code != 0:
    fail("git " & args.join(" ") & " in " & dir & ": " & outp.strip())
  outp

proc initRepo(dir: string) =
  createDir(dir)
  discard git(dir, "init", "-q", "-b", "main")
  discard git(dir, "config", "user.email", "t@example.invalid")
  discard git(dir, "config", "user.name", "workspace test")
  writeFile(dir / "README.md", "hello\n")
  discard git(dir, "add", "README.md")
  discard git(dir, "commit", "-q", "-m", "init")

proc main() =
  let tmp = tempRoot("workspaces")
  defer: removeDir(tmp)

  let primary = tmp / "primary"
  initRepo(primary)
  # a linked worktree (shares the git dir; `.git` there is a *file*)
  let wt = tmp / "primary-feature"
  discard git(primary, "worktree", "add", "-q", wt, "-b", "feature")
  discard git(primary, "remote", "add", "origin", "https://example.invalid/proj.git")
  # two shapes of "the same project, checked out twice": a clone from the local
  # path (its origin IS the path) and an independent clone of the same remote
  # (origin URLs equal — the dev-tree/deployed-clone case in this harness)
  let sibling = tmp / "proj-deployed"
  discard git(tmp, "clone", "-q", primary, sibling)
  let sibling2 = tmp / "proj-second-clone"
  discard git(tmp, "clone", "-q", primary, sibling2)
  discard git(sibling2, "remote", "set-url", "origin",
              "https://example.invalid/proj.git")
  # and an unrelated checkout: same parent, different origin
  let stranger = tmp / "unrelated"
  initRepo(stranger)
  discard git(stranger, "remote", "add", "origin", "https://example.invalid/other.git")

  let roots = computeWorkspaceRoots(primary)
  let prim = normalizeRoot(primary)
  let wtN = normalizeRoot(wt)
  let sibN = normalizeRoot(sibling)
  check("the primary workspace comes first",
        roots.len > 0 and roots[0] == prim, $roots)
  check("a linked git worktree is part of the set", wtN in roots, $roots)
  check("a same-origin sibling checkout is part of the set", sibN in roots, $roots)
  check("a sibling cloned from the local path is part of the set",
        normalizeRoot(sibling2) in roots, $roots)
  check("an unrelated sibling checkout is not",
        normalizeRoot(stranger) notin roots, $roots)
  check("the primary appears once", roots.count(prim) == 1, $roots)

  # --- checkout shape (sdk/checkout.nim) -----------------------------------
  # One answer to "what kind of tree is this?" replacing three hand-rolled
  # parses. The submodule case is the one a naive `gitDir != commonDir` test
  # gets wrong, so it is asserted explicitly.
  let primaryShape = checkoutShape(primary)
  check("the primary checkout is ckRepo",
        primaryShape.kind == ckRepo, $primaryShape.kind)
  check("its git dir and common dir are the same",
        primaryShape.gitDir == primaryShape.commonDir)
  check("its working-tree root is itself",
        primaryShape.root == prim, primaryShape.root)
  # primaryRoot is uniform: in a plain clone the primary checkout IS the clone,
  # so a caller never special-cases "am I already the primary" (the `kind` is
  # what distinguishes the two).
  check("its primaryRoot is itself (it IS the primary)",
        primaryShape.primaryRoot == prim, primaryShape.primaryRoot)
  check("it reports its branch", primaryShape.branch == "main", primaryShape.branch)

  let wtShape = checkoutShape(wt)
  check("a linked worktree is ckLinkedWorktree",
        wtShape.kind == ckLinkedWorktree, $wtShape.kind)
  check("its git dir differs from the common dir",
        wtShape.gitDir != wtShape.commonDir,
        wtShape.gitDir & " vs " & wtShape.commonDir)
  check("it knows its root is itself", wtShape.root == wtN, wtShape.root)
  check("its primaryRoot is the primary checkout",
        wtShape.primaryRoot == prim, wtShape.primaryRoot)
  check("it reports the worktree's branch", wtShape.branch == "feature",
        wtShape.branch)

  # git worktree list, parsed: primary first, both recorded, and a lock reason
  # survives (the ledger's fallback depends on reading it back).
  let trees = worktrees(primary)
  check("worktree list has the primary and the linked tree", trees.len == 2,
        $trees.len)
  check("the primary comes first in git's order",
        normalizeRoot(trees[0].path) == prim, trees[0].path)
  check("the linked tree is recorded with its branch", trees[1].branch == "feature",
        trees[1].branch)
  check("nothing is locked yet", not trees[1].locked, $trees[1].locked)
  discard git(primary, "worktree", "lock", "--reason", "test reason", wt)
  let locked = worktrees(primary)
  check("a locked tree reports locked + the reason",
        locked.len == 2 and locked[1].locked and
        locked[1].lockReason == "test reason", $locked[1].lockReason)
  discard git(primary, "worktree", "unlock", wt)

  # a submodule: gitDir != commonDir, but it is NOT a worktree of the parent
  let subHost = tmp / "subhost"
  initRepo(subHost)
  discard git(subHost, "-c", "protocol.file.allow=always", "submodule", "add",
              "-q", primary, "inner")
  discard git(subHost, "commit", "-qm", "add submodule")
  let subPath = subHost / "inner"
  if dirExists(subPath / ".git") or fileExists(subPath / ".git"):
    let subShape = checkoutShape(subPath)
    check("a submodule is ckSubmodule, not a worktree",
          subShape.kind == ckSubmodule, $subShape.kind)
    check("a submodule names its superproject",
          subShape.superproject.len > 0, subShape.superproject)
  else:
    check("submodule fixture could not be created (skipped)", true)

  # --- pathInRoots / containingRoot ----------------------------------------
  # The separator boundary is what makes the sibling <repo>.wt/<name> layout
  # disjoint from <repo> — the arbitration argument for that layout rests here.
  check("a path is in its root", pathInRoots(prim / "a.txt", @[prim]))
  check("the root itself is in the set", pathInRoots(prim, @[prim]))
  check("a sibling <repo>.wt tree is NOT inside <repo>",
        not pathInRoots(prim & ".wt/feat", @[prim]), prim & ".wt/feat")
  check("a same-prefix sibling is NOT inside <repo>",
        not pathInRoots("/repo2/x", @["/repo"]))
  check("containingRoot picks the tree that holds it",
        containingRoot(prim / "src/x.nim", @[prim, wtN]) == prim)
  check("containingRoot returns '' outside every root",
        containingRoot("/elsewhere/x", @[prim, wtN]) == "")

  # --- non-repos and broke cases: awareness is an improvement, not a need ----
  let plain = tmp / "plain"
  createDir(plain)
  check("a directory that is not a repo is still its own workspace",
        computeWorkspaceRoots(plain) == @[normalizeRoot(plain)],
        $computeWorkspaceRoots(plain))
  check("an empty path yields no roots", computeWorkspaceRoots("") == @[],
        $computeWorkspaceRoots(""))
  check("a missing directory still normalizes to one root",
        computeWorkspaceRoots(tmp / "does-not-exist").len == 1,
        $computeWorkspaceRoots(tmp / "does-not-exist"))
  # checkout shape degrades the same way: no repo is not an error
  check("a plain directory is ckNone",
        checkoutShape(plain).kind == ckNone, $checkoutShape(plain).kind)
  check("an empty path is ckNone", checkoutShape("").kind == ckNone)
  check("a missing directory is ckNone",
        checkoutShape(tmp / "nope").kind == ckNone)

  # --- the cap is a bound, not a promise -----------------------------------
  let capped = computeWorkspaceRoots(primary, 2)
  check("the set is capped", capped.len == 2, $capped)
  check("the cap keeps the primary first", capped[0] == prim, $capped)

  report("WORKSPACES TEST")

main()
