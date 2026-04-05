## Discord Tool (Agent-aware)
##
## Unified Discord tool that routes through Master when in agent context.
## - Master: Executes Discord API calls directly
## - Agent: Routes requests through Master via NATS

import std/[json, strformat, options, asyncdispatch, times, random]
import ../core/database
import ../core/db_config
import ../comms/discord
import ../comms/discord_routing
import ../core/nats_client
import ../types/config

# Thread-local storage for agent context
var toolNatsClient {.threadvar.}: NifflerNatsClient
var toolAgentName {.threadvar.}: string
var toolIsAgentMode {.threadvar.}: bool
var toolIsInitialized {.threadvar.}: bool

proc initDiscordToolContext*(natsClient: NifflerNatsClient, agentName: string, isAgent: bool) =
  ## Initialize Discord tool context
  ## Called by tool worker when starting in agent mode
  toolNatsClient = natsClient
  toolAgentName = agentName
  toolIsAgentMode = isAgent
  toolIsInitialized = true

proc isDiscordToolInitialized*(): bool =
  return toolIsInitialized

proc executeDiscord*(args: JsonNode): string {.gcsafe.} =
  ## Execute Discord tool - routes through Master if in agent context

  if not toolIsInitialized:
    return $ %*{"error": "Discord tool not initialized - context missing"}

  if not args.hasKey("operation") or args["operation"].kind != JString:
    return $ %*{"error": "Missing required string argument: operation"}

  let operation = args["operation"].getStr()

  if not args.hasKey("channel_id") or args["channel_id"].kind != JString:
    return $ %*{"error": "Missing required string argument: channel_id"}

  let channelId = args["channel_id"].getStr()

  # Build request
  var content = ""
  if args.hasKey("content") and args["content"].kind == JString:
    content = args["content"].getStr()

  var limit = 20
  if args.hasKey("limit"):
    limit = args["limit"].getInt()

  var beforeMessageId = ""
  if args.hasKey("before_message_id") and args["before_message_id"].kind == JString:
    beforeMessageId = args["before_message_id"].getStr()

  if toolIsAgentMode:
    # Agent mode: Route through Master via NATS
    try:
      let request = newDiscordRequest(
        toolAgentName,
        operation,
        channelId,
        content,
        limit,
        beforeMessageId
      )

      let response = sendDiscordRequestViaNats(toolNatsClient, request)

      if response.success:
        return $ %*{
          "success": true,
          "operation": operation,
          "data": response.data
        }
      else:
        return $ %*{
          "error": response.error,
          "operation": operation
        }
    except Exception as e:
      return $ %*{"error": fmt("Discord routing error: {e.msg}")}

  else:
    # Master mode: Execute directly
    {.gcsafe.}:
      try:
        # Check if Discord is configured
        let database = getGlobalDatabase()
        if database == nil:
          return $ %*{"error": "Database not available"}

        let discordConfig = getDiscordConfig(database)
        if discordConfig.isNone():
          return $ %*{"error": "Discord is not configured. Use '/discord connect <token>' to enable."}

        let (token, _, _, _, _) = discordConfig.get()
        if token.len == 0:
          return $ %*{"error": "Discord token is not configured"}

        # Execute directly
        let client = newDiscordClient(token)

        case operation
        of "recent_messages":
          if limit < 1 or limit > 100:
            return $ %*{"error": "limit must be between 1 and 100"}

          let messages = waitFor client.api.getChannelMessages(
            channelId,
            before = beforeMessageId,
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

          return $ %*{
            "success": true,
            "operation": operation,
            "channel_id": channelId,
            "count": messages.len,
            "messages": formattedMessages
          }

        of "send_message":
          if content.len == 0:
            return $ %*{"error": "content cannot be empty"}

          let sentMessage = waitFor client.api.sendMessage(channelId, formatResponse(content))
          return $ %*{
            "success": true,
            "operation": operation,
            "channel_id": channelId,
            "message_id": sentMessage.id
          }

        else:
          return $ %*{"error": fmt("Unknown discord operation '{operation}'")}

      except Exception as e:
        return $ %*{"error": fmt("discord tool error: {e.msg}")}
