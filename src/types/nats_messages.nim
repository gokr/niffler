## NATS Message Type Definitions
##
## Defines all message types used for inter-process communication
## between multi-agent niffler processes via NATS.

import std/[json, options, times, tables]

type
  RequestType* = enum
    rtTask = "task"
    rtAsk = "ask"

  ResponseStatus* = enum
    rsCompleted = "completed"
    rsError = "error"
    rsProcessing = "processing"
    rsTimeout = "timeout"

  AgentRequest* = object
    requestType*: RequestType
    requestId*: string
    agentName*: string
    prompt*: string
    conversationId*: Option[string]
    context*: Option[seq[JsonNode]]
    metadata*: Table[string, string]

  AgentResponse* = object
    requestId*: string
    agentName*: string
    content*: string
    conversationId*: string
    toolCalls*: seq[JsonNode]
    tokensUsed*: JsonNode
    status*: ResponseStatus
    metadata*: Table[string, string]

  AgentStatus* = object
    requestId*: string
    agentName*: string
    status*: string
    data*: JsonNode
    timestamp*: string

  AgentHeartbeat* = object
    agentName*: string
    status*: string
    uptime*: int
    requestsProcessed*: int
    currentConversationId*: Option[string]
    timestamp*: string

# JSON serialization helpers
proc toJson*(req: AgentRequest): string =
  let jsonNode = %*{
    "type": if req.requestType == rtTask: "task_request" else: "ask_request",
    "requestId": req.requestId,
    "agentName": req.agentName,
    "prompt": req.prompt,
    "metadata": req.metadata
  }

  if req.conversationId.isSome():
    jsonNode["conversationId"] = %*req.conversationId.get()

  if req.context.isSome():
    jsonNode["context"] = %*req.context.get()

  $jsonNode

proc toJson*(resp: AgentResponse): string =
  $ %*{
    "type": "response",
    "requestId": resp.requestId,
    "agentName": resp.agentName,
    "content": resp.content,
    "conversationId": resp.conversationId,
    "toolCalls": resp.toolCalls,
    "tokensUsed": resp.tokensUsed,
    "status": $resp.status,
    "metadata": resp.metadata,
    "timestamp": getClockStr()
  }

proc getClockStr*(): string =
  ## Get current ISO timestamp
  now().format("yyyy-MM-dd'T'HH:mm:sszzz")

proc toJson*(status: AgentStatus): string =
  $ %*{
    "type": "status",
    "requestId": status.requestId,
    "agentName": status.agentName,
    "status": status.status,
    "data": status.data,
    "timestamp": status.timestamp
  }

proc toJson*(heartbeat: AgentHeartbeat): string =
  let jsonNode = %*{
    "type": "heartbeat",
    "agentName": heartbeat.agentName,
    "status": heartbeat.status,
    "uptime": heartbeat.uptime,
    "requestsProcessed": heartbeat.requestsProcessed,
    "timestamp": heartbeat.timestamp
  }

  if heartbeat.currentConversationId.isSome():
    jsonNode["currentConversationId"] = %*heartbeat.currentConversationId.get()

  $jsonNode