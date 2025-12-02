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

import std/[options, strformat, os, json, strutils, times, tables, algorithm]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}
import ../types/[messages, config, thinking_tokens]
import curlyStreaming

import std/logging
import ../core/[channels, conversation_manager, database, completion_detection, config]
import ../tools/[registry, common]
import ../ui/tool_visualizer
import tool_call_parser
import debby/pools
import ../tokenization/tokenizer

# Global debug flag for thread-safe debug output
var debugEnabled* = false

# Debug output helper functions
proc debugColored*(color, message: string) =
  if isDumpEnabled():
    echo color & message & COLOR_RESET

# Thread-safe debug output that always works when debug mode is enabled
proc debugThreadSafe*(message: string) {.gcsafe.} =
  ## Thread-safe debug output that works in both agent and master modes
  if debugEnabled:
    let timestamp = getTime().format("HH:mm:ss")
    let formattedMessage = fmt"[{timestamp}] DEBUG: {message}"

    # Output to stderr (console)
    stderr.writeLine(formattedMessage)
    stderr.flushFile()

    # Try to output to log file using standard logging
    try:
      # Use the logging system to write to log file
      debug(formattedMessage)
    except Exception:
      # Fail silently if logging isn't available
      discard

# Enable/disable debug logging for all threads
proc setDebugEnabled*(enabled: bool) {.gcsafe.} =
  debugEnabled = enabled


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

# ---------------------------------------------------------------------------
# Duplicate Feedback Prevention Types
# ---------------------------------------------------------------------------

## Tracks duplicate feedback attempts to prevent infinite loops
##
## This structure monitors tool call attempts at multiple levels:
## 1. Per-level tracking: Prevents infinite loops at the same recursion depth
## 2. Global tracking: Provides overall safety limit across all depths
##
## The tracking works by:
## - Creating normalized signatures for each tool call
## - Counting attempts per signature at each recursion level
## - Maintaining a global count for overall safety limits
##
## Usage Flow:
## 1. Check limits before providing duplicate feedback
## 2. Record attempt if within limits
## 3. Attempt recovery if limits exceeded (when enabled)
type
  DuplicateFeedbackTracker* = object
    ## Attempts per recursion level: depth -> (signature -> count)
    ## This prevents the same tool call from being attempted infinitely
    ## at the same recursion depth, which is where most infinite loops occur
    attemptsPerLevel*: Table[int, Table[string, int]]

    ## Global attempts: signature -> total count
    ## provides an overall safety limit to prevent runaway loops
    totalAttempts*: Table[string, int]

## Result type for checking duplicate feedback limits
type
  DuplicateLimitResult* = enum
    dlAllowed = "allowed"           # Proceed with duplicate feedback
    dlLevelExceeded = "level"      # Per-level limit exceeded
    dlTotalExceeded = "total"      # Global limit exceeded
    dlDisabled = "disabled"        # Feature disabled

  ## Detailed reason for limiting duplicate feedback
  DuplicateLimitReason* = object
    result*: DuplicateLimitResult
    signature*: string              # The tool call signature being checked
    currentCount*: int             # Current attempt count
    maxAllowed*: int              # Maximum allowed attempts
    exceededLevel*: int           # Which level exceeded (for dlLevelExceeded)

# ---------------------------------------------------------------------------
# Duplicate Feedback Helper Procedures
# ---------------------------------------------------------------------------

proc createDuplicateFeedbackTracker*(): DuplicateFeedbackTracker =
  ## Create a new duplicate feedback tracker with empty counters
  ## Call this at the start of each task execution to reset tracking
  result = DuplicateFeedbackTracker(
    attemptsPerLevel: initTable[int, Table[string, int]](),
    totalAttempts: initTable[string, int]()
  )

proc createToolCallSignature*(toolCall: LLMToolCall): string =
  ## Create a normalized signature for tool call identification
  ##
  ## The signature includes tool name and normalized arguments to identify
  ## when the same tool call is being made repeatedly, even with slight
  ## parameter variations.
  ##
  ## Format: "toolName(arg1='value1', arg2='value2')"

  # Normalize arguments by sorting keys for consistent signatures
  var args: Table[string, JsonNode]
  try:
    let argsJson = parseJson(toolCall.function.arguments)
    if argsJson.kind == JObject:
      for key, value in argsJson:
        args[key] = value
  except:
    # Fallback to raw arguments if JSON parsing fails
    return fmt("{toolCall.function.name}({toolCall.function.arguments})")

  # Create normalized signature with sorted arguments
  var signatureParts = @[toolCall.function.name & "("]

  var sortedKeys: seq[string]
  for key in args.keys:
    sortedKeys.add(key)
  sortedKeys.sort()

  for i, key in sortedKeys:
    let value = args[key]
    let valueStr = if value.kind == JString:
      fmt("'{value.getStr()}'")
    elif value.kind == JInt:
      $value.getInt()
    elif value.kind == JBool:
      $value.getBool()
    else:
      $value

    signatureParts.add(fmt("{key}={valueStr}"))
    if i < sortedKeys.len - 1:
      signatureParts.add(", ")

  signatureParts.add(")")
  signatureParts.join("")

proc checkDuplicateFeedbackLimits*(tracker: var DuplicateFeedbackTracker,
                                   toolCall: LLMToolCall,
                                   recursionDepth: int,
                                   config: DuplicateFeedbackConfig): DuplicateLimitReason {.gcsafe.} =
  ## Check if providing duplicate feedback would exceed limits
  ##
  ## This is the core limit checking function that decides whether to:
  ## - Allow duplicate feedback within limits
  ## - Block due to per-level limit exceeded
  ## - Block due to global limit exceeded
  ##
  ## Parameters:
  ## - tracker: The current state tracking object
  ## - toolCall: The tool call being checked
  ## - recursionDepth: Current recursion depth
  ## - config: Configuration with limits
  ##
  ## Returns detailed reason whether the feedback is allowed or should be limited

  # Check if feature is disabled
  if not config.enabled:
    result = DuplicateLimitReason(
      result: dlDisabled,
      signature: "",
      currentCount: 0,
      maxAllowed: 0,
      exceededLevel: -1
    )
    return

  let signature = createToolCallSignature(toolCall)

  # Check per-level limit first (more common cause of infinite loops)
  if not tracker.attemptsPerLevel.hasKey(recursionDepth):
    tracker.attemptsPerLevel[recursionDepth] = initTable[string, int]()

  let levelAttempts = tracker.attemptsPerLevel[recursionDepth].getOrDefault(signature, 0)
  if levelAttempts >= config.maxAttemptsPerLevel:
    result = DuplicateLimitReason(
      result: dlLevelExceeded,
      signature: signature,
      currentCount: levelAttempts,
      maxAllowed: config.maxAttemptsPerLevel,
      exceededLevel: recursionDepth
    )
    return

  # Check global limit (safety net)
  let totalAttempts = tracker.totalAttempts.getOrDefault(signature, 0)
  if totalAttempts >= config.maxTotalAttempts:
    result = DuplicateLimitReason(
      result: dlTotalExceeded,
      signature: signature,
      currentCount: totalAttempts,
      maxAllowed: config.maxTotalAttempts,
      exceededLevel: -1
    )
    return

  # Within limits - provide feedback
  result = DuplicateLimitReason(
    result: dlAllowed,
    signature: signature,
    currentCount: levelAttempts,  # Current count before this attempt
    maxAllowed: config.maxAttemptsPerLevel,
    exceededLevel: -1
  )

proc recordDuplicateFeedbackAttempt*(tracker: var DuplicateFeedbackTracker,
                                     toolCall: LLMToolCall,
                                     recursionDepth: int) {.gcsafe.} =
  ## Record that duplicate feedback was provided for a tool call
  ##
  ## Call this AFTER successfully providing duplicate feedback to update
  ## the tracking counters. This ensures future attempts will be properly
  ## limited based on the current state.
  ##
  ## Parameters:
  ## - tracker: The tracking object to update
  ## - toolCall: The tool call that received feedback
  ## - recursionDepth: Current recursion depth

  let signature = createToolCallSignature(toolCall)

  # Update per-level tracking
  if not tracker.attemptsPerLevel.hasKey(recursionDepth):
    tracker.attemptsPerLevel[recursionDepth] = initTable[string, int]()

  let currentLevelAttempts = tracker.attemptsPerLevel[recursionDepth].getOrDefault(signature, 0)
  tracker.attemptsPerLevel[recursionDepth][signature] = currentLevelAttempts + 1

  # Update global tracking
  let currentTotalAttempts = tracker.totalAttempts.getOrDefault(signature, 0)
  tracker.totalAttempts[signature] = currentTotalAttempts + 1

  debugThreadSafe(fmt"Recorded duplicate feedback attempt for '{signature}' at depth {recursionDepth} (level: {currentLevelAttempts + 1}, total: {currentTotalAttempts + 1})")

proc createDuplicateLimitError*(reason: DuplicateLimitReason): string {.gcsafe.} =
  ## Create a user-friendly error message when duplicate feedback limits are exceeded
  ##
  ## This generates clear, actionable error messages that explain:
  ## - Which tool call was limited
  ## - What limit was exceeded
  ## - Suggestions for how to proceed
  ##
  ## Parameters:
  ## - reason: Detailed information about why the limit was exceeded
  ##
  ## Returns: Formatted error message for the user

  case reason.result
  of dlLevelExceeded:
    fmt("Duplicate feedback limit exceeded at recursion depth {reason.exceededLevel}: Tool call '{reason.signature}' has been attempted {reason.currentCount} times (limit: {reason.maxAllowed}). The model appears to be stuck in a loop. Please try a different approach or task.")

  of dlTotalExceeded:
    fmt("Global duplicate feedback limit exceeded: Tool call '{reason.signature}' has been attempted {reason.currentCount} times total (limit: {reason.maxAllowed}). Terminating execution to prevent infinite looping.")

  of dlDisabled:
    "Duplicate feedback prevention is disabled - the system may get stuck in infinite loops. Consider enabling it in your configuration."

  else:
    "Unknown duplicate feedback limit error."

proc suggestAlternativeApproaches*(toolCall: LLMToolCall): string {.gcsafe.} =
  ## Suggest alternative approaches when duplicate feedback limits are exceeded
  ##
  ## When automatic recovery is enabled and limits are exceeded, this function
  ## provides helpful suggestions for alternative approaches the model could take.
  ##
  ## Parameters:
  ## - toolCall: The tool call that was repeated too many times
  ##
  ## Returns: Suggestions for alternative approaches

  let toolName = toolCall.function.name

  # Common suggestions based on tool type
  case toolName
  of "read", "list":
    return "Consider trying a different file or directory, or using different parameters. If you need to re-read the same file, the previous result should still be available."

  of "create", "edit":
    return "Consider checking if the file already exists or reviewing previous changes. If creating the same file multiple times, you may want to verify the current state first."

  of "bash":
    return "Consider using different commands or approaches. If the previous command failed, check the error message and try an alternative method."

  of "fetch":
    return "Consider trying a different URL or approach. The previous fetch result should still be available for analysis."

  else:
    return fmt("Consider using a different tool or approach. The previous '{toolName}' call result should still be available. Try analyzing why the previous call didn't achieve the desired outcome.")

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

# Forward declaration for recursive tool execution
proc executeToolCallsAndContinue*(channels: ptr ThreadChannels, client: var CurlyStreamingClient,
                                request: APIRequest, toolCalls: seq[LLMToolCall],
                                initialContent: string, database: DatabaseBackend,
                                recursionDepth: int = 0,
                                executedCalls: seq[string] = @[],
                                maxTurns: int = 30,
                                duplicateTracker: var DuplicateFeedbackTracker): bool

# Helper procedures for tool execution refactoring
proc filterDuplicateToolCalls(toolCalls: seq[LLMToolCall], executedCalls: seq[string]): tuple[filtered: seq[LLMToolCall], updated: seq[string]] =
  ## Filter out duplicate tool calls to prevent infinite loops
  result.filtered = @[]
  result.updated = executedCalls
  
  for toolCall in toolCalls:
    # Create a normalized signature for better deduplication
    var normalizedArgs = ""
    try:
      let argsJson = parseJson(toolCall.function.arguments)
      normalizedArgs = $argsJson
    except:
      normalizedArgs = toolCall.function.arguments.strip()
    
    let toolSignature = fmt"{toolCall.function.name}({normalizedArgs})"
    
    # Check for duplicates by signature and ID
    var isDuplicate = false
    if toolSignature in executedCalls:
      isDuplicate = true
      debug(fmt"Skipping duplicate tool call (signature match): {toolSignature}")
    else:
      # Additional check: same tool call ID indicates exact duplicate
      for prevCall in result.filtered:
        if prevCall.id == toolCall.id and toolCall.id.len > 0:
          isDuplicate = true
          debug(fmt"Skipping duplicate tool call (ID match): {toolCall.id}")
          break
    
    if not isDuplicate:
      result.filtered.add(toolCall)
      result.updated.add(toolSignature)

proc createTempModelConfig(nickname: string, baseUrl: string, model: string,
                          maxTokens: int, temperature: float, apiKey: string,
                          recursionDepth: int = 0): ModelConfig =
  ## Create a temporary ModelConfig for follow-up requests
  ModelConfig(
    nickname: fmt"{nickname}-{recursionDepth}",
    baseUrl: baseUrl,
    model: model,
    context: 128000,
    enabled: true,
    maxTokens: some(maxTokens),
    temperature: some(temperature),
    apiKey: some(apiKey)
  )

proc handleDuplicateToolCalls(channels: ptr ThreadChannels, client: var CurlyStreamingClient,
                             request: APIRequest, toolCalls: seq[LLMToolCall],
                             initialContent: string, recursionDepth: int,
                             updatedExecutedCalls: seq[string],
                             maxTurns: int = 30,
                             duplicateTracker: var DuplicateFeedbackTracker): bool {.gcsafe.} =
  ## Handle the case when all tool calls are duplicates by providing feedback to the model
  ##
  ## Returns true if feedback provided successfully, false if limits exceeded
  {.gcsafe.}:
    debug("All tool calls were duplicates, sending feedback to model")

    # Check duplicate feedback limits before providing more feedback
    # Use GC-safe block to access global configuration
    try:
      let config = getDuplicateFeedbackConfig()

      if config.enabled:
        # Check if we've exceeded duplicate feedback limits
        let limitReason = checkDuplicateFeedbackLimits(duplicateTracker, toolCalls[0], recursionDepth, config)

        if limitReason.result != dlAllowed:
          # Limits exceeded - stop rather than creating infinite loop
          let errorMessage = createDuplicateLimitError(limitReason)

          debugColored(COLOR_ERROR, fmt"🚫 Duplicate feedback limits exceeded: {errorMessage}")
          debug(fmt"Stopping task to prevent infinite loop: {limitReason.result}")

          # Store final error message in database
          discard conversation_manager.addAssistantMessage(initialContent, some(toolCalls))
          discard conversation_manager.addToolMessage(errorMessage, toolCalls[0].id)

          # Send error to channels for user display
          let errorResponse = APIResponse(
            requestId: request.requestId,
            kind: arkStreamError,
            error: errorMessage
          )
          sendAPIResponse(channels, errorResponse)

          return false

        # Within limits - record this attempt
        recordDuplicateFeedbackAttempt(duplicateTracker, toolCalls[0], recursionDepth)

        debug(fmt"Duplicate feedback attempt recorded: level={recursionDepth}, totalAttempts={duplicateTracker.totalAttempts.len}")
      else:
        debug("Duplicate feedback prevention disabled in configuration")
    except Exception as e:
      # Fail open - if we can't check limits, allow the duplicate feedback
      debug(fmt"Error checking duplicate feedback limits: {e.msg}, allowing feedback as fallback")

  # Store assistant message with duplicate tool calls in database
  {.gcsafe.}:
    # Skip storing empty-content messages (protocol placeholders for tool calls)
    if initialContent.strip().len > 0:
      discard conversation_manager.addAssistantMessage(initialContent, some(toolCalls))
      debugThreadSafe(fmt"Stored assistant message with {toolCalls.len} duplicate tool calls in database")
    else:
      debugThreadSafe(fmt"Skipping empty-content assistant message with {toolCalls.len} duplicate tool calls (protocol placeholder)")

  # Create duplicate feedback message
  let duplicateFeedbackContent = "Note: This tool call was already executed. Please continue the conversation without repeating the same call, or try a different approach if the previous result was insufficient."
  let duplicateResult = Message(
    role: mrTool,
    toolCallId: some(toolCalls[0].id),
    content: duplicateFeedbackContent
  )

  # Store duplicate feedback in database
  {.gcsafe.}:
    discard conversation_manager.addToolMessage(duplicateFeedbackContent, toolCalls[0].id)
    debug("Stored duplicate feedback message in database")

  # Add duplicate feedback and continue conversation
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
  let tempModelConfig = createTempModelConfig(
    fmt"api-request-duplicate",
    request.baseUrl,
    request.model,
    request.maxTokens,
    request.temperature,
    request.apiKey,
    recursionDepth
  )
  
  let followUpRequest = createChatRequest(
    tempModelConfig,
    updatedMessages,
    stream = true,
    tools = if request.enableTools: request.tools else: none(seq[ToolDefinition])
  )
  
  # Handle streaming follow-up response
  debug("Continuing conversation with duplicate feedback instead of stopping")
  var followUpContent = ""
  var followUpToolCalls: seq[LLMToolCall] = @[]
  var toolCallBuffers: Table[string, ToolCallBuffer] = initTable[string, ToolCallBuffer]()
  var isFirstContentChunk = true  # Track first content chunk for newline stripping
  
  proc stripLeadingNewlines(content: string): string =
    ## Strip leading newlines and whitespace from content
    var i = 0
    while i < content.len and content[i] in {'\n', '\r'}:
      inc i
    return content[i..^1]
  
  proc onDuplicateFollowUp(chunk: StreamChunk) {.gcsafe.} =
    if chunk.choices.len > 0:
      let choice = chunk.choices[0]
      let delta = choice.delta
      
      # Handle content
      if delta.content.len > 0:
        var processedContent = delta.content
        
        # Strip leading newlines from first content chunk only
        if isFirstContentChunk:
          let strippedContent = stripLeadingNewlines(delta.content)
          if strippedContent.len == 0:
            # Skip chunks that are only newlines
            return
          processedContent = strippedContent
          isFirstContentChunk = false
        
        followUpContent.add(processedContent)
        let contentResponse = APIResponse(
          requestId: request.requestId,
          kind: arkStreamChunk,
          content: processedContent,
          done: false,
          thinkingContent: none(string),
          isEncrypted: none(bool)
        )
        sendAPIResponse(channels, contentResponse)
      
      # Buffer tool calls for recursive execution
      if delta.toolCalls.isSome():
        for toolCall in delta.toolCalls.get():
          let isComplete = bufferToolCallFragment(toolCallBuffers, toolCall)
          if isComplete:
            let completedCalls = getCompletedToolCalls(toolCallBuffers)
            for completedCall in completedCalls:
              followUpToolCalls.add(completedCall)
              debug(fmt"Duplicate follow-up tool call detected (depth {recursionDepth}): {completedCall.function.name}")
          cleanupStaleBuffers(toolCallBuffers)
  
  let (success, _, duplicateErrorMsg) = client.sendStreamingChatRequest(followUpRequest, onDuplicateFollowUp)

  # Check if duplicate follow-up streaming request failed
  if not success:
    debug(fmt"Duplicate follow-up streaming request failed: {duplicateErrorMsg}")
    let errorResponse = APIResponse(
      requestId: request.requestId,
      kind: arkStreamError,
      error: duplicateErrorMsg
    )
    sendAPIResponse(channels, errorResponse)
    return false

  # Get any remaining completed tool calls after streaming completes
  let remainingCalls = getCompletedToolCalls(toolCallBuffers)
  for completedCall in remainingCalls:
    followUpToolCalls.add(completedCall)

  # Recursively execute any follow-up tool calls detected
  if followUpToolCalls.len > 0:
    debug(fmt"Executing {followUpToolCalls.len} follow-up tool calls from duplicate feedback (depth: {recursionDepth})")
    {.gcsafe.}:
      discard executeToolCallsAndContinue(channels, client, request, followUpToolCalls,
                                         followUpContent, nil, recursionDepth + 1, updatedExecutedCalls, maxTurns, duplicateTracker)

  return success

proc executeToolCallsBatch(channels: ptr ThreadChannels, toolCalls: seq[LLMToolCall], 
                          request: APIRequest): seq[Message] {.gcsafe.} =
  ## Execute a batch of tool calls and return their results
  result = @[]
  
  for toolCall in toolCalls:
    debug(fmt"Executing tool call: {toolCall.function.name}")
    
    # Send tool request display to UI
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
      arguments: toolCall.function.arguments,
      agentName: ""  # Empty = main agent with full access
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
              let toolResult = if toolSuccess: toolResponse.output else: toolResponse.error
              let resultSummary = createToolResultSummary(toolCall.function.name, toolResult, toolSuccess)
              
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
              let status = if toolResponse.kind == trkResult: "success" else: "error"
              debug(fmt"Tool {toolCall.function.name} completed: {status}")
            
            let toolResultMsg = Message(
              role: mrTool,
              content: toolContent,
              toolCallId: some(toolCall.id)
            )
            result.add(toolResultMsg)
            
            # Store tool result in conversation history
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
        result.add(errorMsg)
        discard conversation_manager.addToolMessage("Error: Tool execution timed out", toolCall.id)
    else:
      # Failed to send tool request
      let errorMsg = Message(
        role: mrTool,
        content: "Error: Failed to send tool request",
        toolCallId: some(toolCall.id)
      )
      result.add(errorMsg)
      discard conversation_manager.addToolMessage("Error: Failed to send tool request", toolCall.id)

proc handleFollowUpRequest(channels: ptr ThreadChannels, client: var CurlyStreamingClient,
                          request: APIRequest, toolCalls: seq[LLMToolCall],
                          allToolResults: seq[Message], initialContent: string,
                          recursionDepth: int, updatedExecutedCalls: seq[string],
                          maxTurns: int = 30,
                          duplicateTracker: var DuplicateFeedbackTracker): bool {.gcsafe.} =
  ## Handle follow-up LLM request after tool execution
  debug(fmt"Sending {allToolResults.len} tool results back to LLM (depth: {recursionDepth})")

  # NOTE: Assistant message with tool calls was already stored in executeToolCallsAndContinue
  # We do NOT store it again here to avoid duplication

  # Add tool results to conversation and continue
  var updatedMessages = request.messages
  
  # Add the assistant message with tool calls
  let assistantWithTools = Message(
    role: mrAssistant,
    content: initialContent,
    toolCalls: some(toolCalls)
  )
  updatedMessages.add(assistantWithTools)
  
  # Add all tool result messages
  for toolResult in allToolResults:
    updatedMessages.add(toolResult)
  
  # Create follow-up request to continue conversation
  debug(fmt"Creating follow-up request with {updatedMessages.len} messages (depth: {recursionDepth})")
  
  # Create a temporary ModelConfig from the API request
  let tempModelConfig = createTempModelConfig(
    "api-request-followup", request.baseUrl, request.model,
    request.maxTokens, request.temperature, request.apiKey, recursionDepth
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
  var isFirstContentChunk = true  # Track first content chunk for newline stripping

  debugThreadSafe(fmt"[STREAM] Starting follow-up stream with {updatedMessages.len} messages (depth: {recursionDepth})")
  
  proc stripLeadingNewlines(content: string): string =
    ## Strip leading newlines and whitespace from content
    var i = 0
    while i < content.len and content[i] in {'\n', '\r'}:
      inc i
    return content[i..^1]
  
  proc onFollowUpChunk(chunk: StreamChunk) {.gcsafe.} =
    if chunk.choices.len > 0:
      let choice = chunk.choices[0]
      let delta = choice.delta
      
      # Debug finish reason
      if choice.finishReason.isSome():
        debug(fmt"DEBUG: Follow-up stream finish reason: '{choice.finishReason.get()}'")
      
      # Send follow-up content
      if delta.content.len > 0:
        var processedContent = delta.content
        
        # Strip leading newlines from first content chunk only
        if isFirstContentChunk:
          let strippedContent = stripLeadingNewlines(delta.content)
          if strippedContent.len == 0:
            # Skip chunks that are only newlines
            return
          processedContent = strippedContent
          isFirstContentChunk = false
        
        followUpContent.add(processedContent)
        debugThreadSafe(fmt"[STREAM] followUpContent += '{processedContent}' (total now: {followUpContent.len} chars)")
        let chunkResponse = APIResponse(
          requestId: request.requestId,
          kind: arkStreamChunk,
          content: processedContent,
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
  
  let (followUpSuccess, followUpUsage, followUpErrorMsg) = client.sendStreamingChatRequest(followUpRequest, onFollowUpChunk)

  # Check if follow-up streaming request failed
  if not followUpSuccess:
    debug(fmt"Follow-up streaming request failed: {followUpErrorMsg}")
    let errorResponse = APIResponse(
      requestId: request.requestId,
      kind: arkStreamError,
      error: followUpErrorMsg
    )
    sendAPIResponse(channels, errorResponse)
    return false

  # Get any remaining completed tool calls
  let remainingCalls = getCompletedToolCalls(toolCallBuffers)
  for completedCall in remainingCalls:
    followUpToolCalls.add(completedCall)
  
  cleanupStaleBuffers(toolCallBuffers)
  
  # If we have more tool calls, execute them recursively
  if followUpToolCalls.len > 0:
    debug(fmt"Found {followUpToolCalls.len} follow-up tool calls, executing recursively")
    {.gcsafe.}:
      return executeToolCallsAndContinue(channels, client, request, followUpToolCalls,
                                       followUpContent, nil, recursionDepth + 1, updatedExecutedCalls, maxTurns, duplicateTracker)
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
    
    # Record token count correction for learning (tool conversation)
    debug(fmt"Initial content length for token correction (tools): {initialContent.len} and output tokens: {finalUsage.outputTokens}")
    if initialContent.len > 0 and finalUsage.outputTokens > 0:
      {.gcsafe.}:
        # Use model nickname for consistent correction factor storage
        let estimatedOutputTokens = countTokensForModel(initialContent, request.modelNickname)
        
        # Calculate actual content tokens by subtracting reasoning tokens
        let reasoningTokenCount = if finalUsage.reasoningTokens.isSome(): finalUsage.reasoningTokens.get() else: 0
        let actualContentTokens = finalUsage.outputTokens - reasoningTokenCount
        
        debug(fmt"📊 API TOKEN COMPARISON (tools): content_length={initialContent.len}, estimated={estimatedOutputTokens}, raw_output={finalUsage.outputTokens}, reasoning={reasoningTokenCount}, actual_content={actualContentTokens}, nickname={request.modelNickname}")
        
        # Only record correction if we have actual content tokens to compare
        if actualContentTokens > 0:
          debug(fmt"Token correction learning (tools): estimated={estimatedOutputTokens}, actual_content={actualContentTokens}, nickname={request.modelNickname}")
          recordTokenCountCorrection(request.modelNickname, estimatedOutputTokens, actualContentTokens)
        else:
          debug(fmt"⚠️  Skipping correction: no content tokens after subtracting reasoning tokens")
    
    # Store final assistant message in conversation history
    # Empty content is allowed for messages after tool execution
    debug(fmt"[MSG-STORE] Storing follow-up assistant message (depth: {recursionDepth})")
    debug(fmt"[MSG-STORE] followUpContent length: {followUpContent.len}")
    if followUpContent.len > 0:
      let preview = followUpContent[0..min(80, followUpContent.len-1)]
      debug(fmt"[MSG-STORE] followUpContent preview: '{preview}...'")
    discard conversation_manager.addAssistantMessage(content = followUpContent, toolCalls = none(seq[LLMToolCall]), outputTokens = finalUsage.outputTokens, modelName = request.model)
    debug(fmt"[MSG-STORE] Stored follow-up assistant message in database")
    
    let completeResponse = APIResponse(
      requestId: request.requestId,
      kind: arkStreamComplete,
      usage: finalUsage,
      finishReason: "stop"
    )
    sendAPIResponse(channels, completeResponse)
    
    debug(fmt"Recursive tool execution completed at depth {recursionDepth}")
    return true

proc executeToolCallsAndContinue*(channels: ptr ThreadChannels, client: var CurlyStreamingClient,
                                request: APIRequest, toolCalls: seq[LLMToolCall],
                                initialContent: string, database: DatabaseBackend,
                                recursionDepth: int = 0,
                                executedCalls: seq[string] = @[],
                                maxTurns: int = 30,
                                duplicateTracker: var DuplicateFeedbackTracker): bool =
  ## Execute tool calls and continue conversation recursively
  ## Returns true if successful, false if max recursion depth exceeded

  # Check if LLM signaled completion (even if tool calls present)
  let completionSignal = detectCompletionSignal(initialContent)
  if completionSignal != csNone:
    debug(fmt"Completion signal detected: {completionSignal}, stopping tool execution")
    debugColored(COLOR_RECURSE, fmt"🟢 Task completion detected at depth {recursionDepth}")

    # Store assistant message and return success (don't execute more tools)
    if initialContent.strip().len > 0:
      debugThreadSafe(fmt"[MSG-STORE] Storing completion message (depth: {recursionDepth})")
      discard conversation_manager.addAssistantMessage(initialContent, some(toolCalls))

    return true

  if recursionDepth >= maxTurns:
    debug(fmt"Max turns ({maxTurns}) exceeded at depth {recursionDepth}, stopping tool execution")
    debugColored(COLOR_ERROR, fmt"🔴 TURN LIMIT EXCEEDED at depth {recursionDepth}")
    return false

  if toolCalls.len == 0:
    return true

  debug(fmt"Executing {toolCalls.len} tool calls (recursion depth: {recursionDepth})")
  debugColored(COLOR_RECURSE, fmt"🟣 Recursion depth {recursionDepth}: Executing {toolCalls.len} tool calls")
  
  # Filter duplicate tool calls to prevent infinite loops
  let (filteredToolCalls, updatedExecutedCalls) = filterDuplicateToolCalls(toolCalls, executedCalls)

  if filteredToolCalls.len == 0:
    debugColored(COLOR_BUFFER, fmt"🟡 All tool calls were duplicates, handling duplicates")
    return handleDuplicateToolCalls(channels, client, request, toolCalls, initialContent,
                                   recursionDepth, updatedExecutedCalls, maxTurns, duplicateTracker)

  debug(fmt"After deduplication: {filteredToolCalls.len} unique tool calls")
  debugColored(COLOR_TOOL, fmt"🟢 Deduplication: {toolCalls.len - filteredToolCalls.len} duplicates removed")

  # Store assistant message with tool calls BEFORE executing tools
  # This ensures correct message ordering in database: assistant -> tool results
  # Skip storing empty-content messages (protocol placeholders for tool calls)
  if initialContent.strip().len > 0:
    debugThreadSafe(fmt"[MSG-STORE] Storing assistant message with {toolCalls.len} tool calls BEFORE tool execution")
    discard conversation_manager.addAssistantMessage(initialContent, some(toolCalls))
  else:
    debugThreadSafe(fmt"[MSG-STORE] Skipping empty-content assistant message with {toolCalls.len} tool calls (protocol placeholder)")

  # Execute all unique tool calls using helper function
  let allToolResults = executeToolCallsBatch(channels, filteredToolCalls, request)
  
  # Send tool results back to LLM for continuation
  if allToolResults.len > 0:
    return handleFollowUpRequest(channels, client, request, toolCalls, allToolResults,
                                initialContent, recursionDepth, updatedExecutedCalls, maxTurns, duplicateTracker)

  return true

# ---------------------------------------------------------------------------
# Backwards Compatibility Wrappers
# ---------------------------------------------------------------------------

proc executeToolCallsAndContinue*(channels: ptr ThreadChannels, client: var CurlyStreamingClient,
                                request: APIRequest, toolCalls: seq[LLMToolCall],
                                initialContent: string, database: DatabaseBackend,
                                recursionDepth: int = 0,
                                executedCalls: seq[string] = @[],
                                maxTurns: int = 30): bool =
  ## Backwards compatibility wrapper that creates a duplicate tracker automatically
  ## This allows existing code to continue working without modification
  var dummyTracker = createDuplicateFeedbackTracker()
  executeToolCallsAndContinue(channels, client, request, toolCalls, initialContent,
                            database, recursionDepth, executedCalls, maxTurns, dummyTracker)

proc handleConfigureRequest(request: APIRequest): Option[CurlyStreamingClient] {.gcsafe.} =
  ## Handle API client configuration requests
  try:
    result = some(newCurlyStreamingClient(
      request.configBaseUrl,
      request.configApiKey,
      request.configModelName
    ))
    debug(fmt"API client configured for {request.configBaseUrl}")
  except Exception as e:
    debug(fmt"Failed to configure API client: {e.msg}")
    result = none(CurlyStreamingClient)

proc handleStreamCancellation(channels: ptr ThreadChannels, request: APIRequest, 
                             activeRequests: var seq[string]) {.gcsafe.} =
  ## Handle stream cancellation requests
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

proc initializeAPIWorker(params: ThreadParams): tuple[channels: ptr ThreadChannels, database: DatabaseBackend,
                        currentClient: Option[CurlyStreamingClient], activeRequests: seq[string],
                        toolCallBuffers: Table[string, ToolCallBuffer]] {.gcsafe.} =
  ## Initialize API worker thread with logging, parsing, and state
  # Enable thread-safe debug output based on log level
  let debugMode = params.level == lvlDebug
  setDebugEnabled(debugMode)
  if debugMode:
    echo fmt"[INIT] API worker debug mode: {debugMode}, level: {params.level}"

  # Initialize dump flag for this thread
  setDumpEnabled(params.dump)
  
  let channels = params.channels
  let database = params.database
  
  debug("API worker thread started")
  debugThreadSafe("[TEST] API worker debug output working!")
  incrementActiveThreads(channels)
  
  # Initialize flexible parser for tool call format detection
  initGlobalParser()
  
  let currentClient: Option[CurlyStreamingClient] = none(CurlyStreamingClient)
  let activeRequests: seq[string] = @[]  # Track active request IDs for cancellation
  let toolCallBuffers: Table[string, ToolCallBuffer] = initTable[string, ToolCallBuffer]()  # Buffer incomplete tool calls
  
  return (channels, database, currentClient, activeRequests, toolCallBuffers)

proc apiWorkerProc(params: ThreadParams) {.thread, gcsafe.} =
  let (channels, database, currentClient, activeRequests, toolCallBuffers) = initializeAPIWorker(params)
  var mutableCurrentClient = currentClient
  var mutableActiveRequests = activeRequests
  var mutableToolCallBuffers = toolCallBuffers
  
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
          mutableCurrentClient = handleConfigureRequest(request)
          
        of arkChatRequest:
          debug(fmt"Processing chat request: {request.requestId}")
          # Add to active requests for cancellation tracking
          mutableActiveRequests.add(request.requestId)
          
          # Initialize client with request parameters, or reconfigure if needed
          var needsNewClient = false
          if mutableCurrentClient.isNone():
            needsNewClient = true
          else:
            # Check if current client configuration matches request
            var client = mutableCurrentClient.get()
            if client.baseUrl != request.baseUrl or client.model != request.model:
              needsNewClient = true
              # Create new client for different configuration
              mutableCurrentClient = none(CurlyStreamingClient)
          
          if needsNewClient:
            try:
              mutableCurrentClient = some(newCurlyStreamingClient(
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
            var client = mutableCurrentClient.get()
            
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
            var fullThinkingContent = ""  # Accumulate all thinking content for estimation
            var collectedToolCalls: seq[LLMToolCall] = @[]
            var hasToolCalls = false
            
            # Thinking token buffering to avoid storing tiny chunks
            var thinkingTokenBuffer = ""
            var lastThinkingFormat = ttfAnthropic
            var lastThinkingEncrypted = false
            const THINKING_TOKEN_MIN_LENGTH = 50  # Minimum chars before storing
            var hasThinkingContent = false
            var isFirstContentChunk = true  # Track first content chunk for newline stripping
            
            proc flushThinkingBuffer() =
              ## Store accumulated thinking token if it meets minimum length
              if thinkingTokenBuffer.len >= THINKING_TOKEN_MIN_LENGTH:
                discard storeThinkingTokenFromStreaming(thinkingTokenBuffer, lastThinkingFormat, none(int), lastThinkingEncrypted)
                debug(fmt"Stored aggregated thinking token: {thinkingTokenBuffer.len} chars, format: {lastThinkingFormat}")
                thinkingTokenBuffer = ""
            
            proc stripLeadingNewlines(content: string): string =
              ## Strip leading newlines and whitespace from content
              var i = 0
              while i < content.len and content[i] in {'\n', '\r'}:
                inc i
              return content[i..^1]
            
            proc onChunkReceived(chunk: StreamChunk) {.gcsafe.} =
              # Check for cancellation before processing chunk
              if request.requestId notin mutableActiveRequests:
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
                    debugColored(COLOR_BUFFER, fmt"🟡 Buffering fragment: {toolCall.function.name} args='{toolCall.function.arguments}'")
                    # Buffer the tool call fragment
                    let isComplete = bufferToolCallFragment(mutableToolCallBuffers, toolCall)
                    debug(fmt"Tool call fragment complete: {isComplete}")
                    if isComplete:
                      debugColored(COLOR_TOOL, fmt"🟢 Tool call complete: {toolCall.function.name}")
                      # Tool call is complete, add to collected calls
                      let completedCalls = getCompletedToolCalls(mutableToolCallBuffers)
                      for completedCall in completedCalls:
                        collectedToolCalls.add(completedCall)
                        hasToolCalls = true
                        debug(fmt"Complete tool call detected: {completedCall.function.name} with args: {completedCall.function.arguments}")
                        
                        # Tool call request notification will be sent by main execution loop
                    
                    # Clean up stale buffers periodically
                    cleanupStaleBuffers(mutableToolCallBuffers)
                
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
                    
                    # Accumulate thinking content for estimation (unless encrypted)
                    if not isEncrypted:
                      fullThinkingContent.add(thinkingContent)
                    
                    # Buffer thinking tokens to avoid storing tiny chunks
                    if isEncrypted != lastThinkingEncrypted or format != lastThinkingFormat:
                      # Format or encryption changed, flush current buffer
                      flushThinkingBuffer()
                      lastThinkingFormat = format
                      lastThinkingEncrypted = isEncrypted
                    
                    # Add to buffer instead of storing immediately
                    thinkingTokenBuffer.add(thinkingContent)
                    
                    # Flush buffer if it gets too large (prevent memory issues)
                    if thinkingTokenBuffer.len >= THINKING_TOKEN_MIN_LENGTH * 4:
                      flushThinkingBuffer()
                    
                    # Prepare thinking content for UI display
                    hasThinkingContent = true
                    thinkingContentStr = some(thinkingContent)
                    isThinkingEncrypted = some(isEncrypted)
                    
                    debug(fmt"Buffered thinking token: {thinkingContent.len} chars, buffer total: {thinkingTokenBuffer.len}, format: {format}, encrypted: {isEncrypted}")
                
                # Send content chunks in real-time (but coordinate with tool calls)
                if delta.content.len > 0:
                  var processedContent = delta.content
                  
                  # Strip leading newlines from first content chunk only
                  if isFirstContentChunk:
                    let strippedContent = stripLeadingNewlines(delta.content)
                    if strippedContent.len == 0:
                      # Skip chunks that are only newlines
                      return
                    processedContent = strippedContent
                    isFirstContentChunk = false
                  
                  fullContent.add(processedContent)
                  # Only send content if this chunk doesn't contain tool calls or if we're not actively processing tool calls
                  if not chunkHasToolCalls or not hasToolCalls:
                    let chunkResponse = APIResponse(
                      requestId: request.requestId,
                      kind: arkStreamChunk,
                      content: processedContent,
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
            
            let (streamSuccess, streamUsage, errorMsg) = client.sendStreamingChatRequest(chatRequest, onChunkReceived)

            # Check if streaming request failed
            if not streamSuccess:
              let errorResponse = APIResponse(
                requestId: request.requestId,
                kind: arkStreamError,
                error: errorMsg
              )
              sendAPIResponse(channels, errorResponse)

              # Remove from active requests
              for i in 0..<mutableActiveRequests.len:
                if mutableActiveRequests[i] == request.requestId:
                  mutableActiveRequests.delete(i)
                  break
              continue

            # Use extracted usage data from streaming response if available
            var finalUsage = if streamUsage.isSome():
              streamUsage.get()
            else:
              TokenUsage(inputTokens: 0, outputTokens: 0, totalTokens: 0)
            
            # Flush any remaining thinking tokens in buffer
            flushThinkingBuffer()
            
            # Add reasoning tokens from thinking content if missing from API response
            if (finalUsage.reasoningTokens.isNone() or finalUsage.reasoningTokens.get() == 0) and hasThinkingContent:
              # Count tokens from current response thinking content only
              if fullThinkingContent.len > 0:
                try:
                  # Simple token estimation: ~4 chars per token (safe approximation)
                  let reasoningTokenCount = max(1, fullThinkingContent.len div 4)
                  if reasoningTokenCount > 0:
                    finalUsage.reasoningTokens = some(reasoningTokenCount)
                    debug(fmt"Added {reasoningTokenCount} reasoning tokens from current response thinking content ({fullThinkingContent.len} chars)")
                except Exception as e:
                  debug(fmt"Failed to estimate reasoning tokens from thinking content: {e.msg}")
            
            # After streaming completes, check for any remaining completed tool calls in buffers
            let remainingCompletedCalls = getCompletedToolCalls(mutableToolCallBuffers)
            for completedCall in remainingCompletedCalls:
              collectedToolCalls.add(completedCall)
              hasToolCalls = true
              debug(fmt"Final complete tool call detected: {completedCall.function.name} with args: {completedCall.function.arguments}")
            
            # Clean up any remaining stale buffers
            cleanupStaleBuffers(mutableToolCallBuffers)
            
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

                # Thread-safe call without duplicate feedback to avoid GC safety issues
                # Use the backwards compatibility wrapper which doesn't require the tracker
                let executeSuccess = executeToolCallsAndContinue(channels, mutableClient, request,
                                                                   collectedToolCalls, fullContent, database,
                                                                   0, @[], 30)
                
                if not executeSuccess:
                  # Execution failed (likely max recursion depth exceeded)
                  let errorResponse = APIResponse(
                    requestId: request.requestId,
                    kind: arkStreamError,
                    error: "Tool execution failed or exceeded maximum recursion depth"
                  )
                  sendAPIResponse(channels, errorResponse)
                
                # Remove from active requests
                for i in 0..<mutableActiveRequests.len:
                  if mutableActiveRequests[i] == request.requestId:
                    mutableActiveRequests.delete(i)
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
              debug "Sending API final chunk response"
              sendAPIResponse(channels, finalChunkResponse)
              
              # Log token usage for regular (non-tool) conversations
              let conversationId = getCurrentConversationId().int
              let messageId = getCurrentMessageId().int
              debug("🚀 ABOUT TO LOG TOKEN USAGE FROM REQUEST")
              logTokenUsageFromRequest(request.model, finalUsage, conversationId, messageId)
              debug("✅ COMPLETED logTokenUsageFromRequest")
              
              # Record token count correction for learning (regular conversation)
              debug(fmt"Checking token correction conditions: fullContent.len={fullContent.len}, finalUsage.outputTokens={finalUsage.outputTokens}, model={request.modelNickname}")

              if fullContent.len == 0:
                debug("Token correction skipped: fullContent is empty")
              elif finalUsage.outputTokens == 0:
                debug("Token correction skipped: finalUsage.outputTokens is 0")
              else:
                debug("Token correction conditions met - entering correction block")
              
              if fullContent.len > 0 and finalUsage.outputTokens > 0:
                {.gcsafe.}:
                  # Use model nickname for consistent correction factor storage
                  
                  # Consistent estimation strategy: always estimate total content vs total output
                  # Since outputTokens always includes visible + reasoning/thinking tokens
                  let reasoningTokenCount = if finalUsage.reasoningTokens.isSome(): finalUsage.reasoningTokens.get() else: 0
                  
                  var estimatedOutputTokens: int
                  let actualContentTokens = finalUsage.outputTokens  # Always use full output tokens
                  
                  if fullThinkingContent.len > 0:
                    # Model with thinking/reasoning content: estimate visible + thinking
                    # Use RAW estimates (without correction) for recording new corrections
                    let visibleEstimate = estimateTokens(fullContent)
                    let thinkingEstimate = estimateTokens(fullThinkingContent)
                    estimatedOutputTokens = visibleEstimate + thinkingEstimate
                    debug(fmt"Raw estimation: visible+thinking content ({visibleEstimate}+{thinkingEstimate}={estimatedOutputTokens}) vs actual={actualContentTokens}")
                  else:
                    # No thinking content available: estimate visible only vs full output
                    # Use RAW estimates (without correction) for recording new corrections
                    estimatedOutputTokens = estimateTokens(fullContent)
                    debug(fmt"Raw estimation: {estimatedOutputTokens} vs actual={actualContentTokens} (may include unextracted thinking)")
                  
                  debug(fmt"Token comparison: estimated={estimatedOutputTokens}, raw_output={finalUsage.outputTokens}, reasoning={reasoningTokenCount}, actual_content={actualContentTokens}, thinking_len={fullThinkingContent.len}, model={request.modelNickname}")
                  
                  # Record correction if we have valid tokens to compare
                  if actualContentTokens > 0 and estimatedOutputTokens > 0:
                    debug(fmt"🎯 ABOUT TO CALL recordTokenCountCorrection: estimated={estimatedOutputTokens}, actual={actualContentTokens}, nickname={request.modelNickname}")
                    recordTokenCountCorrection(request.modelNickname, estimatedOutputTokens, actualContentTokens)
                    debug(fmt"✅ CALLED recordTokenCountCorrection successfully")
                  else:
                    debug(fmt"Skipping correction: invalid token counts (estimated={estimatedOutputTokens}, actual={actualContentTokens})")

              # Send completion response with extracted usage data
              let completeResponse = APIResponse(
                requestId: request.requestId,
                kind: arkStreamComplete,
                usage: finalUsage,
                finishReason: "stop"
              )
              sendAPIResponse(channels, completeResponse)
              
              # Remove from active requests
              for i in 0..<mutableActiveRequests.len:
                if mutableActiveRequests[i] == request.requestId:
                  mutableActiveRequests.delete(i)
                  break
              
              debug(fmt"Streaming request {request.requestId} completed successfully")
            
          except Exception as e:
            # Remove from active requests on error
            for i in 0..<mutableActiveRequests.len:
              if mutableActiveRequests[i] == request.requestId:
                mutableActiveRequests.delete(i)
                break
                
            let errorResponse = APIResponse(
              requestId: request.requestId,
              kind: arkStreamError,
              error: fmt"API request failed: {e.msg}"
            )
            sendAPIResponse(channels, errorResponse)
            debug(fmt"Request {request.requestId} failed: {e.msg}")
        
        of arkStreamCancel:
          handleStreamCancellation(channels, request, mutableActiveRequests)
          
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
    modelNickname: modelConfig.nickname,
    maxTokens: maxTokens,
    temperature: temperature,
    baseUrl: modelConfig.baseUrl,
    apiKey: apiKey,
    enableTools: true,
    tools: some(toolSchemas)
  )
  
  return trySendAPIRequest(channels, request)