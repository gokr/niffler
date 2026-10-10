## Fault-injection contract: an unavailable store must not turn a restart
## into an empty lock table, or a failed release into a successful unlock.
import std/[json, os, osproc, strutils]
import natsnim
import helpers

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  let sandbox = newCoreSandbox("lock-recovery", ["store"])
  let root = sandbox.root
  defer: removeDir(root)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var store = startComponent(sandbox.sandboxStoreBin(), url, root = root,
                              logFile = root / "store.log")
  defer:
    if store.running(): store.terminate()
    discard store.waitForExit(2000)
    store.close()
  proc waitStore() =
    var ready = false
    for attempt in 0 ..< 40:
      let r = call(nc, "store", "list", %*{"kind": "lock-lease"}, 1000)
      if r{"ok"}.getBool(false):
        ready = true
        break
      sleep(100)
    check("store ready", ready)
  waitStore()
  let lease = %*{"leaseId": "owner:call", "sessionId": "owner",
    "tool": "edit", "callId": "call", "root": root,
    "stripes": [root / "held"], "acquiredAt": 9999999999.0, "ttlMs": 600000}
  let seeded = call(nc, "store", "put", %*{"kind": "lock-lease",
    "id": "owner:call", "value": lease})
  check("durable holder seeded", seeded{"ok"}.getBool(false), $seeded)
  store.terminate()
  discard store.waitForExit(2000)
  store.close()
  var locks = startComponent(repo / "var/bin/locks", url, root = root,
                              logFile = root / "locks.log")
  defer:
    if locks.running(): locks.terminate()
    discard locks.waitForExit(2000)
    locks.close()
  sleep(200)
  let unavailable = call(nc, "locks", "lock_status", %*{}, 15000)
  check("startup without store refuses, not empty success",
    not unavailable{"ok"}.getBool(false), $unavailable)
  store = startComponent(sandbox.sandboxStoreBin(), url, root = root,
                          logFile = root / "store-recovered.log")
  waitStore()
  let conflict = call(nc, "locks", "lock_acquire", %*{
    "root": root, "paths": [root / "held"], "sessionId": "rival",
    "tool": "write", "callId": "rival"})
  check("retry after store recovery preserves original holder",
    conflict{"holder"}.getStr("") == "owner", $conflict)
  store.terminate()
  discard store.waitForExit(2000)
  store.close()
  let release = call(nc, "locks", "lock_release",
                      %*{"leaseId": "owner:call"}, 15000)
  check("release during outage reports failure",
    not release{"ok"}.getBool(false), $release)
  let stillHeld = call(nc, "locks", "lock_acquire", %*{
    "root": root, "paths": [root / "held"], "sessionId": "rival",
    "tool": "write", "callId": "rival"})
  check("failed durable release retains runtime holder",
    stillHeld{"holder"}.getStr("") == "owner", $stillHeld)
  store = startComponent(sandbox.sandboxStoreBin(), url, root = root,
                          logFile = root / "store-final.log")
  waitStore()
  let released = call(nc, "locks", "lock_release", %*{"leaseId": "owner:call"})
  check("release succeeds after recovery", released{"released"}.getInt(0) == 1,
        $released)
  report("LOCK RECOVERY TEST")
main()
