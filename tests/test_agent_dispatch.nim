import std/[unittest, options, times, strformat, os, strutils]
import ../src/core/[agent_dispatch, nats_client]
import ../src/types/nats_messages

const TestNatsUrl = "nats://localhost:4222"

type DispatchResponderArgs = object
  requestId: string
  agentName: string

proc isNatsAvailable(): bool =
  try:
    var client = initNatsClient(TestNatsUrl, "", 0)
    client.close()
    true
  except:
    false

proc publishResponse(args: DispatchResponderArgs) {.thread.} =
  sleep(150)
  var client = initNatsClient(TestNatsUrl, "", 0)
  defer: client.close()

  let status = createStatusUpdate(args.requestId, args.agentName, "running")
  let response = createResponse(args.requestId, args.agentName, "delegated result", done = true)
  client.publish("niffler.master.status", $status)
  client.publish("niffler.master.response", $response)

suite "Agent dispatch integration":
  var natsAvailable: bool

  setup:
    natsAvailable = isNatsAvailable()
    if not natsAvailable:
      echo "NATS not available - skipping agent dispatch integration tests"

  test "prepare and publish agent request":
    if not natsAvailable:
      skip()

    var sender = initNatsClient(TestNatsUrl, "", 0)
    var receiver = initNatsClient(TestNatsUrl, "", 0)
    defer:
      sender.close()
      receiver.close()

    let subject = fmt("niffler.agent.dispatch-test-{getTime().toUnix()}.request")
    var sub = receiver.subscribe(subject)
    defer: sub.unsubscribe()

    let prepared = prepareAgentRequest(sender, "dispatch-test-" & $getTime().toUnix(), "/task hello")
    check prepared.success

    let requestSubject = prepared.request.subject
    var request = prepared.request
    request.subject = subject
    publishAgentRequest(sender, request)

    let msg = sub.nextMsg(2000)
    check msg.isSome()
    if msg.isSome():
      let received = fromJson(NatsRequest, msg.get().data)
      check received.requestId == prepared.request.requestId
      check received.input == "/task hello"
      check requestSubject.contains("niffler.agent.")

  test "collect agent result receives final response":
    if not natsAvailable:
      skip()

    var client = initNatsClient(TestNatsUrl, "", 0)
    defer: client.close()

    let requestId = "dispatch-result-" & $getTime().toUnix()
    var responder: Thread[DispatchResponderArgs]
    createThread(responder, publishResponse, DispatchResponderArgs(requestId: requestId, agentName: "dispatch-test"))

    let collected = collectAgentResult(client, requestId, timeoutSec = 5)
    joinThread(responder)

    check collected.success
    check collected.message == "delegated result"
    check collected.status == "running"
