## console component tests — bus contract: the passive bus viewer.
##
## Starts console against a throwaway NATS, publishes envelopes, and
## checks the rendered output appears on stdout. Covers call/result/event
## rendering and that the console announces itself on reg.publish.

import std/[json, os, osproc, streams, strtabs, strutils, times]
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

# console should announce itself (reg.publish with name console)
  var sub: ptr natsSubscription
  discard natsConnection_SubscribeSync(addr sub, nc.conn, "reg.publish".cstring)
  check("console registers on reg.publish", waitRegistered(nc, "console"))

  # publish a call envelope and a result; console should render both
  let callEnv = callEnvelope("tping", %*{"hello": "world"})
  nc.publish("svc.tping.call", callEnv.encode())
  let resEnv = resultEnvelope(callEnv.id, %*{"pong": true})
  nc.publish("_INBOX.test-reply", resEnv.encode())
  let evEnv = Envelope(v: 1, id: newId(), kind: ekEvent,
                       payload: %*{"kind": "ev.example", "note": "hello bus"})
  nc.publish("ev.example", evEnv.encode())

  sleep(500)
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
