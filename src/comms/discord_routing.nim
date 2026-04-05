## Discord Routing via NATS
##
## Routes Discord tool calls from agents through Master via NATS.
## This ensures centralized rate limiting, access control, and token security.
##
## Subject: niffler.discord.execute (request)
##          niffler.discord.response.{requestId} (reply)

import std/[json, strformat, options, times, random, asyncdispatch, logging]
import dimscord
import ../core/nats_client
import ../core/database
import ../core/db_config
import ../comms/discord

const DiscordExecuteSubject = "niffler.discord.execute"

## Types for Discord requests/responses
type
  DiscordOperation* = enum
    doRecentMessages
    doSendMessage

  DiscordRequest* = object
    requestId*: string
    agentName*: string
    operation*: DiscordOperation
    channelId*: string
    content*: string
    limit*: int
    beforeMessageId*: string

  DiscordResponse* = object
    requestId*: string
    success*: bool
    error*: string
    data*: JsonNode

proc newDiscordRequest*(
  agentName: string,
  operation: string,
  channelId: string,
  content: string = "",
  limit: int = 20,
  beforeMessageId: string = ""
): DiscordRequest =
  ## Create a new Discord request from tool arguments
  result.requestId = fmt"discord_{getTime().toUnix()}_{rand(100000)}"
  result.agentName = agentName
  result.channelId = channelId
  result.content = content
  result.limit = limit
  result.beforeMessageId = beforeMessageId

  case operation
  of "recent_messages": result.operation = doRecentMessages
  of "send_message": result.operation = doSendMessage
  else: raise newException(ValueError, "Unknown operation: " & operation)

proc toJson*(req: DiscordRequest): string =
  ## Serialize request to JSON
  result = $ %*{
    "request_id": req.requestId,
    "agent_name": req.agentName,
    "operation": $req.operation,
    "channel_id": req.channelId,
    "content": req.content,
    "limit": req.limit,
    "before_message_id": req.beforeMessageId
  }

proc fromJsonDiscordRequest*(jsonStr: string): DiscordRequest =
  ## Deserialize request from JSON
  let data = parseJson(jsonStr)
  result.requestId = data["request_id"].getStr()
  result.agentName = data["agent_name"].getStr()
  result.channelId = data["channel_id"].getStr()
  result.content = data["content"].getStr()
  result.limit = data["limit"].getInt()
  result.beforeMessageId = data["before_message_id"].getStr()

  let opStr = data["operation"].getStr()
  case opStr
  of "doRecentMessages": result.operation = doRecentMessages
  of "doSendMessage": result.operation = doSendMessage
  else: raise newException(ValueError, "Unknown operation: " & opStr)

proc toJson*(resp: DiscordResponse): string =
  ## Serialize response to JSON
  result = $ %*{
    "request_id": resp.requestId,
    "success": resp.success,
    "error": resp.error,
    "data": resp.data
  }

proc fromJsonDiscordResponse*(jsonStr: string): DiscordResponse =
  ## Deserialize response from JSON
  let data = parseJson(jsonStr)
  result.requestId = data["request_id"].getStr()
  result.success = data["success"].getBool()
  result.error = data["error"].getStr()
  result.data = data["data"]

## Agent-side: Send Discord request via NATS
proc sendDiscordRequestViaNats*(
  natsClient: NifflerNatsClient,
  request: DiscordRequest,
  timeoutMs: int = 30000
): DiscordResponse =
  ## Send Discord request to Master via NATS and wait for response
  ## This runs in the Agent process (tool worker thread)

  let jsonRequest = request.toJson()
  let responseOpt = natsClient.request(DiscordExecuteSubject, jsonRequest, timeoutMs)

  if responseOpt.isNone:
    return DiscordResponse(
      requestId: request.requestId,
      success: false,
      error: "No response from Master (timeout or Master not running)",
      data: newJNull()
    )

  try:
    return fromJsonDiscordResponse(responseOpt.get())
  except Exception as e:
    return DiscordResponse(
      requestId: request.requestId,
      success: false,
      error: "Failed to parse response: " & e.msg,
      data: newJNull()
    )

## Master-side: Execute Discord request
proc executeDiscordRequestInMaster*(request: DiscordRequest): DiscordResponse =
  ## Execute Discord operation via Master's connection
  ## This runs in the Master process

  result = DiscordResponse(
    requestId: request.requestId,
    success: false,
    error: "",
    data: newJNull()
  )

  # Check if Discord is enabled
  let database = getGlobalDatabase()
  if database == nil:
    result.error = "Database not available"
    return

  let discordConfig = getDiscordConfig(database)
  if discordConfig.isNone():
    result.error = "Discord is not configured"
    return

  let (token, _, _, _, _) = discordConfig.get()
  if token.len == 0:
    result.error = "Discord token is not configured"
    return

  # Execute the operation
  try:
    let client = newDiscordClient(token)

    case request.operation
    of doRecentMessages:
      var limit = request.limit
      if limit < 1: limit = 1
      if limit > 100: limit = 100

      let messages = waitFor client.api.getChannelMessages(
        request.channelId,
        before = request.beforeMessageId,
        limit = limit
      )

      var formattedMessages = newJArray()
      for message in messages:
        formattedMessages.add(%*{
          "id": message.id,
          "author_id": message.author.id,
          "author_name": message.author.username,
          "is_bot": message.author.bot,
          "timestamp": message.timestamp,
          "content": message.content
        })

      result.success = true
      result.data = %*{
        "operation": "recent_messages",
        "channel_id": request.channelId,
        "count": messages.len,
        "messages": formattedMessages
      }

    of doSendMessage:
      if request.content.len == 0:
        result.error = "content cannot be empty"
        return

      let sentMessage = waitFor client.api.sendMessage(
        request.channelId,
        formatResponse(request.content)
      )

      result.success = true
      result.data = %*{
        "operation": "send_message",
        "channel_id": request.channelId,
        "message_id": sentMessage.id
      }

  except Exception as e:
    result.error = fmt("Discord API error: {e.msg}")

## Master-side: Subscribe to Discord requests
proc startDiscordRoutingSubscriber*(natsClient: NifflerNatsClient): NatsSubscription =
  ## Start subscriber for Discord requests in Master
  ## Returns subscription for caller to poll
  
  result = natsClient.subscribe(DiscordExecuteSubject)
  info(fmt"Discord routing subscriber started on {DiscordExecuteSubject}")

proc handleDiscordRoutingMessage*(natsClient: NifflerNatsClient, msg: NatsMessage) =
  ## Handle a single Discord routing message
  ## Parse request, execute Discord API, send reply
  try:
    let request = fromJsonDiscordRequest(msg.data)
    info(fmt"Discord request from {request.agentName}: {request.operation}")

    let response = executeDiscordRequestInMaster(request)
    let jsonResponse = response.toJson()

    # Publish reply to response subject (based on request ID)
    let replySubject = fmt"niffler.discord.response.{request.requestId}"
    natsClient.publish(replySubject, jsonResponse)

  except Exception as e:
    error(fmt"Failed to handle Discord request: {e.msg}")
