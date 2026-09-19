## Core must answer invalid request envelopes in both idle and busy pumps.

import std/[json, os, strutils]
import natsnim
import envelope
import ../core/[catalog, conversation, dispatch]
import helpers

proc main() =
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let cat = newCatalog(nc)
  var sub, replies: ptr natsSubscription
  doAssert natsConnection_SubscribeSync(addr sub, nc.conn, "svc.core.call") == NATS_OK
  doAssert natsConnection_SubscribeSync(addr replies, nc.conn, "test.replies") == NATS_OK
  defer: natsSubscription_Destroy(sub)
  defer: natsSubscription_Destroy(replies)
  let ct = CoreTools(nc: nc, cat: cat, coreSub: sub,
    pending: PendingCalls())
  for busy in [false, true]:
    for data in ["not json", "null", "[]",
                 """{"id":"keep-id","kind":"event","payload":{}}"""]:
      doAssert natsConnection_PublishRequest(nc.conn, "svc.core.call",
        "test.replies", data.cstring, data.len.cint) == NATS_OK
      doAssert natsConnection_FlushTimeout(nc.conn, 1000) == NATS_OK
      sleep(20)
      if busy: ct.pumpCoreWhileBusy()
      else: ct.pumpCoreCalls(sub)
      var msg: ptr natsMsg
      let st = natsSubscription_NextMsg(addr msg, replies, 500)
      check("invalid request answered (busy=" & $busy & "): " & data,
        st == NATS_OK)
      if st == NATS_OK:
        let response = decode($natsMsg_GetData(msg))
        natsMsg_Destroy(msg)
        check("bad-envelope reply", response.kind == ekError and
          response.error{"code"}.getStr("") == "bad-envelope")
        if data.contains("keep-id"):
          check("decodable id preserved", response.id == "keep-id")
  report("CORE REQUESTS")

main()
