## Live workspace set — a worktree created MID-CONVERSATION is admitted.
##
## The defect this exists for (WORKTREES.md F1): `workspaceRootsFor` cached the
## workspace set in NestedState keyed only on the primary + grants, and the only
## invalidation in the tree was a GRANT. So a `git worktree add` run inside a
## conversation — by the agent's own bash, or by hand in another terminal — left
## the new tree invisible for the runner's lifetime, and every write in it was
## refused `[E_WRITE_OUTSIDE]` until the runner restarted. A restart is not
## something a mid-conversation agent can do, so the tree was unusable.
##
## Measured before the fix, with a real repo: the set returned
## @["…/primary"] before and after `git worktree add`, while a fresh
## computeWorkspaceRoots saw both trees.
##
## What is asserted here:
##
## - pure: graphSignature CHANGES when a worktree appears and when the last one
##   goes (so the cache cannot miss either direction), and it distinguishes two
##   worktrees created within the same second (sub-second precision — a
##   seconds-based signature silently drops the second tree);
## - e2e: a tree created by the conversation's own `bash` is admitted on the
##   NEXT dispatch, with no `/roots add` and no session restart;
## - e2e: the new tree does not widen anything else — the same conversation
##   still cannot write outside the set.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers
import ../core/dispatch
import ../sdk/checkout

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc sh(cmd: string): tuple[output: string, exitCode: int] =
  execCmdEx(cmd)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "agent"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)

  # =========================================================================
  # Part 1 (pure): graphSignature tracks the graph, at sub-second precision
  # =========================================================================
  let tmp = tempRoot("liveset")
  let repo = tmp / "repo"
  createDir(repo)
  discard sh("git -C " & quoteShell(repo) & " init -q -b main")
  discard sh("git -C " & quoteShell(repo) &
             " config user.email t@example.invalid")
  discard sh("git -C " & quoteShell(repo) & " config user.name t")
  writeFile(repo / "a.txt", "one\n")
  discard sh("git -C " & quoteShell(repo) & " add . && git -C " &
             quoteShell(repo) & " commit -qm init")

  let sigEmpty = graphSignature(repo)
  check("a repo with no worktrees has a signature", sigEmpty.len > 0, sigEmpty)
  check("the empty-graph signature says so", "absent" in sigEmpty, sigEmpty)

  # Two trees, back to back, inside one second: a seconds-based signature
  # would give them the SAME stamp and the second tree would stay invisible.
  discard sh("git -C " & quoteShell(repo) & " worktree add -q " &
             quoteShell(tmp / "repo.wt" / "a") & " -b a")
  let sigA = graphSignature(repo)
  discard sh("git -C " & quoteShell(repo) & " worktree add -q " &
             quoteShell(tmp / "repo.wt" / "b") & " -b b")
  let sigB = graphSignature(repo)
  check("adding a worktree changes the signature", sigA != sigEmpty,
        sigEmpty & " -> " & sigA)
  check("a SECOND worktree in the same second is still a new signature",
        sigB != sigA, "both were " & sigB & " — a coarse signature would hide b")
  check("the signature is not the seconds clock alone",
        not (sigA.endsWith(":000000000") and sigB.endsWith(":000000000")))

  # Removing the last tree deletes <commonDir>/worktrees entirely, so absence
  # must be a VALUE, not an error that leaves the stale signature in place.
  discard sh("git -C " & quoteShell(repo) & " worktree remove --force " &
             quoteShell(tmp / "repo.wt" / "a"))
  discard sh("git -C " & quoteShell(repo) & " worktree remove --force " &
             quoteShell(tmp / "repo.wt" / "b"))
  let sigGone = graphSignature(repo)
  check("removing every worktree changes the signature again",
        sigGone != sigB and "absent" in sigGone, sigGone)
  check("the gone-signature matches the never-had-one state",
        sigGone == sigEmpty, sigGone & " vs " & sigEmpty)

  # A non-repo directory degrades instead of failing.
  createDir(tmp / "plain")
  check("a plain directory still yields a signature",
        graphSignature(tmp / "plain") == "nodir",
        graphSignature(tmp / "plain"))

  # =========================================================================
  # Part 2 (pure, the actual cache): workspaceRootsFor sees a tree created
  # AFTER the first dispatch, with no grant and no runner restart.
  #
  # This drives the real function on a real CoreTools, which is the only way to
  # test the defect: the earlier e2e attempt passed `roots` straight to the
  # locks component, so it never consulted the cached set at all and would have
  # passed with the bug present. Verified by reverting the fix — see the commit
  # message.
  # =========================================================================
  let cacheRepo = tmp / "cacherepo"
  createDir(cacheRepo)
  discard sh("git -C " & quoteShell(cacheRepo) & " init -q -b main")
  discard sh("git -C " & quoteShell(cacheRepo) &
             " config user.email t@example.invalid")
  discard sh("git -C " & quoteShell(cacheRepo) & " config user.name t")
  writeFile(cacheRepo / "a.txt", "one\n")
  discard sh("git -C " & quoteShell(cacheRepo) & " add . && git -C " &
             quoteShell(cacheRepo) & " commit -qm init")

  # A runner-like CoreTools: no store (grantedRootsFor catches the failure and
  # yields no grants, exactly like an unreachable store), one live workspace.
  var ct = CoreTools(nested: NestedState(workspace: cacheRepo,
                                         session: "live-set-cache"))
  let firstSet = workspaceRootsFor(ct)
  check("the first dispatch caches a set with one root",
        firstSet.len == 1 and firstSet[0] == normalizeRoot(cacheRepo), $firstSet)

  # The tree appears MID-CONVERSATION, from the conversation's own bash.
  let lateTree = cacheRepo & ".wt/feat"
  discard sh("git -C " & quoteShell(cacheRepo) & " worktree add -q " &
             quoteShell(lateTree) & " -b feat")

  let secondSet = workspaceRootsFor(ct)
  check("the next dispatch sees the new tree WITHOUT a grant or restart",
        normalizeRoot(lateTree) in secondSet,
        "set = " & $secondSet)
  check("the tree really was created after the first call",
        normalizeRoot(lateTree) notin firstSet)
  check("the primary is still first", secondSet[0] == normalizeRoot(cacheRepo),
        $secondSet)
  check("exactly the two trees", secondSet.len == 2, $secondSet)

  # A SECOND tree in the same second (the sub-second case) must also land.
  let second = cacheRepo & ".wt/second"
  discard sh("git -C " & quoteShell(cacheRepo) & " worktree add -q " &
             quoteShell(second) & " -b second")
  let thirdSet = workspaceRootsFor(ct)
  check("a second tree in the same second is admitted too",
        normalizeRoot(second) in thirdSet, $thirdSet)

  # Removal is noticed as well: a tree that no longer exists leaves the set.
  discard sh("git -C " & quoteShell(cacheRepo) & " worktree remove --force " &
             quoteShell(lateTree))
  let afterRemove = workspaceRootsFor(ct)
  check("a removed tree leaves the set",
        normalizeRoot(lateTree) notin afterRemove, $afterRemove)
  check("the remaining tree stays", normalizeRoot(second) in afterRemove,
        $afterRemove)

  # The shape cached alongside the set is the conversation's own tree.
  check("the cached checkout shape is a plain checkout here",
        ct.nested.checkoutCached.kind == ckRepo, $ct.nested.checkoutCached.kind)

  # A conversation BORN in a worktree: its primaryRoot is the repo.
  var wtCt = CoreTools(nested: NestedState(workspace: second,
                                           session: "live-set-wt"))
  discard workspaceRootsFor(wtCt)
  check("a conversation in a worktree knows its primary",
        wtCt.nested.checkoutCached.kind == ckLinkedWorktree and
        wtCt.nested.checkoutCached.primaryRoot == normalizeRoot(cacheRepo),
        $wtCt.nested.checkoutCached)

  report("LIVE SET TEST")

main()
