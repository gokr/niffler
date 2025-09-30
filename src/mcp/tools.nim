## MCP Tool Integration
##
## This module implements the bridge between MCP tools and Niffler's
## tool registry system, enabling seamless integration of external MCP tools.
##
## Key Features:
## - Dynamic tool discovery from MCP servers
## - Tool schema conversion (MCP ↔ OpenAI format)
## - Execution proxy for MCP tool calls
## - Integration with existing tool registry
##
## Integration Strategy:
## - MCP tools appear as regular tools in the registry
## - Tool execution is delegated to appropriate MCP servers
## - Schema conversion ensures compatibility with OpenAI function calling
## - Error handling maintains Niffler's tool execution patterns

import std/[options, json, tables, strutils, strformat, logging]
import ../types/[config, messages]
import ../core/config as configLoader
import protocol
import mcp

type
  McpToolKind* = enum
    mtkStandard, mtkList, mtkRead, mtkEdit, mtkCreate

  McpToolWrapper* = object
    name*: string
    description*: string
    serverName*: string
    mcpTool*: McpTool
    toolKind*: McpToolKind
    requiresConfirmation*: bool

import std/locks

# Shared state for cross-thread access (protected by lock)
var mcpToolsLock: Lock
var mcpTools: Table[string, McpToolWrapper]
var mcpToolsInitialized: bool

initLock(mcpToolsLock)

proc newMcpToolWrapper*(serverName: string, mcpTool: McpTool): McpToolWrapper =
  ## Create a new MCP tool wrapper
  let toolKind =
    if mcpTool.name.startsWith("list_"): mtkList
    elif mcpTool.name.startsWith("read_"): mtkRead
    elif mcpTool.name.startsWith("edit_"): mtkEdit
    elif mcpTool.name.startsWith("create_"): mtkCreate
    else: mtkStandard

  let requiresConfirmation = toolKind in [mtkEdit, mtkCreate]

  McpToolWrapper(
    name: mcpTool.name,
    description: mcpTool.description,
    serverName: serverName,
    mcpTool: mcpTool,
    toolKind: toolKind,
    requiresConfirmation: requiresConfirmation
  )

proc convertMcpToolRegistry*(wrapper: McpToolWrapper): ToolDefinition {.gcsafe.} =
  ## Convert MCP tool wrapper to OpenAI tool definition
  let parameters = %*{
    "type": "object",
    "properties": wrapper.mcpTool.inputSchema.properties
  }

  if wrapper.mcpTool.inputSchema.required.len > 0:
    parameters["required"] = %(wrapper.mcpTool.inputSchema.required)

  ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: wrapper.name,
      description: wrapper.description,
      parameters: parameters
    )
  )

proc discoverMcpTools*() =
  ## Discover and register tools from all available MCP servers (called once at initialization)
  {.gcsafe.}:
    withLock(mcpToolsLock):
      if mcpToolsInitialized:
        return

      let servers = listMcpServers()
      let logger = newConsoleLogger()
      logger.log(lvlDebug, fmt("Discovering MCP tools from {servers.len} servers: {servers}"))

      for serverName in servers:
        logger.log(lvlDebug, fmt("Checking MCP server: {serverName}, available: {isMcpServerAvailable(serverName)}"))
        if isMcpServerAvailable(serverName):
          try:
            let config = configLoader.loadConfig()
            if config.mcpServers.isSome():
              let serverConfigs = config.mcpServers.get()
              if serverName notin serverConfigs:
                logger.log(lvlDebug, fmt("Server {serverName} not in config"))
                continue
              let serverConfig = serverConfigs[serverName]
              if not serverConfig.enabled:
                logger.log(lvlDebug, fmt("Server {serverName} not enabled"))
                continue

            let discoveredTools = getMcpTools(serverName)
            logger.log(lvlDebug, fmt("Got {discoveredTools.len} tools from {serverName}"))
            for mcpTool in discoveredTools:
              let wrapper = newMcpToolWrapper(serverName, McpTool(
                name: mcpTool.function.name,
                description: mcpTool.function.description,
                inputSchema: McpToolInputSchema(
                  `type`: mcpTool.function.parameters["type"].getStr(),
                  properties: mcpTool.function.parameters["properties"],
                  required: @[]
                )
              ))
              mcpTools[wrapper.name] = wrapper

          except KeyError as e:
            let logger = newConsoleLogger()
            logger.log(lvlError, fmt("MCP server {serverName} not found in config: {e.msg}"))
          except Exception as e:
            let logger = newConsoleLogger()
            logger.log(lvlError, fmt("Failed to discover tools from MCP server {serverName}: {e.msg}"))

      mcpToolsInitialized = true

proc executeMcpTool*(toolName: string, args: JsonNode): string =
  ## Execute an MCP tool and return the result
  {.gcsafe.}:
    var wrapper: McpToolWrapper
    var found = false

    withLock(mcpToolsLock):
      if toolName in mcpTools:
        wrapper = mcpTools[toolName]
        found = true

    if not found:
      return fmt("Error: MCP tool {toolName} not found")

    try:
      if not isMcpServerAvailable(wrapper.serverName):
        return fmt("Error: MCP server {wrapper.serverName} is not available")

      let toolResult = callMcpTool(wrapper.serverName, toolName, args)

      # Check for errors in the result
      if toolResult.hasKey("error"):
        return fmt("Error: {toolResult[\"error\"].getStr()}")
      elif toolResult.hasKey("content"):
        # Format content for display
        let content = toolResult["content"]
        return $content
      else:
        return $toolResult

    except Exception as e:
      return fmt("Error executing MCP tool {toolName}: {e.msg}")

proc registerBuiltinMcpTools*() {.gcsafe.} =
  ## Register built-in MCP tools with the tool registry
  # This is a placeholder for any built-in MCP tools
  # Currently, all MCP tools are dynamic and discovered at runtime
  discard

proc getMcpToolSchemas*(): seq[ToolDefinition] =
  ## Get all MCP tool schemas for OpenAI function calling
  {.gcsafe.}:
    result = @[]
    withLock(mcpToolsLock):
      for wrapper in mcpTools.values:
        result.add(convertMcpToolRegistry(wrapper))

proc getMcpToolNames*(): seq[string] =
  ## Get all MCP tool names
  {.gcsafe.}:
    result = @[]
    withLock(mcpToolsLock):
      for name in mcpTools.keys:
        result.add(name)

proc getMcpToolDescriptions*(): string =
  ## Get comma-separated list of MCP tools with descriptions
  {.gcsafe.}:
    var descriptions: seq[string] = @[]
    withLock(mcpToolsLock):
      for wrapper in mcpTools.values:
        descriptions.add(fmt("{wrapper.name} (MCP) - {wrapper.description}"))

    if descriptions.len > 0:
      return descriptions.join(", ")
    else:
      return ""

proc isMcpTool*(toolName: string): bool =
  ## Check if a tool name corresponds to an MCP tool
  {.gcsafe.}:
    withLock(mcpToolsLock):
      return toolName in mcpTools

proc getMcpToolServer*(toolName: string): Option[string] =
  ## Get the server name for an MCP tool
  {.gcsafe.}:
    withLock(mcpToolsLock):
      if toolName in mcpTools:
        return some(mcpTools[toolName].serverName)
    return none(string)

proc doesMcpToolRequireConfirmation*(toolName: string): bool =
  ## Check if an MCP tool requires user confirmation
  {.gcsafe.}:
    withLock(mcpToolsLock):
      if toolName in mcpTools:
        return mcpTools[toolName].requiresConfirmation
    return false

proc getMcpToolInfo*(toolName: string): JsonNode =
  ## Get detailed information about an MCP tool
  {.gcsafe.}:
    result = newJObject()

    withLock(mcpToolsLock):
      if toolName in mcpTools:
        let wrapper = mcpTools[toolName]
        result["name"] = newJString(wrapper.name)
        result["description"] = newJString(wrapper.description)
        result["serverName"] = newJString(wrapper.serverName)
        result["toolKind"] = newJString($wrapper.toolKind)
        result["requiresConfirmation"] = newJBool(wrapper.requiresConfirmation)
        result["inputSchema"] = wrapper.mcpTool.inputSchema.properties
      else:
        result["error"] = newJString(fmt("MCP tool {toolName} not found"))

proc getAllMcpToolsInfo*(): JsonNode =
  ## Get information about all MCP tools
  {.gcsafe.}:
    result = newJArray()

    withLock(mcpToolsLock):
      for name in mcpTools.keys:
        result.add(getMcpToolInfo(name))

# Tool execution functions that integrate with Niffler's tool registry

proc executeMcpBashTool*(args: JsonNode): string {.gcsafe.} =
  ## Execute MCP-based bash command tool
  return executeMcpTool("bash", args)

proc executeMcpReadTool*(args: JsonNode): string {.gcsafe.} =
  ## Execute MCP-based file read tool
  return executeMcpTool("read", args)

proc executeMcpListTool*(args: JsonNode): string {.gcsafe.} =
  ## Execute MCP-based directory listing tool
  return executeMcpTool("list", args)

proc executeMcpEditTool*(args: JsonNode): string {.gcsafe.} =
  ## Execute MCP-based file editing tool
  return executeMcpTool("edit", args)

proc executeMcpCreateTool*(args: JsonNode): string {.gcsafe.} =
  ## Execute MCP-based file creation tool
  return executeMcpTool("create", args)

proc executeMcpFetchTool*(args: JsonNode): string {.gcsafe.} =
  ## Execute MCP-based web fetching tool
  return executeMcpTool("fetch", args)

# Utility procedures

proc getMcpToolsCount*(): int =
  ## Get the number of discovered MCP tools
  {.gcsafe.}:
    withLock(mcpToolsLock):
      return mcpTools.len

proc clearMcpToolsCache*() =
  ## Clear the MCP tools cache to force rediscovery
  {.gcsafe.}:
    withLock(mcpToolsLock):
      mcpTools.clear()
      mcpToolsInitialized = false

proc refreshMcpTools*() =
  ## Refresh MCP tools by clearing cache and rediscovering
  {.gcsafe.}:
    clearMcpToolsCache()
    discoverMcpTools()

# Integration with existing tool registry

proc integrateMcpToolsWithRegistry*() =
  ## Register MCP tools with the existing tool registry
  {.gcsafe.}:
    discoverMcpTools()

    # This function would modify the tool registry to include MCP tools
    # For now, this is a placeholder - actual integration happens at runtime
    # through the API worker's tool selection logic

    let toolCount = getMcpToolsCount()
    let logger = newConsoleLogger()
    logger.log(lvlInfo, fmt("Discovered {toolCount} MCP tools for integration"))

proc isMcpToolAvailable*(toolName: string): bool =
  ## Check if a specific MCP tool is available
  {.gcsafe.}:
    var wrapper: McpToolWrapper
    var found = false

    withLock(mcpToolsLock):
      if toolName in mcpTools:
        wrapper = mcpTools[toolName]
        found = true

    if not found:
      return false

    return isMcpServerAvailable(wrapper.serverName)