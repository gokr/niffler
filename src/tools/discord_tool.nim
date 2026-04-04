## Discord Tool
##
## Provides read-only Discord operations using the configured bot token.

import std/[json, strformat, options, asyncdispatch]
import dimscord
import ../core/database
import ../comms/discord

proc executeDiscord*(args: JsonNode): string {.gcsafe.} =
  {.gcsafe.}:
    try:
      if not args.hasKey("operation") or args["operation"].kind != JString:
        return $ %*{"error": "Missing required string argument: operation"}

      let operation = args["operation"].getStr()
      let database = getGlobalDatabase()
      if database == nil:
        return $ %*{"error": "Database not available"}

      let discordConfig = getDiscordConfig(database)
      if discordConfig.isNone():
        return $ %*{"error": "Discord is not configured"}

      let (token, _, _, _, _) = discordConfig.get()
      if token.len == 0:
        return $ %*{"error": "Discord token is not configured"}

      let client = newDiscordClient(token)

      case operation
      of "recent_messages":
        if not args.hasKey("channel_id") or args["channel_id"].kind != JString:
          return $ %*{"error": "Missing required string argument: channel_id"}

        let channelId = args["channel_id"].getStr()
        var limit = 20
        if args.hasKey("limit"):
          limit = args["limit"].getInt()
        if limit < 1 or limit > 100:
          return $ %*{"error": "limit must be between 1 and 100"}

        let beforeMessageId =
          if args.hasKey("before_message_id") and args["before_message_id"].kind == JString:
            args["before_message_id"].getStr()
          else:
            ""

        let messages = asyncdispatch.waitFor client.api.getChannelMessages(channelId, before = beforeMessageId, limit = limit)
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
        if not args.hasKey("channel_id") or args["channel_id"].kind != JString:
          return $ %*{"error": "Missing required string argument: channel_id"}
        if not args.hasKey("content") or args["content"].kind != JString:
          return $ %*{"error": "Missing required string argument: content"}

        let channelId = args["channel_id"].getStr()
        let content = args["content"].getStr()
        if content.len == 0:
          return $ %*{"error": "content cannot be empty"}

        let sentMessage = asyncdispatch.waitFor client.api.sendMessage(channelId, formatResponse(content))
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
