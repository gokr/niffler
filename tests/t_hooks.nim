import std/[json, os, osproc, strutils, times]
import natswrapper
import envelope
import helpers

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler") or
     not fileExists(repoRoot / "var" / "bin" / "hooks"):
    echo "FAIL: missing binaries — make build first"; quit(1)

  let (natsProc, url) = startNats(routed = true)
  defer: stopServer(natsProc)

  let sandbox = newCoreSandbox("hooks", ["store", "bash"])
  let root = sandbox.root
  defer: removeDir(root)

  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                logFile = root / "core.log")
  defer:
    if coreProc.running(): coreProc.terminate()
    discard coreProc.waitForExit(2000)

  let hookOut = root / "hook-out.jsonl"
  let hookProc = startComponent(repoRoot / "var" / "bin" / "hooks", url,
    root = root,
    extra = [("NIF_HOOKS_EVENTS", "ev.session.turn"),
             ("NIF_HOOKS_EV_SESSION_TURN", "cat >> " & quoteShell(hookOut))],
    logFile = root / "hooks.log")
  defer:
    if hookProc.running(): hookProc.terminate()
    discard hookProc.waitForExit(2000)

  let nc2 = connect(url)
  var up = false
  for i in 0 ..< 50:
    let r = call(nc2, "store", "list",
                 %*{"kind": "conversation", "limit": 1}, 3000)
    if r{"ok"}.getBool(false):
      up = true
      break
    sleep(200)
  if not up:
    echo "FAIL: harness never came up"; quit(1)

  let env = Envelope(v: 1, id: "t1", kind: ekEvent,
    payload: %*{"sessionId": "probe", "turnId": "tr1", "phase": "done",
                "reply": "hello hook"})
  nc2.publish("ev.session.turn", env.encode())
  discard natsConnection_Flush(nc2.conn)

  var fired = false
  for i in 0 ..< 30:
    if fileExists(hookOut):
      let content = readFile(hookOut)
      if content.contains("hello hook") and content.contains("probe"):
        fired = true
        break
    sleep(300)

  if fired:
    echo "HOOKS SMOKE PASSED"
  else:
    echo "FAIL: hook never fired"
    if fileExists(root / "hooks.log"): echo readFile(root / "hooks.log")
    quit(1)

main()
