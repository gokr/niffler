## NATS Client Module (Synchronous API)
##
## Simple wrapper around nim-nats using synchronous subscriptions.
## This approach is more reliable and simpler than async callbacks.
##
## Features:
## - Connect/disconnect
## - Publish messages
## - Synchronous message receiving (poll-based)
## - Request/reply patterns

import std/[options, strformat]
import nats

type
  NatsClient* = ref object
    conn: ptr natsConnection
    url: string
    connected: bool

  NatsSubscription* = ref object
    sub: ptr natsSubscription
    subject: string

  NatsMessage* = object
    subject*: string
    data*: string
    replyTo*: Option[string]

  NatsError* = object of CatchableError

# Global initialization flag
var natsInitialized = false

proc initNats*() =
  ## Initialize NATS library (call once at startup)
  if not natsInitialized:
    let status = nats_Open(-1)
    if status != NATS_OK:
      raise newException(NatsError, fmt"Failed to initialize NATS library: {status}")
    natsInitialized = true

proc connect*(url: string): NatsClient =
  ## Connect to NATS server
  initNats()

  var conn: ptr natsConnection = nil
  let status = natsConnection_ConnectTo(addr conn, cstring(url))

  if status != NATS_OK:
    raise newException(NatsError, fmt"Failed to connect to NATS at {url}: {status}")

  result = NatsClient(
    conn: conn,
    url: url,
    connected: true
  )

proc isConnected*(client: NatsClient): bool =
  ## Check if client is connected
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

proc flush*(client: NatsClient) =
  ## Flush pending messages to ensure delivery
  if client.connected:
    discard natsConnection_Flush(client.conn)

proc subscribe*(client: NatsClient, subject: string): NatsSubscription =
  ## Create a synchronous subscription to a subject
  if not client.connected:
    raise newException(NatsError, "Not connected to NATS server")

  var sub: ptr natsSubscription = nil
  let status = natsConnection_SubscribeSync(addr sub, client.conn, cstring(subject))

  if status != NATS_OK:
    raise newException(NatsError, fmt"Failed to subscribe to {subject}: {status}")

  result = NatsSubscription(
    sub: sub,
    subject: subject
  )

proc nextMessage*(subscription: NatsSubscription, timeoutMs: int = 1000): Option[NatsMessage] =
  ## Wait for next message on subscription (blocking with timeout)
  ## Returns None if timeout occurs
  var msg: ptr natsMsg = nil
  let status = natsSubscription_NextMsg(addr msg, subscription.sub, cint(timeoutMs))

  if status == NATS_OK and msg != nil:
    let natsMsg = NatsMessage(
      subject: $natsMsg_GetSubject(msg),
      data: $natsMsg_GetData(msg),
      replyTo:
        if natsMsg_GetReply(msg) != nil:
          some($natsMsg_GetReply(msg))
        else:
          none(string)
    )
    natsMsg_Destroy(msg)
    return some(natsMsg)
  elif status == NATS_TIMEOUT:
    return none(NatsMessage)
  else:
    raise newException(NatsError, fmt"Error receiving message: {status}")

proc unsubscribe*(subscription: NatsSubscription) =
  ## Unsubscribe and cleanup
  if subscription.sub != nil:
    discard natsSubscription_Unsubscribe(subscription.sub)
    natsSubscription_Destroy(subscription.sub)
    subscription.sub = nil

proc request*(client: NatsClient, subject: string, data: string, timeoutMs: int = 5000): Option[string] =
  ## Send request and wait for reply
  if not client.connected:
    raise newException(NatsError, "Not connected to NATS server")

  var reply: ptr natsMsg = nil
  let status = natsConnection_RequestString(addr reply, client.conn, cstring(subject), cstring(data), cint(timeoutMs))

  if status == NATS_OK and reply != nil:
    let replyData = $natsMsg_GetData(reply)
    natsMsg_Destroy(reply)
    return some(replyData)
  elif status == NATS_TIMEOUT:
    return none(string)
  else:
    raise newException(NatsError, fmt"Request failed: {status}")
