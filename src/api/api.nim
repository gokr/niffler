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
import ../types/[messages, config, thinking_tokens]
import std/logging
import ../core/[channels, conversation_manager, database]
import curlyStreaming
import ../tools/[registry, common]
import ../ui/tool_visualizer
import tool_call_parser
import debby/pools


type
  # Buffer for tracking incomplete tool calls during streaming
  ToolCallBuffer* = object
    id*: string
    name*: string
    arguments*: string
    lastUpdated*: float  # timestamp for timeout handling
    format*: Option[ToolFormat]  # detected format for this tool call

  APIWorker* = object
    thread: Thread[ThreadParams]
    client: CurlyStreamingClient
    isRunning: bool

# Helper functions for tool call buffering (now format-aware)
proc isValidJson*(jsonStr: string): bool =
  ## Check if a string is valid JSON (legacy function for compatibility)
  try:
    discard parseJson(jsonStr)
    return true
  except JsonParsingError:
    return false

proc isCompleteJson*(jsonStr: string): bool =
  ## Check if JSON string is complete (legacy function for compatibility)
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

# New format-aware validation functions
proc detectAndValidateFormat*(content: string, buffer: var ToolCallBuffer): bool =
  ## Detect format and validate tool call content
  if buffer.format.isNone:
    let detectedFormat = detectToolCallFormat(content)
    buffer.format = some(detectedFormat)
    debug(fmt"Detected tool call format for buffer {buffer.id}: {detectedFormat}")
  
  let format = buffer.format.get()
  return isValidToolCall(content, format)

proc isToolCallComplete*(content: string, buffer: ToolCallBuffer): bool =
  ## Check if tool call is complete based on detected format
  if buffer.format.isNone:
    return false
  
  let format = buffer.format.get()
  return isCompleteToolCall(content, format)

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
      
      # Check if the accumulated arguments are complete using format-aware validation
      let hasValidName = mostRecentBuffer[].name.len > 0
      let isComplete = detectAndValidateFormat(mostRecentBuffer[].arguments, mostRecentBuffer[]) and 
                      isToolCallComplete(mostRecentBuffer[].arguments, mostRecentBuffer[])
      
      debug(fmt"Buffer check (associated): name='{mostRecentBuffer[].name}', args='{mostRecentBuffer[].arguments}', validName={hasValidName}, isComplete={isComplete}")
      
      return hasValidName and isComplete
  
  if not buffers.hasKey(toolId):
    buffers[toolId] = ToolCallBuffer(
      id: toolId,
      name: toolCall.function.name,
      arguments: "",
      lastUpdated: epochTime(),
      format: none(ToolFormat)
    )
  
  let buffer = buffers[toolId].addr
  
  # Update name if it's available in this fragment
  if toolCall.function.name.len > 0:
    buffer[].name = toolCall.function.name
  
  # Add arguments fragment
  buffer[].arguments.add(toolCall.function.arguments)
  buffer[].lastUpdated = epochTime()
  
  # Check if the tool call is complete using format-aware validation
  # Only return true if we also have a valid tool name
  let hasValidName = buffer[].name.len > 0
  let isComplete = detectAndValidateFormat(buffer[].arguments, buffer[]) and 
                  isToolCallComplete(buffer[].arguments, buffer[])
  
  debug(fmt"Buffer check: name='{buffer[].name}', args='{buffer[].arguments}', validName={hasValidName}, isComplete={isComplete}")
  
  return hasValidName and isComplete

proc getCompletedToolCalls*(buffers: var Table[string, ToolCallBuffer]): seq[LLMToolCall] =
  ## Get all completed tool calls from buffers
  result = @[]
  var toRemove: seq[string] = @[]
  
  for id, buffer in buffers:
    # Use format-aware validation - make a copy to check completion
    var bufferCopy = buffer
    if detectAndValidateFormat(buffer.arguments, bufferCopy) and 
       isToolCallComplete(buffer.arguments, buffer):
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
    # Remove stale buffers based on time
    if currentTime - buffer.lastUpdated > timeoutSeconds.float:
      debug(fmt"Removing stale tool call buffer for {buffer.name} (ID: {id})")
      toRemove.add(id)
    # Remove malformed buffers with null IDs that have no name
    elif id.startsWith("temp_") and buffer.name.len == 0 and buffer.arguments.len == 0:
      debug(fmt"Removing malformed buffer with temp ID: {id}")
      toRemove.add(id)
    # Remove buffers that failed format detection and have no content
    elif buffer.format.isNone and buffer.arguments.len == 0 and currentTime - buffer.lastUpdated > 5.0:
      debug(fmt"Removing empty buffer that failed format detection: {id}")
      toRemove.add(id)
  
  for id in toRemove:
    buffers.del(id)

proc executeToolCallsAndContinue*(channels: ptr ThreadChannels, client: var CurlyStreamingClient,
                                request: APIRequest, toolCalls: seq[LLMToolCall],
                                initialContent: string, database: DatabaseBackend,
                                recursionDepth: int = 0,
                                executedCalls: seq[string] = @[]): bool =
  ## Execute tool calls and continue conversation recursively
  ## Returns true if successful, false if max recursion depth exceeded
  const MAX_RECURSION_DEPTH = 20  # Reduced from 100 to prevent excessive loops
  
  if recursionDepth >= MAX_RECURSION_DEPTH:
    debug(fmt"Max recursion depth ({MAX_RECURSION_DEPTH}) exceeded, stopping tool execution")
    return false
  
  if toolCalls.len == 0:
    return true
    
  debug(fmt"Executing {toolCalls.len} tool calls (recursion depth: {recursionDepth})")
  
  # Check for duplicate tool calls to prevent infinite loops
  var filteredToolCalls: seq[LLMToolCall] = @[]
  var updatedExecutedCalls = executedCalls
  
  for toolCall in toolCalls:
    # Create a normalized signature for better deduplication
    var normalizedArgs = ""
    try:
      # Try to normalize JSON arguments to catch formatting differences
      let argsJson = parseJson(toolCall.function.arguments)
      normalizedArgs = $argsJson
    except:
      # Fall back to original arguments if JSON parsing fails
      normalizedArgs = toolCall.function.arguments.strip()
    
    let toolSignature = fmt"{toolCall.function.name}({normalizedArgs})"
    
    # Also check by tool call ID to prevent the same call being executed twice
    var isDuplicate = false
    if toolSignature in executedCalls:
      isDuplicate = true
      debug(fmt"DEBUG: Skipping duplicate tool call (signature match): {toolSignature}")
    else:
      # Additional check: same tool call ID indicates exact duplicate
      for prevCall in filteredToolCalls:
        if prevCall.id == toolCall.id and toolCall.id.len > 0:
          isDuplicate = true
          debug(fmt"DEBUG: Skipping duplicate tool call (ID match): {toolCall.id}")
          break
    
    if not isDuplicate:
      filteredToolCalls.add(toolCall)
      updatedExecutedCalls.add(toolSignature)
  
  if filteredToolCalls.len == 0:
    debug("DEBUG: All tool calls were duplicates, sending feedback to model")
    # Instead of stopping, create a tool result indicating duplication
    let duplicateResult = Message(
      role: mrTool,
      toolCallId: some(toolCalls[0].id),
      content: "Note: This tool call was already executed. Please continue the conversation without repeating the same call, or try a different approach if the previous result was insufficient."
    )
    
    # Add duplicate feedback and continue conversation using same pattern as normal tool results
    var updatedMessages = request.messages
    
    # Add the assistant message with tool calls (even though duplicates)
    let assistantWithTools = Message(
      role: mrAssistant,
      content: initialContent,
      toolCalls: some(toolCalls)
    )
    updatedMessages.add(assistantWithTools)
    updatedMessages.add(duplicateResult)
    
    # Create temporary ModelConfig to continue conversation  
    let tempModelConfig = ModelConfig(
      nickname: fmt"api-request-duplicate-{recursionDepth}",
      baseUrl: request.baseUrl,
      model: request.model,
      context: 128000,
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
    
    # Continue with streaming follow-up to let model respond to duplicate feedback
    debug("Continuing conversation with duplicate feedback instead of stopping")
    var followUpContent = ""
    var followUpToolCalls: seq[LLMToolCall] = @[]
    var toolCallBuffers: Table[string, ToolCallBuffer] = initTable[string, ToolCallBuffer]()
    
    proc onDuplicateFollowUp(chunk: StreamChunk) {.gcsafe.} =
      if chunk.choices.len > 0:
        let choice = chunk.choices[0]
        let delta = choice.delta
        
        # Handle content
        if delta.content.len > 0:
          followUpContent.add(delta.content)
          let contentResponse = APIResponse(
            requestId: request.requestId,
            kind: arkStreamChunk,
            content: delta.content,
            done: false,
            thinkingContent: none(string),
            isEncrypted: none(bool)
          )
          sendAPIResponse(channels, contentResponse)
        
        # Buffer tool calls for recursive execution (same pattern as existing code)
        if delta.toolCalls.isSome():
          for toolCall in delta.toolCalls.get():
            let isComplete = bufferToolCallFragment(toolCallBuffers, toolCall)
            if isComplete:
              let completedCalls = getCompletedToolCalls(toolCallBuffers)
              for completedCall in completedCalls:
                followUpToolCalls.add(completedCall)
                debug(fmt"Duplicate follow-up tool call detected (depth {recursionDepth}): {completedCall.function.name}")
            cleanupStaleBuffers(toolCallBuffers)
    
    let (success, _) = client.sendStreamingChatRequest(followUpRequest, onDuplicateFollowUp)
    
    # Get any remaining completed tool calls after streaming completes
    let remainingCalls = getCompletedToolCalls(toolCallBuffers)
    for completedCall in remainingCalls:
      followUpToolCalls.add(completedCall)
    
    # Recursively execute any follow-up tool calls detected
    if followUpToolCalls.len > 0:
      debug(fmt"Executing {followUpToolCalls.len} follow-up tool calls from duplicate feedback (depth: {recursionDepth})")
      discard executeToolCallsAndContinue(channels, client, request, followUpToolCalls, followUpContent, database, recursionDepth + 1, updatedExecutedCalls)
    
    return success
  
  debug(fmt"After deduplication: {filteredToolCalls.len} unique tool calls")
  
  # Execute each unique tool call
  var allToolResults: seq[Message] = @[]
  for toolCall in filteredToolCalls:
    debug(fmt"Executing tool call: {toolCall.function.name}")
    
    # Send tool request display to UI (needed for tool calls not announced during streaming)
    var argsJson = newJObject()
    try:
      argsJson = parseJson(toolCall.function.arguments)
    except:
      argsJson = %*{"raw": toolCall.function.arguments}
    
    # Get tool icon from centralized function
    let toolIcon = getToolIcon(toolCall.function.name)
    
    let toolRequestInfo = CompactToolRequestInfo(
      toolName: toolCall.function.name,
      toolCallId: toolCall.id,
      args: argsJson,
      icon: toolIcon,
      status: "⏳"
    )
    
    let toolRequestResponse = APIResponse(
      requestId: request.requestId,
      kind: arkToolCallRequest,
      toolRequestInfo: toolRequestInfo
    )
    sendAPIResponse(channels, toolRequestResponse)
    
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
      while attempts < 3000:  # Timeout after ~300 seconds
        let maybeResponse = tryReceiveToolResponse(channels)
        if maybeResponse.isSome():
          let toolResponse = maybeResponse.get()
          debug("Tool response: " & $toolResponse)
          if toolResponse.requestId == toolCall.id:
            # Create tool result message
            let toolContent = if toolResponse.kind == trkResult: toolResponse.output else: fmt"Error: {toolResponse.error}"
            debug(fmt"Tool result received for {toolCall.function.name}: {toolContent[0..min(200, toolContent.len-1)]}...")
            
            # Send compact tool result visualization to user
            try:
              let toolSuccess = toolResponse.kind == trkResult
              # Use enhanced tool result summary from tool_visualizer
              let toolResult = if toolSuccess: toolResponse.output else: toolResponse.error
              let resultSummary = createToolResultSummary(toolCall.function.name, toolResult, toolSuccess)
              
              # Get tool icon from centralized function
              let toolIcon = getToolIcon(toolCall.function.name)
              
              let toolResultInfo = CompactToolResultInfo(
                toolCallId: toolCall.id,
                toolName: toolCall.function.name,
                icon: toolIcon,
                success: toolSuccess,
                resultSummary: resultSummary,
                executionTime: 0.0
              )
              
              let toolResultResponse = APIResponse(
                requestId: request.requestId,
                kind: arkToolCallResult,
                toolResultInfo: toolResultInfo
              )
              sendAPIResponse(channels, toolResultResponse)
            except Exception as e:
              debug(fmt"Failed to format compact tool result: {e.msg}")
              # Simple debug output fallback
              let status = if toolResponse.kind == trkResult: "success" else: "error"
              debug(fmt"Tool {toolCall.function.name} completed: {status}")
            
            let toolResultMsg = Message(
              role: mrTool,
              content: toolContent,
              toolCallId: some(toolCall.id)
            )
            allToolResults.add(toolResultMsg)
            
            # Store tool result in conversation history (conversation_manager handles database/threadvar fallback)
            discard conversation_manager.addToolMessage(toolContent, toolCall.id)
            
            break
        sleep(100)
        attempts += 1
      
      if attempts >= 300:
        # Tool execution timed out
        let errorMsg = Message(
          role: mrTool,
          content: "Error: Tool execution timed out",
          toolCallId: some(toolCall.id)
        )
        allToolResults.add(errorMsg)
        discard conversation_manager.addToolMessage("Error: Tool execution timed out", toolCall.id)
    else:
      # Failed to send tool request
      let errorMsg = Message(
        role: mrTool,
        content: "Error: Failed to send tool request",
        toolCallId: some(toolCall.id)
      )
      allToolResults.add(errorMsg)
      discard conversation_manager.addToolMessage("Error: Failed to send tool request", toolCall.id)
  
  # Send tool results back to LLM for continuation
  if allToolResults.len > 0:
    debug(fmt"Sending {allToolResults.len} tool results back to LLM (depth: {recursionDepth})")
    
    # Add tool results to conversation and continue
    var updatedMessages = request.messages
    
    # Add the assistant message with tool calls
    let assistantWithTools = Message(
      role: mrAssistant,
      content: initialContent,
      toolCalls: some(toolCalls)
    )
    updatedMessages.add(assistantWithTools)
    
    # Store assistant message with tool calls in conversation history (conversation_manager handles database/threadvar fallback)
    discard conversation_manager.addAssistantMessage(initialContent, some(toolCalls))
    
    # Add all tool result messages
    for toolResult in allToolResults:
      updatedMessages.add(toolResult)
    
    # Create follow-up request to continue conversation
    debug(fmt"Creating follow-up request with {updatedMessages.len} messages (depth: {recursionDepth})")
    
    # Create a temporary ModelConfig from the API request
    let tempModelConfig = ModelConfig(
      nickname: fmt"api-request-followup-{recursionDepth}",
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
    
    debug(fmt"Sending streaming follow-up request to LLM with tool results (depth: {recursionDepth})...")
    
    # Handle follow-up streaming response with recursive tool call support
    var followUpContent = ""
    var followUpToolCalls: seq[LLMToolCall] = @[]
    var toolCallBuffers: Table[string, ToolCallBuffer] = initTable[string, ToolCallBuffer]()
    
    proc onFollowUpChunk(chunk: StreamChunk) {.gcsafe.} =
      if chunk.choices.len > 0:
        let choice = chunk.choices[0]
        let delta = choice.delta
        
        # Debug finish reason
        if choice.finishReason.isSome():
          debug(fmt"DEBUG: Follow-up stream finish reason: '{choice.finishReason.get()}'")
        
        # Send follow-up content
        if delta.content.len > 0:
          followUpContent.add(delta.content)
          let chunkResponse = APIResponse(
            requestId: request.requestId,
            kind: arkStreamChunk,
            content: delta.content,
            done: false,
            thinkingContent: none(string),
            isEncrypted: none(bool)
          )
          sendAPIResponse(channels, chunkResponse)
        
        # Buffer tool calls for recursive execution
        if delta.toolCalls.isSome():
          for toolCall in delta.toolCalls.get():
            let isComplete = bufferToolCallFragment(toolCallBuffers, toolCall)
            if isComplete:
              let completedCalls = getCompletedToolCalls(toolCallBuffers)
              for completedCall in completedCalls:
                followUpToolCalls.add(completedCall)
                debug(fmt"Follow-up tool call detected (depth {recursionDepth}): {completedCall.function.name}")
            cleanupStaleBuffers(toolCallBuffers)
    
    let (_, followUpUsage) = client.sendStreamingChatRequest(followUpRequest, onFollowUpChunk)
    
    # Get any remaining completed tool calls
    let remainingCalls = getCompletedToolCalls(toolCallBuffers)
    for completedCall in remainingCalls:
      followUpToolCalls.add(completedCall)
    
    cleanupStaleBuffers(toolCallBuffers)
    
    # If we have more tool calls, execute them recursively
    if followUpToolCalls.len > 0:
      debug(fmt"Found {followUpToolCalls.len} follow-up tool calls, executing recursively")
      return executeToolCallsAndContinue(channels, client, request, followUpToolCalls, 
                                       followUpContent, database, recursionDepth + 1, updatedExecutedCalls)
    else:
      # No more tool calls, send completion
      debug(fmt"DEBUG: No follow-up tool calls found (depth {recursionDepth}). Follow-up content: '{followUpContent}'")
      let finalChunkResponse = APIResponse(
        requestId: request.requestId,
        kind: arkStreamChunk,
        content: "",
        done: true,
        thinkingContent: none(string),
        isEncrypted: none(bool)
      )
      sendAPIResponse(channels, finalChunkResponse)
      
      # Use follow-up usage if available, otherwise default
      var finalUsage = if followUpUsage.isSome(): 
        followUpUsage.get() 
      else: 
        TokenUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0)
      
      # Log token usage for tool conversations  
      let conversationId = getCurrentConversationId().int
      let messageId = getCurrentMessageId().int
      
      logTokenUsageFromRequest(request.model, finalUsage, conversationId, messageId)
      
      let completeResponse = APIResponse(
        requestId: request.requestId,
        kind: arkStreamComplete,
        usage: finalUsage,
        finishReason: "stop"
      )
      sendAPIResponse(channels, completeResponse)
      
      debug(fmt"Recursive tool execution completed at depth {recursionDepth}")
      return true
  
  return true

proc apiWorkerProc(params: ThreadParams) {.thread, gcsafe.} =
  # Initialize logging for this thread - use stderr to prevent stdout contamination
  let consoleLogger = newConsoleLogger(useStderr = true)
  addHandler(consoleLogger)
  setLogFilter(params.level)
  
  # Initialize dump flag for this thread
  setDumpEnabled(params.dump)
  
  let channels = params.channels
  let database = params.database
  
  # Initialize conversation tracking
  
  debug("API worker thread started")
  incrementActiveThreads(channels)
  
  # Initialize flexible parser for tool call format detection
  initGlobalParser()
  
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
            var hasThinkingContent = false
            
            proc onChunkReceived(chunk: StreamChunk) {.gcsafe.} =
              # Check for cancellation before processing chunk
              if request.requestId notin activeRequests:
                debug(fmt"Request {request.requestId} was canceled, stopping chunk processing")
                return
                
              if chunk.choices.len > 0:
                let choice = chunk.choices[0]
                let delta = choice.delta
                
                # Handle tool calls first to determine if content should be sent
                var chunkHasToolCalls = false
                if delta.toolCalls.isSome():
                  chunkHasToolCalls = true
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
                        
                        # Tool call request notification will be sent by main execution loop
                    
                    # Clean up stale buffers periodically
                    cleanupStaleBuffers(toolCallBuffers)
                
                # Handle thinking token processing from streaming chunks
                var thinkingContentStr: Option[string] = none(string)
                var isThinkingEncrypted: Option[bool] = none(bool)
                
                if chunk.isThinkingContent and chunk.thinkingContent.isSome():
                  let thinkingContent = chunk.thinkingContent.get()
                  if thinkingContent.len > 0:
                    let format = if chunk.isEncrypted.isSome() and chunk.isEncrypted.get(): 
                                  ttfEncrypted 
                                else: 
                                  ttfAnthropic  # Default to Anthropic format, could enhance detection
                    let isEncrypted = chunk.isEncrypted.isSome() and chunk.isEncrypted.get()
                    
                    # Store thinking token in database
                    discard storeThinkingTokenFromStreaming(thinkingContent, format, none(int), isEncrypted)
                    
                    # Prepare thinking content for UI display
                    hasThinkingContent = true
                    thinkingContentStr = some(thinkingContent)
                    isThinkingEncrypted = some(isEncrypted)
                    
                    debug(fmt"Processed thinking token: {thinkingContent.len} chars, format: {format}, encrypted: {isEncrypted}")
                
                # Send content chunks in real-time (but coordinate with tool calls)
                if delta.content.len > 0:
                  fullContent.add(delta.content)
                  # Only send content if this chunk doesn't contain tool calls or if we're not actively processing tool calls
                  if not chunkHasToolCalls or not hasToolCalls:
                    let chunkResponse = APIResponse(
                      requestId: request.requestId,
                      kind: arkStreamChunk,
                      content: delta.content,
                      done: false,
                      thinkingContent: thinkingContentStr,
                      isEncrypted: isThinkingEncrypted
                    )
                    sendAPIResponse(channels, chunkResponse)
                elif hasThinkingContent:
                  # Send thinking content even if there's no regular content
                  let thinkingOnlyResponse = APIResponse(
                    requestId: request.requestId,
                    kind: arkStreamChunk,
                    content: "",
                    done: false,
                    thinkingContent: thinkingContentStr,
                    isEncrypted: isThinkingEncrypted
                  )
                  sendAPIResponse(channels, thinkingOnlyResponse)
            
            let (_, streamUsage) = client.sendStreamingChatRequest(chatRequest, onChunkReceived)
            
            # Use extracted usage data from streaming response if available
            var finalUsage = if streamUsage.isSome(): 
              streamUsage.get() 
            else: 
              TokenUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0)
            
            # Add reasoning tokens from thinking content if missing from API response
            if (finalUsage.reasoningTokens.isNone() or finalUsage.reasoningTokens.get() == 0) and hasThinkingContent:
              # Count tokens from all thinking content in this response
              {.gcsafe.}:
                let database = getGlobalDatabase()
                if database != nil:
                  try:
                    let conversationId = getCurrentConversationId().int
                    let reasoningStats = getConversationReasoningTokens(database, conversationId)
                    if reasoningStats.totalReasoning > 0:
                      finalUsage.reasoningTokens = some(reasoningStats.totalReasoning)
                      debug(fmt"Added {reasoningStats.totalReasoning} reasoning tokens from XML thinking content")
                  except Exception as e:
                    debug(fmt"Failed to add reasoning tokens from thinking content: {e.msg}")
            
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
                
                # Send assistant message with tool calls (content was already streamed)
                let assistantResponse = APIResponse(
                  requestId: request.requestId,
                  kind: arkStreamChunk,
                  content: "",
                  done: false,
                  toolCalls: some(collectedToolCalls),
                  thinkingContent: none(string),
                  isEncrypted: none(bool)
                )
                sendAPIResponse(channels, assistantResponse)
                
                # Use shared tool execution function with recursive support
                var mutableClient = client
                let executeSuccess = executeToolCallsAndContinue(channels, mutableClient, request, 
                                                               collectedToolCalls, fullContent, database)
                
                if not executeSuccess:
                  # Execution failed (likely max recursion depth exceeded)
                  let errorResponse = APIResponse(
                    requestId: request.requestId,
                    kind: arkStreamError,
                    error: "Tool execution failed or exceeded maximum recursion depth"
                  )
                  sendAPIResponse(channels, errorResponse)
                
                # Remove from active requests
                for i in 0..<activeRequests.len:
                  if activeRequests[i] == request.requestId:
                    activeRequests.delete(i)
                    break
            else:
              # No tool calls, regular streaming response (content was already streamed in onChunkReceived)
              # Send final completion signal
              let finalChunkResponse = APIResponse(
                requestId: request.requestId,
                kind: arkStreamChunk,
                content: "",
                done: true,
                thinkingContent: none(string),
                isEncrypted: none(bool)
              )
              sendAPIResponse(channels, finalChunkResponse)
              
              # Log token usage for regular (non-tool) conversations
              let conversationId = getCurrentConversationId().int
              let messageId = getCurrentMessageId().int
              
              logTokenUsageFromRequest(request.model, finalUsage, conversationId, messageId)
              
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

proc startAPIWorker*(channels: ptr ThreadChannels, level: Level, dump: bool = false, database: DatabaseBackend = nil, pool: Pool = nil): APIWorker =
  result.isRunning = true
  # Create params as heap-allocated object to ensure it stays alive for thread lifetime
  var params = new(ThreadParams)
  params.channels = channels
  params.level = level  
  params.dump = dump
  params.database = database
  params.pool = pool
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
                          maxTokens: int = 8192, temperature: float = 0.7): bool =
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