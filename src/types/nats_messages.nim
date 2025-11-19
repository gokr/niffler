## NATS Message Types
##
## Simplified message protocol for agent communication over NATS.
## All messages use JSON serialization via Sunny.
##
## Message Flow:
## 1. Master sends Request to agent via niffler.agent.<name>.request
## 2. Agent sends multiple Response messages (streaming) with done=false
## 3. Agent sends final Response with done=true
## 4. Agent sends StatusUpdate messages for state changes
## 5. Agent publishes Heartbeat to presence KV store
##
## Design Principles:
## - Single generic Request type (agent parses commands from input)
## - Streaming responses via done flag
## - Agent maintains its own conversation state (no conversationId in Request)
## - Commands like /plan, /model xxx parsed by agent from input string

import std/[json, times]
import sunny

type
  NatsRequest* = object
    ## Generic request sent to an agent
    ## Agent parses commands from input string (e.g., "/plan", "/model xxx")
    requestId*: string      # Unique request identifier
    agentName*: string      # Target agent name
    input*: string          # Full input including commands and prompt

  NatsResponse* = object
    ## Streaming response from agent
    ## Multiple responses can be sent per request with done=false
    ## Final response must have done=true
    requestId*: string      # Matching request ID
    content*: string        # Response content
    done*: bool            # True if this is the final response

  NatsStatusUpdate* = object
    ## Status update from agent (e.g., "Switching to plan mode")
    requestId*: string      # Related request ID (optional)
    agentName*: string      # Agent sending the update
    status*: string         # Status message

  NatsHeartbeat* = object
    ## Heartbeat for presence tracking
    ## Published to JetStream KV store: niffler_presence
    ## Key format: presence.<agentName>
    agentName*: string      # Agent name
    timestamp*: int64       # Unix timestamp in seconds

# JSON Serialization using Sunny

proc toJson*(req: NatsRequest): JsonNode =
  ## Serialize request to JSON
  result = %*{
    "request_id": req.requestId,
    "agent_name": req.agentName,
    "input": req.input
  }

proc fromJson*(json: JsonNode, T: typedesc[NatsRequest]): NatsRequest =
  ## Deserialize request from JSON
  result.requestId = json["request_id"].getStr()
  result.agentName = json["agent_name"].getStr()
  result.input = json["input"].getStr()

proc toJson*(resp: NatsResponse): JsonNode =
  ## Serialize response to JSON
  result = %*{
    "request_id": resp.requestId,
    "content": resp.content,
    "done": resp.done
  }

proc fromJson*(json: JsonNode, T: typedesc[NatsResponse]): NatsResponse =
  ## Deserialize response from JSON
  result.requestId = json["request_id"].getStr()
  result.content = json["content"].getStr()
  result.done = json["done"].getBool()

proc toJson*(update: NatsStatusUpdate): JsonNode =
  ## Serialize status update to JSON
  result = %*{
    "request_id": update.requestId,
    "agent_name": update.agentName,
    "status": update.status
  }

proc fromJson*(json: JsonNode, T: typedesc[NatsStatusUpdate]): NatsStatusUpdate =
  ## Deserialize status update from JSON
  result.requestId = json["request_id"].getStr()
  result.agentName = json["agent_name"].getStr()
  result.status = json["status"].getStr()

proc toJson*(hb: NatsHeartbeat): JsonNode =
  ## Serialize heartbeat to JSON
  result = %*{
    "agent_name": hb.agentName,
    "timestamp": hb.timestamp
  }

proc fromJson*(json: JsonNode, T: typedesc[NatsHeartbeat]): NatsHeartbeat =
  ## Deserialize heartbeat from JSON
  result.agentName = json["agent_name"].getStr()
  result.timestamp = json["timestamp"].getInt()

# Convenience functions

proc createRequest*(requestId: string, agentName: string, input: string): NatsRequest =
  ## Create a new request
  NatsRequest(
    requestId: requestId,
    agentName: agentName,
    input: input
  )

proc createResponse*(requestId: string, content: string, done: bool = false): NatsResponse =
  ## Create a response
  NatsResponse(
    requestId: requestId,
    content: content,
    done: done
  )

proc createStatusUpdate*(requestId: string, agentName: string, status: string): NatsStatusUpdate =
  ## Create a status update
  NatsStatusUpdate(
    requestId: requestId,
    agentName: agentName,
    status: status
  )

proc createHeartbeat*(agentName: string): NatsHeartbeat =
  ## Create a heartbeat with current timestamp
  NatsHeartbeat(
    agentName: agentName,
    timestamp: getTime().toUnix()
  )

# String conversion for convenience

proc `$`*(req: NatsRequest): string =
  $req.toJson()

proc `$`*(resp: NatsResponse): string =
  $resp.toJson()

proc `$`*(update: NatsStatusUpdate): string =
  $update.toJson()

proc `$`*(hb: NatsHeartbeat): string =
  $hb.toJson()