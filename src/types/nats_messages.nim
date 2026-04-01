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
## - Uses Sunny for automatic JSON serialization/deserialization

import std/[times]
import sunny

type
  NatsRequestKind* {.pure.} = enum
    ## Type of request
    nrkNormal = "normal"      ## Normal request with input
    nrkCancel = "cancel"      ## Cancel running request
  
  NatsRequest* = object
    ## Generic request sent to an agent
    ## Agent parses commands from input string (e.g., "/plan", "/model xxx")
    requestId* {.json: "request_id".}: string      # Unique request identifier
    agentName* {.json: "agent_name".}: string      # Target agent name
    input*: string                                  # Full input including commands and prompt
    case kind* {.json: "kind".}: NatsRequestKind = nrkNormal
    of nrkNormal:
      discard
    of nrkCancel:
      cancelRequestId* {.json: "cancel_request_id".}: string  # ID of request to cancel

  NatsResponse* = object
    ## Streaming response from agent
    ## Multiple responses can be sent per request with done=false
    ## Final response must have done=true
    requestId* {.json: "request_id".}: string      # Matching request ID
    agentName* {.json: "agent_name".}: string      # Agent sending the response
    content*: string                                # Response content
    done*: bool                                     # True if this is the final response

  NatsStatusUpdate* = object
    ## Status update from agent (e.g., "Switching to plan mode")
    requestId* {.json: "request_id".}: string      # Related request ID (optional)
    agentName* {.json: "agent_name".}: string      # Agent sending the update
    status*: string                                 # Status message

  NatsHeartbeat* = object
    ## Heartbeat for presence tracking
    ## Published to JetStream KV store: niffler_presence
    ## Key format: presence.<agentName>
    agentName* {.json: "agent_name".}: string      # Agent name
    timestamp*: int64                               # Unix timestamp in seconds

# JSON Serialization - Sunny provides automatic serialization via toJson/fromJson
# The {.json.} pragmas above handle field name mapping automatically

# Convenience functions

proc createRequest*(requestId: string, agentName: string, input: string): NatsRequest =
  ## Create a new request
  NatsRequest(
    requestId: requestId,
    agentName: agentName,
    input: input
  )

proc createCancelRequest*(requestId: string, agentName: string, cancelRequestId: string): NatsRequest =
  ## Create a cancel request to stop a running task/ask
  NatsRequest(
    requestId: requestId,
    agentName: agentName,
    input: "",
    kind: nrkCancel,
    cancelRequestId: cancelRequestId
  )

proc createResponse*(requestId: string, agentName: string, content: string, done: bool = false): NatsResponse =
  ## Create a response
  NatsResponse(
    requestId: requestId,
    agentName: agentName,
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

# String conversion for convenience - uses Sunny's automatic toJson

proc `$`*(req: NatsRequest): string =
  req.toJson()

proc `$`*(resp: NatsResponse): string =
  resp.toJson()

proc `$`*(update: NatsStatusUpdate): string =
  update.toJson()

proc `$`*(hb: NatsHeartbeat): string =
  hb.toJson()

# Deserialization from JSON strings - uses Sunny's fromJson[T](typedesc[T], string)
# Export sunny for consumers to use sunny.fromJson(NatsRequest, data)
export sunny