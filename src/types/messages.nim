import std/options

type
  # Core message types for LLM conversations
  MessageRole* = enum
    mrUser = "user"
    mrAssistant = "assistant"
    mrSystem = "system"
    mrTool = "tool"

  ToolCall* = object
    id*: string
    name*: string
    arguments*: string

  ToolResult* = object
    id*: string
    output*: string
    error*: Option[string]

  Message* = object
    role*: MessageRole
    content*: string
    toolCalls*: Option[seq[ToolCall]]
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

  APIResponse* = object
    requestId*: string
    case kind*: APIResponseKind
    of arkStreamChunk:
      content*: string
      done*: bool
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