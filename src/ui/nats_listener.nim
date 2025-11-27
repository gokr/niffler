## NATS Listener Thread
##
## Background thread that listens for NATS responses and status updates
## from agents, displaying them asynchronously while the user can continue typing.
##
## This creates its own NATS connection to avoid thread-safety issues.

import std/[options, strformat, logging, os, tables]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

import ../core/[nats_client]
import ../types/[nats_messages]
import ../../../linecross/linecross
import sunny

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
        # Check for status updates
        let maybeStatus = statusSubscription.nextMsg(timeoutMs = 50)
        if maybeStatus.isSome():
          try:
            let status = fromJson(NatsStatusUpdate, maybeStatus.get().data)
            # Display status in chat style
            let output = fmt("@{status.agentName}: {status.status}")
            writeOutputRaw(output, addNewline = true, redraw = true)
          except Exception as e:
            debug(fmt("Failed to parse status update: {e.msg}"))

        # Check for responses
        let maybeMsg = responseSubscription.nextMsg(timeoutMs = 50)
        if maybeMsg.isSome():
          try:
            let response = fromJson(NatsResponse, maybeMsg.get().data)

            if response.done:
              # Final response - show completion with content summary
              if response.content.len > 0:
                # Show first 100 chars of response as summary
                let summary = if response.content.len > 100:
                  response.content[0..99] & "..."
                else:
                  response.content
                writeOutputRaw(fmt("✓ Response: {summary}"), addNewline = true, redraw = true)
              else:
                writeOutputRaw("✓ Request completed", addNewline = true, redraw = true)
              debug(fmt("Request {response.requestId} completed"))
            elif response.content.len > 0:
              # Streaming chunk - display directly
              writeOutputRaw(response.content, addNewline = false, redraw = true)
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
