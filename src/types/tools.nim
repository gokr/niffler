import std/[options, json, tables]
import ../types/messages

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

  ToolArguments* = object of RootObj

  ToolCall* = object
    id*: string
    name*: string
    arguments*: JsonNode

  ToolDef* = object of RootObj
    name*: string
    description*: string

  ToolInterface* = concept t
    t is ToolDef
    t.validate is proc(args: JsonNode): void
    t.execute is proc(args: JsonNode): string

  ToolRegistry* = object
    tools*: Table[string, ToolDef]

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

proc newToolRegistry*(): ToolRegistry =
  ToolRegistry(tools: initTable[string, ToolDef]())

proc register*(registry: var ToolRegistry, tool: ToolDef) =
  registry.tools[tool.name] = tool

proc getTool*(registry: ToolRegistry, name: string): Option[ToolDef] =
  if name in registry.tools:
    return some(registry.tools[name])
  return none(ToolDef)

proc listTools*(registry: ToolRegistry): seq[string] =
  result = @[]
  for name in registry.tools.keys:
    result.add(name)

proc hasTool*(registry: ToolRegistry, name: string): bool =
  name in registry.tools

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
  if node.kind != JInt:
    raise newToolValidationError("unknown", field, "int", $node.kind)
  return node.getInt()

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
  if node.kind != JInt:
    raise newToolValidationError("unknown", field, "int", $node.kind)
  return node.getInt()