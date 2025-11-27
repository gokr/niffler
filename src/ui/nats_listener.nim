## NATS Listener Thread
##
## Background thread that listens for NATS responses and status updates
## from agents, displaying them asynchronously while the user can continue typing.
##
## This creates its own NATS connection to avoid thread-safety issues.

import std/[options, strformat, logging, os, tables, hashes, strutils]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

import ../core/[nats_client]
import ../types/[nats_messages]
import ../../../linecross/linecross
import sunny
import theme

type
  NatsListenerParams* = ref object
    natsUrl*: string
    level*: Level
    running*: ptr bool

  NatsListenerWorker* = object
    thread: Thread[NatsListenerParams]
    isRunning*: bool
    runningFlag: bool

  # Track pending requests for context (agent name lookup)
  PendingAgentRequest = object
    agentName: string
    input: string

var pendingRequests {.threadvar.}: Table[string, PendingAgentRequest]

proc getAgentColor(agentName: string): ThemeStyle =
  ## Get deterministic color for agent name using hash
  let colorPalette = [
    createThemeStyle("cyan", "default", "bright"),
    createThemeStyle("magenta", "default", "bright"),
    createThemeStyle("yellow", "default", "bright"),
    createThemeStyle("blue", "default", "bright"),
    createThemeStyle("green", "default", "bright")
  ]
  let hashValue = hash(agentName)
  let colorIndex = abs(hashValue) mod colorPalette.len
  return colorPalette[colorIndex]

proc natsListenerProc(params: NatsListenerParams) {.thread, gcsafe.} =
  ## NATS listener thread that processes agent responses and displays them
  {.gcsafe.}:
    # NOTE: Don't modify logging state - the logging module is not thread-safe
    # Worker threads inherit logging settings from main thread
    discard # setLogFilter not thread safe

    debug("NATS listener thread starting...")

    var client: NifflerNatsClient
    try:
      # Create our own NATS connection for this thread
      client = initNatsClient(params.natsUrl, "", presenceTTL = 0)
      debug("NATS listener connected")
    except Exception as e:
      error(fmt("NATS listener failed to connect: {e.msg}"))
      return

    # Subscribe to response and status channels
    var responseSubscription = client.subscribe("niffler.master.response")
    var statusSubscription = client.subscribe("niffler.master.status")

    debug("NATS listener subscribed to response and status channels")

    try:
      while params.running[]:
        # Check for status updates (but don't display them for cleaner UX)
        let maybeStatus = statusSubscription.nextMsg(timeoutMs = 50)
        if maybeStatus.isSome():
          try:
            let status = fromJson(NatsStatusUpdate, maybeStatus.get().data)
            # Status updates are consumed but not displayed
            debug(fmt("Status from {status.agentName}: {status.status}"))
          except Exception as e:
            debug(fmt("Failed to parse status update: {e.msg}"))

        # Check for responses
        let maybeMsg = responseSubscription.nextMsg(timeoutMs = 50)
        if maybeMsg.isSome():
          try:
            let response = fromJson(NatsResponse, maybeMsg.get().data)

            if response.done:
              # Final response - show with colored agent name
              if response.content.len > 0:
                # Get agent name from response
                let agentColor = getAgentColor(response.agentName)
                let coloredName = formatWithStyle(response.agentName, agentColor)
                # Convert LF to CRLF for proper terminal display
                let normalizedContent = response.content.replace("\n", "\r\n")
                writeOutputRaw(fmt("{coloredName}: {normalizedContent}"), addNewline = true, redraw = true)
              debug(fmt("Request {response.requestId} completed from {response.agentName}"))
            elif response.content.len > 0:
              # Streaming chunk - display directly, convert LF to CRLF
              let normalizedContent = response.content.replace("\n", "\r\n")
              writeOutputRaw(normalizedContent, addNewline = false, redraw = true)
          except Exception as e:
            debug(fmt("Failed to parse response: {e.msg}"))

        # Small sleep to prevent busy-waiting
        sleep(10)

    except Exception as e:
      error(fmt("NATS listener thread error: {e.msg}"))
    finally:
      responseSubscription.unsubscribe()
      statusSubscription.unsubscribe()
      client.close()
      debug("NATS listener thread stopped")

proc startNatsListenerWorker*(natsUrl: string, level: Level): NatsListenerWorker =
  ## Start the NATS listener background thread
  result.isRunning = true
  result.runningFlag = true

  var params = new(NatsListenerParams)
  params.natsUrl = natsUrl
  params.level = level
  params.running = addr result.runningFlag

  createThread(result.thread, natsListenerProc, params)

proc stopNatsListenerWorker*(worker: var NatsListenerWorker) =
  ## Stop the NATS listener thread
  if worker.isRunning:
    worker.runningFlag = false
    joinThread(worker.thread)
    worker.isRunning = false

proc trackAgentRequest*(requestId: string, agentName: string, input: string) =
  ## Track a pending request for context when response arrives
  pendingRequests[requestId] = PendingAgentRequest(
    agentName: agentName,
    input: input
  )

proc clearAgentRequest*(requestId: string) =
  ## Clear a tracked request
  if pendingRequests.hasKey(requestId):
    pendingRequests.del(requestId)
