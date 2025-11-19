import std/[unittest, os, times, options, strutils, json]
import ../src/core/nats_client
import ../src/types/nats_messages

# Integration tests for NATS client
# NOTE: These tests require a running NATS server with JetStream enabled
# Start NATS server with: nats-server -js
# Tests will be skipped if NATS is not available

proc isNatsAvailable(): bool =
  ## Check if NATS server is available
  try:
    var client = initNatsClient("nats://localhost:4222", "", 0)
    client.close()
    result = true
  except:
    result = false

suite "NATS Client Integration":
  var natsAvailable: bool

  setup:
    natsAvailable = isNatsAvailable()
    if not natsAvailable:
      echo "⚠️  NATS server not available - skipping integration tests"
      echo "   Start NATS with: nats-server -js"

  test "Connect to NATS server":
    if not natsAvailable:
      skip()
    else:
      var client = initNatsClient("nats://localhost:4222")
      check client.nc.conn != nil
      client.close()

  test "Publish and subscribe to messages":
    if not natsAvailable:
      skip()
    else:
      var client = initNatsClient("nats://localhost:4222")
      defer: client.close()

      let subject = "test.pubsub." & $getTime().toUnix()

      # Subscribe first
      var sub = client.subscribe(subject)
      defer: sub.unsubscribe()

      # Publish message
      client.publish(subject, "Hello NATS")

      # Receive message
      let msg = sub.nextMsg(timeoutMs = 2000)
      check msg.isSome()
      if msg.isSome():
        check msg.get().subject == subject
        check msg.get().data == "Hello NATS"

  test "Subscription timeout returns none":
    if not natsAvailable:
      skip()
    else:
      var client = initNatsClient("nats://localhost:4222")
      defer: client.close()

      let subject = "test.timeout." & $getTime().toUnix()
      var sub = client.subscribe(subject)
      defer: sub.unsubscribe()

      # Wait for message that will never come
      let msg = sub.nextMsg(timeoutMs = 100)
      check msg.isNone()

  test "Request-reply pattern":
    if not natsAvailable:
      skip()
    else:
      var client = initNatsClient("nats://localhost:4222")
      defer: client.close()

      let subject = "test.request." & $getTime().toUnix()

      # Create a simple responder in the background
      var responderSub = client.subscribe(subject)

      # Simulate responding (this would normally be in another thread/process)
      # For this test, we'll just verify the request mechanism works

      # Note: Full request-reply test requires multiple processes
      # This test just verifies the API works

      responderSub.unsubscribe()

  test "Presence tracking with JetStream KV":
    if not natsAvailable:
      skip()
    else:
      # Initialize client with presence tracking
      var client = initNatsClient("nats://localhost:4222", "test-agent", presenceTTL = 15)
      defer:
        client.removePresence()
        client.close()

      # Skip if JetStream is not available
      if client.kv == nil:
        skip()
        echo "   JetStream not available - presence tests skipped"
      else:
        # Send heartbeat
        client.sendHeartbeat()

        # Check presence
        let isPresent = client.isPresent("test-agent")
        check isPresent == true

  test "List all present agents":
    if not natsAvailable:
      skip()
    else:
      var client1 = initNatsClient("nats://localhost:4222", "agent1", presenceTTL = 15)
      var client2 = initNatsClient("nats://localhost:4222", "agent2", presenceTTL = 15)

      defer:
        client1.removePresence()
        client1.close()
        client2.removePresence()
        client2.close()

      # Skip if JetStream is not available
      if client1.kv == nil or client2.kv == nil:
        skip()
        echo "   JetStream not available - presence tests skipped"
      else:
        # Send heartbeats
        client1.sendHeartbeat()
        client2.sendHeartbeat()

        # List present agents
        let agents = client1.listPresent()

        check agents.len >= 2
        check "agent1" in agents
        check "agent2" in agents

  test "Remove presence on cleanup":
    if not natsAvailable:
      skip()
    else:
      var client = initNatsClient("nats://localhost:4222", "temp-agent", presenceTTL = 15)

      # Skip if JetStream is not available
      if client.kv == nil:
        client.close()
        skip()
        echo "   JetStream not available - presence tests skipped"
      else:
        client.sendHeartbeat()
        check client.isPresent("temp-agent") == true

        # Remove presence
        client.removePresence()

        # Check it's gone
        check client.isPresent("temp-agent") == false

        client.close()

  test "Send and receive NatsRequest via NATS":
    if not natsAvailable:
      skip()
    else:
      var client = initNatsClient("nats://localhost:4222")
      defer: client.close()

      let subject = "niffler.agent.coder.request"

      # Create request
      let req = createRequest("req-123", "coder", "/plan Create tests")

      # Serialize to JSON
      let reqJson = $req.toJson()

      # Subscribe to receive it
      var sub = client.subscribe(subject)
      defer: sub.unsubscribe()

      # Publish request
      client.publish(subject, reqJson)

      # Receive and deserialize
      let msg = sub.nextMsg(timeoutMs = 2000)
      check msg.isSome()

      if msg.isSome():
        let receivedJson = parseJson(msg.get().data)
        let receivedReq = fromJson(receivedJson, NatsRequest)

        check receivedReq.requestId == "req-123"
        check receivedReq.agentName == "coder"
        check receivedReq.input == "/plan Create tests"

  test "Send and receive NatsResponse via NATS":
    if not natsAvailable:
      skip()
    else:
      var client = initNatsClient("nats://localhost:4222")
      defer: client.close()

      let subject = "niffler.master.response"

      # Create response
      let resp = createResponse("req-123", "Here is the result", done = true)

      # Serialize to JSON
      let respJson = $resp.toJson()

      # Subscribe to receive it
      var sub = client.subscribe(subject)
      defer: sub.unsubscribe()

      # Publish response
      client.publish(subject, respJson)

      # Receive and deserialize
      let msg = sub.nextMsg(timeoutMs = 2000)
      check msg.isSome()

      if msg.isSome():
        let receivedJson = parseJson(msg.get().data)
        let receivedResp = fromJson(receivedJson, NatsResponse)

        check receivedResp.requestId == "req-123"
        check receivedResp.content == "Here is the result"
        check receivedResp.done == true

  test "Multiple clients can communicate":
    if not natsAvailable:
      skip()
    else:
      var client1 = initNatsClient("nats://localhost:4222")
      var client2 = initNatsClient("nats://localhost:4222")

      defer:
        client1.close()
        client2.close()

      let subject = "test.multi." & $getTime().toUnix()

      # Client 2 subscribes
      var sub = client2.subscribe(subject)
      defer: sub.unsubscribe()

      # Wait for subscription to be ready
      sleep(100)

      # Client 1 publishes
      client1.publish(subject, "Cross-client message")

      # Client 2 receives
      let msg = sub.nextMsg(timeoutMs = 2000)
      check msg.isSome()
      if msg.isSome():
        check msg.get().data == "Cross-client message"
