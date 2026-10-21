## Kernel-cleanup wrapper selection for supervised children (core/supervisor.nim).
##
## Regression: the supervisor wrapped every child in the first `setpriv` on
## PATH. BusyBox (stock Alpine) ships a setpriv applet that rejects
## --pdeathsig, so every component spawn failed at once. The wrapper must be
## chosen by capability (sdk/niffler/procutil.nim:pdeathsigSetprivPath).

import std/[os, strutils, times]
import ../core/supervisor
import ../sdk/niffler/procutil
import helpers

proc main() =
  let root = tempRoot("supervisor-setpriv")
  defer: removeDir(root)
  let shim = root / "shim"
  createDir(shim)
  # Same refusal BusyBox 1.36 prints; the shim must win the PATH lookup
  # before the (once-per-process) probe runs.
  writeFile(shim / "setpriv",
    "#!/bin/sh\necho 'setpriv: unrecognized option: pdeathsig' >&2\nexit 1\n")
  setFilePermissions(shim / "setpriv", {fpUserRead, fpUserWrite, fpUserExec})
  putEnv("PATH", shim & ":" & getEnv("PATH"))
  check("setpriv without --pdeathsig is never chosen",
        pdeathsigSetprivPath() == "", pdeathsigSetprivPath())

  let marker = root / "started"
  let child = root / "child.sh"
  writeFile(child, "#!/bin/sh\necho started > " & quoteShell(marker) & "\n")
  setFilePermissions(child, {fpUserRead, fpUserWrite, fpUserExec})
  let sup = Supervisor(root: root)
  sup.startChild(sup.addChild("probe", child))
  let deadline = epochTime() + 10
  while not fileExists(marker) and epochTime() < deadline: sleep(50)
  let log = root / "var" / "logs" / "probe.log"
  check("child still starts without a usable setpriv",
        fileExists(marker) and readFile(marker).strip() == "started",
        (if fileExists(log): readFile(log) else: "no child log"))
  report("SUPERVISOR SETPRIV")

main()
