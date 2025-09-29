## Thread Communication Channels
##
## This module provides thread-safe communication channels for coordinating
## between the main UI thread, API worker thread, and tool worker thread.
##
## Key Features:
## - Thread-safe queues for message passing
## - Atomic shutdown signaling
## - Non-blocking try operations for real-time responsiveness
## - Active thread counting for graceful shutdown
##
## Channel Types:
## - API Request/Response channels for LLM communication
## - Tool Request/Response channels for tool execution
## - UI Update channel for progress notifications
## - Shutdown signaling for clean termination

import std/[locks, atomics, options, logging, times, os]
import ../types/messages
import queue
import database
import debby/pools

# MCP support
import ../mcp/protocol as mcpProtocol

type
  ThreadParams* = ref object
    channels*: ptr ThreadChannels
    level*: Level
    dump*: bool
    database*: DatabaseBackend  # Keep for backward compatibility
    pool*: Pool                 # New database pool for cross-thread sharing

  ThreadChannels* = object
    # API Thread Communication
    apiRequestChan*: ThreadSafeQueue[APIRequest]
    apiResponseChan*: ThreadSafeQueue[APIResponse]

    # Tool Thread Communication
    toolRequestChan*: ThreadSafeQueue[ToolRequest]
    toolResponseChan*: ThreadSafeQueue[ToolResponse]

    # MCP Thread Communication
    mcpRequestChan*: ThreadSafeQueue[McpRequest]
    mcpResponseChan*: ThreadSafeQueue[McpResponse]

    # UI Thread Communication
    uiUpdateChan*: ThreadSafeQueue[UIUpdate]

    # Thread Management
    shutdownSignal*: Atomic[bool]
    threadsActive*: Atomic[int]
    
  ThreadSafeChannels* = object
    channels: ThreadChannels
    lock: Lock

var globalChannels {.threadvar.}: ThreadSafeChannels

proc initializeChannels*(): ThreadChannels =
  ## Initialize all thread communication channels with empty queues
  result.apiRequestChan = initThreadSafeQueue[APIRequest]()
  result.apiResponseChan = initThreadSafeQueue[APIResponse]()
  result.toolRequestChan = initThreadSafeQueue[ToolRequest]()
  result.toolResponseChan = initThreadSafeQueue[ToolResponse]()
  result.mcpRequestChan = initThreadSafeQueue[McpRequest]()
  result.mcpResponseChan = initThreadSafeQueue[McpResponse]()
  result.uiUpdateChan = initThreadSafeQueue[UIUpdate]()

  result.shutdownSignal.store(false)
  result.threadsActive.store(0)

proc initThreadSafeChannels*() =
  ## Initialize thread-safe global channels with lock protection
  globalChannels.channels = initializeChannels()
  initLock(globalChannels.lock)

proc getChannels*(): ptr ThreadChannels =
  ## Get pointer to global thread channels (thread-safe)
  acquire(globalChannels.lock)
  result = addr globalChannels.channels
  release(globalChannels.lock)

proc closeChannels*(channels: var ThreadChannels) =
  ## Close all channels and cleanup resources
  channels.apiRequestChan.close()
  channels.apiResponseChan.close()
  channels.toolRequestChan.close()
  channels.toolResponseChan.close()
  channels.mcpRequestChan.close()
  channels.mcpResponseChan.close()
  channels.uiUpdateChan.close()

proc signalShutdown*(channels: ptr ThreadChannels) =
  ## Signal shutdown to all worker threads and send shutdown messages
  channels.shutdownSignal.store(true)

  # Send shutdown messages to all worker threads
  var apiShutdown = APIRequest(kind: arkShutdown)
  var toolShutdown = ToolRequest(kind: trkShutdown)
  var mcpShutdown = McpRequest(kind: mcrkShutdown, serverName: "all")

  discard channels.apiRequestChan.trySend(apiShutdown)
  discard channels.toolRequestChan.trySend(toolShutdown)
  discard channels.mcpRequestChan.trySend(mcpShutdown)

proc isShutdownSignaled*(channels: ptr ThreadChannels): bool =
  ## Check if shutdown has been signaled to workers
  channels.shutdownSignal.load()

proc incrementActiveThreads*(channels: ptr ThreadChannels) =
  ## Increment active thread count atomically
  discard channels.threadsActive.fetchAdd(1)

proc decrementActiveThreads*(channels: ptr ThreadChannels) =
  ## Decrement active thread count atomically
  discard channels.threadsActive.fetchSub(1)

proc getActiveThreadCount*(channels: ptr ThreadChannels): int =
  ## Get current active thread count (thread-safe)
  channels.threadsActive.load()

# Non-blocking channel operations
proc tryReceiveAPIRequest*(channels: ptr ThreadChannels): Option[APIRequest] =
  return channels.apiRequestChan.tryReceive()

proc tryReceiveAPIResponse*(channels: ptr ThreadChannels, response: var APIResponse): bool =
  let maybeResponse = channels.apiResponseChan.tryReceive()
  if maybeResponse.isSome():
    response = maybeResponse.get()
    return true
  return false

proc tryReceiveToolRequest*(channels: ptr ThreadChannels): Option[ToolRequest] =
  return channels.toolRequestChan.tryReceive()

proc tryReceiveToolResponse*(channels: ptr ThreadChannels): Option[ToolResponse] =
  return channels.toolResponseChan.tryReceive()

proc tryReceiveMcpRequest*(channels: ptr ThreadChannels): Option[McpRequest] =
  return channels.mcpRequestChan.tryReceive()

proc tryReceiveMcpResponse*(channels: ptr ThreadChannels): Option[McpResponse] =
  return channels.mcpResponseChan.tryReceive()

proc tryReceiveUIUpdate*(channels: ptr ThreadChannels): Option[UIUpdate] =
  return channels.uiUpdateChan.tryReceive()

# Blocking send operations (for worker threads)
proc sendAPIResponse*(channels: ptr ThreadChannels, response: APIResponse) =
  channels.apiResponseChan.send(response)

proc sendToolResponse*(channels: ptr ThreadChannels, response: ToolResponse) =
  channels.toolResponseChan.send(response)

proc sendMcpResponse*(channels: ptr ThreadChannels, response: McpResponse) =
  channels.mcpResponseChan.send(response)

proc sendUIUpdate*(channels: ptr ThreadChannels, update: UIUpdate) =
  channels.uiUpdateChan.send(update)

# Non-blocking send operations (for main thread)
proc trySendAPIRequest*(channels: ptr ThreadChannels, request: APIRequest): bool =
  return channels.apiRequestChan.trySend(request)

proc trySendToolRequest*(channels: ptr ThreadChannels, request: ToolRequest): bool =
  return channels.toolRequestChan.trySend(request)

proc trySendMcpRequest*(channels: ptr ThreadChannels, request: McpRequest): bool =
  return channels.mcpRequestChan.trySend(request)

# Blocking MCP status request
proc requestMcpStatus*(channels: ptr ThreadChannels, timeoutMs: int = 1000): Option[McpStatusInfo] =
  ## Send status request and wait for response (blocking with timeout)
  let request = McpRequest(kind: mcrkStatus, serverName: "status")
  if not channels.mcpRequestChan.trySend(request):
    return none(McpStatusInfo)

  # Wait for response with timeout
  let startTime = epochTime()
  while (epochTime() - startTime) * 1000 < float(timeoutMs):
    let maybeResponse = channels.tryReceiveMcpResponse()
    if maybeResponse.isSome() and maybeResponse.get().kind == mcrrkStatus:
      return some(maybeResponse.get().statusInfo)
    sleep(10)  # Small sleep to avoid busy waiting

  return none(McpStatusInfo)