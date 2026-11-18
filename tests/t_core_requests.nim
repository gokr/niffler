## Core must answer invalid request envelopes in both idle and busy pumps.

import std/[json, monotimes, os, strutils, times]
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
  # An expired forward with no reply is retired even without a process exit.
  var lostReply: ptr natsSubscription
  doAssert natsConnection_SubscribeSync(addr lostReply, nc.conn,
    "test.lost-reply") == NATS_OK
  let forward = callEnvelope("session", %*{"sessionId": "lost-reply"})
  ct.pending.forwards.add(SessionForward(env: forward, reply: "test.replies",
    sub: lostReply, runnerPid: getCurrentProcessId(),
    deadline: getMonoTime() - initDuration(milliseconds = 1)))
  ct.pumpSessionForwards()
  check("an expired forward releases its inbox", ct.pending.forwards.len == 0)
  var expired: ptr natsMsg
  let expiredStatus = natsSubscription_NextMsg(addr expired, replies, 500)
  check("an expired forward answers its caller", expiredStatus == NATS_OK)
  if expiredStatus == NATS_OK:
    let response = decode($natsMsg_GetData(expired))
    natsMsg_Destroy(expired)
    check("expiry reports an unknown outcome on the original request",
      response.id == forward.id and response.kind == ekError and
      response.error{"code"}.getStr("") == "session-forward-timeout")
  report("CORE REQUESTS")

main()
