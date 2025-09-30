## MCP Protocol Implementation
##
## This module implements the Model Context Protocol (MCP) communication layer
## for Niffler, providing JSON-RPC 2.0 client functionality for MCP servers.
##
## Key Features:
## - JSON-RPC 2.0 client implementation
## - MCP-specific message types and serialization
## - Connection management and error handling
## - Tool discovery and execution protocols
##
## Protocol Support:
## - Server initialization and capabilities negotiation
## - Tool listing and schema retrieval
## - Tool execution with result handling
## - Connection lifecycle management

import std/[options, json, osproc, streams, os, tables, strtabs, strformat, logging]
import ../types/[config, messages]

type
  # MCP Error types
  McpError* = object
    code*: int
    message*: string
    data*: Option[JsonNode]

  # MCP Tool schema types
  McpToolInputSchema* = object
    `type`*: string
    properties*: JsonNode
    required*: seq[string]

  McpToolOutputSchema* = object
    `type`*: string
    description*: Option[string]

  McpTool* = object
    name*: string
    description*: string
    inputSchema*: McpToolInputSchema
    outputSchema*: Option[McpToolOutputSchema]

  # MCP Message types
  McpRequestKind* = enum
    mcrkInitialize = "initialize"
    mcrkListTools = "tools/list"
    mcrkCallTool = "tools/call"
    mcrkShutdown = "shutdown"

  McpResponseKind* = enum
    mcrrkSuccess = "success"
    mcrrkError = "error"
    mcrrkToolResult = "tool_result"

  # Initialize message types
  McpInitializeParams* = object
    protocolVersion*: string
    capabilities*: JsonNode
    clientInfo*: JsonNode

  McpInitializeResult* = object
    protocolVersion*: string
    capabilities*: JsonNode
    serverInfo*: JsonNode

  # Tool call message types
  McpCallToolParams* = object
    name*: string
    arguments*: JsonNode

  McpCallToolResult* = object
    content*: seq[JsonNode]
    isError*: bool

  # Core MCP protocol message types (JSON-RPC level)
  McpJsonRequest* = object
    jsonrpc*: string  # Always "2.0"
    id*: string
    methodType*: string  # Renamed from 'method' to avoid Nim keyword conflict
    params*: JsonNode

  McpJsonResponse* = object
    jsonrpc*: string  # Always "2.0"
    id*: string
    result*: Option[JsonNode]
    error*: Option[McpError]

  # MCP Client types
  McpClient* = ref object
    process: Process
    inputStream: Stream
    outputStream: Stream
    serverName: string
    requestIdCounter: int
    connected: bool
    capabilities: JsonNode

# MCP Protocol constants
const
  MCP_PROTOCOL_VERSION* = "2024-11-05"
  JSON_RPC_VERSION* = "2.0"

# Helper procedures

proc newMcpError*(code: int, message: string, data: Option[JsonNode] = none(JsonNode)): McpError =
  ## Create a new MCP error
  McpError(
    code: code,
    message: message,
    data: data
  )

proc newMcpRequest*(methodType: McpRequestKind, params: JsonNode, id: string): McpJsonRequest =
  ## Create a new MCP request
  McpJsonRequest(
    jsonrpc: JSON_RPC_VERSION,
    id: id,
    methodType: $methodType,
    params: params
  )

proc newMcpJsonResponse*(id: string, resultParam: Option[JsonNode], error: Option[McpError] = none(McpError)): McpJsonResponse =
  ## Create a new MCP JSON response
  McpJsonResponse(
    jsonrpc: JSON_RPC_VERSION,
    id: id,
    result: resultParam,
    error: error
  )

proc newMcpJsonResponseSuccess*(id: string, resultParam: JsonNode): McpJsonResponse =
  ## Create a successful MCP JSON response
  McpJsonResponse(
    jsonrpc: JSON_RPC_VERSION,
    id: id,
    result: some(resultParam),
    error: none(McpError)
  )

proc newMcpJsonResponseError*(id: string, error: McpError): McpJsonResponse =
  ## Create an error MCP JSON response
  McpJsonResponse(
    jsonrpc: JSON_RPC_VERSION,
    id: id,
    result: none(JsonNode),
    error: some(error)
  )

# Conversion procedures for JSON serialization

proc `%`*(error: McpError): JsonNode =
  ## Convert McpError to JSON
  result = newJObject()
  result["code"] = newJInt(error.code)
  result["message"] = newJString(error.message)
  if error.data.isSome():
    result["data"] = error.data.get()

proc `%`*(request: McpJsonRequest): JsonNode =
  ## Convert McpJsonRequest to JSON
  result = newJObject()
  result["jsonrpc"] = newJString(request.jsonrpc)
  result["id"] = newJString(request.id)
  result["method"] = newJString(request.methodType)
  result["params"] = request.params

proc parseMcpError*(node: JsonNode): McpError =
  ## Parse JSON node to McpError
  result.code = node["code"].getInt()
  result.message = node["message"].getStr()
  if node.hasKey("data"):
    result.data = some(node["data"])

proc parseMcpJsonResponse*(node: JsonNode): McpJsonResponse =
  ## Parse JSON node to McpJsonResponse
  result.jsonrpc = node["jsonrpc"].getStr()
  result.id = node["id"].getStr()

  if node.hasKey("result"):
    result.result = some(node["result"])

  if node.hasKey("error"):
    result.error = some(parseMcpError(node["error"]))

proc parseMcpTool*(node: JsonNode): McpTool =
  ## Parse JSON node to McpTool
  result.name = node["name"].getStr()
  result.description = node["description"].getStr()

  let inputSchema = node["inputSchema"]
  result.inputSchema.`type` = inputSchema["type"].getStr()
  result.inputSchema.properties = inputSchema["properties"]

  if inputSchema.hasKey("required"):
    result.inputSchema.required = @[]
    for reqNode in inputSchema["required"]:
      result.inputSchema.required.add(reqNode.getStr())

  if node.hasKey("outputSchema"):
    let outputSchema = node["outputSchema"]
    result.outputSchema = some(McpToolOutputSchema(
      `type`: outputSchema["type"].getStr()
    ))
    if outputSchema.hasKey("description"):
      result.outputSchema.get().description = some(outputSchema["description"].getStr())

# MCP Client implementation

proc newMcpClient*(serverName: string): McpClient =
  ## Create a new MCP client instance
  McpClient(
    serverName: serverName,
    requestIdCounter: 0,
    connected: false,
    capabilities: newJObject()
  )

proc generateRequestId*(client: McpClient): string =
  ## Generate a unique request ID
  inc client.requestIdCounter
  return $client.requestIdCounter

proc startMcpProcess*(client: McpClient, config: McpServerConfig) {.gcsafe.} =
  ## Start the MCP server process
  let args = if config.args.isSome(): config.args.get() else: @[]

  # Set up environment variables
  var envTable: StringTableRef = nil
  if config.env.isSome():
    envTable = newStringTable()
    for key, value in config.env.get():
      envTable[key] = value

  # Set working directory
  let workingDir = if config.workingDir.isSome(): config.workingDir.get() else: getCurrentDir()

  try:
    # Don't redirect stderr to stdout - MCP servers use stderr for logging
    # and stdout for JSON-RPC messages
    client.process = osproc.startProcess(
      command = config.command,
      args = args,
      workingDir = workingDir,
      env = envTable,
      options = {poUsePath}
    )

    client.inputStream = client.process.outputStream()
    client.outputStream = client.process.inputStream()
    client.connected = true

  except Exception as e:
    raise newException(Exception, fmt("Failed to start MCP server {client.serverName}: {e.msg}"))

proc sendRequest*(client: McpClient, request: McpJsonRequest): string =
  ## Send a request to the MCP server
  if not client.connected:
    raise newException(Exception, fmt("MCP client {client.serverName} not connected"))

  let jsonRequest = %request
  let line = $jsonRequest & "\n"

  try:
    client.outputStream.write(line)
    client.outputStream.flush()
    return request.id
  except Exception as e:
    raise newException(Exception, fmt("Failed to send request to MCP server {client.serverName}: {e.msg}"))

proc readResponse*(client: McpClient): McpJsonResponse =
  ## Read a response from the MCP server
  if not client.connected:
    raise newException(Exception, fmt("MCP client {client.serverName} not connected"))

  try:
    let line = client.inputStream.readLine()
    let jsonNode = parseJson(line)
    return parseMcpJsonResponse(jsonNode)
  except Exception as e:
    raise newException(Exception, fmt("Failed to read response from MCP server {client.serverName}: {e.msg}"))

proc sendRequestAndWait*(client: McpClient, request: McpJsonRequest): McpJsonResponse =
  ## Send a request and wait for the response
  discard client.sendRequest(request)
  return client.readResponse()

proc initialize*(client: McpClient): bool {.gcsafe.} =
  ## Initialize the MCP server connection
  try:
    let params = %*{
      "protocolVersion": MCP_PROTOCOL_VERSION,
      "capabilities": {
        "roots": {
          "listChanged": true
        },
        "sampling": {}
      },
      "clientInfo": {
        "name": "niffler",
        "version": "0.4.0"
      }
    }

    let request = newMcpRequest(mcrkInitialize, params, client.generateRequestId())
    let response = client.sendRequestAndWait(request)

    if response.error.isSome():
      let error = response.error.get()
      debug(fmt("MCP initialization error for {client.serverName}: {error.message}"))
      return false

    if response.result.isSome():
      let initResult = response.result.get()
      client.capabilities = initResult["capabilities"]
      return true

    return false

  except Exception as e:
    debug(fmt("MCP initialization failed for {client.serverName}: {e.msg}"))
    return false

proc listTools*(client: McpClient): seq[McpTool] {.gcsafe.} =
  ## List available tools from the MCP server
  try:
    let params = newJObject()
    let request = newMcpRequest(mcrkListTools, params, client.generateRequestId())
    let response = client.sendRequestAndWait(request)

    if response.error.isSome():
      let error = response.error.get()
      debug(fmt("MCP list tools error for {client.serverName}: {error.message}"))
      return @[]

    if response.result.isSome():
      let resultData = response.result.get()
      var tools: seq[McpTool] = @[]
      if resultData.hasKey("tools"):
        for toolNode in resultData["tools"]:
          tools.add(parseMcpTool(toolNode))
      return tools

    return @[]

  except Exception as e:
    debug(fmt("MCP list tools failed for {client.serverName}: {e.msg}"))
    return @[]

proc callTool*(client: McpClient, toolName: string, arguments: JsonNode): JsonNode {.gcsafe.} =
  ## Call a tool on the MCP server
  try:
    let params = %*{
      "name": toolName,
      "arguments": arguments
    }

    let request = newMcpRequest(mcrkCallTool, params, client.generateRequestId())
    let response = client.sendRequestAndWait(request)

    if response.error.isSome():
      let error = response.error.get()
      return %*{"error": error.message, "code": error.code}

    if response.result.isSome():
      return response.result.get()

    return newJObject()

  except Exception as e:
    return %*{"error": fmt("Tool call failed: {e.msg}")}

proc shutdown*(client: McpClient): bool {.gcsafe.} =
  ## Shutdown the MCP server connection
  try:
    let params = newJObject()
    let request = newMcpRequest(mcrkShutdown, params, client.generateRequestId())
    let response = client.sendRequestAndWait(request)

    return response.error.isNone()

  except Exception as e:
    debug(fmt("MCP shutdown failed for {client.serverName}: {e.msg}"))
    return false

proc close*(client: McpClient) {.gcsafe.} =
  ## Close the MCP client connection and clean up resources
  try:
    if client.connected:
      discard client.shutdown()
      client.connected = false

    if client.process != nil:
      client.process.close()

  except Exception as e:
    debug(fmt("Error closing MCP client {client.serverName}: {e.msg}"))

proc isConnected*(client: McpClient): bool =
  ## Check if the MCP client is connected
  client.connected

proc getCapabilities*(client: McpClient): JsonNode =
  ## Get the server capabilities
  client.capabilities

# Utility procedures

proc convertMcpToolToOpenai*(mcpTool: McpTool): ToolDefinition {.gcsafe.} =
  ## Convert MCP tool schema to OpenAI function calling format
  let parameters = %*{
    "type": "object",
    "properties": mcpTool.inputSchema.properties
  }

  if mcpTool.inputSchema.required.len > 0:
    parameters["required"] = %(mcpTool.inputSchema.required)

  ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: mcpTool.name,
      description: mcpTool.description,
      parameters: parameters
    )
  )

proc convertOpenaiArgsToMcp*(openaiArgs: JsonNode): JsonNode {.gcsafe.} =
  ## Convert OpenAI tool arguments to MCP format
  # For now, we assume the argument formats are compatible
  # This may need enhancement for complex schema differences
  openaiArgs