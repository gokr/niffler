import std/[options, os, json, logging]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}

import ../types/[tools, messages]
import ../core/channels
import registry
# import ../implementations/index  # Not needed for now

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

proc toolWorkerProc(channels: ptr ThreadChannels) {.thread.} =
  # Initialize logging for this thread
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(lvlInfo)
  
  debug("Tool worker thread started")
  
  # Initialize tool registry for this thread
  initializeGlobalToolRegistry()
  debug("Tool registry initialized")
  
  try:
    while not isShutdownSignaled(channels):
      # Check for tool requests
      let maybeRequest = tryReceiveToolRequest(channels)
      
      if maybeRequest.isSome():
        let request = maybeRequest.get()
        
        case request.kind:
        of trkShutdown:
          info("Received shutdown signal")
          break
          
        of trkExecute:
          info("Processing tool request: " & request.requestId)
          info("Tool name: " & request.toolName)
          info("Arguments: " & request.arguments)
          
          try:
            # Parse the tool call from JSON arguments
            info("Parsing JSON arguments...")
            let toolCallJson = parseJson(request.arguments)
            info("JSON parsed successfully: " & $toolCallJson)
            
            let toolCall = tools.ToolCall(
              id: request.requestId,
              name: request.toolName,
              arguments: toolCallJson
            )
            info("ToolCall object created: " & toolCall.name)
            
            # Get the global tool registry
            info("Getting global tool registry...")
            let registryPtr = getGlobalToolRegistry()
            let registry = registryPtr[]
            info("Registry obtained")
            
            # Validate the tool call
            info("Validating tool call...")
            validateToolCall(registry, toolCall)
            info("Tool call validated successfully")
            
            # Get the tool definition
            info("Getting tool definition...")
            let toolOpt = getTool(registry, toolCall.name)
            if toolOpt.isNone:
              debug("Tool not found in registry: " & toolCall.name)
              raise newToolValidationError(toolCall.name, "name", "registered tool", toolCall.name)
            
            let toolDef = toolOpt.get()
            info("Tool definition obtained: " & toolDef.name)
            
            # Execute the tool - for now use a simple approach
            info("Executing tool " & toolDef.name & " with arguments: " & $toolCall.arguments)
            
            # Simple execution for testing - replace with proper tool execution later
            let output =
              case toolDef.name:
              of "read":
                # Simple file read for testing
                info("Executing read tool...")
                let path = getArgStr(toolCall.arguments, "path")
                info("Reading file: " & path)
                try:
                  let content = readFile(path)
                  let result = $ %*{"content": content, "path": path, "size": content.len}
                  info("File read successfully, size: " & $content.len)
                  result
                except:
                  let errorMsg = "Failed to read file: " & getCurrentExceptionMsg()
                  debug(errorMsg)
                  $ %*{"error": errorMsg}
              of "bash":
                info("Bash tool not implemented")
                $ %*{"error": "Bash tool not yet implemented"}
              of "list":
                info("List tool not implemented")
                $ %*{"error": "List tool not yet implemented"}
              of "edit":
                info("Edit tool not implemented")
                $ %*{"error": "Edit tool not yet implemented"}
              of "create":
                info("Create tool not implemented")
                $ %*{"error": "Create tool not yet implemented"}
              of "fetch":
                info("Fetch tool not implemented")
                $ %*{"error": "Fetch tool not yet implemented"}
              else:
                debug("Unknown tool: " & toolDef.name)
                raise newToolValidationError(toolDef.name, "name", "supported tool", toolDef.name)
            
            info("Tool " & toolDef.name & " execution completed, output length: " & $output.len)
            info("Output preview: " & (if output.len > 100: output[0..100] & "..." else: output))
            
            info("Creating ToolExecutionResponse...")
            let response = ToolExecutionResponse(
              requestId: request.requestId,
              result: newToolResult(output),
              success: true
            )
            info("ToolExecutionResponse created")
            
            # Send response back through channels
            info("Creating ToolResponse...")
            let toolResponse = ToolResponse(
              requestId: request.requestId,
              kind: trkResult,
              output: response.result.output
            )
            info("ToolResponse created, sending...")
            sendToolResponse(channels, toolResponse)
            info("ToolResponse sent successfully")
            
            info("Tool request " & request.requestId & " completed successfully")
            
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

proc startToolWorker*(channels: ptr ThreadChannels): ToolWorker =
  result.isRunning = true
  createThread(result.thread, toolWorkerProc, channels)
  debug("Tool worker thread started")

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