## Output Handler Thread
##
## This module implements a dedicated thread for handling output display
## while keeping the main thread available for readline input.

import std/[options, strformat, logging, os]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

import ../core/[channels]
import ../types/[messages]
import theme
import tool_visualizer
import output_shared
import ui_state

type
  OutputHandlerWorker* = object
    thread: Thread[ThreadParams]
    isRunning: bool

# State for tracking current response (thread-local)
var currentRequestId {.threadvar.}: string
var accumulatedResponse {.threadvar.}: string
var hadToolCallsInResponse {.threadvar.}: bool
var isInThinkingBlock {.threadvar.}: bool

proc outputHandlerProc(params: ThreadParams) {.thread, gcsafe.} =
  ## Output handler thread that processes API responses and displays them
  {.gcsafe.}:
    let channels = params.channels

    # NOTE: Don't modify logging state - the logging module is not thread-safe
    # Worker threads inherit logging settings from main thread
    discard # setLogFilter not thread safe

    debug("Output handler thread started")
    incrementActiveThreads(channels)

    try:
      while not isShutdownSignaled(channels):
        # Check for API responses
        var response: APIResponse
        if tryReceiveAPIResponse(channels, response):
          # Only process responses for the current active request
          if currentRequestId.len > 0 and response.requestId != currentRequestId:
            debug(fmt"Ignoring response from old request {response.requestId} (current: {currentRequestId})")
            sleep(5)
            continue

          case response.kind:
          of arkStreamChunk:
            # Check if this chunk contains tool calls
            if response.toolCalls.isSome():
              hadToolCallsInResponse = true
              debug("Output handler: Tool calls detected")

            # Handle thinking content display
            if response.thinkingContent.isSome():
              let thinkingContent = response.thinkingContent.get()
              let isEncrypted = response.isEncrypted.isSome() and response.isEncrypted.get()

              if not isInThinkingBlock:
                let emojiPrefix = if isEncrypted: "🔒 " else: "🤔 "
                let styledContent = formatWithStyle(thinkingContent, currentTheme.thinking)
                writeStreamingChunk(emojiPrefix & styledContent)
                isInThinkingBlock = true
              else:
                writeStreamingChunkStyled(thinkingContent, currentTheme.thinking)

            if response.content.len > 0:
              if isInThinkingBlock:
                finishStreaming()
                writeCompleteLine("")
                isInThinkingBlock = false

              accumulatedResponse.add(response.content)
              writeStreamingChunk(response.content)

          of arkToolCallRequest:
            finishStreaming()
            let toolRequest = response.toolRequestInfo
            let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
            writeCompleteLine(formattedRequest)

          of arkToolCallResult:
            let toolResult = response.toolResultInfo
            let formattedResult = formatCompactToolResultWithIndent(toolResult)
            writeCompleteLine(formattedResult)

          of arkStreamComplete:
            finishStreaming()
            if accumulatedResponse.len > 0:
              writeCompleteLine("")

            # Update token counts (thread-safe, no UI calls)
            updateTokenCounts(response.usage.inputTokens, response.usage.outputTokens)

            # Clear processing indicator (next prompt will show without ⚡)
            ui_state.isProcessing = false

            # Reset state for next request
            currentRequestId = ""
            accumulatedResponse = ""
            hadToolCallsInResponse = false
            isInThinkingBlock = false

            debug("Output handler: Stream complete")

          of arkStreamError:
            writeCompleteLine(formatWithStyle(fmt"Error: {response.error}", currentTheme.error))
            currentRequestId = ""
            accumulatedResponse = ""
            hadToolCallsInResponse = false
            isInThinkingBlock = false

          of arkReady:
            discard
        else:
          sleep(5)

    except Exception as e:
      fatal(fmt"Output handler thread crashed: {e.msg}")
    finally:
      decrementActiveThreads(channels)
      debug("Output handler thread stopped")

proc startOutputHandlerWorker*(channels: ptr ThreadChannels, level: Level): OutputHandlerWorker =
  result.isRunning = true
  var params = new(ThreadParams)
  params.channels = channels
  params.level = level
  params.dump = false
  params.dumpsse = false  # Output handler doesn't need SSE dumping
  params.database = nil
  params.pool = nil
  createThread(result.thread, outputHandlerProc, params)

proc stopOutputHandlerWorker*(worker: var OutputHandlerWorker) =
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false

proc setActiveRequest*(requestId: string) =
  currentRequestId = requestId
  accumulatedResponse = ""
  hadToolCallsInResponse = false
  isInThinkingBlock = false
