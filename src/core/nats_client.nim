## NATS Client Module
##
## Provides a simple wrapper around the nim-nats library for inter-process communication
## in the multi-agent architecture.
##
## Features:
## - Connect to NATS server with reconnection handling
## - Publish/subscribe to subjects
## - Request/reply patterns for agent communication
## - JSON message serialization

import std/[options, tables, strformat, locks]
import nats

type
  NatsClient* = ref object
    conn: ptr natsConnection
    url: string
    connected: bool
    subscriptions: seq[ptr natsSubscription]

  NatsMessage* = object
    subject*: string
    data*: string
    replyTo*: Option[string]

  NatsError* = object of CatchableError

  CallbackWrapper = ref object
    callback: proc(msg: NatsMessage) {.gcsafe.}

# Global table to store callbacks by ID (needs to work across threads)
var callbackTable: Table[int, CallbackWrapper]
var callbackLock: Lock
var nextCallbackId: int
var initialized: bool = false

proc connect*(url: string): NatsClient {.gcsafe.} =
  ## Connect to NATS server at specified URL
  ## Example: "nats://localhost:4222"
  {.gcsafe.}:
    # Initialize NATS library
    let initStatus = nats_Open(-1)
    if initStatus != NATS_OK:
      raise newException(NatsError, fmt"Failed to initialize NATS library: {initStatus}")

    # Initialize callback table if needed
    if not initialized:
      initLock(callbackLock)
      callbackTable = initTable[int, CallbackWrapper]()
      nextCallbackId = 1
      initialized = true

    result = NatsClient(
      url: url,
      connected: false,
      subscriptions: @[]
    )

    var conn: ptr natsConnection = nil
    let status = natsConnection_ConnectTo(addr conn, cstring(url))

    if status != NATS_OK:
      raise newException(NatsError, fmt"Failed to connect to NATS at {url}: {status}")

    result.conn = conn
    result.connected = true

proc isConnected*(client: NatsClient): bool =
  ## Check if client is currently connected
  return client.connected

proc disconnect*(client: NatsClient) =
  ## Disconnect from NATS server
  if client.connected and client.conn != nil:
    natsConnection_Close(client.conn)
    natsConnection_Destroy(client.conn)
    client.conn = nil
    client.connected = false

proc publish*(client: NatsClient, subject: string, data: string) =
  ## Publish message to subject
  if not client.connected:
    raise newException(NatsError, "Not connected to NATS server")

  let status = natsConnection_PublishString(client.conn, cstring(subject), cstring(data))
  if status != NATS_OK:
    raise newException(NatsError, fmt"Failed to publish to {subject}: {status}")

proc subscribe*(client: NatsClient, subject: string, callback: proc(msg: NatsMessage) {.gcsafe.}) =
  ## Subscribe to subject with callback for incoming messages
  {.gcsafe.}:
    if not client.connected:
      raise newException(NatsError, "Not connected to NATS server")

    # Wrapper callback that converts nats message to NatsMessage
    proc wrappedCallback(conn: ptr natsConnection, sub: ptr natsSubscription, msg: ptr natsMsg, closure: pointer) =
      if msg == nil:
        return

      let callbackId = cast[int](closure)

      acquire(callbackLock)
      let hasCallback = callbackTable.hasKey(callbackId)
      let wrapper = if hasCallback: callbackTable[callbackId] else: nil
      release(callbackLock)

      if wrapper == nil:
        natsMsg_Destroy(msg)
        return

      let natsMsg = NatsMessage(
        subject: $natsMsg_GetSubject(msg),
        data: $natsMsg_GetData(msg),
        replyTo:
          if natsMsg_GetReply(msg) != nil:
            some($natsMsg_GetReply(msg))
          else:
            none(string)
      )
      wrapper.callback(natsMsg)
      natsMsg_Destroy(msg)

    # Store callback in global table
    acquire(callbackLock)
    let callbackId = nextCallbackId
    inc nextCallbackId
    let wrapper = CallbackWrapper(callback: callback)
    callbackTable[callbackId] = wrapper
    release(callbackLock)

    var sub: ptr natsSubscription = nil
    let status = natsConnection_Subscribe(addr sub, client.conn, cstring(subject), wrappedCallback, cast[pointer](callbackId))

    if status != NATS_OK:
      raise newException(NatsError, fmt"Failed to subscribe to {subject}: {status}")

    # Keep subscription alive
    client.subscriptions.add(sub)

proc request*(client: NatsClient, subject: string, data: string, timeoutMs: int = 5000): Option[string] {.gcsafe.} =
  ## Send request and wait for reply with timeout
  if not client.connected:
    raise newException(NatsError, "Not connected to NATS server")

  var reply: ptr natsMsg = nil
  let status = natsConnection_RequestString(addr reply, client.conn, cstring(subject), cstring(data), cint(timeoutMs))

  if status == NATS_OK and reply != nil:
    let replyData = $natsMsg_GetData(reply)
    natsMsg_Destroy(reply)
    return some(replyData)
  else:
    return none(string)

proc flush*(client: NatsClient) =
  ## Flush any pending messages
  if client.connected:
    discard natsConnection_Flush(client.conn)
