## console component tests — bus contract: the passive bus viewer.
##
## Starts console against a throwaway NATS, publishes envelopes, and
## checks the rendered output appears on stdout. Covers call/result/event
## rendering and that the console announces itself on reg.publish.

import std/[json, os, osproc, streams, strtabs, strutils, times]
when defined(nifflerNimNats):
  # Pure-Nim client (github.com/gokr/natsnim), aliased to `natswrapper` so every
  # call site below stays byte-identical. Enabled with
  #   make build NIMFLAGS='-d:nifflerNimNats --path:$HOME/git/natsnim/src'
  # See docs/research/NATSNIM.md.
  import natsnim as natswrapper
else:
  import natswrapper
import envelope
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "console"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # start console with its stdout redirected to a file (pipe streams don't
  # support peek/position — poll the file instead)
  let tmp = tempRoot("console")
  defer: removeDir(tmp)
  let outPath = tmp / "console.out"
  # Install the observer server-side before spawning: startup announcements
  # are not replayed to subscribers that arrive later.
  var regSub: ptr natsSubscription
  let regSt = natsConnection_SubscribeSync(addr regSub, nc.conn,
                                           "reg.publish".cstring)
  if not checkStatus(regSt):
    raise newException(IOError, "subscribe reg.publish: " & getErrorString(regSt))
  defer: natsSubscription_Destroy(regSub)
  let flushSt = natsConnection_FlushTimeout(nc.conn, 2000)
  if not checkStatus(flushSt):
    raise newException(IOError, "flush reg.publish: " & getErrorString(flushSt))
  var env = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs():
    env[k] = v
  env["NIF_ROOT"] = tmp
  env["NIF_NATS_URL"] = url
  let consoleProc = startProcess("bash",
      args = ["-c", "exec " & quoteShell(bin) & " > " & quoteShell(outPath) & " 2>&1"],
      env = env, options = {poUsePath})
  defer:
    if consoleProc.running():
      consoleProc.terminate()
      sleep(200)
    consoleProc.close()

  proc waitForOutput(needle: string, secs: int): bool =
    let deadline = epochTime() + secs.float
    while epochTime() < deadline:
      if fileExists(outPath) and readFile(outPath).contains(needle):
        return true
      sleep(100)
    return false

  check("console registers on reg.publish", waitRegisteredOn(regSub, "console"))

  # Registration precedes the console's SUB >. Prove the viewer is receiving
  # before sending the one-shot rendering fixtures; the banner alone is not
  # a server-side subscription barrier.
  let readyEnv = Envelope(v: 1, id: newId(), kind: ekEvent,
                          payload: %*{"ready": true})
  var ready = false
  for attempt in 0 ..< 5:
    nc.publish("ev.console.ready", readyEnv.encode())
    if waitForOutput("ev.console.ready", 1):
      ready = true
      break
  check("console subscription is ready", ready)

  # publish a call envelope and a result; console should render both
  let callEnv = callEnvelope("tping", %*{"hello": "world"})
  nc.publish("svc.tping.call", callEnv.encode())
  let resEnv = resultEnvelope(callEnv.id, %*{"pong": true})
  nc.publish("_INBOX.test-reply", resEnv.encode())
  let evEnv = Envelope(v: 1, id: newId(), kind: ekEvent,
                       payload: %*{"kind": "ev.example", "note": "hello bus"})
  nc.publish("ev.example", evEnv.encode())

  discard waitForOutput("ev.example", 5)
  let buf = if fileExists(outPath): readFile(outPath) else: ""

  check("console renders call with tool+args",
        buf.contains("call") and buf.contains("tping") and
        buf.contains("hello"), buf)
  check("console renders result", buf.contains("result") and
        buf.contains("pong"), buf)
  check("console renders event subject", buf.contains("ev.example"), buf)
  check("console announces itself", buf.contains("console"), buf)

  # drain: console has no signal handling; SIGTERM kills it
  consoleProc.terminate()
  sleep(200)

  report("CONSOLE TEST")

main()
