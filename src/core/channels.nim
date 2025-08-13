import std/[locks, atomics, options, logging]
import ../types/messages
import queue

type
  ThreadParams* = ref object
    channels*: ptr ThreadChannels
    level*: Level

  ThreadChannels* = object
    # API Thread Communication
    apiRequestChan*: ThreadSafeQueue[APIRequest]
    apiResponseChan*: ThreadSafeQueue[APIResponse]
    
    # Tool Thread Communication  
    toolRequestChan*: ThreadSafeQueue[ToolRequest]
    toolResponseChan*: ThreadSafeQueue[ToolResponse]
    
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
  result.apiRequestChan = initThreadSafeQueue[APIRequest]()
  result.apiResponseChan = initThreadSafeQueue[APIResponse]()
  result.toolRequestChan = initThreadSafeQueue[ToolRequest]()
  result.toolResponseChan = initThreadSafeQueue[ToolResponse]()
  result.uiUpdateChan = initThreadSafeQueue[UIUpdate]()
  
  result.shutdownSignal.store(false)
  result.threadsActive.store(0)

proc initThreadSafeChannels*() =
  globalChannels.channels = initializeChannels()
  initLock(globalChannels.lock)

proc getChannels*(): ptr ThreadChannels =
  acquire(globalChannels.lock)
  result = addr globalChannels.channels
  release(globalChannels.lock)

proc closeChannels*(channels: var ThreadChannels) =
  channels.apiRequestChan.close()
  channels.apiResponseChan.close()
  channels.toolRequestChan.close()
  channels.toolResponseChan.close() 
  channels.uiUpdateChan.close()

proc signalShutdown*(channels: ptr ThreadChannels) =
  channels.shutdownSignal.store(true)
  
  # Send shutdown messages to all worker threads
  var apiShutdown = APIRequest(kind: arkShutdown)
  var toolShutdown = ToolRequest(kind: trkShutdown)
  
  discard channels.apiRequestChan.trySend(apiShutdown)
  discard channels.toolRequestChan.trySend(toolShutdown)

proc isShutdownSignaled*(channels: ptr ThreadChannels): bool =
  channels.shutdownSignal.load()

proc incrementActiveThreads*(channels: ptr ThreadChannels) =
  discard channels.threadsActive.fetchAdd(1)

proc decrementActiveThreads*(channels: ptr ThreadChannels) =
  discard channels.threadsActive.fetchSub(1)

proc getActiveThreadCount*(channels: ptr ThreadChannels): int =
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

proc tryReceiveUIUpdate*(channels: ptr ThreadChannels): Option[UIUpdate] =
  return channels.uiUpdateChan.tryReceive()

# Blocking send operations (for worker threads)
proc sendAPIResponse*(channels: ptr ThreadChannels, response: APIResponse) =
  channels.apiResponseChan.send(response)

proc sendToolResponse*(channels: ptr ThreadChannels, response: ToolResponse) =
  channels.toolResponseChan.send(response)

proc sendUIUpdate*(channels: ptr ThreadChannels, update: UIUpdate) =
  channels.uiUpdateChan.send(update)

# Non-blocking send operations (for main thread)
proc trySendAPIRequest*(channels: ptr ThreadChannels, request: APIRequest): bool =
  return channels.apiRequestChan.trySend(request)

proc trySendToolRequest*(channels: ptr ThreadChannels, request: ToolRequest): bool =
  return channels.toolRequestChan.trySend(request)