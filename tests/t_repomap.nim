## repomap component tests — bus contract: the repo_map tool (map contents,
## cache files, focus exclusion, budget, errors) and the auto-append flow
## (ev.workspace.opened -> svc.session.<id>.map).

import std/[json, os, osproc, sequtils, strutils]
import envelope
import natsnim
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "repomap"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)
  let tmp = tempRoot("repomap")
  defer: removeDir(tmp)

  # fixture workspace: real sources + a special file
  let ws = tmp / "ws"
  createDir(ws)
  for f in ["sample.nim", "sample.py", "sample.go"]:
    copyFile(root / "tests" / "fixtures" / "repomap" / f, ws / f)
  writeFile(ws / "README.md", "# fixture repo\n")

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let rmProc = startComponent(bin, url, root = tmp)
  defer:
    if rmProc.running():
      rmProc.terminate()
      sleep(200)
    rmProc.close()

  check("repomap registers", waitRegistered(nc, "repomap"))

  proc mapCall(args: JsonNode, timeoutMs = 60000): JsonNode =
    call(nc, "repomap", "repo_map", args, timeoutMs)

  # --- full map -------------------------------------------------------------
  let m1 = mapCall(%*{"workspace": "ws"})
  check("map renders defs from all tiers",
        m1{"ok"}.getBool(false) and
        m1{"text"}.getStr("").contains("resolveBinIn") and
        m1{"text"}.getStr("").contains("parse_config") and
        m1{"text"}.getStr("").contains("NewServer"), $m1)
  check("special file rendered bare", m1{"text"}.getStr("").contains("README.md"),
        $m1)

  # --- cache: files exist under var/repomap-tags, second call identical -----
  let cacheDir = tmp / "var" / "repomap-tags"
  check("cache dir populated", dirExists(cacheDir) and
        toSeq(walkDir(cacheDir)).len >= 3, $(
        (if dirExists(cacheDir): toSeq(walkDir(cacheDir)).len else: 0)))
  let m2 = mapCall(%*{"workspace": "ws"})
  check("cached rebuild is byte-identical", m2{"text"}.getStr("") ==
        m1{"text"}.getStr(""), "")

  # --- focus: the conversation's own defs are dropped ------------------------
  let mf = mapCall(%*{"workspace": "ws", "focus": ["sample.py"]})
  check("focus file's defs are excluded",
        mf{"ok"}.getBool(false) and
        not mf{"text"}.getStr("").contains("parse_config") and
        mf{"text"}.getStr("").contains("resolveBinIn"), $mf)

  # --- budget ----------------------------------------------------------------
  let mb = mapCall(%*{"workspace": "ws", "budget": 60})
  # the budget binary search accepts within +/-15% (aider's tolerance)
  check("budget bounds the map",
        mb{"ok"}.getBool(false) and
        mb{"text"}.getStr("").len <= (60.0 * 1.15).int * 4 + 16,
        $mb{"text"}.getStr("").len)

  # --- errors -----------------------------------------------------------------
  let miss = mapCall(%*{"workspace": "nope"})
  check("missing workspace refused", miss.hasKey("error") and
        miss{"error"}.getStr("").contains("[E_NOT_FOUND]"), $miss)

  # --- auto-append: ev.workspace.opened -> svc.session.<id>.map ---------------
  var mapSub: ptr natsSubscription
  let sst = natsConnection_SubscribeSync(addr mapSub, nc.conn,
                                         "svc.session.sess-test.map".cstring)
  if not checkStatus(sst): fail("cannot subscribe to map subject"); quit(1)
  let ev = Envelope(v: 1, id: newId(), kind: ekEvent,
                    payload: %*{"workspace": ws, "conversationId": "sess-test"})
  nc.publish("ev.workspace.opened", ev.encode())
  # the build is bounded and cached — should arrive quickly; 60s for slow CI
  var got: JsonNode = nil
  for i in 0 ..< 120:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, mapSub, 500)
    if st == NATS_OK:
      let env = decode($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if env.kind == ekEvent and env.payload{"map"}.getStr("").len > 0:
        got = env.payload
        break
  check("auto-append publishes the map for the conversation",
        got != nil and got{"conversationId"}.getStr("") == "sess-test" and
        got{"map"}.getStr("").contains("resolveBinIn"),
        (if got != nil: $got{"map"}.getStr("")[0 ..< 120] else: "nothing arrived"))

  report("REPOMAP")

main()
