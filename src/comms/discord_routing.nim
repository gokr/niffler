## Discord Routing Module
##
## Routes Discord tool calls from agents through the Master Niffler process.
## This ensures centralized rate limiting, access control, and token security.
##
## Agent sends NATS request to: niffler.discord.execute
## Master handles Discord API calls and returns results

import std/[json, strformat, options, asyncdispatch, strutils]
import ../core/database
import ../core/db_config
import ../comms/discord
import ../types/nats_messages

const DiscordExecuteSubject = "niffler.discord.execute"
const DiscordResponseSubject = "niffler.discord.response"

type
  DiscordExecuteRequest* = object
    requestId*: string
    agentName*: string
    operation*: string
    channelId*: string
    content*: string
    limit*: int
    beforeMessageId*: string

  DiscordExecuteResponse* = object
    requestId*: string
    success*: bool
    error*: string
    data*: JsonNode

proc parseDiscordExecuteRequest*(data: JsonNode): Option[DiscordExecuteRequest] =
  ## Parse Discord execute request from JSON
  try:
    if not data.hasKey("operation") or not data.hasKey("channel_id"):
      return none(DiscordExecuteRequest)
    
    result = some(DiscordExecuteRequest(
      requestId: if data.hasKey("request_id"): data["request_id"].getStr() else: "",
      agentName: if data.hasKey("agent_name"): data["agent_name"].getStr() else: "unknown",
      operation: data["operation"].getStr(),
      channelId: data["channel_id"].getStr(),
      content: if data.hasKey("content"): data["content"].getStr() else: "",
      limit: if data.hasKey("limit"): data["limit"].getInt() else: 20,
      beforeMessageId: if data.hasKey("before_message_id"): data["before_message_id"].getStr() else: ""
    ))
  except Exception as e:
    debug(fmt"Failed to parse Discord execute request: {e.msg}")
    return none(DiscordExecuteRequest)

proc executeDiscordViaMaster*(request: DiscordExecuteRequest): DiscordExecuteResponse =
  ## Execute Discord operation via Master's connection
  ## This runs in the Master process
  
  result = DiscordExecuteResponse(
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
    of "recent_messages":
      var limit = request.limit
      if limit < 1: limit = 1
      if limit > 100: limit = 100
      
      let messages = asyncdispatch.waitFor client.api.getChannelMessages(
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
        "operation": request.operation,
        "channel_id": request.channelId,
        "count": messages.len,
        "messages": formattedMessages
      }
    
    of "send_message":
      if request.content.len == 0:
        result.error = "content cannot be empty"
        return
      
      let sentMessage = asyncdispatch.waitFor client.api.sendMessage(
        request.channelId, 
        formatResponse(request.content)
      )
      
      result.success = true
      result.data = %*{
        "operation": request.operation,
        "channel_id": request.channelId,
        "message_id": sentMessage.id
      }
    
    else:
      result.error = fmt("Unknown discord operation '{request.operation}'")
  
  except Exception as e:
    result.error = fmt("Discord API error: {e.msg}")
    debug(fmt"Discord execute error: {e.msg}")

proc formatDiscordExecuteResponse*(response: DiscordExecuteResponse): string =
  ## Format response as JSON for NATS
  result = $ %*{
    "request_id": response.requestId,
    "success": response.success,
    "error": response.error,
    "data": response.data
  }

proc formatDiscordExecuteError*(requestId, errorMsg: string): string =
  ## Format error response
  result = $ %*{
    "request_id": requestId,
    "success": false,
    "error": errorMsg,
    "data": newJNull()
  }
