## cli component test — drive a live harness through the cli binary.
##
## Spawns a NATS server and core (headless service mode, NIF_AUTO_APPROVE=1),
## then exercises the cli's catalog/call/wait commands against the bus.
##
## With NIF_TEST_INSTALL=1 the test additionally installs the
## niffler-weather package via `cli install` and validates the tools the
## spawned weather component registers (catalog + live calls) — the same
## flow a plugin repo's CI uses to prove its package works.
##
## Requires a prior `nimble all` (core + all components + cli in var/bin)
## and no other harness running against this repo's var/barrel-db.

import std/[json, net, os, osproc, strtabs, strutils, times]
import natswrapper
import envelope

var failures = 0

proc fail(msg: string) =
  echo "FAIL: ", msg
  inc failures

proc check(name: string, cond: bool, detail: string = "") =
  if cond:
    echo "OK: ", name
  else:
    inc failures
    echo "FAIL: ", name, " — ", detail

proc runCli(bin: string, args: seq[string], url: string,
            timeoutMs: int = 60_000): tuple[code: int, output: string] =
  var env = newStringTable(modeCaseSensitive)
  env["NIF_NATS_URL"] = url
  env["NIF_ROOT"] = getEnv("NIF_ROOT", getAppDir().parentDir())
  let p = startProcess(bin, args = args, env = env,
                       options = {poUsePath, poStdErrToStdOut})
  result.code = p.waitForExit(timeoutMs)
  if result.code == -1:
    p.terminate()
    result.code = 124
  result.output = p.outputStream.readAll()
  p.close()

proc main() =
  let initSt = nats_Open(-1)
  if not checkStatus(initSt):
    fail("nats_Open: " & getErrorString(initSt))
    quit(1)

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let coreBin = root / "var" / "bin" / "niffler"
  let cliBin = root / "var" / "bin" / "cli"
  if not fileExists(coreBin) or not fileExists(cliBin):
    fail(coreBin & " or " & cliBin & " missing — run `make build` first")
    quit(1)

  # --- spawn NATS on a free port -----------------------------------------
  var s = newSocket()
  s.bindAddr(Port(0))
  let port = int(s.getLocalAddr()[1])
  s.close()
  let natsUrl = "nats://127.0.0.1:" & $port
  let server = startProcess("nats-server", args = ["-p", $port],
                            options = {poUsePath})

  var nc: NatsConnection
  var connected = false
  for i in 0 ..< 40:
    try:
      nc = connect(natsUrl)
      connected = true
      break
    except CatchableError:
      sleep(100)
  if not connected:
    fail("cannot connect to " & natsUrl)
    quit(1)

  # --- boot core (headless service mode) ---------------------------------
  var env = newStringTable(modeCaseSensitive)
  env["NIF_ROOT"] = root
  env["NIF_NATS_URL"] = natsUrl
  env["NIF_AUTO_APPROVE"] = "1"
  let coreProc = startProcess(coreBin, workingDir = root, env = env,
                              options = {poUsePath})
  defer:
    # graceful teardown: SIGTERM → core drains children and exits
    if coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running():
        coreProc.kill()
        sleep(200)
    coreProc.close()

  # --- wait for core to be up: svc.core.call answers ---------------------
  var coreUp = false
  for i in 0 ..< 100:
    var msg: ptr natsMsg
    let env2 = callEnvelope("catalog", %*{"op": "list"})
    let data = env2.encode()
    let st = natsConnection_Request(addr msg, nc.conn,
                                    "svc.core.call".cstring,
                                    data.cstring, data.len.cint,
                                    3000)
    if st == NATS_OK:
      let r = decode($natsMsg_GetData(msg))
      natsMsg_Destroy(msg)
      if r.kind == ekResult and r.args{"tools"} != nil:
        coreUp = true
        break
    else:
      sleep(200)
  if not coreUp:
    fail("core never came up on " & natsUrl)
    quit(1)
  echo "OK: core up"

  # --- cli catalog -------------------------------------------------------
  let cat = runCli(cliBin, @["catalog"], natsUrl)
  check("cli catalog exits 0", cat.code == 0, "code=" & $cat.code)
  check("cli catalog lists plugins component",
        cat.output.contains("plugins"), cat.output)
  check("cli catalog lists plugin_install tool",
        cat.output.contains("plugin_install"), cat.output)

  # --- cli wait ----------------------------------------------------------
  let waitOk = runCli(cliBin, @["wait", "plugins", "15"], natsUrl)
  check("cli wait plugins succeeds", waitOk.code == 0, waitOk.output)
  let waitNo = runCli(cliBin, @["wait", "nonexistent-xyz", "2"], natsUrl)
  check("cli wait nonexistent fails", waitNo.code != 0, waitNo.output)

  # --- cli call (store round trip through the bus) -----------------------
  let callOk = runCli(cliBin, @["call", "list", """{"kind":"plugin"}"""], natsUrl)
  check("cli call list succeeds", callOk.code == 0, callOk.output)
  check("cli call returns ok:true", callOk.output.contains("\"ok\":true"),
        callOk.output)
  let callBad = runCli(cliBin, @["call", "no_such_tool_xyz", "{}"], natsUrl)
  check("cli call unknown tool fails", callBad.code != 0, callBad.output)

  # --- install + validate (opt-in: needs network, takes minutes) ---------
  if getEnv("NIF_TEST_INSTALL") == "1":
    echo "-- install phase (network) --"
    let inst = runCli(cliBin, @["install", "gokr/niffler-weather"], natsUrl,
                      900_000)
    echo inst.output
    check("cli install niffler-weather ok", inst.code == 0 and
          inst.output.contains("INSTALL OK"), "code=" & $inst.code)

    let cat2 = runCli(cliBin, @["catalog"], natsUrl)
    check("catalog shows weather_current",
          cat2.output.contains("weather_current"), cat2.output)
    check("catalog shows weather_forecast",
          cat2.output.contains("weather_forecast"), cat2.output)

    let cur = runCli(cliBin,
                     @["call", "weather_current", """{"place":"Gothenburg"}"""],
                     natsUrl, 60_000)
    check("weather_current works", cur.code == 0 and
          cur.output.contains("Gothenburg") and
          cur.output.contains("temperatureC"), cur.output)
    let fc = runCli(cliBin,
                    @["call", "weather_forecast", """{"place":"Stockholm","days":2}"""],
                    natsUrl, 60_000)
    check("weather_forecast works", fc.code == 0 and
          fc.output.contains("forecast"), fc.output)
  else:
    echo "NOTE: set NIF_TEST_INSTALL=1 to run the install + tool-validation phase"

  nc.close()
  server.terminate()
  server.close()
  if failures > 0:
    echo "CLI TEST FAILED: ", failures, " failure(s)"
    quit(1)
  echo "CLI TEST PASSED"

main()
