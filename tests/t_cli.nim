## cli component tests — bus contract: driving a live harness from the
## command line.
##
## Boots core headless and exercises the cli's catalog/wait/call commands
## (exit codes and output), including error paths. With NIF_TEST_INSTALL=1
## it also runs the real `cli install` of gokr/niffler-weather and
## validates the tools the spawned weather component registers (network,
## minutes). The hermetic file:// install path is covered by t_plugins.

import std/[json, os, osproc, strutils]
import natswrapper
import envelope
import helpers

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  if not fileExists(repoRoot / "var" / "bin" / "niffler") or
     not fileExists(repoRoot / "var" / "bin" / "cli"):
    fail("missing binaries — run `make build` first")
    quit(1)
  let sandbox = newCoreSandbox("cli", ["store", "builder", "plugins"])
  let root = sandbox.root
  let coreBin = sandbox.sandboxBin("niffler")
  let cliBin = sandbox.sandboxBin("cli")
  defer: removeDir(root)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let coreProc = startComponent(coreBin, url, root = root,
                                extra = [("NIF_AUTO_APPROVE", "1")])
  defer:
    if coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running():
        coreProc.kill()
        sleep(200)
    coreProc.close()

  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check("core up", coreUp)

  # --- catalog -------------------------------------------------------------
  let cat = runCli(cliBin, url, @["catalog"], root = root)
  check("cli catalog exits 0", cat.code == 0, "code=" & $cat.code)
  check("cli catalog lists plugins + tools",
        cat.output.contains("plugins") and cat.output.contains("plugin_install"),
        cat.output)

  # --- wait ----------------------------------------------------------------
  let waitOk = runCli(cliBin, url, @["wait", "plugins", "15"], root = root)
  check("cli wait plugins succeeds", waitOk.code == 0, waitOk.output)
  let waitNo = runCli(cliBin, url, @["wait", "nonexistent-xyz", "2"],
                      root = root)
  check("cli wait nonexistent fails", waitNo.code != 0, waitNo.output)

  # --- call ----------------------------------------------------------------
  let callOk = runCli(cliBin, url, @["call", "list", """{"kind":"plugin"}"""],
                      root = root)
  check("cli call list succeeds", callOk.code == 0 and
        callOk.output.contains("\"ok\":true"), callOk.output)
  let callBad = runCli(cliBin, url, @["call", "no_such_tool_xyz", "{}"],
                       90_000, root = root)
  check("cli call unknown tool fails", callBad.code != 0 and
        callBad.output.contains("no component provides"), callBad.output)
  let callJson = runCli(cliBin, url, @["call", "list", "not-json{"], root = root)
  check("cli call bad json fails", callJson.code != 0, callJson.output)

  # --- install + validate (opt-in: real network install, takes minutes) -----
  if getEnv("NIF_TEST_INSTALL") == "1":
    echo "-- install phase (network) --"
    let inst = runCli(cliBin, url, @["install", "gokr/niffler-weather"],
                      900_000, root = root)
    echo inst.output
    check("cli install niffler-weather ok", inst.code == 0 and
          inst.output.contains("INSTALL OK"), "code=" & $inst.code)

    let cat2 = runCli(cliBin, url, @["catalog"], root = root)
    check("catalog shows weather_current + weather_forecast",
          cat2.output.contains("weather_current") and
          cat2.output.contains("weather_forecast"), cat2.output)

    let cur = runCli(cliBin, url,
                     @["call", "weather_current", """{"place":"Gothenburg"}"""],
                     60_000, root = root)
    check("weather_current works", cur.code == 0 and
          cur.output.contains("Gothenburg") and
          cur.output.contains("temperatureC"), cur.output)
    let fc = runCli(cliBin, url,
                     @["call", "weather_forecast",
                      """{"place":"Stockholm","days":2}"""], 60_000,
                     root = root)
    check("weather_forecast works", fc.code == 0 and
          fc.output.contains("forecast"), fc.output)
  else:
    echo "NOTE: set NIF_TEST_INSTALL=1 to run the real install + validation"

  report("CLI TEST")

main()
