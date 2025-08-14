## Message Type Definitions
##
## This module defines all message-related types used throughout Niffler for
## LLM communication, tool calling, and streaming responses.
##
## Key Type Categories:
## - Message types (user, assistant, system, tool messages)
## - OpenAI-compatible tool calling types (function calls, tool results)
## - Streaming response types (chunks, deltas)
## - API request/response types for thread communication
##
## OpenAI Compatibility:
## - Follows OpenAI API specification for message formatting
## - Compatible with tool calling protocol
## - Supports streaming response format with proper chunk handling
##
## Design Decisions:
## - Uses enum for message roles to ensure type safety
## - Separate types for LLM tool calls vs internal tool execution
## - Optional fields using Option[T] for flexibility
## - Streaming-first approach with chunk-based processing

import std/[options, json]

type
  # Core message types for LLM conversations
  MessageRole* = enum
    mrUser = "user"
    mrAssistant = "assistant"
    mrSystem = "system"
    mrTool = "tool"

  # OpenAI-compatible tool calling types
  FunctionCall* = object
    name*: string
    arguments*: string

  LLMToolCall* = object
    id*: string
    `type`*: string  # Always "function" for OpenAI - backticks escape the keyword
    function*: FunctionCall

  ToolResult* = object
    id*: string
    output*: string
    error*: Option[string]

  # Legacy tool call type (for existing tool system)
  ToolCall* = object
    id*: string
    name*: string
    arguments*: string

  Message* = object
    role*: MessageRole
    content*: string
    # OpenAI format tool calls (for LLM communication)
    toolCalls*: Option[seq[LLMToolCall]]
    # Tool call ID for tool messages
    toolCallId*: Option[string]
    # Legacy fields for backward compatibility
    legacyToolCalls*: Option[seq[ToolCall]]
    toolResults*: Option[seq[ToolResult]]

  # API Thread Communication
  APIRequestKind* = enum
    arkChatRequest
    arkStreamCancel
    arkShutdown
    arkConfigure

  APIRequest* = object
    case kind*: APIRequestKind
    of arkChatRequest:
      requestId*: string
      messages*: seq[Message] 
      model*: string
      maxTokens*: int
      temperature*: float
      baseUrl*: string
      apiKey*: string
      # Tool calling support
      enableTools*: bool
      tools*: Option[seq[ToolDefinition]]
    of arkStreamCancel:
      cancelRequestId*: string
    of arkShutdown:
      discard
    of arkConfigure:
      configBaseUrl*: string
      configApiKey*: string
      configModelName*: string

  APIResponseKind* = enum
    arkStreamChunk
    arkStreamComplete
    arkStreamError
    arkReady

  TokenUsage* = object
    promptTokens*: int
    completionTokens*: int
    totalTokens*: int

  # Tool definition for API requests (OpenAI format)
  ToolParameter* = object
    `type`*: string
    description*: Option[string]
    `enum`*: Option[seq[string]]
    items*: Option[JsonNode]
    properties*: Option[JsonNode]
    required*: Option[seq[string]]

  ToolFunction* = object
    name*: string
    description*: string
    parameters*: JsonNode

  ToolDefinition* = object
    `type`*: string  # Always "function" for OpenAI - backticks escape the keyword
    function*: ToolFunction

  APIResponse* = object
    requestId*: string
    case kind*: APIResponseKind
    of arkStreamChunk:
      content*: string
      done*: bool
      # Tool calling in stream chunks
      toolCalls*: Option[seq[LLMToolCall]]
    of arkStreamComplete:
      usage*: TokenUsage
      finishReason*: string
    of arkStreamError:
      error*: string
    of arkReady:
      discard

  # Tool Thread Communication
  ToolRequestKind* = enum
    trkExecute
    trkShutdown

  ToolRequest* = object
    case kind*: ToolRequestKind
    of trkExecute:
      requestId*: string
      toolName*: string
      arguments*: string
    of trkShutdown:
      discard

  ToolResponseKind* = enum
    trkResult
    trkError
    trkReady

  ToolResponse* = object
    requestId*: string
    case kind*: ToolResponseKind
    of trkResult:
      output*: string
    of trkError:
      error*: string
    of trkReady:
      discard

  # UI Thread Communication
  UIUpdateKind* = enum
    uukStateChange
    uukNewMessage
    uukStreamUpdate
    uukError
    uukToolRequest

  UIState* = enum
    usInput
    usResponding
    usToolRequest
    usErrorRecovery
    usDiffApply
    usFixJson
    usMenu
    usToolWaiting

  UIUpdate* = object
    case kind*: UIUpdateKind
    of uukStateChange:
      newState*: UIState
    of uukNewMessage:
      message*: Message
    of uukStreamUpdate:
      streamContent*: string
      streamDone*: bool
    of uukError:
      errorMessage*: string
    of uukToolRequest:
      toolName*: string
      toolArgs*: string
      requestId*: string

  # Streaming response types for OpenAI-compatible APIs
  StreamChunk* = object
    id*: string
    `object`*: string
    created*: int64
    model*: string
    choices*: seq[StreamChoice]
    usage*: Option[TokenUsage]
    done*: bool  # Additional field to indicate end of stream

  StreamChoice* = object
    index*: int
    delta*: ChatMessage
    finishReason*: Option[string]

  # OpenAI-compatible request/response types
  ChatRequest* = object
    model*: string
    messages*: seq[ChatMessage]
    maxTokens*: Option[int]
    temperature*: Option[float]
    stream*: bool
    tools*: Option[seq[ToolDefinition]]

  ChatMessage* = object
    role*: string
    content*: string
    toolCalls*: Option[seq[ChatToolCall]]
    toolCallId*: Option[string]

  ChatToolCall* = object
    id*: string
    `type`*: string
    function*: ChatFunction

  ChatFunction* = object
    name*: string
    arguments*: string