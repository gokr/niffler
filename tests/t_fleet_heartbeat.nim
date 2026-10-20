## Fleet's transport waits must keep NATS protocol traffic moving, without
## dispatching another tool handler. No real SSH/VMs, short isolated heartbeat.
import std/[json, os, osproc, strtabs, strutils, tempfiles]
import natsnim
import niffler/sdk
import helpers
import ../components/fleet/delegation

if paramCount() == 1:
  let c = newComponent("fleet-heartbeat-fixture", "0.1.0")
  let pump = paramStr(1) == "pumped"
  discard c.tool("fleet_heartbeat_wait", %*{"type": "object", "properties": {}},
    proc(c: Component, args: JsonNode): JsonNode =
      if not pump:
        sleep(1800)
        return %*{"ok": true}
      let run = connectedRunner(c)
      let r = run(@["/bin/sh", "-c", "sleep 1.8; printf 'finished'"], "", 4000)
      %*{"ok": r.code == 0, "text": r.output})
  c.run()
else:
  proc main() =
    let root = createTempDir("fleet-heartbeat-", "", getCurrentDir() / "var")
    defer: removeDir(root)
    writeFile(root / "nats.conf", "ping_interval: 200ms\nping_max: 2\n")
    let server = startProcess(getCurrentDir() / "var/bin/nats-server",
      args = ["-c", root / "nats.conf", "-a", "127.0.0.1", "-p", "-1",
              "--ports_file_dir", root], options = {poParentStreams})
    defer: stopServer(server)
    var url = ""
    for i in 0..<100:
      for p in walkFiles(root / "*.ports"):
        url = parseFile(p)["nats"][0].getStr()
      if url.len > 0: break
      sleep(20)
    doAssert url.len > 0
    var nc = waitConnect(url)
    defer: nc.close()
    let client = newComponent("fleet-heartbeat-client", "0.1.0")
    client.nc = nc
    var env = newStringTable(modeCaseSensitive)
    for k, v in envPairs(): env[k] = v
    env["NIF_NATS_URL"] = url
    env["NIF_ROOT"] = root
    # Negative control: a handler that blocks without pumping loses its reply.
    for mode in ["blocked", "pumped"]:
      var registration: ptr natsSubscription
      doAssert checkStatus(natsConnection_SubscribeSync(addr registration, nc.conn, "reg.publish"))
      discard natsConnection_Flush(nc.conn)
      let child = startProcess(getAppFilename(), args = [mode], env = env,
                               options = {poParentStreams})
      try:
        check("fixture registers " & mode, waitRegisteredOn(registration, "fleet-heartbeat-fixture"))
        var replied = false
        var text = ""
        try:
          let r = client.request("fleet-heartbeat-fixture", "fleet_heartbeat_wait", %*{}, 3500)
          replied = r{"ok"}.getBool(false)
          text = r{"text"}.getStr("")
        except CatchableError: discard
        if mode == "blocked":
          check("negative control loses stale-connection reply", not replied)
        else:
          check("transport wait preserves original caller reply", replied and text == "finished")
          let again = client.request("fleet-heartbeat-fixture", "fleet_heartbeat_wait", %*{}, 3500)
          check("connection remains usable after long handler", again{"ok"}.getBool(false))
      finally:
        stopProcess(child)
        natsSubscription_Destroy(registration)
      # Let its departed registration drain before starting the next fixture.
      sleep(250)
    report("FLEET HEARTBEAT TEST")
  main()
