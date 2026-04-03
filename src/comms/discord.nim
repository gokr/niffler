## Discord Communication Channel
##
## Discord bot integration for Niffler autonomous agent.
## Allows users to interact with Niffler via Discord messages.
##
## This module runs Discord in a background thread and forwards
## messages to the agent via a thread-safe channel.

import std/[asyncdispatch, json, options, strutils, strformat, logging]
import dimscord
import ../core/[database, db_config]
import channel

const
  DiscordCommandPrefix = "!"
  MaxMessageLength = 2000

type
  DiscordMessage* = object
    ## Message received from Discord
    content*: string
    channelId*: string
    guildId*: string
    authorId*: string
    authorName*: string
    messageId*: string

  DiscordChannel* = ref object of CommunicationChannel
    ## Discord communication channel
    client*: DiscordClient
    token*: string
    guildId*: string
    monitoredChannels*: seq[string]
    db*: DatabaseBackend
    ready*: bool
    myUserId*: string

var
  discordThread*: Thread[tuple[token: string, guildId: string, channels: seq[string]]]
  discordRunning* {.global.}: bool = false
  discordMessageChannel* {.global.}: system.Channel[DiscordMessage]

proc initDiscordChannel*() =
  ## Initialize the Discord message channel
  discordMessageChannel.open(100)

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

proc shouldProcessMessage*(channel: DiscordChannel, msg: Message): bool =
  ## Determine if we should process this message
  
  # Ignore own messages
  if msg.author.bot:
    return false
  
  # Check if it's a DM (no guild_id means DM)
  if msg.guild_id.isNone:
    return true
  
  # Check if mentioned
  for mention in msg.mention_users:
    if mention.id == channel.myUserId:
      return true
  
  # Check for command prefix
  if msg.content.startsWith(DiscordCommandPrefix):
    return true
  
  # Check if in monitored channel
  if channel.monitoredChannels.len > 0:
    # Get channel name from ID would require API call
    # For now, check against channel IDs
    if msg.channel_id notin channel.monitoredChannels:
      return false
  
  return true

proc extractCleanContent*(content: string, myUserId: string): string =
  ## Clean message content by removing mentions
  result = content.strip()
  
  # Remove bot mention
  let mentionStr = "<@" & myUserId & ">"
  let mentionStrNick = "<@!" & myUserId & ">"
  result = result.replace(mentionStr, "")
  result = result.replace(mentionStrNick, "")
  
  # Remove command prefix if present
  if result.startsWith(DiscordCommandPrefix):
    result = result[DiscordCommandPrefix.len..^1].strip()
  
  result = result.strip()

proc formatResponse*(content: string): string =
  ## Format response for Discord (handle length limits)
  if content.len <= MaxMessageLength:
    return content
  
  # Truncate and add ellipsis
  return content[0..<MaxMessageLength-3] & "..."

proc runDiscordBot*(token: string, guildId: string = "", monitoredChannels: seq[string] = @[]) =
  ## Run the Discord bot (blocking, call in separate thread)
  try:
    let client = newDiscordClient(token)
    var botUserId = ""

    info("Starting Discord bot...")

    # Set up event handlers using dimscord's event system
    client.events.on_ready = proc(s: Shard, r: Ready) {.async.} =
      botUserId = r.user.id
      info("Discord bot connected and ready")
      discordRunning = true

    client.events.message_create = proc(s: Shard, msg: Message) {.async.} =
      debug(fmt"Discord message: {msg.content[0..min(50, msg.content.len-1)]}")

      let cleanContent = if botUserId.len > 0:
        extractCleanContent(msg.content, botUserId)
      else:
        msg.content.strip()

      # Create DiscordMessage and send to channel
      let discordMsg = DiscordMessage(
        content: cleanContent,
        channelId: msg.channel_id,
        guildId: if msg.guild_id.isSome: msg.guild_id.get else: "",
        authorId: msg.author.id,
        authorName: msg.author.username,
        messageId: msg.id
      )
      try:
        discordMessageChannel.send(discordMsg)
      except:
        error("Failed to send Discord message to channel")
    
    # Start session (blocking)
    waitFor client.startSession(
      gateway_intents = {giGuildMessages, giDirectMessages, giMessageContent}
    )
    
  except Exception as e:
    error(fmt"Discord bot error: {e.msg}")
    discordRunning = false

proc startDiscordThread*(token: string, guildId: string = "", monitoredChannels: seq[string] = @[]) =
  ## Start Discord bot in background thread
  proc discordThreadProc(params: tuple[token: string, guildId: string, channels: seq[string]]) {.thread, gcsafe.} =
    {.gcsafe.}:
      runDiscordBot(params.token, params.guildId, params.channels)
  
  createThread(discordThread, discordThreadProc, (token: token, guildId: guildId, channels: monitoredChannels))
  
  info("Discord thread started")

proc stopDiscordBot*() =
  ## Stop the Discord bot
  discordRunning = false
  # Note: dimscord doesn't have explicit stop, thread will exit when session ends

proc sendDiscordMessage*(token: string, channelId: string, content: string) =
  ## Send a message to a Discord channel (blocking)
  try:
    let client = newDiscordClient(token)
    let formatted = formatResponse(content)
    
    # Use REST API to send message (don't need full gateway for this)
    let api = client.api
    discard waitFor api.sendMessage(channelId, formatted)
    
    debug(fmt"Sent Discord message to {channelId}")
  except Exception as e:
    error(fmt"Failed to send Discord message: {e.msg}")

proc isDiscordEnabled*(db: DatabaseBackend): bool =
  ## Check if Discord integration is enabled
  if db == nil:
    return false
  
  let config = getConfigValue(db, "discord")
  if config.isNone:
    return false
  
  let cfg = config.get()
  if not cfg.hasKey("enabled"):
    return false
  
  return cfg["enabled"].getBool()

proc getDiscordConfig*(db: DatabaseBackend): Option[tuple[token: string, guildId: string, channels: seq[string], defaultAgent: string, allowedPeople: seq[string]]] =
  ## Get Discord configuration from database
  if db == nil:
    return none(tuple[token: string, guildId: string, channels: seq[string], defaultAgent: string, allowedPeople: seq[string]])

  let config = getConfigValue(db, "discord")
  if config.isNone:
    return none(tuple[token: string, guildId: string, channels: seq[string], defaultAgent: string, allowedPeople: seq[string]])

  let cfg = config.get()

  if not cfg.hasKey("token"):
    return none(tuple[token: string, guildId: string, channels: seq[string], defaultAgent: string, allowedPeople: seq[string]])

  let token = cfg["token"].getStr()
  let guildId = if cfg.hasKey("guildId"): cfg["guildId"].getStr() else: ""
  let defaultAgent = if cfg.hasKey("defaultAgent"): cfg["defaultAgent"].getStr() else: ""

  var channels: seq[string] = @[]
  if cfg.hasKey("monitoredChannels") and cfg["monitoredChannels"].kind == JArray:
    for ch in cfg["monitoredChannels"]:
      channels.add(ch.getStr())

  var allowedPeople: seq[string] = @[]
  if cfg.hasKey("allowedPeople") and cfg["allowedPeople"].kind == JArray:
    for person in cfg["allowedPeople"]:
      allowedPeople.add(person.getStr())

  return some((token: token, guildId: guildId, channels: channels, defaultAgent: defaultAgent, allowedPeople: allowedPeople))
