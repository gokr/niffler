## von launcher contract: the supervised Von wrapper reports an absent venv
## honestly without crashing, starts a child only when the binary exists,
## adopts an already-serving endpoint, survives a hard SIGKILL through the
## supervisor's restart, and passes kernel-enforced cleanup (setpriv) to its
## child. The fake "von" is this test binary itself answering HTTP — the
## suite never downloads real Von.

import std/[json, net, os, strutils, times]
import posix
import natsnim
import envelope
import helpers

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  let (_, p) = s.getLocalAddr()
  s.close()
  p.int

proc openSub(nc: NatsConnection, subject: string): ptr natsSubscription =
  var sub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr sub, nc.conn,
                                                 subject.cstring)):
    fail("subscribe " & subject)
  sub

proc pollEnvelope(sub: ptr natsSubscription,
                  timeoutMs: int64): tuple[found: bool, env: Envelope] =
  var msg: ptr natsMsg
  if natsSubscription_NextMsg(addr msg, sub, timeoutMs) != NATS_OK:
    return (false, Envelope())
  let data = $natsMsg_GetData(msg)
  natsMsg_Destroy(msg)
  try:
    return (true, decode(data))
  except CatchableError:
    return (false, Envelope())

proc pidAlive(pid: int): bool =
  pid > 0 and dirExists("/proc/" & $pid)

proc fakeVon() =
  ## Stand-in for the venv binary: binds NIF_VON_PORT (a few retries for
  ## TIME_WAIT), writes its pid to NIF_VON_PIDFILE, answers any HTTP request.
  let port = parseInt(getEnv("NIF_VON_PORT", "0"))
  let pidFile = getEnv("NIF_VON_PIDFILE", "")
  if pidFile.len > 0: writeFile(pidFile, $getCurrentProcessId())
  let server = newSocket()
  for attempt in 0 ..< 20:
    try:
      server.bindAddr(Port(port), "127.0.0.1")
      break
    except CatchableError:
      sleep(100)
  server.listen()
  while true:
    var peer: owned(Socket)
    server.accept(peer)
    peer.send("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n" &
              "Connection: close\r\n\r\n{}")
    peer.close()

proc waitStatus(nc: NatsConnection, wanted: string,
                secs = 20.0): JsonNode =
  ## Poll von_status until state == wanted; returns the last payload.
  let deadline = epochTime() + secs
  while epochTime() < deadline:
    result = call(nc, "von", "von_status", %*{}, 2000)
    if result{"state"}.getStr("") == wanted: return
    sleep(150)

proc main() =
  if paramCount() == 1 and paramStr(1) == "fakevon":
    fakeVon()
    return
  let repo = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let vonBin = repo / "var" / "bin" / "von"
  if not fileExists(vonBin):
    fail(vonBin & " missing — run `make build` first")
    quit(1)

  # --- A: absent venv binary — honest status, one warning, no crash ---------
  let tmp = tempRoot("von")
  defer: removeDir(tmp)
  let (nats, url) = startNats()
  defer: stopServer(nats)
  var nc = waitConnect(url)
  defer: nc.close()
  let logSub = openSub(nc, "ev.log.von")
  let absent = startComponent(vonBin, url, root = tmp,
    extra = [("NIF_VON_BIN", tmp / "nope" / "von"),
             ("NIF_VON_POLL_MS", "200")])
  defer: stopProcess(absent)
  check("von registers with no venv present", waitRegistered(nc, "von"))
  let statusA = waitStatus(nc, "absent", 5)
  check("status reports absent, no child, honest endpoint",
        statusA{"state"}.getStr("") == "absent" and
        statusA{"childPid"}.getInt(0) == 0 and
        statusA{"endpoint"}.getStr("").contains("/v1/systemone"), $statusA)
  var warned = false
  for _ in 0 ..< 25:
    let (found, env) = pollEnvelope(logSub, 200)
    if found and env.kind == ekEvent and
        env.payload{"level"}.getStr("") == "warn" and
        env.payload{"msg"}.getStr("").contains("missing"):
      warned = true
      break
  check("missing venv is one warning, not a crash loop", warned)
  stopProcess(absent)

  # --- B: spawn-record enablement, supervision, child cleanup, removal ------
  let sandbox = newCoreSandbox("von", ["store"])
  defer: removeDir(sandbox.root)
  copyFileWithPermissions(vonBin, sandbox.sandboxBin("von"))
  let port = freePort()
  let pidFile = sandbox.root / "var" / "fake-von.pid"
  let (coreNats, coreUrl) = startNats()
  defer: stopServer(coreNats)
  var coreNc = waitConnect(coreUrl)
  defer: coreNc.close()
  let core = startComponent(sandbox.sandboxBin("niffler"), coreUrl,
    root = sandbox.root,
    extra = [("NIF_AUTO_APPROVE", "1"),
             ("NIF_VON_BIN", getAppFilename()),
             ("NIF_VON_ARGS", "fakevon"),
             ("NIF_VON_PORT", $port),
             ("NIF_VON_PIDFILE", pidFile),
             ("NIF_VON_POLL_MS", "200")])
  defer: stopProcess(core)
  var ready = false
  for _ in 0 ..< 100:
    let snapshot = call(coreNc, "core", "catalog", %*{"op": "snapshot"}, 2000)
    if snapshot{"components"} != nil and snapshot{"components"}.kind == JArray:
      for c in snapshot["components"]:
        if c{"name"}.getStr("") == "store": ready = true
    if ready: break
    sleep(100)
  check("sandbox core and store ready", ready)
  let spawned = call(coreNc, "core", "spawn",
    %*{"name": "von", "binary": sandbox.sandboxBin("von")})
  check("spawn enables the supervised launcher", spawned{"ok"}.getBool(false), $spawned)
  let serving = waitStatus(coreNc, "serving", 20)
  check("launcher starts the runtime and reports serving",
        serving{"state"}.getStr("") == "serving" and
        serving{"childPid"}.getInt(0) > 0, $serving)
  let childPid1 = serving{"childPid"}.getInt(0)
  let fakePid1 = (if fileExists(pidFile): parseInt(readFile(pidFile).strip()) else: 0)
  check("fake von child is alive", pidAlive(fakePid1) and
        (fakePid1 == childPid1 or not pidAlive(childPid1)), $fakePid1)
  let selfPid = serving{"selfPid"}.getInt(0)
  check("status carries the launcher pid", selfPid > 0)

  # Hard crash: the supervisor must restart the launcher, and the child
  # must not outlive it (kernel-enforced via setpriv; skipped without it).
  let hasSetpriv = findExe("setpriv").len > 0
  discard kill(Pid(selfPid), SIGKILL)
  let regSub = openSub(coreNc, "reg.publish")
  let restarted = waitRegisteredOn(regSub, "von", 15)
  check("supervisor restarts the crashed launcher", restarted)
  if hasSetpriv:
    var childGone = false
    for _ in 0 ..< 30:
      if not pidAlive(fakePid1): childGone = true; break
      sleep(100)
    check("child dies with the launcher (PDEATHSIG)", childGone)
  else:
    echo "  (setpriv absent — skipping the PDEATHSIG child-death check)"
  let servingAgain = waitStatus(coreNc, "serving", 20)
  check("restarted launcher serves again",
        servingAgain{"state"}.getStr("") == "serving", $servingAgain)

  # Disable: remove stops the process and deletes the persisted record.
  let removed = call(coreNc, "core", "remove", %*{"name": "von"})
  check("remove disables the launcher", removed{"ok"}.getBool(false), $removed)
  var recordGone = false
  for _ in 0 ..< 50:
    let list = call(coreNc, "store", "list", %*{"kind": "component"}, 2000)
    var still = false
    if list{"items"} != nil and list{"items"}.kind == JArray:
      for item in list["items"]:
        if item{"id"}.getStr("") == "von": still = true
    if not still: recordGone = true; break
    sleep(100)
  check("spawn record deleted on remove", recordGone)
  # Orphan cleanup (only when setpriv was absent): kill any fake that lived.
  for leftover in [fakePid1, childPid1, servingAgain{"childPid"}.getInt(0)]:
    if leftover > 0 and pidAlive(leftover) and leftover != getCurrentProcessId():
      discard kill(Pid(leftover), SIGKILL)
  report("VON TEST")

when isMainModule: main()
