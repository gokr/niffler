## Session runner — one conversation, one process.
##
## Spawned by the system harness (core/niffler.nim: ensureRunner) with the
## session id as argv. Serves svc.session.<sessionId>.call: runs turn per
## request via conversation.nim (resume from the store on first use),
## emitting ev.session.* events. Core tools (spawn/kill/remove/catalog) go
## back over the bus to svc.core.call — one implementation, in the system.
##
## The process is the unit of isolation: kill the runner, every other
## session keeps going. On SIGTERM/ev.sys.drain it departs and exits.
## Runners are ephemeral — history lives in the store; a fresh runner
## resumes the conversation on the next session call.

import std/[json, os, tables]
when defined(posix):
  import std/posix
import natswrapper
import ../sdk/dotenv
import ../sdk/envelope
import approval
import catalog
import conversation
import dispatch

var gStop = false

proc onSig(sig: cint) {.noconv.} =
  gStop = true

proc main() =
  if paramCount() < 1:
    stderr.writeLine("session: needs a session id as argument")
    quit(1)
  let sessionId = paramStr(1)
  let root = getEnv("NIF_ROOT", getAppDir().parentDir().parentDir())
  loadDotEnv(".env", root / ".env")

  if not checkStatus(nats_Open(-1)):
    quit(1)
  var nc = connect(getEnv("NIF_NATS_URL", "nats://127.0.0.1:4222"))

  var cat = newCatalog(nc)
  var approval = newApproval(nc, cat, tty = false)
  var ct = CoreTools(nc: nc, cat: cat, sup: nil, root: root,
                     approval: approval, coreSub: nil, runner: true,
                     pending: PendingCalls(items: @[]),
                     tokenStream: new(TokenStream))

  # Seed the catalog with everything registered before we connected
  # (reg.publish is fire-once; late joiners ask the system for a snapshot),
  # then follow reg.> live from there.
  try:
    let snap = dispatchToolCall(ct, "catalog", %*{"op": "snapshot"}, 15_000)
    for comp in snap{"components"}:
      cat.applyReg(comp)
  except CatchableError as e:
    echo "session: WARNING cannot seed catalog: " & e.msg

  let name = runnerName(sessionId)
  let subject = sessionSubject(sessionId)
  var sub: ptr natsSubscription
  let st = natsConnection_QueueSubscribeSync(addr sub, nc.conn, subject.cstring,
                                             "session".cstring)
  if not checkStatus(st):
    stderr.writeLine("session: subscribe " & subject & ": " & getErrorString(st))
    quit(1)

  # Readiness signal for the system's ensureRunner: presence in the catalog.
  let reg = %*{"name": name, "version": "0.1.0", "pid": getCurrentProcessId(),
               "tools": newJArray()}
  nc.publish("reg.publish", $reg)
  echo "session: serving " & subject & " (" & sessionId & ")"
  # Create the conversation header now so the session shows in the sidebar
  # the moment the runner is live, not only once the first message is sent.
  ensureConversationHeader(ct, sessionId)

  when defined(posix):
    discard signal(SIGTERM, onSig)
    discard signal(SIGINT, onSig)

  var sessions = initTable[string, Session]()
  while not gStop:
    var msg: ptr natsMsg
    let ms = natsSubscription_NextMsg(addr msg, sub, 200)
    if ms == NATS_TIMEOUT: continue
    if not checkStatus(ms): break
    let data = $natsMsg_GetData(msg)
    let reply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    let env = decode(data)
    if env.kind != ekCall or reply.len == 0: continue
    var resp: Envelope
    try:
      case env.tool
      of "session":
        if env.args{"sessionId"}.getStr("") != sessionId:
          raise newException(ValueError,
            "runner serves only session " & sessionId)
        let r = handleSessionCall(ct, env.args, sessions)
        if r{"error"} != nil:
          raise newException(ValueError, r{"error"}.getStr("session error"))
        resp = resultEnvelope(env.id, r)
      else:
        resp = errorEnvelope(env.id, "no-tool",
          "session runner has no tool '" & env.tool & "'")
    except CatchableError as e:
      resp = errorEnvelope(env.id, "boom", e.msg)
    nc.publish(reply, resp.encode())

  # Depart like any component: deregister, close.
  echo "session: shutting down (" & sessionId & ")"
  discard natsSubscription_Unsubscribe(sub)
  let dep = %*{"name": name, "pid": getCurrentProcessId()}
  nc.publish("reg.depart", $dep)
  sleep(100)
  nc.close()

when isMainModule:
  main()
