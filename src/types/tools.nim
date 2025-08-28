## Tool System Type Definitions
##
## This module defines all types related to the tool execution system,
## including tool calls, results, errors, and execution context.
##
## Key Type Categories:
## - Tool error types (validation, execution, timeout errors)
## - Tool execution types (calls, results, responses)
## - Thread communication types for tool worker coordination
##
## Error Hierarchy:
## - ToolError (base): Generic tool-related errors
## - ToolExecutionError: Command execution failures with exit codes
## - ToolValidationError: Parameter validation failures
## - ToolTimeoutError: Tool execution timeouts
## - ToolNotFoundError: Unknown tool requests
##
## Design Decisions:
## - Exception-based error handling with detailed error types
## - Separate tool call types for internal execution vs LLM communication
## - Result wrapper types for consistent error handling
## - Thread-safe types for worker communication

import std/[options, json, strutils]
import messages

type
  ToolError* = ref object of CatchableError
    toolName*: string
    details*: string

  ToolExecutionError* = ref object of ToolError
    exitCode*: int
    output*: string

  ToolValidationError* = ref object of ToolError
    field*: string
    expected*: string
    actual*: string

  ToolTimeoutError* = ref object of ToolError
    timeoutMs*: int

  ToolPermissionError* = ref object of ToolError
    path*: string

  ToolCall* = object
    id*: string
    name*: string
    arguments*: JsonNode

proc newToolError*(toolName, message: string): ToolError =
  result = ToolError(msg: message)
  result.toolName = toolName

proc newToolExecutionError*(toolName, message: string, exitCode: int, output: string): ToolExecutionError =
  result = ToolExecutionError(msg: message)
  result.toolName = toolName
  result.exitCode = exitCode
  result.output = output

proc newToolValidationError*(toolName, field, expected, actual: string): ToolValidationError =
  result = ToolValidationError(msg: "Validation failed for field '" & field & "': expected " & expected & ", got " & actual)
  result.toolName = toolName
  result.field = field
  result.expected = expected
  result.actual = actual

proc newToolTimeoutError*(toolName: string, timeoutMs: int): ToolTimeoutError =
  result = ToolTimeoutError(msg: "Tool execution timed out after " & $timeoutMs & "ms")
  result.toolName = toolName
  result.timeoutMs = timeoutMs

proc newToolPermissionError*(toolName, path: string): ToolPermissionError =
  result = ToolPermissionError(msg: "Permission denied for path: " & path)
  result.toolName = toolName
  result.path = path



proc newToolResult*(output: string): ToolResult =
  ToolResult(id: "", output: output, error: none(string))

proc newToolErrorResult*(error: string): ToolResult =
  ToolResult(id: "", output: "", error: some(error))

# Convert between tool calls and messages
proc toToolCall*(toolCall: ToolCall): ToolCall =
  toolCall

proc fromToolCall*(toolCall: ToolCall): ToolCall =
  toolCall

proc toMessage*(toolResult: ToolResult, toolCallId: string): Message =
  Message(
    role: mrTool,
    content: toolResult.output,
    toolResults: some(@[ToolResult(id: toolCallId, output: toolResult.output, error: toolResult.error)])
  )

# Helper for JSON argument validation
proc validateArgs*(args: JsonNode, requiredFields: seq[string]) =
  for field in requiredFields:
    if not args.hasKey(field):
      raise newToolValidationError("unknown", field, "required field", "missing")

proc getArgStr*(args: JsonNode, field: string): string =
  if not args.hasKey(field):
    raise newToolValidationError("unknown", field, "string", "missing")
  let node = args[field]
  if node.kind != JString:
    raise newToolValidationError("unknown", field, "string", $node.kind)
  return node.getStr()

proc getArgInt*(args: JsonNode, field: string): int =
  if not args.hasKey(field):
    raise newToolValidationError("unknown", field, "int", "missing")
  let node = args[field]
  case node.kind:
  of JInt:
    return node.getInt()
  of JString:
    # Try to parse string as integer (LLMs often send numbers as strings)
    try:
      return parseInt(node.getStr())
    except ValueError:
      raise newToolValidationError("unknown", field, "int", "invalid string: " & node.getStr())
  else:
    raise newToolValidationError("unknown", field, "int", $node.kind)

proc getArgBool*(args: JsonNode, field: string): bool =
  if not args.hasKey(field):
    raise newToolValidationError("unknown", field, "bool", "missing")
  let node = args[field]
  if node.kind != JBool:
    raise newToolValidationError("unknown", field, "bool", $node.kind)
  return node.getBool()

proc getOptArgStr*(args: JsonNode, field: string, default: string = ""): string =
  if not args.hasKey(field):
    return default
  let node = args[field]
  if node.kind != JString:
    raise newToolValidationError("unknown", field, "string", $node.kind)
  return node.getStr()

proc getOptArgInt*(args: JsonNode, field: string, default: int = 0): int =
  if not args.hasKey(field):
    return default
  let node = args[field]
  case node.kind:
  of JInt:
    return node.getInt()
  of JString:
    # Try to parse string as integer (LLMs often send numbers as strings)
    try:
      return parseInt(node.getStr())
    except ValueError:
      raise newToolValidationError("unknown", field, "int", "invalid string: " & node.getStr())
  else:
    raise newToolValidationError("unknown", field, "int", $node.kind)