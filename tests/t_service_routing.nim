## Admission controls delivery, even if a rejected subscriber stays connected.
import std/[json, tables]
import ../core/catalog
import natswrapper
import envelope
import helpers

proc main() =
  let (server, url) = startNats(routed = true)
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let acceptedSubject = "svc.routing.instance.accepted.call"
  let rejectedSubject = "svc.routing.instance.rejected.call"
  let replicaSubject = "svc.routing.instance.replica.call"
  var accepted, rejected, replica: ptr natsSubscription
  doAssert natsConnection_SubscribeSync(addr accepted, nc.conn, acceptedSubject.cstring) == NATS_OK
  doAssert natsConnection_SubscribeSync(addr rejected, nc.conn, rejectedSubject.cstring) == NATS_OK
  doAssert natsConnection_SubscribeSync(addr replica, nc.conn, replicaSubject.cstring) == NATS_OK
  defer:
    natsSubscription_Destroy(accepted)
    natsSubscription_Destroy(rejected)
    natsSubscription_Destroy(replica)
  discard natsConnection_Flush(nc.conn)

  proc register(pid: int, service: string, extra = false, name = "routing"): bool =
    var tools = %*[{"name": "routing_ping", "schema": {"type": "object"}}]
    if extra: tools.add(%*{"name": "routing_extra", "schema": {"type": "object"}})
    let data = $(%*{"name": name, "pid": pid, "service": service, "tools": tools})
    var msg: ptr natsMsg
    doAssert natsConnection_Request(addr msg, nc.conn, "reg.publish",
      data.cstring, data.len.cint, 3_000) == NATS_OK
    defer: natsMsg_Destroy(msg)
    parseJson($natsMsg_GetData(msg)){"accepted"}.getBool(false)

  check("first instance admitted", register(1001, acceptedSubject))
  check("incompatible instance rejected", not register(1002, rejectedSubject, true))
  # It deliberately remains subscribed after rejection. Public calls must
  # never reach it, including calls to the tool it shares with the live group.
  let call = callEnvelope("routing_ping", %*{}).encode()
  for i in 0 ..< 20:
    discard natsConnection_PublishRequest(nc.conn, "svc.routing.call", "_INBOX.routing",
      call.cstring, call.len.cint)
    var msg: ptr natsMsg
    doAssert natsSubscription_NextMsg(addr msg, accepted, 3_000) == NATS_OK
    check("forward preserves request and reply inbox", $natsMsg_GetData(msg) == call and
      $natsMsg_GetReply(msg) == "_INBOX.routing")
    natsMsg_Destroy(msg)
    doAssert natsSubscription_NextMsg(addr msg, rejected, 1) == NATS_TIMEOUT
  check("rejected live subscriber receives zero calls", true)
  check("compatible replica admitted", register(1003, replicaSubject))
  for i in 0 ..< 10:
    for j in 0 ..< 2:
      discard natsConnection_PublishRequest(nc.conn, "svc.routing.call", "_INBOX.routing",
        call.cstring, call.len.cint)
    var msg: ptr natsMsg
    doAssert natsSubscription_NextMsg(addr msg, accepted, 3_000) == NATS_OK
    natsMsg_Destroy(msg)
    doAssert natsSubscription_NextMsg(addr msg, replica, 3_000) == NATS_OK
    natsMsg_Destroy(msg)
    doAssert natsSubscription_NextMsg(addr msg, rejected, 1) == NATS_TIMEOUT
  check("calls distributed only among accepted replicas", true)
  check("service registration without an instance address rejected", not register(1004, ""))
  # Invalid routing addresses cannot redirect core to another public service.
  check("public service injection rejected", not register(1004, "svc.core.call"))
  check("wildcard service injection rejected", not register(1004, "svc.routing.instance.*.call"))
  check("wildcard component injection rejected",
        not register(1004, "svc.*.instance.any.call", name = "*"))
  check("empty instance token rejected", not register(1004, "svc.routing.instance.call"))
  let mirror = newCatalog(nc)
  mirror.applyReg(%*{"name": "routing", "pid": 1001, "pids": [1001, 1003],
    "tools": [{"name": "routing_ping", "schema": {"type": "object"}}]})
  discard natsConnection_Flush(nc.conn)
  nc.publish("reg.depart", $(%*{"name": "routing", "pid": 1001, "service": acceptedSubject}))
  discard natsConnection_Flush(nc.conn)
  # Request/reply orders this check after the authority has seen departure.
  doAssert not register(1002, rejectedSubject, true)
  mirror.pump()
  check("snapshot-seeded mirror honors instance departure",
        mirror.components["routing"].pids == @[1003])
  natsSubscription_Destroy(mirror.sub)
  report("SERVICE ROUTING TEST")

main()
