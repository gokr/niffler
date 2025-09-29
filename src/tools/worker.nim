## Tool Worker Thread
##
## This module implements the tool execution worker that runs in a dedicated thread
## and safely executes all tool operations requested by the API worker.
##
## Key Features:
## - Thread-safe tool execution with proper isolation
## - JSON schema validation for all tool parameters
## - Comprehensive error handling and timeout management
## - Support for all 6 core tools: bash, read, list, edit, create, fetch
## - Tool confirmation system for dangerous operations
## - Proper result formatting and error reporting
##
## Tool Execution Flow:
## 1. Receives tool execution requests via channels from API worker
## 2. Validates tool parameters against JSON schemas
## 3. Executes appropriate tool with safety checks
## 4. Handles confirmations for dangerous operations (bash, edit, create)
## 5. Formats results and sends back to API worker
##
## Design Decisions:
## - Dedicated thread for tool execution to prevent blocking API operations
## - Exception-based error handling with detailed error messages
## - Tool registry pattern for extensible tool system
## - Thread-safe channel communication with API worker

import std/[options, os, json, logging, strformat]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

import ../types/[tools, messages]
import ../core/[channels, database]
import registry
import ../mcp/tools as mcpTools
import debby/pools


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
  let consoleLogger = newConsoleLogger(useStderr = true)
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
            
            var toolSuccess = false
            let output =
              try:
                # Execute the tool using registry lookup
                let maybeTool = getTool(toolCall.name)
                let result = if maybeTool.isSome():
                  executeTool(maybeTool.get(), toolCall.arguments)
                elif mcpTools.isMcpTool(toolCall.name):
                  # Execute MCP tool
                  mcpTools.executeMcpTool(toolCall.name, toolCall.arguments)
                else:
                  raise newToolValidationError(toolCall.name, "name", "supported tool", toolCall.name)
                
                debug("Tool execution successful, result length: " & $result.len)
                toolSuccess = true
                result
              except ToolExecutionError as e:
                # For execution errors, include both the error message and the actual output
                let errorMsg = "Tool execution error: " & e.msg
                # Skip WARN log for bash tool failures since they're often expected  
                if toolCall.name != "bash":
                  debug(errorMsg)  # Changed from warn to debug
                toolSuccess = false
                if e.output.len > 0:
                  # Include the actual command output for the LLM to see what went wrong
                  $ %*{"error": errorMsg, "output": e.output, "exit_code": e.exitCode, "tool": toolCall.name}
                else:
                  $ %*{"error": errorMsg, "exit_code": e.exitCode, "tool": toolCall.name}
              except ToolError as e:
                let errorMsg = "Tool execution error: " & e.msg
                debug(errorMsg)  # Changed from warn to debug
                toolSuccess = false
                $ %*{"error": errorMsg, "tool": toolCall.name}
              except Exception as e:
                let errorMsg = "Unexpected error executing tool " & toolCall.name & ": " & e.msg
                error(errorMsg)
                toolSuccess = false
                $ %*{"error": errorMsg, "tool": toolCall.name}
            
            debug("Tool " & toolCall.name & " execution completed, output length: " & $output.len)
            debug("Output preview: " & (if output.len > 100: output[0..100] & "..." else: output))
            
            # Send response based on success/failure
            if toolSuccess:
              debug("Creating successful ToolResponse...")
              let toolResponse = ToolResponse(
                requestId: request.requestId,
                kind: trkResult,
                output: output
              )
              debug("ToolResponse created, sending...")
              sendToolResponse(channels, toolResponse)
              debug("ToolResponse sent successfully")
            else:
              debug("Creating error ToolResponse...")
              let toolResponse = ToolResponse(
                requestId: request.requestId,
                kind: trkError,
                error: output
              )
              debug("Error ToolResponse created, sending...")
              sendToolResponse(channels, toolResponse)
              debug("Error ToolResponse sent successfully")
            
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

proc startToolWorker*(channels: ptr ThreadChannels, level: Level, dump: bool = false, database: DatabaseBackend = nil, pool: Pool = nil): ToolWorker =
  result.isRunning = true
  # Create params as heap-allocated object to ensure it stays alive for thread lifetime
  var params = new(ThreadParams)
  params.channels = channels
  params.level = level
  params.dump = dump  
  params.database = database
  params.pool = pool
  createThread(result.thread, toolWorkerProc, params)

proc stopToolWorker*(worker: var ToolWorker) =
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false

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