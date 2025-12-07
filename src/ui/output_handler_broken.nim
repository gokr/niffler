## Output Handler Thread
##
## This module implements a dedicated thread for handling output display
## while keeping the main thread available for readline input.
##
## Design:
## - Runs in a dedicated thread
## - Polls for API responses from the response channel
## - Writes output directly using linecross's thread-safe writeOutputRaw()
## - Tracks response state and completion
## - Allows main thread to stay in readline() at all times

import std/[options, strformat, logging, tables, os]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

import ../core/[channels]
import ../types/[messages]
import theme
import tool_visualizer
import output_shared

# Forward declarations for functions from cli that we need
# These will be linked at compile time
proc updateTokenCounts*(newInputTokens: int, newOutputTokens: int)

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

    # Initialize logging for this thread
    let consoleLogger = newConsoleLogger(useStderr = true)
    addHandler(consoleLogger)
    setLogFilter(params.level)

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
              debug("Output handler: Tool calls detected - will not add duplicate assistant message")

            # Handle thinking content display
            if response.thinkingContent.isSome():
              let thinkingContent = response.thinkingContent.get()
              let isEncrypted = response.isEncrypted.isSome() and response.isEncrypted.get()

              if not isInThinkingBlock:
                # Start of thinking block - show emoji prefix
                let emojiPrefix = if isEncrypted: "🔒 " else: "🤔 "
                let styledContent = formatWithStyle(thinkingContent, currentTheme.thinking)
                writeStreamingChunk(emojiPrefix & styledContent)
                isInThinkingBlock = true
              else:
                # Continuing thinking block - just show content
                writeStreamingChunkStyled(thinkingContent, currentTheme.thinking)

            if response.content.len > 0:
              # Add separator when transitioning from thinking to regular content
              if isInThinkingBlock:
                finishStreaming()
                writeCompleteLine("")
                isInThinkingBlock = false

              accumulatedResponse.add(response.content)
              # Stream the content in real-time
              writeStreamingChunk(response.content)

            of arkToolCallRequest:
            # Flush any pending thinking content
            finishStreaming()

            # Display tool request
            let toolRequest = response.toolRequestInfo
            let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
            writeCompleteLine(formattedRequest)

          of arkToolCallResult:
            # Display tool result
            let toolResult = response.toolResultInfo
            let formattedResult = formatCompactToolResultWithIndent(toolResult)
            writeCompleteLine(formattedResult)

            of arkStreamComplete:
            # Flush any remaining buffered output
            finishStreaming()

            # Add final newline if we have content
            if accumulatedResponse.len > 0:
              writeCompleteLine("")

            # Update token counts with new response
            updateTokenCounts(response.usage.inputTokens, response.usage.outputTokens)

            # Note: History management is handled by API worker thread
            # We just display the output here

            # Reset state for next request
            currentRequestId = ""
            accumulatedResponse = ""
            hadToolCallsInResponse = false
            isInThinkingBlock = false

            debug("Output handler: Stream complete")

          of arkStreamError:
            writeCompleteLine(formatWithStyle(fmt"Error: {response.error}", currentTheme.error))

            # Reset state
            currentRequestId = ""
            accumulatedResponse = ""
            hadToolCallsInResponse = false
            isInThinkingBlock = false

          of arkReady:
            # Just ignore ready responses
            discard
        else:
          # No responses available, sleep briefly
          sleep(5)

    except Exception as e:
      fatal(fmt"Output handler thread crashed: {e.msg}")
    finally:
      decrementActiveThreads(channels)
      debug("Output handler thread stopped")

proc startOutputHandlerWorker*(channels: ptr ThreadChannels, level: Level): OutputHandlerWorker =
  ## Start the output handler worker thread
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
  ## Stop the output handler worker thread
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false

proc setActiveRequest*(requestId: string) =
  ## Set the currently active request ID for output filtering
  currentRequestId = requestId
  accumulatedResponse = ""
  hadToolCallsInResponse = false
  isInThinkingBlock = false
