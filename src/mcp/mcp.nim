## MCP Worker Thread
##
## This module implements the MCP worker thread that manages communication
## with external MCP servers and coordinates tool execution.
##
## Key Features:
## - Dedicated worker thread for MCP server communication
## - Connection management and health monitoring
## - Tool execution from external MCP servers
## - Error handling and reconnection logic
## - Integration with existing threading architecture

import std/[options, json, tables, strformat, logging, os, locks]
import debby/pools
import ../core/[channels, database]
import ../types/[config, messages]
import ../core/config as configLoader
import protocol
import manager

type
  McpWorkerState* = enum
    mwsIdle, mwsProcessing, mwsShuttingDown

  McpWorkerInternal* = ref object
    channels*: ptr ThreadChannels
    state*: McpWorkerState
    manager*: McpManager

  McpWorker* = object
    thread*: Thread[ThreadParams]
    isRunning*: bool

var mcpWorkerInternal {.threadvar.}: McpWorkerInternal

# Shared state for cross-thread access (protected by lock)
var mcpStatusLock: Lock
var mcpCachedServerList: seq[string]
var mcpCachedServerInfo: JsonNode
var mcpCachedTools: Table[string, seq[ToolDefinition]]  # serverName -> tools
var mcpCachedClients: Table[string, McpClient]  # serverName -> client

initLock(mcpStatusLock)

proc updateCachedStatus(manager: McpManager) =
  ## Update the cached server status (called from MCP worker thread)
  withLock(mcpStatusLock):
    mcpCachedServerList = manager.listServers()
    mcpCachedServerInfo = manager.getAllServersInfo()

proc updateCachedTools(serverName: string, tools: seq[ToolDefinition]) =
  ## Update the cached tools for a server (called from MCP worker thread)
  withLock(mcpStatusLock):
    mcpCachedTools[serverName] = tools

proc updateCachedClient(serverName: string, client: McpClient) =
  ## Update the cached client for a server (called from MCP worker thread)
  withLock(mcpStatusLock):
    mcpCachedClients[serverName] = client

proc newMcpWorkerInternal*(channels: ptr ThreadChannels): McpWorkerInternal =
  ## Create a new MCP worker internal instance
  result = McpWorkerInternal(
    channels: channels,
    state: mwsIdle,
    manager: newMcpManager()
  )

proc initializeMcpServers*(worker: McpWorkerInternal, config: Config) =
  ## Initialize MCP servers from configuration
  {.gcsafe.}:
    if config.mcpServers.isNone():
      debug("No MCP servers configured")
      updateCachedStatus(worker.manager)
      return

    debug("Initializing MCP servers")

    for serverName, serverConfig in config.mcpServers.get():
      debug(fmt("Processing MCP server: {serverName}, enabled: {serverConfig.enabled}"))
      if serverConfig.enabled:
        try:
          worker.manager.addServer(serverName, serverConfig)
          debug(fmt("Added MCP server: {serverName}"))

          # Try to start the server
          debug(fmt("Starting MCP server: {serverName}"))
          worker.manager.startServer(serverName)

          let status = worker.manager.getServerStatus(serverName)
          debug(fmt("MCP server {serverName} status after start: {status}"))

          # Discover and cache tools and client if server started successfully
          if status == mssRunning:
            let client = worker.manager.getClient(serverName)
            if client.isSome():
              # Cache the client for cross-thread access
              updateCachedClient(serverName, client.get())

              var tools: seq[ToolDefinition] = @[]
              let mcpTools = client.get().listTools()
              for mcpTool in mcpTools:
                tools.add(convertMcpToolToOpenai(mcpTool))
              updateCachedTools(serverName, tools)
              debug(fmt("Discovered {tools.len} tools from MCP server: {serverName}"))
        except Exception as e:
          debug(fmt("Failed to initialize MCP server {serverName}: {e.msg}"))

    # Update cached status after initialization
    updateCachedStatus(worker.manager)

proc processMcpRequest*(worker: McpWorkerInternal, request: McpRequest) =
  ## Process an MCP request and send response
  {.gcsafe.}:
    try:
      case request.kind:
      of mcrkInitializeAll:
        # This is handled specially in mcpWorkerMain before processMcpRequest
        # Send ready response
        let response = McpResponse(kind: mcrrkReady, serverName: "all")
        worker.channels.sendMcpResponse(response)

      of mcrkInitialize:
        debug(fmt("Initializing MCP server: {request.serverName}"))
        let config = McpServerConfig(
          command: request.command,
          args: request.args,
          enabled: true,
          name: request.serverName
        )

        try:
          worker.manager.addServer(request.serverName, config)
          worker.manager.startServer(request.serverName)

          let success = worker.manager.isServerAvailable(request.serverName)
          let response = McpResponse(kind: mcrrkReady, serverName: request.serverName)
          worker.channels.sendMcpResponse(response)
          debug(fmt("MCP server {request.serverName} initialized: {success}"))
        except Exception as e:
          debug(fmt("Failed to initialize MCP server {request.serverName}: {e.msg}"))
          let response = McpResponse(kind: mcrrkError, serverName: request.serverName, error: e.msg)
          worker.channels.sendMcpResponse(response)

      of mcrkListTools:
        debug(fmt("Listing tools from MCP server: {request.serverName}"))
        let client = worker.manager.getClient(request.serverName)
        if client.isSome():
          let mcpTools = client.get().listTools()
          var tools: seq[ToolDefinition] = @[]
          for mcpTool in mcpTools:
            tools.add(convertMcpToolToOpenai(mcpTool))

          let toolsList = McpToolsList(
            serverName: request.serverName,
            tools: tools
          )
          let response = McpResponse(kind: mcrrkToolsList, toolsList: toolsList)
          worker.channels.sendMcpResponse(response)
          debug(fmt("Listed {tools.len} tools from {request.serverName}"))
        else:
          let response = McpResponse(kind: mcrrkError, serverName: request.serverName, error: "Server not found")
          worker.channels.sendMcpResponse(response)

      of mcrkCallTool:
        debug(fmt("Calling tool {request.toolName} on MCP server: {request.serverName}"))
        let client = worker.manager.getClient(request.serverName)
        if client.isSome():
          let result = client.get().callTool(request.toolName, request.arguments)
          let toolResult = McpToolResult(
            serverName: request.serverName,
            toolName: request.toolName,
            result: result
          )
          let response = McpResponse(kind: mcrrkToolResult, toolResult: toolResult)
          worker.channels.sendMcpResponse(response)
          debug(fmt("Tool {request.toolName} executed on {request.serverName}"))
        else:
          let response = McpResponse(kind: mcrrkError, serverName: request.serverName, error: "Server not found")
          worker.channels.sendMcpResponse(response)

      of mcrkShutdown:
        debug(fmt("Shutting down MCP server: {request.serverName}"))
        if request.serverName == "all":
          worker.manager.shutdownAll()
        else:
          worker.manager.shutdownServer(request.serverName)
        let response = McpResponse(kind: mcrrkReady, serverName: request.serverName)
        worker.channels.sendMcpResponse(response)

      of mcrkStatus:
        debug("Querying MCP server status")
        let serverList = worker.manager.listServers()
        let allServersInfo = worker.manager.getAllServersInfo()
        let statusInfo = McpStatusInfo(
          serverList: serverList,
          serverInfo: allServersInfo
        )
        let response = McpResponse(kind: mcrrkStatus, serverName: "status", statusInfo: statusInfo)
        worker.channels.sendMcpResponse(response)

    except Exception as e:
      debug(fmt("Error processing MCP request: {e.msg}"))
      let response = McpResponse(kind: mcrrkError, serverName: request.serverName, error: e.msg)
      worker.channels.sendMcpResponse(response)

proc mcpWorkerMain*(params: ThreadParams) {.thread.} =
  ## Main MCP worker thread function
  # NOTE: Don't modify logging state - the logging module is not thread-safe
  # Worker threads inherit logging settings from main thread
  discard # setLogFilter not thread safe

  {.gcsafe.}:
    try:
      # Initialize worker
      mcpWorkerInternal = newMcpWorkerInternal(params.channels)
      params.channels.incrementActiveThreads()

      debug("MCP worker thread started")

      # Load config and initialize servers
      let config = configLoader.loadConfig()
      mcpWorkerInternal.initializeMcpServers(config)

      # Send ready signal
      let readyResponse = McpResponse(kind: mcrrkReady, serverName: "worker")
      params.channels.sendMcpResponse(readyResponse)

      # Main message processing loop
      while not params.channels.isShutdownSignaled():
        mcpWorkerInternal.state = mwsIdle

        # Check for MCP requests
        let maybeRequest = params.channels.tryReceiveMcpRequest()

        if maybeRequest.isSome():
          let request = maybeRequest.get()
          mcpWorkerInternal.state = mwsProcessing

          # Handle special case: reinitialize all servers
          if request.kind == mcrkInitializeAll:
            let freshConfig = configLoader.loadConfig()
            mcpWorkerInternal.initializeMcpServers(freshConfig)

          # Process the request
          mcpWorkerInternal.processMcpRequest(request)

        else:
          # No incoming requests, perform maintenance
          mcpWorkerInternal.manager.performMaintenance()

          # Small sleep to prevent busy waiting
          sleep(10)

      # Shutdown sequence
      mcpWorkerInternal.state = mwsShuttingDown
      debug("MCP worker shutting down")

      # Shutdown all MCP servers
      mcpWorkerInternal.manager.shutdownAll()

    except Exception as e:
      debug(fmt("MCP worker error: {e.msg}"))

    finally:
      params.channels.decrementActiveThreads()
      debug("MCP worker thread stopped")

proc startMcpWorker*(channels: ptr ThreadChannels, level: Level, dump: bool = false, database: DatabaseBackend = nil, pool: Pool = nil): McpWorker =
  ## Start the MCP worker thread
  result.isRunning = true
  var params = new(ThreadParams)
  params.channels = channels
  params.level = level  
  params.dump = dump
  params.database = database
  params.pool = pool
  createThread(result.thread, mcpWorkerMain, params)

proc stopMcpWorker*(worker: var McpWorker) =
  ## Stop the MCP worker thread
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false

# Public API for MCP operations

proc getMcpTools*(serverName: string): seq[ToolDefinition] =
  ## Get available tools from an MCP server (thread-safe via cache)
  {.gcsafe.}:
    # Try cached version first (works from any thread)
    withLock(mcpStatusLock):
      if serverName in mcpCachedTools:
        return mcpCachedTools[serverName]

    # If called from MCP worker thread, fetch directly
    if mcpWorkerInternal != nil:
      let client = mcpWorkerInternal.manager.getClient(serverName)
      if client.isSome():
        var tools: seq[ToolDefinition] = @[]
        let mcpTools = client.get().listTools()
        for mcpTool in mcpTools:
          tools.add(convertMcpToolToOpenai(mcpTool))

        # Update cache
        updateCachedTools(serverName, tools)
        return tools

    return @[]

proc callMcpTool*(serverName: string, toolName: string, arguments: JsonNode): JsonNode =
  ## Call a tool on an MCP server (thread-safe via cached client)
  {.gcsafe.}:
    # First try cached client (works from any thread)
    var cachedClient: McpClient
    var foundClient = false

    withLock(mcpStatusLock):
      if serverName in mcpCachedClients:
        cachedClient = mcpCachedClients[serverName]
        foundClient = true

    if foundClient:
      return cachedClient.callTool(toolName, arguments)

    # Fallback: if called from MCP worker thread, try direct access
    if mcpWorkerInternal != nil:
      let client = mcpWorkerInternal.manager.getClient(serverName)
      if client.isSome():
        return client.get().callTool(toolName, arguments)
      else:
        return %*{"error": fmt("MCP server {serverName} not available")}
    else:
      return %*{"error": fmt("MCP server {serverName} not available (no cached client)")}

proc isMcpServerAvailable*(serverName: string): bool =
  ## Check if an MCP server is available (thread-safe via cache)
  {.gcsafe.}:
    # First check cached server info (works from any thread)
    withLock(mcpStatusLock):
      if mcpCachedServerInfo != nil:
        for serverInfo in mcpCachedServerInfo:
          if serverInfo.hasKey("name") and serverInfo["name"].getStr() == serverName:
            if serverInfo.hasKey("status"):
              let status = serverInfo["status"].getStr()
              return status == "mssRunning"

    # If called from MCP worker thread, check directly
    if mcpWorkerInternal != nil:
      return mcpWorkerInternal.manager.isServerAvailable(serverName)

    return false

proc listMcpServers*(): seq[string] =
  ## List all configured MCP servers (thread-safe)
  {.gcsafe.}:
    withLock(mcpStatusLock):
      return mcpCachedServerList

proc getMcpAllServersInfo*(): JsonNode =
  ## Get all server info as JSON (thread-safe)
  {.gcsafe.}:
    withLock(mcpStatusLock):
      return mcpCachedServerInfo

proc getMcpManager*(): McpManager =
  ## Get the MCP manager instance (for status commands)
  ## NOTE: This only works from MCP worker thread
  {.gcsafe.}:
    if mcpWorkerInternal != nil:
      return mcpWorkerInternal.manager
    return nil