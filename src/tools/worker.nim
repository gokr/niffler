import std/[options, os, json, logging, strformat]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

import ../types/[tools, messages]
import ../core/channels
import bash, create, edit, fetch, list, read


type    
  ToolWorker* = object
    thread: Thread[ThreadParams]
    isRunning: bool

  ToolExecutionRequest* = object
    requestId*: string
    toolCall*: tools.ToolCall
    requireConfirmation*: bool

  ToolExecutionResponse* = object
    requestId*: string
    result*: ToolResult
    success*: bool

proc toolWorkerProc(params: ThreadParams) {.thread, gcsafe.} =
  # Initialize logging for this thread
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(params.level)
  
  let channels = params.channels
  
  debug("Tool worker thread started")
    
  try:
    while not isShutdownSignaled(channels):
      # Check for tool requests
      let maybeRequest = tryReceiveToolRequest(channels)
      if maybeRequest.isSome():
        let request = maybeRequest.get()
        case request.kind:
        of trkShutdown:
          debug("Received shutdown signal")
          break
          
        of trkExecute:
          debug(fmt"Processing tool request '{request.toolName}' ({request.requestId}) with arguments: {request.arguments}")
          try:
            # Parse the tool call from JSON arguments
            let toolCallJson = parseJson(request.arguments)
            debug("JSON parsed successfully: " & $toolCallJson)
            
            let toolCall = tools.ToolCall(
              id: request.requestId,
              name: request.toolName,
              arguments: toolCallJson
            )

            # Execute the tool call
            debug("Executing tool " & toolCall.name & " with arguments: " & $toolCall.arguments)
            
            let output = 
              try:
                # Execute the tool using direct implementation lookup
                let result = case toolCall.name:
                  of "bash":
                    newBashTool().execute(toolCall.arguments)
                  of "read":
                    newReadTool().execute(toolCall.arguments)
                  of "list":
                    newListTool().execute(toolCall.arguments)
                  of "edit":
                    newEditTool().execute(toolCall.arguments)
                  of "create":
                    newCreateTool().execute(toolCall.arguments)
                  of "fetch":
                    newFetchTool().execute(toolCall.arguments)
                  else:
                    raise newToolValidationError(toolCall.name, "name", "supported tool", toolCall.name)
                
                debug("Tool execution successful, result length: " & $result.len)
                result
              except ToolError as e:
                let errorMsg = "Tool execution error: " & e.msg
                warn(errorMsg)
                $ %*{"error": errorMsg, "tool": toolCall.name}
              except Exception as e:
                let errorMsg = "Unexpected error executing tool " & toolCall.name & ": " & e.msg
                error(errorMsg)
                $ %*{"error": errorMsg, "tool": toolCall.name}
            
            debug("Tool " & toolCall.name & " execution completed, output length: " & $output.len)
            debug("Output preview: " & (if output.len > 100: output[0..100] & "..." else: output))
            
            debug("Creating ToolExecutionResponse...")
            let response = ToolExecutionResponse(
              requestId: request.requestId,
              result: newToolResult(output),
              success: true
            )
            
            # Send response back through channels
            debug("Creating ToolResponse...")
            let toolResponse = ToolResponse(
              requestId: request.requestId,
              kind: trkResult,
              output: response.result.output
            )
            debug("ToolResponse created, sending...")
            sendToolResponse(channels, toolResponse)
            debug("ToolResponse sent successfully")
            
            debug("Tool request " & request.requestId & " completed successfully")
            
          except ToolError as e:
            debug("Tool execution failed: " & e.msg)
            let errorResponse = ToolResponse(
              requestId: request.requestId,
              kind: trkError,
              error: e.msg
            )
            sendToolResponse(channels, errorResponse)
            
          except Exception as e:
            debug("Unexpected error in tool execution: " & e.msg)
            let errorResponse = ToolResponse(
              requestId: request.requestId,
              kind: trkError,
              error: "Unexpected error: " & e.msg
            )
            sendToolResponse(channels, errorResponse)
      
      else:
        # No requests, sleep briefly
        sleep(10)
    
  except Exception as e:
    fatal("Tool worker thread crashed: " & e.msg)
  finally:
    debug("Tool worker thread stopped")

proc startToolWorker*(channels: ptr ThreadChannels, level: Level): ToolWorker =
  result.isRunning = true
  let params = ThreadParams(channels: channels, level: level)
  createThread(result.thread, toolWorkerProc, params)

proc stopToolWorker*(worker: var ToolWorker) =
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false
    debug("Tool worker thread stopped")

proc executeToolAsync*(channels: ptr ThreadChannels, toolCall: tools.ToolCall, 
                       requireConfirmation: bool = false): bool =
  let request = ToolRequest(
    kind: trkExecute,
    requestId: toolCall.id,
    toolName: toolCall.name,
    arguments: $toolCall.arguments
  )
  
  return trySendToolRequest(channels, request)

proc sendToolReady*(channels: ptr ThreadChannels) =
  let readyResponse = ToolResponse(
    requestId: "ready",
    kind: trkReady
  )
  sendToolResponse(channels, readyResponse)