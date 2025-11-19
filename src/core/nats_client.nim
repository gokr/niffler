## NATS Client Wrapper
##
## Wraps natswrapper for Niffler's multi-agent communication
##
## Features:
## - Basic pub/sub messaging
## - Request/reply pattern  
## - Presence tracking via JetStream KV store
## - Auto-reconnect support
## - Subject-based routing: niffler.agent.<name>.*

import std/[strformat, logging, times, strutils, options]

# Import natswrapper - path configured in config.nims
import natswrapper

export NatsConnection, checkStatus, getErrorString, natsStatus

type
  NifflerNatsClient* = object
    ## Main NATS client for Niffler
    nc*: NatsConnection
    js*: ptr jsCtx
    kv*: ptr kvStore
    clientId*: string
    presenceTTL*: int64  # TTL in nanoseconds

  NatsMessage* = object
    ## Simple message wrapper
    subject*: string
    data*: string

  NatsSubscription* = object
    ## Subscription handle
    sub*: ptr natsSubscription

proc initNatsClient*(url: string = "nats://localhost:4222",
                     clientId: string = "",
                     presenceTTL: int = 15): NifflerNatsClient =
  ## Initialize NATS client with optional presence tracking
  result.clientId = clientId
  result.presenceTTL = presenceTTL.int64 * 1_000_000_000  # Convert to nanoseconds

  # Initialize NATS library
  var status = nats_Open(-1)
  if not checkStatus(status):
    raise newException(IOError, "Failed to initialize NATS: " & getErrorString(status))

  # Connect to NATS server
  result.nc = connect(url)
  debug(fmt"Connected to NATS at {url}")

  # Initialize JetStream if presence tracking is needed
  if clientId.len > 0:
    var js: ptr jsCtx
    status = natsConnection_JetStream(addr js, result.nc.conn, nil)
    if not checkStatus(status):
      warn(fmt"Failed to get JetStream context: {getErrorString(status)}")
      warn("Presence tracking will not be available")
    else:
      result.js = js
      debug("JetStream context initialized")

      # Create or get presence KV bucket
      var kvCfg: kvConfig
      status = kvConfig_Init(addr kvCfg)
      if checkStatus(status):
        kvCfg.Bucket = "niffler_presence".cstring
        kvCfg.TTL = result.presenceTTL
        kvCfg.MaxValueSize = 256

        var kv: ptr kvStore
        status = js_CreateKeyValue(addr kv, js, addr kvCfg)
        if not checkStatus(status):
          # Try to get existing bucket
          status = js_KeyValue(addr kv, js, "niffler_presence".cstring)

        if checkStatus(status):
          result.kv = kv
          debug("Presence KV store initialized")
        else:
          warn(fmt"Failed to create/get KV bucket: {getErrorString(status)}")

proc close*(client: var NifflerNatsClient) =
  ## Close NATS connection and cleanup
  if client.kv != nil:
    kvStore_Destroy(client.kv)
    client.kv = nil
  if client.js != nil:
    jsCtx_Destroy(client.js)
    client.js = nil
  client.nc.close()
  nats_Close()
  debug("NATS client closed")

proc publish*(client: NifflerNatsClient, subject: string, data: string) =
  ## Publish a message to a subject
  client.nc.publish(subject, data)
  debug(fmt"Published to {subject}: {data.len} bytes")

proc subscribe*(client: NifflerNatsClient, subject: string): NatsSubscription =
  ## Subscribe to a subject (synchronous subscription)
  var sub: ptr natsSubscription
  let status = natsConnection_SubscribeSync(addr sub, client.nc.conn, subject.cstring)
  if not checkStatus(status):
    raise newException(IOError, fmt"Failed to subscribe to {subject}: {getErrorString(status)}")

  result.sub = sub
  debug(fmt"Subscribed to {subject}")

proc nextMsg*(subscription: NatsSubscription, timeoutMs: int = 1000): Option[NatsMessage] =
  ## Get next message from subscription (blocks up to timeout)
  var msg: ptr natsMsg
  let status = natsSubscription_NextMsg(addr msg, subscription.sub, timeoutMs.int64)

  if status == NATS_TIMEOUT:
    return none(NatsMessage)

  if not checkStatus(status):
    warn(fmt"Failed to get next message: {getErrorString(status)}")
    return none(NatsMessage)

  let subject = $natsMsg_GetSubject(msg)
  let data = $natsMsg_GetData(msg)
  natsMsg_Destroy(msg)

  return some(NatsMessage(subject: subject, data: data))

proc unsubscribe*(subscription: var NatsSubscription) =
  ## Unsubscribe and cleanup
  if subscription.sub != nil:
    natsSubscription_Destroy(subscription.sub)
    subscription.sub = nil

proc request*(client: NifflerNatsClient, subject: string, data: string,
              timeoutMs: int = 5000): Option[string] =
  ## Send a request and wait for reply
  var msg: ptr natsMsg
  let status = natsConnection_Request(addr msg, client.nc.conn,
                                      subject.cstring, data.cstring,
                                      data.len.cint, timeoutMs.int64)

  if status == NATS_TIMEOUT:
    debug(fmt"Request to {subject} timed out")
    return none(string)

  if not checkStatus(status):
    warn(fmt"Request failed: {getErrorString(status)}")
    return none(string)

  let reply = $natsMsg_GetData(msg)
  natsMsg_Destroy(msg)
  return some(reply)

# Presence tracking functions

proc sendHeartbeat*(client: NifflerNatsClient) =
  ## Send a heartbeat (update presence key with current timestamp)
  if client.kv == nil:
    return

  let key = "presence." & client.clientId
  let timestamp = $getTime().toUnix()

  var rev: uint64
  let status = kvStore_PutString(addr rev, client.kv, key.cstring, timestamp.cstring)
  if not checkStatus(status):
    warn(fmt"Failed to send heartbeat: {getErrorString(status)}")

proc isPresent*(client: NifflerNatsClient, agentId: string): bool =
  ## Check if an agent is present (key exists in KV)
  if client.kv == nil:
    return false

  let key = "presence." & agentId
  var entry: ptr kvEntry

  let status = kvStore_Get(addr entry, client.kv, key.cstring)
  if status == NATS_OK:
    kvEntry_Destroy(entry)
    return true
  elif status == NATS_NOT_FOUND:
    return false
  else:
    warn(fmt"Failed to check presence for {agentId}: {getErrorString(status)}")
    return false

proc listPresent*(client: NifflerNatsClient): seq[string] =
  ## List all currently present agents
  result = @[]

  if client.kv == nil:
    return

  var watcher: ptr kvWatcher
  var status = kvStore_WatchAll(addr watcher, client.kv, nil)
  if not checkStatus(status):
    warn(fmt"Failed to create watcher: {getErrorString(status)}")
    return

  # Get initial state (synchronous read)
  var entry: ptr kvEntry
  while true:
    status = kvWatcher_Next(addr entry, watcher, 100)  # 100ms timeout
    if status == NATS_TIMEOUT:
      break
    if not checkStatus(status):
      continue

    let key = $kvEntry_Key(entry)
    if key.startsWith("presence."):
      result.add(key[9..^1])  # Strip "presence." prefix

    kvEntry_Destroy(entry)

  kvWatcher_Destroy(watcher)
  debug(fmt"Found {result.len} present agents")

proc removePresence*(client: NifflerNatsClient) =
  ## Remove this client's presence (for graceful shutdown)
  if client.kv == nil or client.clientId.len == 0:
    return

  let key = "presence." & client.clientId
  let status = kvStore_Delete(client.kv, key.cstring)
  if checkStatus(status):
    debug(fmt"Removed presence for {client.clientId}")
  else:
    warn(fmt"Failed to remove presence: {getErrorString(status)}")
