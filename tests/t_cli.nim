## cli component tests — bus contract: driving a live harness from the
## command line.
##
## Boots core headless and exercises the cli's catalog/wait/call commands
## (exit codes and output), including error paths. With NIF_TEST_INSTALL=1
## it also runs the real `cli install` of gokr/niffler-weather and
## validates the tools the spawned weather component registers (network,
## minutes). The hermetic file:// install path is covered by t_plugins.

import std/[json, os, osproc, streams, strutils]
import natsnim
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

  # --- --bus beats the environment, in BOTH spellings ----------------------
  # Two bugs the space form hid (found driving a remote instance, not by the
  # suite — every other test spells its options `--x=y`):
  #  1. `cli call/catalog/wait` never read --bus at all; only `cli run` did,
  #     so `cli --bus <other> catalog` answered from NIF_NATS_URL — the
  #     accidental cross-attachment the identity rules exist to prevent.
  #  2. The parser captured the option NAME after consuming the value, so
  #     every space-separated flag was filed under its own value and dropped.
  # A bus that cannot be reached is the proof: with the env pointing at the
  # live test bus, `--bus <dead>` must FAIL rather than quietly succeed.
  let fleetBus = runCli(cliBin, url, @["catalog"], root = root)
  let explicitEq = runCli(cliBin, url, @["--bus=nats://127.0.0.1:9", "catalog"],
                          root = root)
  let explicitSpace = runCli(cliBin, url,
                             @["--bus", "nats://127.0.0.1:9", "catalog"],
                             root = root)
  check("cli catalog without --bus uses NIF_NATS_URL",
        fleetBus.code == 0 and fleetBus.output.contains("plugins"),
        fleetBus.output)
  check("cli --bus=<dead> is honoured", explicitEq.code != 0 and
        explicitEq.output.contains("cannot connect"), explicitEq.output)
  check("cli --bus <dead> (space form) is honoured too",
        explicitSpace.code != 0 and explicitSpace.output.contains("cannot connect"),
        explicitSpace.output)
  # The space form must also still carry a REAL value through: same bus, both
  # spellings, same harness identity line.
  let sameEq = runCli(cliBin, url, @["--bus=" & url, "catalog"], root = root)
  let sameSpace = runCli(cliBin, url, @["--bus", url, "catalog"], root = root)
  check("both --bus spellings reach the same harness",
        sameEq.code == 0 and sameSpace.code == 0 and
        sameEq.output.splitLines()[0] == sameSpace.output.splitLines()[0],
        sameEq.output & "|" & sameSpace.output)

  # --- catalog -------------------------------------------------------------
  let cat = runCli(cliBin, url, @["catalog"], root = root)
  check("cli catalog exits 0", cat.code == 0, "code=" & $cat.code)
  check("cli catalog lists plugins + tools",
        cat.output.contains("plugins") and cat.output.contains("plugin_install"),
        cat.output)

  # --- wait ----------------------------------------------------------------
  let waitOk = runCli(cliBin, url, @["wait", "plugins", "15"], root = root)
  check("cli wait plugins succeeds", waitOk.code == 0, waitOk.output)
  let waitImmediate = runCli(cliBin, url, @["wait", "plugins", "0"], root = root)
  check("cli zero-second wait checks core once", waitImmediate.code == 0,
        waitImmediate.output)
  let waitNo = runCli(cliBin, url, @["wait", "nonexistent-xyz", "2"],
                      root = root)
  check("cli wait nonexistent fails", waitNo.code != 0, waitNo.output)

  # Start the CLI first, then announce. Observing its catalog request is a
  # synchronization barrier: an old CLI has already subscribed to reg.>.
  # Starting it after the announcement misses the original false-success bug.
  block:
    var requests: ptr natsSubscription
    doAssert natsConnection_SubscribeSync(addr requests, nc.conn,
                                          "svc.core.call") == NATS_OK
    defer: natsSubscription_Destroy(requests)
    discard natsConnection_Flush(nc.conn)
    let waiting = startComponent(cliBin, url, root = root,
                                  args = ["wait", "cli-rejected", "2"])
    defer: stopProcess(waiting)
    var request: ptr natsMsg
    doAssert natsSubscription_NextMsg(addr request, requests, 5_000) == NATS_OK
    natsMsg_Destroy(request)
    nc.publish("reg.publish", $(%*{"name": "cli-rejected", "version": "1",
      "tools": [{"name": "catalog", "schema": {"type": "object"}}]}))
    let snapshot = call(nc, "core", "catalog", %*{"op": "components"})
    check("core rejects conflicting registration",
          snapshot{"components"} != nil and
          snapshot{"components", "cli-rejected"} == nil, $snapshot)
    let code = waiting.waitForExit(7_000)
    if code == -1: waiting.kill()
    let output = waiting.outputStream.readAll()
    check("cli wait rejects a live conflicting announcement",
          code > 0 and output.contains("not registered"), output)

  block:
    var requests: ptr natsSubscription
    doAssert natsConnection_SubscribeSync(addr requests, nc.conn,
                                          "svc.core.call") == NATS_OK
    defer: natsSubscription_Destroy(requests)
    discard natsConnection_Flush(nc.conn)
    let waiting = startComponent(cliBin, url, root = root,
                                  args = ["wait", "cli-accepted", "5"])
    defer: stopProcess(waiting)
    var request: ptr natsMsg
    doAssert natsSubscription_NextMsg(addr request, requests, 5_000) == NATS_OK
    natsMsg_Destroy(request)
    nc.publish("reg.publish", $(%*{"name": "cli-accepted", "version": "1",
                                  "tools": []}))
    let code = waiting.waitForExit(7_000)
    if code == -1: waiting.kill()
    let output = waiting.outputStream.readAll()
    check("cli wait sees a newly accepted zero-tool component",
          code == 0 and output.contains("cli-accepted registered"), output)
    nc.publish("reg.depart", $(%*{"name": "cli-accepted"}))
    let departed = runCli(cliBin, url, @["wait", "cli-accepted", "1"], root = root)
    check("cli wait rejects a departed component", departed.code != 0,
          departed.output)

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

  # --- call honours the tool's declared budget ------------------------------
  # The bug this pins, found live: `fleet_update` declares a 4400 s budget
  # because it rebuilds a remote checkout, but `call` used a flat 30 s default.
  # A real update was reported as a timeout while the component kept working —
  # and the operator could not tell "my client stopped waiting" from "it
  # failed", on an operation that mutates another machine. A slow tool must be
  # awaited for as long as it declared.
  const slowSource = """
    import niffler/sdk
    import std/os

    let comp = newComponent("cli-slow", "0.1.0")
    comp.tool(%*{"timeoutMs": 60000, "hidden": true}):
      proc cli_slow_operation(milliseconds: int = 40000): JsonNode =
        ## Sleep, standing in for a long remote operation.
        ## - milliseconds: how long to occupy the call
        sleep(milliseconds)
        %*{"ok": true, "waited": milliseconds}
    comp.run()
    """.dedent()
  let built = call(nc, "builder", "build",
                   %*{"lang": "nim", "name": "cli-slow", "source": slowSource},
                   300_000)
  check("builder builds a tool with a declared budget",
        built{"ok"}.getBool(false), $built)
  let spawned = call(nc, "core", "spawn",
                     %*{"name": "cli-slow", "binary": built{"binary"}.getStr("")},
                     60_000)
  check("core spawns the slow tool", spawned{"ok"}.getBool(false), $spawned)
  if spawned{"ok"}.getBool(false):
    # 40 s of work against a 30 s default: the regression is exactly that this
    # used to exit non-zero at 30 s.
    let slow = runCli(cliBin, url, @["call", "cli_slow_operation"], 90_000,
                      root = root)
    check("cli call waits past the old 30s default for a tool that declares more",
          slow.code == 0 and slow.output.contains("\"waited\":40000"),
          slow.output)

    # An explicit --timeout is the operator's intent and must still win,
    # including when it is SHORTER than the declared budget.
    let cut = runCli(cliBin, url,
                     @["--timeout", "5", "call", "cli_slow_operation"], 60_000,
                     root = root)
    check("an explicit --timeout still cuts a long call short", cut.code != 0,
          cut.output)
    check("a cut-off call says the work may still be running",
          cut.output.contains("does NOT cancel work already dispatched"),
          cut.output)
    discard call(nc, "core", "remove", %*{"name": "cli-slow"}, 60_000)

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
