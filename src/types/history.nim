import std/[json, options, tables]
import validation

type
  SequenceId* = int64

  ToolCallRequest* = object
    `type`*: string  # Should be "function"
    function*: ToolCallFunction
    toolCallId*: string

  ToolCallFunction* = object
    name*: string
    arguments*: string

  HistoryItemType* = enum
    hitUser = "user"
    hitAssistant = "assistant"
    hitTool = "tool"
    hitToolOutput = "tool-output"
    hitToolMalformed = "tool-malformed"
    hitToolFailed = "tool-failed"
    hitToolReject = "tool-reject"
    hitFileOutdated = "file-outdated"
    hitFileUnreadable = "file-unreadable"
    hitRequestFailed = "request-failed"
    hitNotification = "notification"

  AnthropicAssistantData* = object
    encrypted*: Option[string]
    itemId*: Option[string]

  ToolCallOriginal* = object
    id*: Option[string]
    function*: Option[ToolCallFunction]

  # History item using variant objects
  HistoryItem* = object
    id*: SequenceId
    case itemType*: HistoryItemType
    of hitUser:
      userContent*: string
    of hitAssistant:
      assistantContent*: string
      anthropicData*: Option[AnthropicAssistantData]
      toolCalls*: Option[seq[ToolCallRequest]]
    of hitTool:
      tool*: ToolCallRequest
    of hitToolOutput:
      toolOutputContent*: string
      toolCallId*: string
    of hitToolMalformed:
      malformedError*: string
      original*: ToolCallOriginal
      malformedToolCallId*: string
    of hitToolFailed:
      failedError*: string
      failedToolCallId*: string
      toolName*: string
    of hitToolReject:
      rejectToolCallId*: string
    of hitFileOutdated:
      outdatedFile*: string
    of hitFileUnreadable:
      unreadableFile*: string
      unreadableError*: string
    of hitRequestFailed:
      requestError*: string
    of hitNotification:
      notificationContent*: string

  History* = seq[HistoryItem]

# Basic validators - will be implemented fully in Phase 2
proc validateToolCallFunction*(node: JsonNode, field: string = ""): ValidationResult[ToolCallFunction] =
  # Simplified validation for now
  if node.kind != JObject:
    return invalid[ToolCallFunction](newValidationError(field, "object", $node.kind))
  result = valid(ToolCallFunction(name: "placeholder", arguments: "{}"))

proc validateToolCallRequest*(node: JsonNode, field: string = ""): ValidationResult[ToolCallRequest] =
  # Simplified validation for now
  if node.kind != JObject:
    return invalid[ToolCallRequest](newValidationError(field, "object", $node.kind))
  result = valid(ToolCallRequest(
    `type`: "function",
    function: ToolCallFunction(name: "placeholder", arguments: "{}"),
    toolCallId: "placeholder"
  ))

# History manipulation
proc addItem*[T: HistoryItem](history: var History, item: T) =
  history.add(item)

proc getLastItem*(history: History): Option[HistoryItem] =
  if history.len == 0:
    return none(HistoryItem)
  return some(history[^1])

proc getItemsByType*(history: History, itemType: HistoryItemType): seq[HistoryItem] =
  result = @[]
  for item in history:
    if item.itemType == itemType:
      result.add(item)

proc removeLastItem*(history: var History) =
  if history.len > 0:
    history.setLen(history.len - 1)

# Generate sequence IDs
var nextSequenceId {.threadvar.}: SequenceId

proc getNextSequenceId*(): SequenceId =
  if nextSequenceId == 0:
    nextSequenceId = 1
  result = nextSequenceId
  inc nextSequenceId

# Factory functions
proc newUserItem*(content: string): HistoryItem =
  result = HistoryItem(
    id: getNextSequenceId(),
    itemType: hitUser,
    userContent: content
  )

proc newAssistantItem*(content: string, toolCalls: Option[seq[ToolCallRequest]] = none(seq[ToolCallRequest])): HistoryItem =
  result = HistoryItem(
    id: getNextSequenceId(),
    itemType: hitAssistant,
    assistantContent: content,
    toolCalls: toolCalls
  )

proc newToolCallItem*(tool: ToolCallRequest): HistoryItem =
  result = HistoryItem(
    id: getNextSequenceId(),
    itemType: hitTool,
    tool: tool
  )

proc newToolOutputItem*(content: string, toolCallId: string): HistoryItem =
  result = HistoryItem(
    id: getNextSequenceId(),
    itemType: hitToolOutput,
    toolOutputContent: content,
    toolCallId: toolCallId
  )

proc newToolFailedItem*(error: string, toolCallId: string, toolName: string): HistoryItem =
  result = HistoryItem(
    id: getNextSequenceId(),
    itemType: hitToolFailed,
    failedError: error,
    failedToolCallId: toolCallId,
    toolName: toolName
  )