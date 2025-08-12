import std/[options, strutils, os, json, strformat]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

import ../types/[tools, messages]
import ../core/[channels, logging]
import registry

type
  ToolWorker* = object
    thread: Thread[ptr ThreadChannels]
    isRunning: bool

  ToolExecutionRequest* = object
    requestId*: string
    toolCall*: tools.ToolCall
    requireConfirmation*: bool

  ToolExecutionResponse* = object
    requestId*: string
    result*: ToolResult
    success*: bool

proc toolWorkerProc(channels: ptr ThreadChannels) {.thread, gcsafe.} =
  logInfo("tool-worker", "Tool worker thread started")
  
  try:
    while not isShutdownSignaled(channels):
      # Check for tool requests
      let maybeRequest = tryReceiveToolRequest(channels)
      
      if maybeRequest.isSome():
        let request = maybeRequest.get()
        
        case request.kind:
        of trkShutdown:
          logInfo("tool-worker", "Received shutdown signal")
          break
          
        of trkExecute:
          logInfo("tool-worker", fmt"Processing tool request: {request.requestId}")
          
          try:
            # Parse the tool call from JSON arguments
            let toolCallJson = parseJson(request.arguments)
            let toolCall = tools.ToolCall(
              id: request.requestId,
              name: request.toolName,
              arguments: toolCallJson
            )
            
            # Get the global tool registry
            let registryPtr = getGlobalToolRegistry()
            let registry = registryPtr[]
            
            # Validate the tool call
            validateToolCall(registry, toolCall)
            
            # Get the tool definition
            let toolOpt = getTool(registry, toolCall.name)
            if toolOpt.isNone:
              raise newToolValidationError(toolCall.name, "name", "registered tool", toolCall.name)
            
            let toolDef = toolOpt.get()
            
            # Execute the tool (this will be implemented by specific tools)
            # For now, just return a placeholder response
            let response = ToolExecutionResponse(
              requestId: request.requestId,
              result: newToolResult("Tool execution not yet implemented"),
              success: true
            )
            
            # Send response back through channels
            let toolResponse = ToolResponse(
              requestId: request.requestId,
              kind: trkResult,
              output: response.result.output
            )
            sendToolResponse(channels, toolResponse)
            
            logInfo("tool-worker", fmt"Tool request {request.requestId} completed successfully")
            
          except ToolError as e:
            logError("tool-worker", fmt"Tool execution failed: {e.msg}")
            let errorResponse = ToolResponse(
              requestId: request.requestId,
              kind: trkError,
              error: e.msg
            )
            sendToolResponse(channels, errorResponse)
            
          except Exception as e:
            logError("tool-worker", fmt"Unexpected error in tool execution: {e.msg}")
            let errorResponse = ToolResponse(
              requestId: request.requestId,
              kind: trkError,
              error: fmt"Unexpected error: {e.msg}"
            )
            sendToolResponse(channels, errorResponse)
      
      else:
        # No requests, sleep briefly
        sleep(10)
    
  except Exception as e:
    logFatal("tool-worker", fmt"Tool worker thread crashed: {e.msg}")
  finally:
    logInfo("tool-worker", "Tool worker thread stopped")

proc startToolWorker*(channels: ptr ThreadChannels): ToolWorker =
  result.isRunning = true
  createThread(result.thread, toolWorkerProc, channels)
  logInfo("tool-main", "Tool worker thread started")

proc stopToolWorker*(worker: var ToolWorker) =
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false
    logInfo("tool-main", "Tool worker thread stopped")

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