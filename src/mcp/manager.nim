## MCP Server Manager
##
## This module implements the MCP server management system that handles
## the lifecycle of multiple MCP server connections.
##
## Key Features:
## - MCP server lifecycle management (start/stop/restart)
## - Connection pooling and health monitoring
## - Error handling and automatic reconnection
## - Resource cleanup and shutdown handling
##
## Manager Responsibilities:
## - Track active MCP server connections
## - Handle server failures and reconnections
## - Provide access to MCP clients by name
## - Manage server-specific configuration

import std/[options, json, tables, logging, times, monotimes, strformat, sequtils, os]
import ../types/config
import protocol

type
  McpServerStatus* = enum
    mssStopped, mssStarting, mssRunning, mssStopping, mssError

  McpServerInstance* = ref object
    name*: string
    config*: McpServerConfig
    client*: Option[McpClient]
    status*: McpServerStatus
    lastActivity*: MonoTime
    errorCount*: int
    restartCount*: int
    logger*: Logger

  McpManager* = ref object
    servers*: Table[string, McpServerInstance]
    logger*: Logger

proc newMcpServerInstance*(name: string, config: McpServerConfig): McpServerInstance =
  ## Create a new MCP server instance
  McpServerInstance(
    name: name,
    config: config,
    client: none(McpClient),
    status: mssStopped,
    lastActivity: getMonoTime(),
    errorCount: 0,
    restartCount: 0,
    logger: newConsoleLogger()
  )

proc newMcpManager*(): McpManager =
  ## Create a new MCP manager instance
  McpManager(
    servers: initTable[string, McpServerInstance](),
    logger: newConsoleLogger()
  )

proc addServer*(manager: McpManager, name: string, config: McpServerConfig) {.gcsafe.} =
  ## Add an MCP server to the manager
  if name in manager.servers:
    raise newException(Exception, fmt("MCP server {name} already exists"))

  let server = newMcpServerInstance(name, config)
  manager.servers[name] = server
  manager.logger.log(lvlInfo, fmt("Added MCP server: {name}"))

proc removeServer*(manager: McpManager, name: string) {.gcsafe.} =
  ## Remove an MCP server from the manager
  if name in manager.servers:
    let server = manager.servers[name]
    if server.client.isSome():
      server.client.get().close()
    manager.servers.del(name)
    manager.logger.log(lvlInfo, fmt("Removed MCP server: {name}"))

proc startServer*(manager: McpManager, name: string) {.gcsafe.} =
  ## Start an MCP server
  if name notin manager.servers:
    raise newException(Exception, fmt("MCP server {name} not found"))

  let server = manager.servers[name]

  if server.status == mssRunning:
    return  # Already running

  server.status = mssStarting
  server.logger.log(lvlInfo, fmt("Starting MCP server: {name}"))

  try:
    let client = newMcpClient(name)
    client.startMcpProcess(server.config)

    if client.initialize():
      server.client = some(client)
      server.status = mssRunning
      server.lastActivity = getMonoTime()
      server.restartCount += 1
      server.logger.log(lvlInfo, fmt("MCP server {name} started successfully"))
    else:
      server.status = mssError
      server.errorCount += 1
      server.logger.log(lvlError, fmt("Failed to initialize MCP server {name}"))

  except Exception as e:
    server.status = mssError
    server.errorCount += 1
    server.logger.log(lvlError, fmt("Failed to start MCP server {name}: {e.msg}"))

proc stopServer*(manager: McpManager, name: string) {.gcsafe.} =
  ## Stop an MCP server
  if name notin manager.servers:
    return

  let server = manager.servers[name]

  if server.status == mssStopped:
    return  # Already stopped

  server.status = mssStopping
  server.logger.log(lvlInfo, fmt("Stopping MCP server: {name}"))

  try:
    if server.client.isSome():
      discard server.client.get().shutdown()
      server.client.get().close()
      server.client = none(McpClient)

    server.status = mssStopped
    server.lastActivity = getMonoTime()
    server.logger.log(lvlInfo, fmt("MCP server {name} stopped"))

  except Exception as e:
    server.status = mssError
    server.errorCount += 1
    server.logger.log(lvlError, fmt("Failed to stop MCP server {name}: {e.msg}"))

proc restartServer*(manager: McpManager, name: string) {.gcsafe.} =
  ## Restart an MCP server
  manager.logger.log(lvlInfo, fmt("Restarting MCP server: {name}"))
  manager.stopServer(name)
  sleep(1000)  # Brief pause before restarting
  manager.startServer(name)

proc getClient*(manager: McpManager, name: string): Option[McpClient] {.gcsafe.} =
  ## Get MCP client for a server
  if name in manager.servers:
    let server = manager.servers[name]
    if server.status == mssRunning and server.client.isSome():
      server.lastActivity = getMonoTime()
      return server.client

  return none(McpClient)

proc isServerAvailable*(manager: McpManager, name: string): bool {.gcsafe.} =
  ## Check if an MCP server is available
  if name in manager.servers:
    let server = manager.servers[name]
    return server.status == mssRunning and server.client.isSome()

  return false

proc listServers*(manager: McpManager): seq[string] {.gcsafe.} =
  ## List all configured MCP servers
  for name in manager.servers.keys:
    result.add(name)

proc getServerStatus*(manager: McpManager, name: string): McpServerStatus {.gcsafe.} =
  ## Get the status of an MCP server
  if name in manager.servers:
    return manager.servers[name].status

  return mssStopped

proc performHealthCheck*(manager: McpManager, name: string): bool {.gcsafe.} =
  ## Perform health check on an MCP server
  if name notin manager.servers:
    return false

  let server = manager.servers[name]

  if server.status != mssRunning or server.client.isNone():
    return false

  try:
    let client = server.client.get()
    if not client.isConnected():
      return false

    # Simple health check - try to list tools
    let tools = client.listTools()
    server.lastActivity = getMonoTime()
    return true

  except Exception as e:
    server.logger.log(lvlWarn, fmt("Health check failed for MCP server {name}: {e.msg}"))
    return false

proc performMaintenance*(manager: McpManager) {.gcsafe.} =
  ## Perform maintenance on all MCP servers
  let currentTime = getMonoTime()

  for name, server in manager.servers:
    case server.status:
    of mssRunning:
      # Check if server has been inactive for too long
      if (currentTime - server.lastActivity).inMinutes > 30:
        server.logger.log(lvlInfo, fmt("MCP server {name} inactive, performing health check"))
        if not manager.performHealthCheck(name):
          server.logger.log(lvlWarn, fmt("Health check failed, restarting MCP server {name}"))
          manager.restartServer(name)

    of mssError:
      # Auto-restart failed servers after a cooldown period
      if server.errorCount < 5:  # Limit restart attempts
        server.logger.log(lvlInfo, fmt("Attempting to restart failed MCP server {name}"))
        manager.startServer(name)

    of mssStarting, mssStopping, mssStopped:
      # No action needed for these states
      discard

proc shutdownServer*(manager: McpManager, name: string) {.gcsafe.} =
  ## Shutdown and remove an MCP server
  manager.stopServer(name)
  manager.removeServer(name)

proc shutdownAll*(manager: McpManager) {.gcsafe.} =
  ## Shutdown all MCP servers
  manager.logger.log(lvlInfo, "Shutting down all MCP servers")

  # Create a copy of server names to avoid modification during iteration
  let serverNames = toSeq(manager.servers.keys)

  for name in serverNames:
    manager.shutdownServer(name)

  manager.logger.log(lvlInfo, "All MCP servers shutdown")

# Utility procedures

proc getServerInfo*(manager: McpManager, name: string): JsonNode {.gcsafe.} =
  ## Get information about an MCP server
  result = newJObject()

  if name notin manager.servers:
    result["error"] = newJString(fmt("Server {name} not found"))
    return

  let server = manager.servers[name]

  result["name"] = newJString(server.name)
  result["status"] = newJString($server.status)
  result["errorCount"] = newJInt(server.errorCount)
  result["restartCount"] = newJInt(server.restartCount)
  result["lastActivitySeconds"] = newJInt((getMonoTime() - server.lastActivity).inSeconds)

  if server.config.enabled:
    result["command"] = newJString(server.config.command)

  if server.config.args.isSome():
    var argsArray = newJArray()
    for arg in server.config.args.get():
      argsArray.add(newJString(arg))
    result["args"] = argsArray

proc getAllServersInfo*(manager: McpManager): JsonNode {.gcsafe.} =
  ## Get information about all MCP servers
  result = newJArray()

  for name in manager.servers.keys:
    result.add(manager.getServerInfo(name))