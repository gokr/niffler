## Discord Communication Channel
##
## Discord bot integration for Niffler autonomous agent.
## Allows users to interact with Niffler via Discord messages.

import std/[asyncdispatch, json, options, strutils, strformat, logging, tables]
import dimscord
import ../core/database
import ../autonomous/task_queue
import channel

const
  DiscordCommandPrefix = "!"
  MaxMessageLength = 2000

type
  DiscordChannel* = ref object of CommunicationChannel
    client*: DiscordClient
    token*: string
    guildId*: string
    monitoredChannels*: seq[string]
    db*: DatabaseBackend
    ready*: bool

proc newDiscordChannel*(token: string, guildId: string = "", monitoredChannels: seq[string] = @[]): DiscordChannel =
  ## Create a new Discord channel
  result = DiscordChannel(
    name: "discord",
    enabled: true,
    token: token,
    guildId: guildId,
    monitoredChannels: monitoredChannels,
    db: nil,
    ready: false
  )

proc shouldProcessMessage*(channel: DiscordChannel, msg: Message, myUserId: string): bool =
  ## Determine if we should process this message
  
  # Ignore own messages
  if msg.author.bot:
    return false
  
  # Check if it's a DM (no guild_id means DM)
  if msg.guild_id.isNone:
    return true
  
  # Check if mentioned (in mention_users)
  for mention in msg.mention_users:
    if mention.id == myUserId:
      return true
  
  # Check if in monitored channel
  if channel.monitoredChannels.len > 0:
    if msg.channel_id notin channel.monitoredChannels:
      return false
  
  # Check for command prefix
  if msg.content.startsWith(DiscordCommandPrefix):
    return true
  
  return false

proc extractCommand*(content: string): tuple[command: string, args: string] =
  ## Extract command and arguments from message
  let parts = content.splitWhitespace()
  if parts.len == 0:
    return ("", "")
  
  var cmd = parts[0].toLower()
  
  # Remove prefix if present
  if cmd.startsWith(DiscordCommandPrefix):
    cmd = cmd[DiscordCommandPrefix.len..^1]
  
  # Remove mention if present
  if cmd.startsWith("<@"):
    cmd = ""
  
  let args = if parts.len > 1: parts[1..^1].join(" ") else: ""
  
  return (cmd, args)

proc formatResponse*(content: string): string =
  ## Format response for Discord (handle length limits)
  if content.len <= MaxMessageLength:
    return content
  
  # Truncate and add ellipsis
  return content[0..<MaxMessageLength-3] & "..."

proc handleDiscordMessage*(channel: DiscordChannel, msg: Message, myUserId: string) {.async.} =
  ## Handle an incoming Discord message
  
  if not shouldProcessMessage(channel, msg, myUserId):
    return
  
  let content = msg.content
  let (cmd, args) = extractCommand(content)
  
  # Remove bot mention from content for processing
  var cleanContent = content
  for mention in msg.mention_users:
    let mentionStr = "<@" & mention.id & ">"
    let mentionStrNick = "<@!" & mention.id & ">"
    cleanContent = cleanContent.replace(mentionStr, "")
    cleanContent = cleanContent.replace(mentionStrNick, "")
  cleanContent = cleanContent.strip()
  
  # Create task from message
  if channel.db != nil and cleanContent.len > 0:
    let taskId = createTask(
      channel.db,
      instruction = cleanContent,
      taskType = ttUserRequest,
      sourceChannel = "discord",
      sourceId = $msg.id,
      priority = 0
    )
    
    if taskId > 0:
      # Acknowledge receipt
      let ackMsg = fmt"Task created (ID: {taskId}). I'll work on this and report back when done."
      discard await channel.client.api.sendMessage(
        msg.channel_id,
        ackMsg
      )
    else:
      discard await channel.client.api.sendMessage(
        msg.channel_id,
        "Failed to create task. Please try again."
      )

method start*(channel: DiscordChannel) =
  ## Start the Discord bot
  if channel.token.len == 0:
    error("Discord token not configured")
    return
  
  try:
    channel.client = newDiscordClient(channel.token)
    
    # TODO: Set up event handlers properly using dimscord's event system
    # For now, the bot starts but doesn't handle events
    
    # Connect and start with proper intents
    waitFor channel.client.startSession(
      gateway_intents = {giGuildMessages, giDirectMessages}
    )
    
    channel.ready = true
    channel.started = true
    info("Discord bot started successfully")
    
  except Exception as e:
    error(fmt("Failed to start Discord bot: {e.msg}"))
    channel.ready = false

method stop*(channel: DiscordChannel) =
  ## Stop the Discord bot
  if channel.client != nil:
    try:
      # Disconnect the client
      # Note: dimscord doesn't have explicit stopSession, 
      # we rely on garbage collection or client closure
      channel.client = nil
      info("Discord bot stopped")
    except Exception as e:
      error(fmt("Error stopping Discord bot: {e.msg}"))
  
  channel.started = false
  channel.ready = false

method sendMessage*(channel: DiscordChannel, msg: ChannelMessage) {.async.} =
  ## Send a message through Discord
  if not channel.ready or channel.client == nil:
    raise newException(IOError, "Discord channel not ready")
  
  # For Discord, we need a channel ID
  # This would come from the message metadata or config
  let channelId = if msg.metadata.hasKey("channelId"):
    msg.metadata["channelId"].getStr()
  else:
    ""
  
  if channelId.len == 0:
    raise newException(ValueError, "No Discord channel ID provided")
  
  let formattedContent = formatResponse(msg.content)
  discard await channel.client.api.sendMessage(channelId, formattedContent)

method sendNotification*(channel: DiscordChannel, title, body: string) {.async.} =
  ## Send a notification through Discord
  if not channel.ready or channel.client == nil:
    return
  
  # For notifications, we'd need a default notification channel configured
  # This is a simplified implementation
  let content = fmt"**{title}**\n{body}"
  # Would need to know which channel to send to
  discard

proc runDiscordBot*(token: string, db: DatabaseBackend) {.async.} =
  ## Run the Discord bot asynchronously
  let channel = newDiscordChannel(token)
  channel.db = db
  
  # This would normally be called in an async context
  # For now, just start it
  channel.start()

proc startDiscordChannel*(token: string, db: DatabaseBackend) =
  ## Start Discord channel in a new thread or async context
  let channel = newDiscordChannel(token)
  channel.db = db
  channel.start()
