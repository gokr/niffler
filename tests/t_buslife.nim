## buslife — issue #104: the core-owned bus is a supervised resource.
##
## Cases:
##   heal    — kill the spawned nats-server; core respawns it on the SAME
##             client port, rewrites the discovery files, and a component that
##             never restarted answers again (it re-attached on its own).
##   graceful— an intentional shutdown must NOT resurrect the bus, and
##             var/nats-pid is removed as before.
##
## "Same port" is the whole point: children inherited a pinned NIF_NATS_URL
## from core's environment, so a respawn on a new port would strand every one
## of them. The heal assertion therefore drives a real component call rather
## than trusting core's own log line.

import std/[json, os, osproc, strutils, times]
import natsnim
import helpers

proc waitBusPid(root: string, secs = 20): int =
  ## The pid core recorded for the bus it owns (0 when absent).
  let path = root / "var" / "nats-pid"
  for i in 0 ..< secs * 10:
    if fileExists(path):
      try:
        let pid = parseInt(readFile(path).strip())
        if pid > 0: return pid
      except CatchableError:
        discard
    sleep(100)
  return 0

proc main() =
  let sandbox = newCoreSandbox("buslife", ["store", "bash", "llm"])
  defer: removeDir(sandbox.root)

  # NIF_NATS_SPAWN=1 makes core own an isolated bus on a random port — the
  # only case where respawning is ours to do (an attached bus is never ours).
  # startComponent forces NIF_NATS_URL="", which this process's os getEnv
  # treats as UNSET — correct for tests that want core to own a bus, but this
  # test must ALSO survive being launched from inside a harness shell, where
  # NIF_NATS_URL is inherited and would make core attach to the developer's
  # 4222 instead. So the pin is explicit: spawn an isolated bus.
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), "",
    root = sandbox.root,
    extra = @[("NIF_NATS_SPAWN", "1"), ("NIF_TRUST", "always")],
    logFile = sandbox.root / "var" / "buslife-core.log")
  defer:
    if coreProc != nil and coreProc.running():
      coreProc.terminate()
      sleep(800)
      if coreProc.running(): coreProc.kill()
    if coreProc != nil: coreProc.close()

  # Wait for core to publish the URL of the bus it spawned.
  let urlPath = sandbox.root / "var" / "nats-url"
  var url = ""
  for i in 0 ..< 200:
    if fileExists(urlPath):
      url = readFile(urlPath).strip()
      if url.len > 0: break
    sleep(100)
  check("core published its spawned bus URL", url.len > 0, url)
  if url.len == 0:
    report("BUS LIFE")
    return

  var nc = waitConnect(url)

  # Store must be up on this bus before anything else is meaningful.
  var storeUp = false
  for i in 0 ..< 150:
    let r = call(nc, "core", "catalog", %*{"op": "components"}, 3_000)
    if r{"components"}{"store"} != nil:
      storeUp = true
      break
    sleep(200)
  check("store registered on the spawned bus", storeUp)

  let firstPid = waitBusPid(sandbox.root)
  check("core recorded the bus pid", firstPid > 0, $firstPid)
  let firstPort = url.rsplit(':', 1)[^1]

  # --- heal: kill the bus out from under the harness ----------------------
  if firstPid > 0:
    discard execShellCmd("kill -9 " & $firstPid)
    # Core's idle loop notices and respawns on the SAME port.
    var newPid = 0
    for i in 0 ..< 200:
      newPid = waitBusPid(sandbox.root, 1)
      if newPid > 0 and newPid != firstPid:
        # the discovery file is rewritten by the respawn; make sure we are
        # not just reading the stale pre-kill value
        if fileExists(sandbox.root / "var" / "nats-pid"):
          break
      sleep(200)
    check("core respawned the bus (new pid)", newPid > 0 and newPid != firstPid,
          "first=" & $firstPid & " new=" & $newPid)
    let newUrl = readFile(urlPath).strip()
    check("the respawn reused the SAME client port",
          newUrl.rsplit(':', 1)[^1] == firstPort, newUrl & " vs port " & firstPort)
    check("the discovery file names the new pid",
          readFile(sandbox.root / "var" / "nats-pid").strip() == $newPid)

    # --- and a component that never restarted answers again --------------
    # A fresh client connection is what a re-attached component effectively
    # has; the stronger claim (an existing process re-attaches) is covered by
    # t_reconnect, so this test owns core's half.
    var healed = false
    for i in 0 ..< 200:
      try:
        var nc2 = connect(newUrl)
        let r = call(nc2, "store", "list", %*{"kind": "message", "limit": 1}, 5_000)
        nc2.close()
        if r{"error"} == nil:
          healed = true
          break
      except CatchableError:
        discard
      sleep(200)
    check("the harness serves calls again after the respawn", healed)
    close(nc)

  # --- graceful shutdown must not resurrect ------------------------------
  if coreProc != nil and coreProc.running():
    # Read the pid WHILE core still exists: the file is removed by a graceful
    # exit, so reading it afterwards would compare against 0 and pass trivially.
    let pidBefore = waitBusPid(sandbox.root, 2)
    check("the bus pid is known before shutdown", pidBefore > 0, $pidBefore)
    coreProc.terminate()
    discard coreProc.waitForExit(15_000)
    check("core exited on SIGTERM", not coreProc.running())
    check("a graceful exit removed var/nats-pid", not fileExists(sandbox.root / "var" / "nats-pid"))
    # The bus must be gone with its core (PDEATHSIG), not respawned by anyone.
    var stillThere = false
    for i in 0 ..< 50:
      if pidBefore > 0 and fileExists("/proc/" & $pidBefore):
        stillThere = true
        break
      sleep(100)
    check("the bus went down with its core (no resurrection)", not stillThere,
          "pid " & $pidBefore & " still alive")

  report("BUS LIFE")

main()
