## Communication Channel Interface
##
## Abstract interface for different communication channels (Discord, CLI, etc.)
## Each channel implements these methods to provide a uniform way to
## send and receive messages regardless of the underlying transport.

import std/[json, options, times, asyncdispatch, tables]

type
  ChannelMessage* = object
    id*: string
    sourceChannel*: string
    sourceId*: string
    senderId*: string
    senderName*: string
    content*: string
    workspaceId*: Option[int]
    replyTo*: Option[string]
    metadata*: JsonNode
    receivedAt*: DateTime

  ChannelResponse* = object
    content*: string
    reactions*: seq[string]
    replyTo*: Option[string]
    metadata*: JsonNode

  CommunicationChannel* = ref object of RootObj
    name*: string
    enabled*: bool
    started*: bool

method start*(channel: CommunicationChannel) {.base.} =
  ## Start the communication channel
  raise newException(CatchableError, "Not implemented")

method stop*(channel: CommunicationChannel) {.base.} =
  ## Stop the communication channel
  raise newException(CatchableError, "Not implemented")

method sendMessage*(channel: CommunicationChannel, msg: ChannelMessage): Future[void] {.base.} =
  ## Send a message through this channel
  raise newException(CatchableError, "Not implemented")

method sendNotification*(channel: CommunicationChannel, title, body: string): Future[void] {.base.} =
  ## Send a notification through this channel
  raise newException(CatchableError, "Not implemented")

method isRunning*(channel: CommunicationChannel): bool {.base.} =
  ## Check if the channel is currently running
  return channel.started and channel.enabled

proc createChannelMessage*(
  sourceChannel, sourceId, senderId, senderName, content: string,
  workspaceId: Option[int] = none(int),
  replyTo: Option[string] = none(string),
  metadata: JsonNode = newJObject()
): ChannelMessage =
  ## Helper to create a ChannelMessage
  result = ChannelMessage(
    id: $getTime().toUnix() & "_" & sourceChannel,
    sourceChannel: sourceChannel,
    sourceId: sourceId,
    senderId: senderId,
    senderName: senderName,
    content: content,
    workspaceId: workspaceId,
    replyTo: replyTo,
    metadata: metadata,
    receivedAt: now()
  )
