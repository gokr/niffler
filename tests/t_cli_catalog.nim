## CLI catalog authority at the wire boundary. A controlled core responder
## orders raw announcements before snapshot replies, without scheduler races.
## Real core conflict rejection and plugin installation live in t_cli/t_plugins.

import std/[json, os, osproc, streams, strutils]
import natswrapper
import envelope
import helpers

proc nextCall(sub: ptr natsSubscription): tuple[reply: string, env: Envelope] =
  var msg: ptr natsMsg
  doAssert natsSubscription_NextMsg(addr msg, sub, 5_000) == NATS_OK
  defer: natsMsg_Destroy(msg)
  result = ($natsMsg_GetReply(msg), decode($natsMsg_GetData(msg)))

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  let root = tempRoot("cli-catalog")
  defer: removeDir(root)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var core, service: ptr natsSubscription
  doAssert natsConnection_SubscribeSync(addr core, nc.conn, "svc.core.call") == NATS_OK
  defer: natsSubscription_Destroy(core)
  doAssert natsConnection_SubscribeSync(addr service, nc.conn, "svc.owner.call") == NATS_OK
  defer: natsSubscription_Destroy(service)
  discard natsConnection_Flush(nc.conn)
  let cliBin = repoRoot / "var" / "bin" / "cli"

  proc announce() =
    nc.publish("reg.publish", $(%*{"name": "rejected", "tools": [
      {"name": "owner_ping", "schema": {"type": "object"}}]}))

  # Publish first, then answer the CLI's initial snapshot request. An old
  # CLI consumes the queued announcement after its authoritative seed.
  block:
    let cli = startComponent(cliBin, url, root = root, args = ["catalog"])
    defer: stopProcess(cli)
    let request = nextCall(core)
    announce()
    nc.publish(request.reply, resultEnvelope(request.env.id,
      %*{"components": {"owner": ["owner_ping"]}}).encode())
    let code = cli.waitForExit(5_000)
    if code == -1: cli.kill()
    let output = cli.outputStream.readAll()
    check("catalog ignores unaccepted announcements", code == 0 and
      output.contains("owner: owner_ping") and not output.contains("rejected:"), output)

  block:
    let cli = startComponent(cliBin, url, root = root,
                             args = ["--timeout:1", "call", "owner_ping", "{}"])
    defer: stopProcess(cli)
    let request = nextCall(core)
    announce()
    nc.publish(request.reply, resultEnvelope(request.env.id,
      %*{"components": {"owner": ["owner_ping"]}}).encode())
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, service, 2_000)
    check("tool lookup retains core's accepted owner", st == NATS_OK)
    if st == NATS_OK:
      let call = decode($natsMsg_GetData(msg))
      nc.publish($natsMsg_GetReply(msg), resultEnvelope(call.id, %*{"pong": true}).encode())
      natsMsg_Destroy(msg)
    let code = cli.waitForExit(5_000)
    if code == -1: cli.kill()
    let output = cli.outputStream.readAll()
    check("call reaches accepted provider", code == 0 and output.contains("\"pong\":true"), output)

  for response in ["not-json", "{}", "{\"components\":[]}"]:
    let cli = startComponent(cliBin, url, root = root, args = ["catalog"])
    defer: stopProcess(cli)
    let request = nextCall(core)
    announce()
    let data = if response == "not-json": response
               else: resultEnvelope(request.env.id, parseJson(response)).encode()
    nc.publish(request.reply, data)
    let code = cli.waitForExit(5_000)
    if code == -1: cli.kill()
    let output = cli.outputStream.readAll()
    check("invalid snapshot cannot validate announcements: " & response,
          code > 0 and not output.contains("rejected:"), output)

  block:
    let cli = startComponent(cliBin, url, root = root,
                             args = ["wait", "rejected", "1"])
    defer: stopProcess(cli)
    discard nextCall(core)
    announce()
    # Deliberately withhold core's response. The wait must honor its deadline
    # and cannot fall back to a raw announcement when the request times out.
    let code = cli.waitForExit(3_000)
    if code == -1: cli.kill()
    let output = cli.outputStream.readAll()
    check("unresponsive core cannot confirm registration", code > 0 and
          output.contains("not registered"), output)

  block:
    var plugins: ptr natsSubscription
    doAssert natsConnection_SubscribeSync(addr plugins, nc.conn,
                                          "svc.plugins.call") == NATS_OK
    defer: natsSubscription_Destroy(plugins)
    discard natsConnection_Flush(nc.conn)
    let cli = startComponent(cliBin, url, root = root,
                             args = ["install", "fixture/package"])
    defer: stopProcess(cli)
    let initial = nextCall(core)
    nc.publish(initial.reply, resultEnvelope(initial.env.id,
      %*{"components": {"plugins": ["plugin_install"],
                         "replacement": ["old_tool"]}}).encode())
    let install = nextCall(plugins)
    nc.publish(install.reply, resultEnvelope(install.env.id,
      %*{"ok": true, "components": [{"name": "replacement", "spawned": true, "pids": [222, 333]}]}).encode())
    # Old membership remains present. Neither it nor a partially accepted
    # replica group can acknowledge the instances returned by this spawn.
    for ids in [@[111], @[111, 222]]:
      let pending = nextCall(core)
      nc.publish(pending.reply, resultEnvelope(pending.env.id,
        %*{"components": [{"name": "replacement", "pids": ids,
                           "tools": [{"name": "old_tool"}]}]}).encode())
    let missing = nextCall(core)
    nc.publish(missing.reply, resultEnvelope(missing.env.id,
      %*{"components": []}).encode())
    let accepted = nextCall(core)
    nc.publish(accepted.reply, resultEnvelope(accepted.env.id,
      %*{"components": [{"name": "replacement", "pids": [222, 333],
        "tools": [{"name": "new_one"}, {"name": "new_two"}]}]}).encode())
    let code = cli.waitForExit(5_000)
    if code == -1: cli.kill()
    let output = cli.outputStream.readAll()
    check("install requires every spawned instance in a fresh accepted snapshot",
          code == 0 and output.contains("replacement registered (2 tools)"), output)

  for ids in [newJNull(), %* [], %* [0], %* ["222"]]:
    var plugins: ptr natsSubscription
    doAssert natsConnection_SubscribeSync(addr plugins, nc.conn,
                                          "svc.plugins.call") == NATS_OK
    defer: natsSubscription_Destroy(plugins)
    discard natsConnection_Flush(nc.conn)
    let cli = startComponent(cliBin, url, root = root,
                             args = ["install", "fixture/package"])
    defer: stopProcess(cli)
    let initial = nextCall(core)
    nc.publish(initial.reply, resultEnvelope(initial.env.id,
      %*{"components": {"plugins": ["plugin_install"],
                         "replacement": ["old_tool"]}}).encode())
    let install = nextCall(plugins)
    nc.publish(install.reply, resultEnvelope(install.env.id,
      %*{"ok": true, "components": [{"name": "replacement", "spawned": true,
                                      "pids": ids}]}).encode())
    let code = cli.waitForExit(5_000)
    if code == -1: cli.kill()
    let output = cli.outputStream.readAll()
    check("install fails closed without valid spawn IDs: " & $ids,
      code > 0 and output.contains("INSTALL FAILED"), output)

  report("CLI CATALOG TEST")

main()
