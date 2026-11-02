## git component tests — bus contract: registration + the five read-only
## git tools against a throwaway repo.
##
## Covers: porcelain status (+path scope), diff vs HEAD (+stat, clean-path
## marker), log (+max_count/author/path filters), show (+path scope,
## revision expressions), blame (+line window, "Not Committed Yet" for
## uncommitted lines), argument validation (path escapes, absolute paths,
## option-looking and whitespace refs), and the not-a-repo behaviour.

import std/[json, os, osproc, sequtils, strutils]
import natsnim
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)
  false

proc sh(cmd: string): tuple[output: string, exitCode: int] =
  execCmdEx(cmd)

proc gitSetup(tmp: string) =
  ## Two commits: "first commit" (a.txt), "second commit" (a.txt + b.txt);
  ## then an unstaged a.txt tweak and an untracked c.txt.
  doAssert sh("git -C " & quoteShell(tmp) & " init -q").exitCode == 0
  doAssert sh("git -C " & quoteShell(tmp) &
              " config user.email t@example.com").exitCode == 0
  doAssert sh("git -C " & quoteShell(tmp) &
              " config user.name \"Test User\"").exitCode == 0
  writeFile(tmp / "a.txt", "one\ntwo\nthree\n")
  doAssert sh("git -C " & quoteShell(tmp) & " add a.txt").exitCode == 0
  doAssert sh("git -C " & quoteShell(tmp) &
              " commit -q -m \"first commit\"").exitCode == 0
  writeFile(tmp / "a.txt", "ONE\ntwo\nthree\n")
  writeFile(tmp / "b.txt", "bee\n")
  doAssert sh("git -C " & quoteShell(tmp) & " add -A").exitCode == 0
  doAssert sh("git -C " & quoteShell(tmp) &
              " commit -q -m \"second commit\"").exitCode == 0
  writeFile(tmp / "a.txt", "ONE\ntwo\nTHREE\n")  # unstaged modification
  writeFile(tmp / "c.txt", "untracked\n")

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "git"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)
  let tmp = tempRoot("git")
  defer: removeDir(tmp)
  gitSetup(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let gProc = startComponent(bin, url, root = tmp)
  defer:
    if gProc.running():
      gProc.terminate()
      sleep(200)
    gProc.close()

  check("git registers", waitRegistered(nc, "git"))

  # git_status: branch line + one line per changed file
  let s1 = call(nc, "git", "git_status", %*{})
  check("git_status exit 0", s1{"exit_code"}.getInt(-1) == 0, $s1)
  let so1 = s1{"text"}.getStr("")
  check("git_status shows branch", so1.contains("## "), $s1)
  check("git_status shows modified file", so1.contains(" M a.txt"), $s1)
  check("git_status shows untracked file", so1.contains("?? c.txt"), $s1)

  # path scope narrows the listing
  let s2 = call(nc, "git", "git_status", %*{"path": "c.txt"})
  let so2 = s2{"text"}.getStr("")
  check("git_status path scope includes", so2.contains("?? c.txt"), $s2)
  check("git_status path scope excludes", not so2.contains("a.txt"), $s2)

  # repo param: a second repository inside the root is inspected in place
  let subrepo = tmp / "subrepo"
  createDir(subrepo)
  doAssert sh("git -C " & quoteShell(subrepo) & " init -q").exitCode == 0
  doAssert sh("git -C " & quoteShell(subrepo) &
              " config user.email t@example.com").exitCode == 0
  doAssert sh("git -C " & quoteShell(subrepo) &
              " config user.name \"Sub User\"").exitCode == 0
  writeFile(subrepo / "s.txt", "sub\n")
  doAssert sh("git -C " & quoteShell(subrepo) & " add -A").exitCode == 0
  doAssert sh("git -C " & quoteShell(subrepo) &
              " commit -q -m \"sub commit\"").exitCode == 0
  let s3 = call(nc, "git", "git_status", %*{"repo": "subrepo"})
  check("git_status repo param scopes the subrepo",
        s3{"exit_code"}.getInt(-1) == 0 and
        not s3{"text"}.getStr("").contains("c.txt"), $s3)
  let s4 = call(nc, "git", "git_status", %*{"repo": "nowhere"})
  check("git_status refuses a missing repo",
        s4{"exit_code"}.getInt(-1) == 2 and
        s4{"text"}.getStr("").contains("existing directory"), $s4)
  let s5 = call(nc, "git", "git_status", %*{"repo": "../escape"})
  check("git_status refuses a .. repo",
        s5{"exit_code"}.getInt(-1) == 2, $s5)

  # git_diff: staged+unstaged since HEAD = the a.txt tweak only
  let d1 = call(nc, "git", "git_diff", %*{})
  check("git_diff exit 0", d1{"exit_code"}.getInt(-1) == 0, $d1)
  let do1 = d1{"text"}.getStr("")
  check("git_diff shows hunk", do1.contains("--- a/a.txt") and
        do1.contains("+++ b/a.txt"), $d1)
  check("git_diff shows removed line", do1.contains("-three"), $d1)
  check("git_diff shows added line", do1.contains("+THREE"), $d1)

  # stat: compact one-line-per-file summary, no hunks
  let d2 = call(nc, "git", "git_diff", %*{"stat": true})
  let do2 = d2{"text"}.getStr("")
  check("git_diff stat is compact", do2.contains("a.txt |") and
        not do2.contains("--- a/a.txt"), $d2)

  # clean path: marker instead of empty output
  let d3 = call(nc, "git", "git_diff", %*{"path": "b.txt"})
  check("git_diff clean path marker",
        d3{"text"}.getStr("").contains("[no changes since HEAD]"), $d3)

  # git_log: both commits, newest first
  let l1 = call(nc, "git", "git_log", %*{})
  let lo1 = l1{"text"}.getStr("")
  check("git_log lists commits", lo1.contains("second commit") and
        lo1.contains("first commit"), $l1)

  # max_count caps
  let l2 = call(nc, "git", "git_log", %*{"max_count": 1})
  let lo2 = l2{"text"}.getStr("")
  check("git_log max_count caps", lo2.contains("second commit") and
        not lo2.contains("first commit"), $l2)

  # author substring filter
  let l3 = call(nc, "git", "git_log", %*{"author": "Test"})
  check("git_log author filter matches",
        l3{"text"}.getStr("").contains("second commit"), $l3)
  let l4 = call(nc, "git", "git_log", %*{"author": "zzzNobody"})
  check("git_log author filter empty marker",
        l4{"text"}.getStr("").contains("[no commits matched]"), $l4)

  # path filter: only commits touching b.txt
  let l5 = call(nc, "git", "git_log", %*{"path": "b.txt"})
  let lo5 = l5{"text"}.getStr("")
  check("git_log path filter", lo5.contains("second commit") and
        not lo5.contains("first commit"), $l5)

  # git_show: full commit with diff
  let h1 = call(nc, "git", "git_show", %*{"rev": "HEAD"})
  let ho1 = h1{"text"}.getStr("")
  check("git_show shows commit", ho1.contains("second commit") and
        ho1.contains("diff --git a/a.txt") and
        ho1.contains("diff --git a/b.txt"), $h1)

  # path scope limits the shown diff
  let h2 = call(nc, "git", "git_show", %*{"rev": "HEAD", "path": "b.txt"})
  let ho2 = h2{"text"}.getStr("")
  check("git_show path scope", ho2.contains("diff --git a/b.txt") and
        not ho2.contains("a/a.txt"), $h2)

  # revision expressions
  let h3 = call(nc, "git", "git_show", %*{"rev": "HEAD~1"})
  let ho3 = h3{"text"}.getStr("")
  check("git_show revision expression", ho3.contains("first commit") and
        not ho3.contains("b/b.txt"), $h3)

  # git_blame: author attribution, uncommitted lines flagged
  let b1 = call(nc, "git", "git_blame", %*{"path": "a.txt"})
  let bo1 = b1{"text"}.getStr("")
  check("git_blame shows author", bo1.contains("Test User"), $b1)
  check("git_blame flags uncommitted line",
        bo1.contains("Not Committed Yet"), $b1)

  # line window paging
  let b2 = call(nc, "git", "git_blame", %*{"path": "a.txt",
                                           "start_line": 2, "max_lines": 1})
  let bo2 = b2{"text"}.getStr("")
  check("git_blame line window", bo2.contains("two") and
        not bo2.contains("THREE"), $b2)

  # argument validation: nothing runs, everything refused with exit 2
  let e1 = call(nc, "git", "git_status", %*{"path": "../escape"})
  check("git_status refuses .. escape", e1{"exit_code"}.getInt(-1) == 2, $e1)
  let e2 = call(nc, "git", "git_status", %*{"path": "/etc/passwd"})
  check("git_status refuses absolute path", e2{"exit_code"}.getInt(-1) == 2,
        $e2)
  let e3 = call(nc, "git", "git_show", %*{"rev": "--help"})
  check("git_show refuses option-like ref", e3{"exit_code"}.getInt(-1) == 2,
        $e3)
  let e4 = call(nc, "git", "git_show", %*{"rev": "bad ref with spaces"})
  check("git_show refuses whitespace ref", e4{"exit_code"}.getInt(-1) == 2,
        $e4)
  let e5 = call(nc, "git", "git_log", %*{"author": "-injection"})
  check("git_log refuses option-like author", e5{"exit_code"}.getInt(-1) == 2,
        $e5)

  # not-a-repo behaviour: same component against a plain directory
  stopProcess(gProc)
  let plain = tempRoot("gitplain")
  defer: removeDir(plain)
  let gProc2 = startComponent(bin, url, root = plain)
  defer:
    if gProc2.running():
      gProc2.terminate()
      sleep(200)
    gProc2.close()
  sleep(700)  # let it subscribe and register
  let n1 = call(nc, "git", "git_status", %*{})
  check("git_status not-a-repo", n1{"exit_code"}.getInt(-1) == 128 and
        n1{"text"}.getStr("").contains("no git repository"), $n1)

  # =========================================================================
  # Mutation surface: worktree ops (WORKTREES.md §4.3)
  #
  # Needs a REAL store (the ownership ledger) and a conversation identity, so
  # this half runs against a core sandbox rather than the bare component above.
  # =========================================================================
  let sb = newCoreSandbox("gitwt", ["store"])
  let sroot = sb.root
  defer: removeDir(sroot)
  createDir(sroot / "ws")
  let repo = sroot / "ws"
  doAssert sh("git -C " & quoteShell(repo) & " init -q -b main").exitCode == 0
  doAssert sh("git -C " & quoteShell(repo) &
              " config user.email t@example.com").exitCode == 0
  doAssert sh("git -C " & quoteShell(repo) &
              " config user.name \"Test User\"").exitCode == 0
  writeFile(repo / "a.txt", "one\n")
  doAssert sh("git -C " & quoteShell(repo) & " add -A && git -C " &
              quoteShell(repo) & " commit -q -m init").exitCode == 0

  let (server2, url2) = startNats()
  defer: stopServer(server2)
  let core2 = startComponent(sb.sandboxBin("niffler"), url2, root = sroot,
                             extra = [("NIF_AUTO_APPROVE", "1")],
                             logFile = sroot / "var" / "test-logs" / "core.log")
  defer:
    if core2.running(): core2.terminate()
    discard core2.waitForExit(2000)
  var wtProc = startComponent(root / "var" / "bin" / "git", url2,
                              root = sroot,
                              logFile = sroot / "var" / "test-logs" / "git.log")
  defer:
    if wtProc.running(): wtProc.terminate()
    discard wtProc.waitForExit(2000)
  var nc2 = waitConnect(url2)
  defer: nc2.close()
  check("store up for the ledger", waitComponent(nc2, "store", 30))
  # Probe FUNCTIONALLY, not through reg.publish: a component started directly
  # (no spawn record) is callable but never appears in `catalog {op:
  # components}`, and `waitRegistered` only watches announcements that arrive
  # AFTER it subscribes — so both those probes race a component that has
  # already announced. "It answers its read verb" is the honest liveness test.
  var gitUp = false
  for _ in 0 ..< 100:
    let probe = call(nc2, "git", "git_worktree_list", %*{"repo": repo}, 5_000)
    if probe{"exit_code"}.getInt(-1) == 0:
      gitUp = true
      break
    sleep(200)
  check("git serves its worktree surface", gitUp)

  # --- list: the primary is reported, the container is named --------------
  let wtList0 = call(nc2, "git", "git_worktree_list", %*{"repo": repo}, 30_000)
  check("git_worktree_list ok", wtList0{"exit_code"}.getInt(-1) == 0, $wtList0)
  check("it names the primary", wtList0{"primary"}.getStr("") == repo, $wtList0)
  check("it names the SIBLING container (<repo>.wt)",
        wtList0{"container"}.getStr("") == repo & ".wt", $wtList0)
  check("one tree (the primary) before any add",
        wtList0{"trees"}.len == 1, $wtList0{"trees"})
  check("the primary is marked as current",
        wtList0{"trees"}[0]{"isCurrent"}.getBool(false), $wtList0{"trees"}[0])

  # --- add: the sibling layout, no ignore rule, git-locked ---------------
  let added = call(nc2, "git", "git_worktree",
                   %*{"op": "add", "repo": repo, "name": "feat"}, 120_000)
  check("add succeeds", added{"exit_code"}.getInt(-1) == 0, $added)
  let wtPath = repo & ".wt" & "/" & "feat"
  check("the tree lands in the PRIMARY's container, as a sibling",
        added{"path"}.getStr("") == wtPath, $added{"path"})
  check("the tree exists on disk", dirExists(wtPath))
  check("it is NOT inside the repository",
        not dirExists(repo / ".wt") and not wtPath.startsWith(repo & "/"))
  check("the branch defaults to the name",
        added{"branch"}.getStr("") == "feat", $added)
  check("the tree is git-locked", added{"locked"}.getBool(false), $added)
  # The status-clean check: an ignore rule must NOT have been needed.
  let st = sh("git -C " & quoteShell(repo) & " status --porcelain")
  check("the primary's git status stays clean (no ignore rule needed)",
        st.output.strip().len == 0, st.output)
  let excl = sh("git -C " & quoteShell(repo) & " check-ignore -v . || true")
  check("no .gitignore/.git/info/exclude entry was added for the tree",
        not excl.output.contains(".wt"), excl.output)

  # git's own lock reason names the conversation, readable WITHOUT the store
  let began = sh("git -C " & quoteShell(repo) & " worktree list --porcelain")
  check("git records the lock and its reason",
        began.output.contains("locked") and began.output.contains("niffler"),
        began.output)

  # --- add refuses the expensive mistakes --------------------------------
  let twice = call(nc2, "git", "git_worktree",
                   %*{"op": "add", "repo": repo, "name": "feat"}, 60_000)
  check("adding over an existing path is refused",
        twice{"exit_code"}.getInt(-1) != 0 and
        twice{"text"}.getStr("").contains("already exists"), $twice)

  # A path OUTSIDE the container (e.g. in-repo) is refused: that is the layout
  # whose claims collide with the primary's opaque claim.
  let inRepo = call(nc2, "git", "git_worktree",
                    %*{"op": "add", "repo": repo, "name": "bad",
                       "path": repo / "inner"}, 60_000)
  check("a non-sibling path is refused",
        inRepo{"exit_code"}.getInt(-1) != 0 and
        inRepo{"text"}.getStr("").contains("worktree container"), $inRepo)

  # Nesting inside an existing worktree is the orientation mistake.
  let nested = call(nc2, "git", "git_worktree",
                    %*{"op": "add", "repo": repo, "name": "nested",
                       "path": wtPath / "deeper"}, 60_000)
  check("a path inside an existing worktree is refused",
        nested{"exit_code"}.getInt(-1) != 0, $nested)

  # --- ORIENTATION: add from INSIDE a worktree uses the primary's container
  let fromTree = call(nc2, "git", "git_worktree",
                      %*{"op": "add", "repo": wtPath, "name": "second"}, 120_000)
  check("add from inside a worktree succeeds",
        fromTree{"exit_code"}.getInt(-1) == 0, $fromTree)
  check("it lands in the PRIMARY's container, not <tree>.wt (no hop-wise nesting)",
        fromTree{"path"}.getStr("") == repo & ".wt/second", $fromTree{"path"})
  check("no bogus <tree>.wt container was created",
        not dirExists(wtPath & ".wt"))

  # --- list now reports both, with owners from the ledger -----------------
  let wtList1 = call(nc2, "git", "git_worktree_list", %*{"repo": repo}, 30_000)
  check("three trees now", wtList1{"trees"}.len == 3, $wtList1{"trees"})
  var sawOwner = false
  var sawFeat = false
  for t in wtList1{"trees"}:
    if t{"path"}.getStr("") == wtPath and t{"branch"}.getStr("") == "feat":
      sawFeat = true
      if t{"owner"} != nil and t{"owner"}{"state"}.getStr("") == "live":
        sawOwner = true
  check("the feat tree is listed with its branch", sawFeat, $wtList1{"trees"})
  check("the ledger reports the owning conversation", sawOwner, $wtList1{"trees"})

  # --- remove: refuses an unmerged branch, then succeeds with force -------
  writeFile(wtPath / "a.txt", "tree change\n")
  doAssert sh("git -C " & quoteShell(wtPath) & " add -A && git -C " &
              quoteShell(wtPath) & " commit -q -m \"work in the tree\"").exitCode == 0
  let unmerged = call(nc2, "git", "git_worktree",
                      %*{"op": "remove", "repo": repo, "path": wtPath}, 60_000)
  check("removing an UNMERGED tree is refused",
        unmerged{"exit_code"}.getInt(-1) != 0 and
        unmerged{"text"}.getStr("").contains("not merged"), $unmerged)
  check("the refusal names the override flag",
        unmerged{"text"}.getStr("").contains("force"), $unmerged)
  check("the tree survives the refusal", dirExists(wtPath))

  let forced = call(nc2, "git", "git_worktree",
                    %*{"op": "remove", "repo": repo, "path": wtPath,
                       "force": true}, 60_000)
  check("force removes it", forced{"exit_code"}.getInt(-1) == 0, $forced)
  check("the tree is gone", not dirExists(wtPath))
  check("the branch is KEPT by default",
        sh("git -C " & quoteShell(repo) & " rev-parse --verify feat").exitCode == 0)
  let wtList2 = call(nc2, "git", "git_worktree_list", %*{"repo": repo}, 30_000)
  check("it leaves the list", wtList2{"trees"}.len == 2, $wtList2{"trees"})

  # --- remove refuses the primary ----------------------------------------
  let rmPrimary = call(nc2, "git", "git_worktree",
                       %*{"op": "remove", "repo": repo, "path": repo,
                          "force": true}, 60_000)
  check("the primary checkout cannot be removed",
        rmPrimary{"exit_code"}.getInt(-1) != 0, $rmPrimary)

  # --- prune: a tree deleted out from under git --------------------------
  let secondPath = repo & ".wt/second"
  if dirExists(secondPath):
    removeDir(secondPath)              # exactly the case prune exists for
    let pruned = call(nc2, "git", "git_worktree",
                      %*{"op": "prune", "repo": repo}, 60_000)
    check("prune succeeds", pruned{"exit_code"}.getInt(-1) == 0, $pruned)
    let wtList3 = call(nc2, "git", "git_worktree_list", %*{"repo": repo}, 30_000)
    check("the hand-deleted tree is gone from the list",
          wtList3{"trees"}.len == 1, $wtList3{"trees"})

  # --- op validation ------------------------------------------------------
  let badOp = call(nc2, "git", "git_worktree", %*{"op": "frobnicate"})
  check("an unknown op is refused",
        badOp{"exit_code"}.getInt(-1) != 0, $badOp)

  # drain: component exits
  drain(nc)
  sleep(700)
  check("git drains and exits", not gProc2.running())

  report("GIT TEST")

main()
