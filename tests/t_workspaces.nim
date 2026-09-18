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

  # --- the cap is a bound, not a promise -----------------------------------
  let capped = computeWorkspaceRoots(primary, 2)
  check("the set is capped", capped.len == 2, $capped)
  check("the cap keeps the primary first", capped[0] == prim, $capped)

  report("WORKSPACES TEST")

main()
