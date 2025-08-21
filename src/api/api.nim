## API Worker Thread
##
## This module implements the core API worker that handles all LLM communication
## and tool calling orchestration. It runs in a dedicated thread and communicates
## with the main thread and tool worker through thread-safe channels.
##
## Key Features:
## - Complete OpenAI-compatible tool calling implementation
## - Real-time streaming with tool call buffering during streaming
## - Sophisticated tool call fragment buffering for partial responses
## - Multi-turn conversations with tool results integration
## - Error recovery and timeout management
## - Support for concurrent tool execution
##
## Tool Calling Flow:
## 1. Sends tool schemas to LLM with each request
## 2. Detects tool calls in streaming response chunks
## 3. Buffers partial tool call fragments until complete
## 4. Executes tools via tool worker thread
## 5. Integrates tool results back into conversation
## 6. Continues conversation with LLM
##
## Design Decisions:
## - Thread-based architecture (no async) for deterministic behavior
## - Streaming-first approach with real-time chunk processing
## - Sophisticated buffering for handling partial tool calls during streaming
## - Exception-based error handling with comprehensive recovery

import std/[options, strformat, os, json, strutils, times, tables]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}
import ../types/[messages, config]
import std/logging
import ../core/[channels, history, database]
import curlyStreaming
import ../tools/schemas

type
  # Buffer for tracking incomplete tool calls during streaming
  ToolCallBuffer* = object
    id*: string
    name*: string
    arguments*: string
    lastUpdated*: float  # timestamp for timeout handling

  APIWorker* = object
    thread: Thread[ThreadParams]
    client: CurlyStreamingClient
    isRunning: bool

# Helper function to convert ChatToolCall to LLMToolCall - REMOVED (now using LLMToolCall directly)

# Helper functions for tool display
proc getToolIcon(toolName: string): string =
  case toolName:
  of "bash": "🔧"
  of "read": "📖"
  of "list": "📁"
  of "edit": "✏️"
  of "create": "📝"
  of "fetch": "🌐"
  else: "🔧"

proc getArgsPreview(arguments: string): string =
  try:
    let argsJson = parseJson(arguments)
    case argsJson.kind:
    of JObject:
      var parts: seq[string] = @[]
      for key, value in argsJson:
        case key:
        of "path", "file_path", "target_path":
          let pathStr = value.getStr()
          let filename = pathStr.splitPath().tail
          parts.add(if filename != "": filename else: pathStr)
        of "url":
          let urlStr = value.getStr()
          parts.add(urlStr)
        of "command":
          let cmdStr = value.getStr()
          parts.add(if cmdStr.len > 20: cmdStr[0..19] & "..." else: cmdStr)
        of "content":
          parts.add("...")
        of "old_string", "new_string":
          let str = value.getStr()
          parts.add(if str.len > 15: str[0..14] & "..." else: str)
        else:
          parts.add(".")
      return parts.join(", ")
    else:
      return "."
  except:
    return "."

# Helper functions for tool call buffering
proc isValidJson*(jsonStr: string): bool =
  ## Check if a string is valid JSON
  try:
    discard parseJson(jsonStr)
    return true
  except JsonParsingError:
    return false

proc isCompleteJson*(jsonStr: string): bool =
  ## Check if JSON string is complete (balanced braces and brackets)
  var braceCount = 0
  var bracketCount = 0
  var inString = false
  var escapeNext = false
  
  # Must start with { or [ to be valid JSON object/array
  if jsonStr.len == 0:
    return false
  
  let firstChar = jsonStr[0]
  if firstChar != '{' and firstChar != '[':
    return false
  
  for i, c in jsonStr:
    if escapeNext:
      escapeNext = false
      continue
    
    if c == '\\':
      escapeNext = true
      continue
    
    if c == '"' and not escapeNext:
      inString = not inString
      continue
    
    if not inString:
      case c:
      of '{': inc braceCount
      of '}': dec braceCount
      of '[': inc bracketCount
      of ']': dec bracketCount
      else: discard
  
  return braceCount == 0 and bracketCount == 0 and not inString

proc bufferToolCallFragment*(buffers: var Table[string, ToolCallBuffer], toolCall: LLMToolCall): bool =
  ## Buffer a tool call fragment, return true if complete
  let toolId = if toolCall.id.len > 0: toolCall.id else: "temp_" & $epochTime()
  
  # Special handling for Kimi K2: if we have fragments with null IDs, try to associate them
  # with the most recent tool call that has a name and is still accumulating arguments
  if toolCall.id.len == 0 and toolCall.function.name.len == 0:
    # Look for the most recent buffer that has a name and is still accumulating arguments
    # Kimi K2 sends fragments like: {"path", ":", " "."}, "}" which should all go to the same tool call
    var mostRecentBuffer: ptr ToolCallBuffer = nil
    var mostRecentTime = -1.0
    
    for existingId, existingBuffer in buffers:
      if existingBuffer.name.len > 0:
        # Prefer buffers that already have some arguments (continuing accumulation)
        if existingBuffer.arguments.len > 0:
          if existingBuffer.lastUpdated > mostRecentTime:
            mostRecentBuffer = buffers[existingId].addr
            mostRecentTime = existingBuffer.lastUpdated
        # Fall back to buffers with name but no arguments yet
        elif mostRecentBuffer.isNil:
          mostRecentBuffer = buffers[existingId].addr
          mostRecentTime = existingBuffer.lastUpdated
    
    if not mostRecentBuffer.isNil:
      # Associate this fragment with the most recent tool call buffer
      mostRecentBuffer[].arguments.add(toolCall.function.arguments)
      mostRecentBuffer[].lastUpdated = epochTime()
      
      # Check if the accumulated arguments form complete JSON
      let hasValidName = mostRecentBuffer[].name.len > 0
      let hasValidJson = mostRecentBuffer[].arguments.isCompleteJson() and mostRecentBuffer[].arguments.isValidJson()
      
      debug(fmt"Buffer check (associated): name='{mostRecentBuffer[].name}', args='{mostRecentBuffer[].arguments}', validName={hasValidName}, validJson={hasValidJson}")
      
      return hasValidName and hasValidJson
  
  if not buffers.hasKey(toolId):
    buffers[toolId] = ToolCallBuffer(
      id: toolId,
      name: toolCall.function.name,
      arguments: "",
      lastUpdated: epochTime()
    )
  
  let buffer = buffers[toolId].addr
  
  # Update name if it's available in this fragment
  if toolCall.function.name.len > 0:
    buffer[].name = toolCall.function.name
  
  # Add arguments fragment
  buffer[].arguments.add(toolCall.function.arguments)
  buffer[].lastUpdated = epochTime()
  
  # Check if the accumulated arguments form complete JSON
  # Only return true if we also have a valid tool name
  let hasValidName = buffer[].name.len > 0
  let hasValidJson = buffer[].arguments.isCompleteJson() and buffer[].arguments.isValidJson()
  
  debug(fmt"Buffer check: name='{buffer[].name}', args='{buffer[].arguments}', validName={hasValidName}, validJson={hasValidJson}")
  
  return hasValidName and hasValidJson

proc getCompletedToolCalls*(buffers: var Table[string, ToolCallBuffer]): seq[LLMToolCall] =
  ## Get all completed tool calls from buffers
  result = @[]
  var toRemove: seq[string] = @[]
  
  for id, buffer in buffers:
    if buffer.arguments.isCompleteJson() and buffer.arguments.isValidJson():
      result.add(LLMToolCall(
        id: buffer.id,
        `type`: "function",
        function: FunctionCall(
          name: buffer.name,
          arguments: buffer.arguments
        )
      ))
      toRemove.add(id)
  
  # Remove completed tool calls from buffers
  for id in toRemove:
    buffers.del(id)

proc cleanupStaleBuffers*(buffers: var Table[string, ToolCallBuffer], timeoutSeconds: int = 30) =
  ## Remove stale buffers that haven't been updated recently
  let currentTime = epochTime()
  var toRemove: seq[string] = @[]
  
  for id, buffer in buffers:
    if currentTime - buffer.lastUpdated > timeoutSeconds.float:
      debug(fmt"Removing stale tool call buffer for {buffer.name} (ID: {id})")
      toRemove.add(id)
  
  for id in toRemove:
    buffers.del(id)

proc apiWorkerProc(params: ThreadParams) {.thread, gcsafe.} =
  # Initialize logging for this thread
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(params.level)
  
  # Initialize dump flag for this thread
  setDumpEnabled(params.dump)
  
  let channels = params.channels
  let database = params.database
  
  debug("API worker thread started")
  incrementActiveThreads(channels)
  
  var currentClient: Option[CurlyStreamingClient] = none(CurlyStreamingClient)
  var activeRequests: seq[string] = @[]  # Track active request IDs for cancellation
  var toolCallBuffers: Table[string, ToolCallBuffer] = initTable[string, ToolCallBuffer]()  # Buffer incomplete tool calls
  
  try:
    while not isShutdownSignaled(channels):
      # Check for API requests
      let maybeRequest = tryReceiveAPIRequest(channels)
      
      if maybeRequest.isSome():
        let request = maybeRequest.get()
        
        case request.kind:
        of arkShutdown:
          debug("Received shutdown signal")
          break
          
        of arkConfigure:
          try:
            currentClient = some(newCurlyStreamingClient(
              request.configBaseUrl,
              request.configApiKey,
              request.configModelName
            ))
            debug(fmt"API client configured for {request.configBaseUrl}")
          except Exception as e:
            debug(fmt"Failed to configure API client: {e.msg}")
          
        of arkChatRequest:
          debug(fmt"Processing chat request: {request.requestId}")
          # Add to active requests for cancellation tracking
          activeRequests.add(request.requestId)
          
          # Initialize client with request parameters, or reconfigure if needed
          var needsNewClient = false
          if currentClient.isNone():
            needsNewClient = true
          else:
            # Check if current client configuration matches request
            var client = currentClient.get()
            if client.baseUrl != request.baseUrl or client.model != request.model:
              needsNewClient = true
              # Create new client for different configuration
              currentClient = none(CurlyStreamingClient)
          
          if needsNewClient:
            try:
              currentClient = some(newCurlyStreamingClient(
                request.baseUrl,
                request.apiKey,
                request.model
              ))
              debug(fmt"API client initialized for {request.baseUrl}")
            except Exception as e:
              let errorResponse = APIResponse(
                requestId: request.requestId,
                kind: arkStreamError,
                error: fmt"Failed to initialize API client: {e.msg}"
              )
              sendAPIResponse(channels, errorResponse)
              continue
          
          # Send ready response
          let readyResponse = APIResponse(
            requestId: request.requestId,
            kind: arkReady
          )
          sendAPIResponse(channels, readyResponse)
          
          try:
            # Create and send HTTP request
            var client = currentClient.get()
            
            # Create a temporary ModelConfig from the API request
            let tempModelConfig = ModelConfig(
              nickname: "api-request",
              baseUrl: request.baseUrl,
              model: request.model,
              context: 128000,  # Default context
              enabled: true,
              maxTokens: some(request.maxTokens),
              temperature: some(request.temperature),
              apiKey: some(request.apiKey),
              inputCostPerMToken: none(float),  # Will be filled from actual model config
              outputCostPerMToken: none(float)  # Will be filled from actual model config
            )
            
            let chatRequest = createChatRequest(
              tempModelConfig,
              request.messages,
              stream = true,  # Enable streaming for real-time responses
              tools = if request.enableTools: request.tools else: none(seq[ToolDefinition])
            )
            
            debug(fmt"Sending streaming request to {request.baseUrl}")
            if request.enableTools:
              let toolCount = if request.tools.isSome(): request.tools.get().len else: 0
              debug(fmt"Tools enabled: {toolCount}")
            
            # Handle streaming response with real-time chunks
            var fullContent = ""
            var collectedToolCalls: seq[LLMToolCall] = @[]
            var hasToolCalls = false
            var suppressInitialContent = false  # Suppress initial content if tool calls detected
            
            proc onChunkReceived(chunk: StreamChunk) {.gcsafe.} =
              # Check for cancellation before processing chunk
              if request.requestId notin activeRequests:
                debug(fmt"Request {request.requestId} was canceled, stopping chunk processing")
                return
                
              if chunk.choices.len > 0:
                let choice = chunk.choices[0]
                let delta = choice.delta
                
                # Send content chunks in real-time, unless we detect tool calls
                if delta.content.len > 0:
                  fullContent.add(delta.content)
                  
                  # Only send content if we haven't detected tool calls yet
                  if not suppressInitialContent:
                    let chunkResponse = APIResponse(
                      requestId: request.requestId,
                      kind: arkStreamChunk,
                      content: delta.content,
                      done: false
                    )
                    sendAPIResponse(channels, chunkResponse)
                
                # Buffer tool calls from delta instead of processing immediately
                if delta.toolCalls.isSome():
                  if not suppressInitialContent:
                    suppressInitialContent = true  # Stop sending initial content when ANY tool call fragment detected
                    debug("Tool call detected - suppressing further initial content")
                  for toolCall in delta.toolCalls.get():
                    debug(fmt"Buffering tool call fragment: id='{toolCall.id}', name='{toolCall.function.name}', args='{toolCall.function.arguments}'")
                    # Buffer the tool call fragment
                    let isComplete = bufferToolCallFragment(toolCallBuffers, toolCall)
                    debug(fmt"Tool call fragment complete: {isComplete}")
                    if isComplete:
                      # Tool call is complete, add to collected calls
                      let completedCalls = getCompletedToolCalls(toolCallBuffers)
                      for completedCall in completedCalls:
                        collectedToolCalls.add(completedCall)
                        hasToolCalls = true
                        debug(fmt"Complete tool call detected: {completedCall.function.name} with args: {completedCall.function.arguments}")
                    
                    # Clean up stale buffers periodically
                    cleanupStaleBuffers(toolCallBuffers)
            
            let (streamSuccess, streamUsage) = client.sendStreamingChatRequest(chatRequest, onChunkReceived)
            
            # Use extracted usage data from streaming response if available
            var finalUsage = if streamUsage.isSome(): 
              streamUsage.get() 
            else: 
              TokenUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0)
            
            # After streaming completes, check for any remaining completed tool calls in buffers
            let remainingCompletedCalls = getCompletedToolCalls(toolCallBuffers)
            for completedCall in remainingCompletedCalls:
              collectedToolCalls.add(completedCall)
              hasToolCalls = true
              debug(fmt"Final complete tool call detected: {completedCall.function.name} with args: {completedCall.function.arguments}")
            
            # Clean up any remaining stale buffers
            cleanupStaleBuffers(toolCallBuffers)
            
            # Process tool calls if any were collected
            if hasToolCalls and collectedToolCalls.len > 0:
                debug(fmt"Found {collectedToolCalls.len} tool calls in streaming response")
                
                # Send assistant message with tool calls
                let assistantResponse = APIResponse(
                  requestId: request.requestId,
                  kind: arkStreamChunk,
                  content: fullContent,
                  done: false,
                  toolCalls: some(collectedToolCalls)
                )
                sendAPIResponse(channels, assistantResponse)
                
                # Execute each tool call
                var allToolResults: seq[Message] = @[]
                for toolCall in collectedToolCalls:
                  debug(fmt"Executing tool call: {toolCall.function.name}")
                  
                  # Send tool execution status to user
                  let toolIcon = getToolIcon(toolCall.function.name)
                  let argsPreview = getArgsPreview(toolCall.function.arguments)
                  let toolStatusResponse = APIResponse(
                    requestId: request.requestId,
                    kind: arkStreamChunk,
                    content: fmt"{'\n'}{toolIcon} {toolCall.function.name}({argsPreview}){'\n'}",
                    done: false
                  )
                  sendAPIResponse(channels, toolStatusResponse)
                  
                  # Send tool request to tool worker
                  let toolRequest = ToolRequest(
                    kind: trkExecute,
                    requestId: toolCall.id,
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments
                  )
                  debug("Tool request: " & $toolRequest)
                  
                  if trySendToolRequest(channels, toolRequest):
                    # Wait for tool response
                    var attempts = 0
                    while attempts < 300:  # Timeout after ~30 seconds
                      let maybeResponse = tryReceiveToolResponse(channels)
                      if maybeResponse.isSome():
                        let toolResponse = maybeResponse.get()
                        debug("Tool response: " & $toolResponse)
                        if toolResponse.requestId == toolCall.id:
                          # Create tool result message
                          let toolContent = if toolResponse.kind == trkResult: toolResponse.output else: fmt"Error: {toolResponse.error}"
                          debug(fmt"Tool result received for {toolCall.function.name}: {toolContent[0..min(200, toolContent.len-1)]}...")
                          
                          # Tool completion - no status indicator needed, output shows success/failure
                          
                          let toolResultMsg = Message(
                            role: mrTool,
                            content: toolContent,
                            toolCallId: some(toolCall.id)
                          )
                          allToolResults.add(toolResultMsg)
                          
                          # Store tool result in conversation history
                          discard addToolMessage(toolContent, toolCall.id)
                          
                          break
                      sleep(100)
                      attempts += 1
                    
                    if attempts >= 300:
                      # Tool execution timed out - error will be in the tool result message
                      
                      let errorMsg = Message(
                        role: mrTool,
                        content: "Error: Tool execution timed out",
                        toolCallId: some(toolCall.id)
                      )
                      allToolResults.add(errorMsg)
                      
                      # Store error in conversation history
                      discard addToolMessage("Error: Tool execution timed out", toolCall.id)
                  else:
                    # Failed to send tool request - error will be in the tool result message
                    
                    let errorMsg = Message(
                      role: mrTool,
                      content: "Error: Failed to send tool request",
                      toolCallId: some(toolCall.id)
                    )
                    allToolResults.add(errorMsg)
                    
                    # Store error in conversation history
                    discard addToolMessage("Error: Failed to send tool request", toolCall.id)
                
                # Send tool results back to LLM for continuation
                if allToolResults.len > 0:
                  debug(fmt"Sending {allToolResults.len} tool results back to LLM")
                  
                  # Add tool results to conversation and continue
                  var updatedMessages = request.messages
                  
                  # Add the assistant message with tool calls
                  let assistantWithTools = Message(
                    role: mrAssistant,
                    content: fullContent,
                    toolCalls: some(collectedToolCalls)
                  )
                  updatedMessages.add(assistantWithTools)
                  
                  # Store assistant message with tool calls in conversation history
                  discard addAssistantMessage(fullContent, some(collectedToolCalls))
                  # Add all tool result messages
                  for toolResult in allToolResults:
                    updatedMessages.add(toolResult)
                  # Create follow-up request to continue conversation
                  debug(fmt"Creating follow-up request with {updatedMessages.len} messages")
                  
                  # Create a temporary ModelConfig from the API request
                  let tempModelConfig = ModelConfig(
                    nickname: "api-request-followup",
                    baseUrl: request.baseUrl,
                    model: request.model,
                    context: 128000,  # Default context
                    enabled: true,
                    maxTokens: some(request.maxTokens),
                    temperature: some(request.temperature),
                    apiKey: some(request.apiKey)
                  )
                  
                  let followUpRequest = createChatRequest(
                    tempModelConfig,
                    updatedMessages,
                    stream = true,
                    tools = if request.enableTools: request.tools else: none(seq[ToolDefinition])
                  )
                  
                  debug("Sending streaming follow-up request to LLM with tool results...")
                  
                  # Handle follow-up streaming response
                  var followUpContent = ""
                  proc onFollowUpChunk(chunk: StreamChunk) {.gcsafe.} =
                    # Check for cancellation
                    if request.requestId notin activeRequests:
                      debug(fmt"Follow-up request {request.requestId} was canceled")
                      return
                      
                    if chunk.choices.len > 0:
                      let choice = chunk.choices[0]
                      let delta = choice.delta
                      
                      # Send follow-up content (initial content was suppressed)
                      if delta.content.len > 0:
                        followUpContent.add(delta.content)
                        let chunkResponse = APIResponse(
                          requestId: request.requestId,
                          kind: arkStreamChunk,
                          content: delta.content,
                          done: false
                        )
                        sendAPIResponse(channels, chunkResponse)
                      
                      # Buffer tool calls from delta (same logic as main streaming)
                      if delta.toolCalls.isSome():
                        for toolCall in delta.toolCalls.get():
                          # Buffer the tool call fragment
                          let isComplete = bufferToolCallFragment(toolCallBuffers, toolCall)
                          if isComplete:
                            # Tool call is complete, add to collected calls
                            let completedCalls = getCompletedToolCalls(toolCallBuffers)
                            for completedCall in completedCalls:
                              collectedToolCalls.add(completedCall)
                              hasToolCalls = true
                              debug(fmt"Follow-up complete tool call detected: {completedCall.function.name} with args: {completedCall.function.arguments}")
                          
                          # Clean up stale buffers periodically
                          cleanupStaleBuffers(toolCallBuffers)
                  
                  let (followUpSuccess, followUpUsage) = client.sendStreamingChatRequest(followUpRequest, onFollowUpChunk)
                  
                  # Update usage data with follow-up request usage if available
                  if followUpUsage.isSome():
                    finalUsage = followUpUsage.get()
                  
                  # After follow-up streaming completes, check for any remaining completed tool calls in buffers
                  let followUpCompletedCalls = getCompletedToolCalls(toolCallBuffers)
                  for completedCall in followUpCompletedCalls:
                    collectedToolCalls.add(completedCall)
                    hasToolCalls = true
                    debug(fmt"Follow-up final complete tool call detected: {completedCall.function.name} with args: {completedCall.function.arguments}")
                  
                  # Clean up any remaining stale buffers
                  cleanupStaleBuffers(toolCallBuffers)
                  
                  debug(fmt"Follow-up streaming response completed")
                  
                  # Send final completion signal
                  let finalChunkResponse = APIResponse(
                    requestId: request.requestId,
                    kind: arkStreamChunk,
                    content: "",
                    done: true
                  )
                  sendAPIResponse(channels, finalChunkResponse)
                  
                  # Send completion with extracted usage data
                  # Log model-specific token usage to database
                  if database != nil:
                    try:
                      # Get current conversation ID from history and convert to int
                      let conversationId = getCurrentConversationId().int
                      let messageId = getCurrentMessageId().int
                      
                      # Get pricing from temp model config (already has Option[float] type)
                      let inputCostPerMToken = tempModelConfig.inputCostPerMToken
                      let outputCostPerMToken = tempModelConfig.outputCostPerMToken
                      
                      # Log model-specific token usage to database
                      logModelTokenUsage(database, conversationId, messageId, request.model,
                                        finalUsage.inputTokens, finalUsage.outputTokens,
                                        inputCostPerMToken, outputCostPerMToken)
                      
                      debug(fmt"Logged token usage for model {request.model}: {finalUsage.inputTokens} input, {finalUsage.outputTokens} output")
                    except Exception as e:
                      debug(fmt"Failed to log token usage to database: {e.msg}")
                  
                  let completeResponse = APIResponse(
                    requestId: request.requestId,
                    kind: arkStreamComplete,
                    usage: finalUsage,
                    finishReason: "stop"
                  )
                  sendAPIResponse(channels, completeResponse)
                  
                  # Remove from active requests
                  for i in 0..<activeRequests.len:
                    if activeRequests[i] == request.requestId:
                      activeRequests.delete(i)
                      break
                  
                  debug(fmt"Tool calling conversation completed for request {request.requestId}")
                  debug("Successfully sent streaming final response back to user")
                else:
                  # No valid tool results, send error
                  let errorResponse = APIResponse(
                    requestId: request.requestId,
                    kind: arkStreamError,
                    error: "Failed to execute tool calls"
                  )
                  sendAPIResponse(channels, errorResponse)
            else:
              # No tool calls, regular streaming response (content was already streamed in onChunkReceived)
              # Send final completion signal
              let finalChunkResponse = APIResponse(
                requestId: request.requestId,
                kind: arkStreamChunk,
                content: "",
                done: true
              )
              sendAPIResponse(channels, finalChunkResponse)
              
              # Send completion response with extracted usage data
              let completeResponse = APIResponse(
                requestId: request.requestId,
                kind: arkStreamComplete,
                usage: finalUsage,
                finishReason: "stop"
              )
              sendAPIResponse(channels, completeResponse)
              
              # Remove from active requests
              for i in 0..<activeRequests.len:
                if activeRequests[i] == request.requestId:
                  activeRequests.delete(i)
                  break
              
              debug(fmt"Streaming request {request.requestId} completed successfully")
            
          except Exception as e:
            # Remove from active requests on error
            for i in 0..<activeRequests.len:
              if activeRequests[i] == request.requestId:
                activeRequests.delete(i)
                break
                
            let errorResponse = APIResponse(
              requestId: request.requestId,
              kind: arkStreamError,
              error: fmt"API request failed: {e.msg}"
            )
            sendAPIResponse(channels, errorResponse)
            debug(fmt"Request {request.requestId} failed: {e.msg}")
        
        of arkStreamCancel:
          debug(fmt"Canceling stream: {request.cancelRequestId}")
          # Remove the request from active requests
          for i in 0..<activeRequests.len:
            if activeRequests[i] == request.cancelRequestId:
              activeRequests.delete(i)
              # Send cancellation response
              let cancelResponse = APIResponse(
                requestId: request.cancelRequestId,
                kind: arkStreamError,
                error: "Stream canceled by user"
              )
              sendAPIResponse(channels, cancelResponse)
              debug(fmt"Stream {request.cancelRequestId} canceled successfully")
              break
          
      else:
        # No requests, sleep briefly
        sleep(10)
    
  except Exception as e:
    fatal(fmt"API worker thread crashed: {e.msg}")
  finally:
    # Curly handles cleanup automatically, no need to explicitly close
    decrementActiveThreads(channels)
    debug("API worker thread stopped")

proc startAPIWorker*(channels: ptr ThreadChannels, level: Level, dump: bool = false, database: DatabaseBackend = nil): APIWorker =
  result.isRunning = true
  let params = ThreadParams(channels: channels, level: level, dump: dump, database: database)
  createThread(result.thread, apiWorkerProc, params)

proc stopAPIWorker*(worker: var APIWorker) =
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false

proc initializeAPIClient*(worker: var APIWorker, config: ModelConfig) =
  # This will be called when we have configuration loaded
  # For now, just log the configuration
  debug(fmt"Would initialize client for: {config.baseUrl}")

proc sendChatRequestAsync*(channels: ptr ThreadChannels, messages: seq[Message], 
                          modelConfig: ModelConfig, requestId: string, apiKey: string,
                          maxTokens: int = 2048, temperature: float = 0.7): bool =
  let toolSchemas = getAllToolSchemas()
  debug(fmt"Preparing chat request with {toolSchemas.len} available tools")
  
  let request = APIRequest(
    kind: arkChatRequest,
    requestId: requestId,
    messages: messages,
    model: modelConfig.model,
    maxTokens: maxTokens,
    temperature: temperature,
    baseUrl: modelConfig.baseUrl,
    apiKey: apiKey,
    enableTools: true,
    tools: some(toolSchemas)
  )
  
  return trySendAPIRequest(channels, request)