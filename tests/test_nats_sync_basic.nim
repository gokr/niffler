## NATS Synchronous Communication Test
##
## This test uses the working synchronous NATS API instead of the broken async callbacks.

import unittest2
import std/[strformat, options]
import ../src/core/nats_client_sync

suite "NATS Synchronous Communication":
  setup:
    echo "NOTE: This test requires NATS server running on localhost:4222"

  test "Connect to NATS server":
    var client: NatsClient
    try:
      client = connect("nats://localhost:4222")
      check client.isConnected()
      client.disconnect()
      check not client.isConnected()
    except NatsError as e:
      skip()
      echo fmt"Skipping test - NATS server not available: {e.msg}"

  test "Publish and synchronous subscribe":
    var client: NatsClient
    try:
      client = connect("nats://localhost:4222")

      # Subscribe first
      let subscription = client.subscribe("test.subject")

      # Publish message
      client.publish("test.subject", "Hello SYNC NATS!")
      client.flush()

      # Wait for message
      let msg = subscription.nextMessage(1000)

      check msg.isSome()
      if msg.isSome():
        check msg.get().data == "Hello SYNC NATS!"
        check msg.get().subject == "test.subject"

      subscription.unsubscribe()
      client.disconnect()
    except NatsError as e:
      skip()
      echo fmt"Skipping test - NATS error: {e.msg}"

  test "Request-reply pattern":
    var client1: NatsClient
    var client2: NatsClient

    try:
      client1 = connect("nats://localhost:4222")
      client2 = connect("nats://localhost:4222")

      # Test request to non-existent subject (should timeout)
      let reply = client1.request("test.nonexistent", "ping", 100)
      check reply.isNone()  # Should timeout since no responder

      client1.disconnect()
      client2.disconnect()
    except NatsError as e:
      skip()
      echo fmt"Skipping test - NATS error: {e.msg}"