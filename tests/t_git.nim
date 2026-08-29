## git component tests — bus contract: registration + the five read-only
## git tools against a throwaway repo.
##
## Covers: porcelain status (+path scope), diff vs HEAD (+stat, clean-path
## marker), log (+max_count/author/path filters), show (+path scope,
## revision expressions), blame (+line window, "Not Committed Yet" for
## uncommitted lines), argument validation (path escapes, absolute paths,
## option-looking and whitespace refs), and the not-a-repo behaviour.

import std/[json, os, osproc, strutils]
import natswrapper
import helpers

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
  let so1 = s1{"output"}.getStr("")
  check("git_status shows branch", so1.contains("## "), $s1)
  check("git_status shows modified file", so1.contains(" M a.txt"), $s1)
  check("git_status shows untracked file", so1.contains("?? c.txt"), $s1)

  # path scope narrows the listing
  let s2 = call(nc, "git", "git_status", %*{"path": "c.txt"})
  let so2 = s2{"output"}.getStr("")
  check("git_status path scope includes", so2.contains("?? c.txt"), $s2)
  check("git_status path scope excludes", not so2.contains("a.txt"), $s2)

  # git_diff: staged+unstaged since HEAD = the a.txt tweak only
  let d1 = call(nc, "git", "git_diff", %*{})
  check("git_diff exit 0", d1{"exit_code"}.getInt(-1) == 0, $d1)
  let do1 = d1{"output"}.getStr("")
  check("git_diff shows hunk", do1.contains("--- a/a.txt") and
        do1.contains("+++ b/a.txt"), $d1)
  check("git_diff shows removed line", do1.contains("-three"), $d1)
  check("git_diff shows added line", do1.contains("+THREE"), $d1)

  # stat: compact one-line-per-file summary, no hunks
  let d2 = call(nc, "git", "git_diff", %*{"stat": true})
  let do2 = d2{"output"}.getStr("")
  check("git_diff stat is compact", do2.contains("a.txt |") and
        not do2.contains("--- a/a.txt"), $d2)

  # clean path: marker instead of empty output
  let d3 = call(nc, "git", "git_diff", %*{"path": "b.txt"})
  check("git_diff clean path marker",
        d3{"output"}.getStr("").contains("[no changes since HEAD]"), $d3)

  # git_log: both commits, newest first
  let l1 = call(nc, "git", "git_log", %*{})
  let lo1 = l1{"output"}.getStr("")
  check("git_log lists commits", lo1.contains("second commit") and
        lo1.contains("first commit"), $l1)

  # max_count caps
  let l2 = call(nc, "git", "git_log", %*{"max_count": 1})
  let lo2 = l2{"output"}.getStr("")
  check("git_log max_count caps", lo2.contains("second commit") and
        not lo2.contains("first commit"), $l2)

  # author substring filter
  let l3 = call(nc, "git", "git_log", %*{"author": "Test"})
  check("git_log author filter matches",
        l3{"output"}.getStr("").contains("second commit"), $l3)
  let l4 = call(nc, "git", "git_log", %*{"author": "zzzNobody"})
  check("git_log author filter empty marker",
        l4{"output"}.getStr("").contains("[no commits matched]"), $l4)

  # path filter: only commits touching b.txt
  let l5 = call(nc, "git", "git_log", %*{"path": "b.txt"})
  let lo5 = l5{"output"}.getStr("")
  check("git_log path filter", lo5.contains("second commit") and
        not lo5.contains("first commit"), $l5)

  # git_show: full commit with diff
  let h1 = call(nc, "git", "git_show", %*{"rev": "HEAD"})
  let ho1 = h1{"output"}.getStr("")
  check("git_show shows commit", ho1.contains("second commit") and
        ho1.contains("diff --git a/a.txt") and
        ho1.contains("diff --git a/b.txt"), $h1)

  # path scope limits the shown diff
  let h2 = call(nc, "git", "git_show", %*{"rev": "HEAD", "path": "b.txt"})
  let ho2 = h2{"output"}.getStr("")
  check("git_show path scope", ho2.contains("diff --git a/b.txt") and
        not ho2.contains("a/a.txt"), $h2)

  # revision expressions
  let h3 = call(nc, "git", "git_show", %*{"rev": "HEAD~1"})
  let ho3 = h3{"output"}.getStr("")
  check("git_show revision expression", ho3.contains("first commit") and
        not ho3.contains("b/b.txt"), $h3)

  # git_blame: author attribution, uncommitted lines flagged
  let b1 = call(nc, "git", "git_blame", %*{"path": "a.txt"})
  let bo1 = b1{"output"}.getStr("")
  check("git_blame shows author", bo1.contains("Test User"), $b1)
  check("git_blame flags uncommitted line",
        bo1.contains("Not Committed Yet"), $b1)

  # line window paging
  let b2 = call(nc, "git", "git_blame", %*{"path": "a.txt",
                                           "start_line": 2, "max_lines": 1})
  let bo2 = b2{"output"}.getStr("")
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
        n1{"output"}.getStr("").contains("no git repository"), $n1)

  # drain: component exits
  drain(nc)
  sleep(700)
  check("git drains and exits", not gProc2.running())

  report("GIT TEST")

main()
