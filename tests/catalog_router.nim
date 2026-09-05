## Standalone component tests use the production admission/routing authority,
## without booting a supervisor, store or conversation runner.
import std/[os, json, tables]
import ../sdk/envelope
import natswrapper
import ../core/catalog

let nc = connect(paramStr(1))
let cat = newCatalog(nc, serve = true)
var core: ptr natsSubscription
doAssert natsConnection_SubscribeSync(addr core, nc.conn, "svc.core.call") == NATS_OK
discard natsConnection_Flush(nc.conn)
writeFile(paramStr(2), "ready")
while true:
  cat.pump()
  var msg: ptr natsMsg
  if natsSubscription_NextMsg(addr msg, core, 1) == NATS_OK:
    let env = decode($natsMsg_GetData(msg))
    let reply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    if env.tool == "catalog" and env.args{"op"}.getStr() == "components":
      var components = newJObject()
      for name, reg in cat.components:
        var tools = newJArray()
        for tool in reg.tools: tools.add(%tool.name)
        components[name] = tools
      nc.publish(reply, resultEnvelope(env.id, %*{"components": components}).encode())
  sleep(1)
