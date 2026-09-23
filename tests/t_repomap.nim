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

  # --- auto-append is ON by default (the admission gates still apply) ------
  # A tiny fixture must be withheld by the census floor. A padded workspace
  # below proves that an unset switch does publish a qualifying map.

  # --- append gates (docs/research/REPOMAP-GATES.md) --------------------------
  # The append admits a map only when the workspace clears the census floor
  # and the rendered map clears the content gate. The fixture `ws` above is
  # tiny (4 files, ~10 syms), so the content-gate test below overrides only
  # the census floor; the default-on happy path uses a padded workspace.
  proc recvMap(mapSub: ptr natsSubscription, secs = 60): JsonNode =
    ## wait for a map event (or return nil on timeout)
    for i in 0 ..< secs * 2:
      var msg: ptr natsMsg
      let st = natsSubscription_NextMsg(addr msg, mapSub, 500)
      if st == NATS_OK:
        let env = decode($natsMsg_GetData(msg))
        natsMsg_Destroy(msg)
        if env.kind == ekEvent and env.payload{"map"}.getStr("").len > 0:
          return env.payload
    nil

  # padded workspace: 60 files x 4 defs, past both gates
  let bigWs = tmp / "bigws"
  createDir(bigWs)
  for i in 0 ..< 60:
    var src = ""
    for j in 0 ..< 4:
      src.add("proc fn" & $i & "x" & $j & "(x: int): int =\n  x + " & $j &
              "\n\n")
    writeFile(bigWs / ("mod" & $i & ".nim"), src)

  # append ON, floor default (50): tiny ws must be WITHHELD (size floor).
  var sub1: ptr natsSubscription
  discard natsConnection_SubscribeSync(addr sub1, nc.conn,
                                       "svc.session.sess-small.map".cstring)
  nc.publish("ev.workspace.opened",
    Envelope(v: 1, id: newId(), kind: ekEvent,
             payload: %*{"workspace": ws,
                         "conversationId": "sess-small"}).encode())
  check("default-on size floor withholds the tiny workspace",
        recvMap(sub1, 3) == nil)

  # default-on append, padded workspace: must publish
  var mapSub: ptr natsSubscription
  let sst = natsConnection_SubscribeSync(addr mapSub, nc.conn,
                                         "svc.session.sess-big.map".cstring)
  if not checkStatus(sst): fail("cannot subscribe to map subject"); quit(1)
  nc.publish("ev.workspace.opened",
    Envelope(v: 1, id: newId(), kind: ekEvent,
             payload: %*{"workspace": bigWs,
                         "conversationId": "sess-big"}).encode())
  var got = recvMap(mapSub)
  check("auto-append publishes a substantive map by default",
        got != nil and got{"conversationId"}.getStr("") == "sess-big" and
        got{"map"}.getStr("").contains("fn0x0"),
        (if got != nil: $got{"map"}.getStr("")[0 ..< 120] else: "nothing arrived"))

  # Restart with the switch explicitly OFF: even the padded workspace must
  # remain silent, while the onDemand tool continues to work.
  if rmProc.peekExitCode() == -1: rmProc.terminate()
  sleep(300)
  let rmOff = startComponent(bin, url, root = tmp,
                             extra = [("NIF_REPOMAP_AUTOAPPEND", "0")])
  defer:
    if rmOff.peekExitCode() == -1: rmOff.terminate()
    rmOff.close()
  check("repomap re-registers with auto-append off", waitRegistered(nc, "repomap"))
  var offBigSub: ptr natsSubscription
  discard natsConnection_SubscribeSync(addr offBigSub, nc.conn,
                                       "svc.session.sess-big-off.map".cstring)
  nc.publish("ev.workspace.opened",
    Envelope(v: 1, id: newId(), kind: ekEvent,
             payload: %*{"workspace": bigWs,
                         "conversationId": "sess-big-off"}).encode())
  check("explicit opt-out withholds a qualifying map", recvMap(offBigSub, 3) == nil)
  let mOff = mapCall(%*{"workspace": "ws"})
  check("tool remains available with append disabled",
        mOff{"ok"}.getBool(false) and mOff{"text"}.getStr("").contains("resolveBinIn"), $mOff)
  if rmOff.peekExitCode() == -1: rmOff.terminate()
  sleep(300)

  # content gate: floor overridden to 1, tiny ws builds but is a stub — the
  # component must withhold it (its map is ~10 syms / 4 files / <800B).
  let rmTiny = startComponent(bin, url, root = tmp,
                              extra = [("NIF_REPOMAP_MIN_CENSUS", "1")])
  defer:
    if rmTiny.peekExitCode() == -1: rmTiny.terminate()
    rmTiny.close()
  check("repomap re-registers with the floor overridden",
        waitRegistered(nc, "repomap"))
  var sub2: ptr natsSubscription
  discard natsConnection_SubscribeSync(addr sub2, nc.conn,
                                       "svc.session.sess-stub.map".cstring)
  nc.publish("ev.workspace.opened",
    Envelope(v: 1, id: newId(), kind: ekEvent,
             payload: %*{"workspace": ws,
                         "conversationId": "sess-stub"}).encode())
  check("content gate withholds a stub map", recvMap(sub2, 3) == nil)

  # tool path immunity: same tiny workspace, explicit call, no gates
  let mTiny = mapCall(%*{"workspace": "ws"})
  check("tool path is never gated",
        mTiny{"ok"}.getBool(false) and
        mTiny{"text"}.getStr("").contains("resolveBinIn"), $mTiny)

  report("REPOMAP")

main()
