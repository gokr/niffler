## t_selfbinary — the rebuild trap, reproduced in a copy of this binary.
##
## A long-lived component is rebuilt in place by `make build` while it runs.
## Linux then resolves /proc/self/exe to "<path> (deleted)", getAppFilename()
## returns that verbatim, and any re-exec fails with ENOENT naming a path that
## never existed. Observed live: `fleet` stopped reconciling jobs entirely
## ("Additional info: …/var/bin/fleet (deleted)") and every task sat at
## `queued` — which reads exactly like an unreachable peer, and cost real time
## to diagnose.
##
## The trap is exercised in a COPY (never in the real test binary, which a
## prior version of this test replaced mid-run): the copy replaces its own
## file, then reports what it can still do. Assertions live in the child, so
## the parent only has to check its exit code.

import std/[os, osproc, strutils]
import niffler/sdk           # re-exports procutil
import helpers

const
  modeObserve = "observe"    ## replace self, probe both spawn paths, report
  modeChild = "child"        ## the spawned grandchild: prove we can run

proc runObserve(): int =
  let self = getAppFilename()
  if self.endsWith(" (deleted)"):
    echo "SKIP already-replaced"
    return 0
  # Replace our own file the way a build does: a NEW inode, renamed over the
  # name. Writing in place gives ETXTBSY on a running binary.
  let staged = self & ".new"
  writeFile(staged, "#!/bin/sh\necho replaced-by-build\n")
  setFilePermissions(staged, {fpUserRead, fpUserWrite, fpUserExec})
  moveFile(staged, self)

  var failures = 0
  proc want(what: string, ok: bool) =
    if ok: echo "OK ", what
    else: echo "FAIL ", what
    if not ok: inc failures

  want("the replaced binary is reported as such", selfBinaryReplaced())

  # The bug, exactly as it happens: code reads getAppFilename() AT SPAWN TIME,
  # i.e. after the rebuild, and gets "<path> (deleted)". Note the difference
  # from `self` above, captured before the replacement: that one names the NEW
  # file, so spawning it would silently run the wrong build.
  let stale = getAppFilename()
  want("getAppFilename reports the deleted name after a rebuild",
       stale.endsWith(" (deleted)"))
  var staleFailed = false
  try:
    let p = startProcess(stale, args = @[modeChild], options = {poParentStreams})
    p.close()
  except OSError:
    staleFailed = true
  want("spawning by the deleted name fails (this is the trap)", staleFailed)

  # The fix: /proc/self/exe still reaches the original inode.
  let live = selfBinaryPath()
  want("selfBinaryPath does not return the deleted name", live != stale)
  var ran = false
  try:
    let p = startProcess(live, args = @[modeChild], options = {poParentStreams})
    ran = p.waitForExit(20_000) == 0
    p.close()
  except OSError as e:
    echo "FAIL selfBinaryPath spawn: ", e.msg
    inc failures
  want("a child spawned through selfBinaryPath runs", ran)
  echo "failures=", failures
  if failures > 0: 1 else: 0

proc main() =
  if paramCount() >= 1:
    if paramStr(1) == modeChild:
      echo "child-alive"
      quit(0)
    if paramStr(1) == modeObserve:
      quit(runObserve())
    quit(0)

  let dir = getTempDir() / ("niffler-selfbin-" & $getCurrentProcessId())
  createDir(dir)
  defer: removeDir(dir)
  let copy = dir / "selfbin"
  copyFile(getAppFilename(), copy)
  setFilePermissions(copy, {fpUserRead, fpUserWrite, fpUserExec})

  let probe = startProcess(copy, args = @[modeObserve], options = {poParentStreams})
  let code = probe.waitForExit(60_000)
  probe.close()
  check("the trap is reproducible and selfBinaryPath survives it", code == 0,
        "observed-probe exit " & $code)
  report("SELF-BINARY TEST")

main()
