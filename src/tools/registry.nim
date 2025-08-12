import std/[tables, options, json]
import ../types/[tools, messages]

type
  ToolRegistry* = object
    tools*: Table[string, ToolDef]

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

proc getToolNames*(registry: ToolRegistry): seq[string] =
  result = @[]
  for name in registry.tools.keys:
    result.add(name)

proc getToolDescriptions*(registry: ToolRegistry): seq[string] =
  result = @[]
  for tool in registry.tools.values:
    result.add(tool.name & ": " & tool.description)

proc validateToolCall*(registry: ToolRegistry, toolCall: tools.ToolCall): void =
  if not registry.hasTool(toolCall.name):
    raise newToolValidationError(toolCall.name, "name", "valid tool name", toolCall.name)
  
  let toolOpt = registry.getTool(toolCall.name)
  if toolOpt.isNone:
    raise newToolValidationError(toolCall.name, "name", "registered tool", toolCall.name)
  
  # Basic validation - individual tools will implement specific validation
  if toolCall.arguments.kind != JObject:
    raise newToolValidationError(toolCall.name, "arguments", "object", $toolCall.arguments.kind)

# Global registry instance
var globalToolRegistry* {.threadvar.}: ToolRegistry

proc getGlobalToolRegistry*(): ptr ToolRegistry =
  if globalToolRegistry.tools.len == 0:
    globalToolRegistry = newToolRegistry()
  return addr globalToolRegistry

proc initializeGlobalToolRegistry*() =
  globalToolRegistry = newToolRegistry()