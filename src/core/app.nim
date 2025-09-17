## Core Application Logic
##
## This module provides the main application orchestration for Niffler.
## It coordinates between the UI layer, API workers, and tool workers through
## the thread-safe channel communication system.
##
## Key Responsibilities:
## - Single prompt execution for CLI usage
## - Interactive session management
## - Message history integration
## - API key management and validation
## - Request orchestration between different workers
##
## Design Decisions:
## - Uses thread-safe channels for worker communication
## - Integrates with history system for conversation persistence
## - Handles API key retrieval from configuration and environment
## - Provides both interactive and single-shot execution modes

import std/[strformat, logging, options, strutils, terminal, random, os, re, json, times]
import channels, conversation_manager, config, system_prompt, database, mode_state
import ../types/[messages, config as configTypes, mode]
import ../api/api
import ../tools/common
import ../tools/registry
when defined(posix):
  import posix


# Forward declaration
proc initializePlanModeCreatedFiles*(database: DatabaseBackend, conversationId: int)

# Simple file reference processing
proc isValidTextFileForReference*(path: string): bool =
  ## Check if a file is valid for @ referencing (text files only, no binary files)
  ## Check if a file is valid for @ referencing (text files only)
  let info = getFileInfo(path)
  
  # Directories are valid for navigation
  if info.kind == pcDir:
    return true
  
  # First try extension-based detection
  if isTextFile(path):
    return true
  
  # For files without extensions, check content
  let ext = getFileExtension(path)
  if ext.len == 0:
    # No extension - check for binary content (simple check)
    try:
      let file = open(path, fmRead)
      defer: file.close()
      
      # Read first 1KB of file
      let bufferSize = 1024
      var buffer = newString(bufferSize)
      let bytesRead = file.readChars(toOpenArray(buffer, 0, bufferSize-1))
      
      # Check for null bytes which are common in binary files
      for i in 0..<bytesRead:
        if buffer[i] == '\0':
          return false
      
      return true
    except:
      # If we can't read the file, assume it's not valid
      return false
  
  # Has extension but not in text list - assume binary
  return false

proc processFileReferencesInText*(input: string): tuple[processedText: string, toolCalls: seq[LLMToolCall]] =
  ## Process @ file references in input text and convert to tool calls
  ## Returns modified text and generated read tool calls for valid files
  ## Process @ file references in input text and convert to tool calls
  result.processedText = input
  result.toolCalls = @[]
  
  # Regex to match @ references
  let pattern = re(r"@([^\s]+)")
  
  # Find all @ references
  var matches: seq[string] = @[]
  for match in input.findAll(pattern):
    matches.add(match)
  
  # Process each match in reverse order to maintain string indices
  var replacements: seq[tuple[original, replacement: string]] = @[]
  
  for match in matches:
    # Extract the path part (remove the @)
    let pathPart = match[1..^1]
    
    # Resolve the full path
    let fullPath = if isAbsolute(pathPart):
      pathPart
      else:
        getCurrentDir() / pathPart
    
    # Check if file exists
    if fileExists(fullPath) or dirExists(fullPath):
      # Check if it's a valid text file
      if isValidTextFileForReference(fullPath):
        # Valid text file - create tool call
        let toolCall = LLMToolCall(
          id: "call_" & $getTime().toUnix() & "_" & $rand(9999),
          `type`: "function",
          function: FunctionCall(
            name: "read",
            arguments: $ %*{
              "path": pathPart
            }
          )
        )
        result.toolCalls.add(toolCall)
        # Keep the reference in the text for now (will be handled by the LLM)
        replacements.add((match, match))
      else:
        # Binary file - replace with error message
        replacements.add((match, "[Error: Cannot reference binary file: " & pathPart & "]"))
    else:
      # File not found - replace with error message
      replacements.add((match, "[Error: File not found: " & pathPart & "]"))
  
  # Apply replacements
  result.processedText = input
  for rep in replacements:
    result.processedText = result.processedText.replace(rep.original, rep.replacement)

# Context management constants
const
  DEFAULT_MAX_CONTEXT_MESSAGES* = 1000
  DEFAULT_MAX_CONTEXT_TOKENS* = 10000000
  CHARS_PER_TOKEN_ESTIMATE* = 4  # Rough estimate: 1 token ≈ 4 characters

proc estimateTokenCount*(messages: seq[Message]): int =
  ## Rough token count estimation for context management (1 token ≈ 4 characters)
  result = 0
  for msg in messages:
    result += msg.content.len div CHARS_PER_TOKEN_ESTIMATE
    # Add tokens for role and structure overhead
    result += 10
    # Add tokens for tool calls if present
    if msg.toolCalls.isSome():
      for toolCall in msg.toolCalls.get():
        result += toolCall.function.name.len div CHARS_PER_TOKEN_ESTIMATE
        result += toolCall.function.arguments.len div CHARS_PER_TOKEN_ESTIMATE
        result += 20  # Function call overhead


proc truncateContextIfNeeded*(messages: seq[Message], maxTokens: int = DEFAULT_MAX_CONTEXT_TOKENS): seq[Message] =
  ## Truncate context if it exceeds token limits using sliding window approach
  ## Truncate context if it exceeds token limits using sliding window
  result = messages
  var currentTokens = estimateTokenCount(result)
  
  # Remove oldest messages until we're under the limit
  while currentTokens > maxTokens and result.len > 1:
    result.delete(0)  # Remove oldest message
    currentTokens = estimateTokenCount(result)
    debug(fmt"Truncated context to {result.len} messages, {currentTokens} tokens")
  
  if currentTokens > maxTokens:
    info(fmt"Warning: Context still large ({currentTokens} tokens) after truncation")


proc initializePlanModeCreatedFiles*(database: DatabaseBackend, conversationId: int) =
  ## Initialize plan mode with empty created files list
  try:
    # Set the plan mode created files with empty list
    let success = setPlanModeCreatedFiles(database, conversationId, @[])
    if success:
      info("Plan mode initialized with empty created files list")
    else:
      warn("Failed to initialize plan mode created files")
      
  except Exception as e:
    error(fmt"Failed to initialize plan mode created files: {e.msg}")

proc handleModeToggleWithProtection*(previousMode: AgentMode, newMode: AgentMode) {.gcsafe.} =
  ## Handle the database updates and protection logic for mode toggling
  ## This is called by toggleModeWithProtection to avoid circular dependencies
  {.gcsafe.}:
    try:
      let currentSession = getCurrentSession()
      if currentSession.isSome():
        let database = getGlobalDatabase()
        if database != nil:
          let conversationId = currentSession.get().conversation.id
          
          # Update conversation mode in database
          updateConversationMode(database, conversationId, newMode)
          debug(fmt"Updated conversation mode in database to: {newMode}")
          
          # Handle plan mode created files tracking
          if newMode == amPlan and previousMode != amPlan:
            # Entering plan mode - initialize empty created files list
            initializePlanModeCreatedFiles(database, conversationId)
            debug("Initialized plan mode created files list")
          elif previousMode == amPlan and newMode != amPlan:
            # Leaving plan mode - clear created files
            discard clearPlanModeCreatedFiles(database, conversationId)
            debug("Cleared plan mode created files")
    except Exception as e:
      error(fmt"Error in handleModeToggleWithProtection: {e.msg}")

proc toggleModeWithProtection*(): AgentMode {.gcsafe.} =
  ## Toggle between Plan and Code modes with full database updates and protection
  ## This is the complete mode switching function that should be used by the UI
  let previousMode = getCurrentMode()
  let newMode = getNextMode(previousMode)
  setCurrentMode(newMode)
  
  # Handle database updates and protection
  handleModeToggleWithProtection(previousMode, newMode)
  
  return newMode

proc restoreModeWithProtection*(targetMode: AgentMode) {.gcsafe.} =
  ## Restore mode from conversation and initialize plan mode protection if needed
  ## This should be used when loading/switching conversations
  let previousMode = getCurrentMode()
  setCurrentMode(targetMode)
  
  # If restoring to plan mode, ensure created files tracking is active
  if targetMode == amPlan:
    # Check if plan mode protection is already active
    {.gcsafe.}:
      let currentSession = getCurrentSession()
      if currentSession.isSome():
        let database = getGlobalDatabase()
        if database != nil:
          let conversationId = currentSession.get().conversation.id
          let createdFiles = getPlanModeCreatedFiles(database, conversationId)
          if not createdFiles.enabled:
            # Plan mode protection not active, initialize it
            handleModeToggleWithProtection(previousMode, targetMode)
            debug(fmt"Restored to plan mode and initialized created files tracking")
          else:
            debug(fmt"Restored to plan mode (protection already active)")
  elif previousMode == amPlan and targetMode != amPlan:
    # If leaving plan mode, clear created files
    handleModeToggleWithProtection(previousMode, targetMode)
    debug(fmt"Left plan mode and cleared created files")
  else:
    debug(fmt"Restored mode to {targetMode} (no created files changes needed)")

proc getModePromptColor*(): ForegroundColor =
  ## Get the mode color for prompt display
  let mode = getCurrentMode()
  case mode:
  of amPlan: fgGreen
  of amCode: fgBlue

# Cost calculation functions

proc formatCost*(cost: float): string =
  ## Format cost as currency string with appropriate precision (assumes USD)
  ## Format cost as currency (assumes USD)
  if cost < 0.01:
    return fmt"${cost:.6f}"
  elif cost < 0.1:
    return fmt"${cost:.4f}"
  else:
    return fmt"${cost:.2f}"

proc validateApiKey*(modelConfig: configTypes.ModelConfig): Option[string] =
  ## Validate and return API key, or None with error message displayed
  ## Local servers (localhost/127.0.0.1) don't require API keys
  ## Validate and return API key, or None with error message displayed
  ## Local servers (localhost/127.0.0.1) don't require API keys
  let apiKey = readKeyForModel(modelConfig)
  
  # Check if this is a local server that doesn't require authentication
  if apiKey.len == 0:
    let baseUrl = modelConfig.baseUrl.toLower()
    if baseUrl.contains("localhost") or baseUrl.contains("127.0.0.1"):
      # Local server - return empty string as valid key
      return some("")
    else:
      # Remote server - API key required
      echo fmt"Error: No API key found for {modelConfig.baseUrl}"
      echo "Set environment variable or configure API key"
      return none(string)
  
  return some(apiKey)

proc prepareConversationMessagesWithTokens*(text: string, modelName: string): (seq[Message], string, SystemPromptTokens, int) =
  ## Prepare conversation context with system prompt and process @ file references
  ## Returns messages, request ID, system prompt tokens, and tool schema tokens
  var messages = getConversationContext()
  messages = truncateContextIfNeeded(messages)
  
  # Insert system message at the beginning based on current mode and get token breakdown
  let (systemMsg, systemTokens) = createSystemMessageWithTokens(getCurrentMode(), modelName)
  messages.insert(systemMsg, 0)
  
  # Count tool schema tokens
  let toolSchemaTokens = countToolSchemaTokens(modelName)
  
  # Process @ file references in the user message
  let processed = processFileReferencesInText(text)
  let finalText = processed.processedText
  
  # Add the current user message to conversation and to the conversation context
  var userMessage = conversation_manager.addUserMessage(finalText)
  
  # Add tool calls for valid file references
  if processed.toolCalls.len > 0:
    userMessage.toolCalls = some(processed.toolCalls)
  
  messages.add(userMessage)
  
  let requestId = fmt"req_{rand(100000)}"
  debug(fmt"Prepared {messages.len} messages for {getCurrentMode()} mode (including current user message)")
  debug(fmt"System prompt tokens: {systemTokens.total}, Tool schema tokens: {toolSchemaTokens}")
  return (messages, requestId, systemTokens, toolSchemaTokens)

proc prepareConversationMessages*(text: string): (seq[Message], string) =
  ## Backward-compatible wrapper for prepareConversationMessagesWithTokens
  let (messages, requestId, _, _) = prepareConversationMessagesWithTokens(text, "default")
  return (messages, requestId)

proc selectModelFromConfig*(config: configTypes.Config, model: string): configTypes.ModelConfig =
  ## Select model from config based on parameter or return default model
  if model.len > 0:
    return getModelFromConfig(config, model)
  else:
    return config.models[0]


proc sendSinglePromptInteractiveWithId*(text: string, modelConfig: configTypes.ModelConfig): (bool, string) =
  ## Send a prompt interactively and return success status and request ID
  let channels = getChannels()
  
  let apiKeyOpt = validateApiKey(modelConfig)
  if apiKeyOpt.isNone:
    return (false, "")
  
  let (messages, requestId, systemTokens, toolSchemaTokens) = prepareConversationMessagesWithTokens(text, modelConfig.model)
  
  # Log system prompt token usage if we can get conversation context
  try:
    let currentSession = getCurrentSession()
    if currentSession.isSome():
      let database = getGlobalDatabase()
      if database != nil:
        let conversationId = currentSession.get().conversation.id
        # We don't have messageId yet since the message hasn't been created, so use 0 for now
        logSystemPromptTokenUsage(database, conversationId, 0, modelConfig.model, $getCurrentMode(),
                                 systemTokens.basePrompt, systemTokens.modePrompt, systemTokens.environmentInfo,
                                 systemTokens.instructionFiles, systemTokens.toolInstructions, systemTokens.availableTools,
                                 systemTokens.total, toolSchemaTokens)
  except Exception as e:
    debug(fmt"Failed to log system prompt tokens: {e.msg}")
  
  let success = sendChatRequestAsync(channels, messages, modelConfig, requestId, apiKeyOpt.get())
  return (success, requestId)


proc sendSinglePromptAsyncWithId*(text: string, model: string = ""): (bool, string) =
  ## Send a prompt asynchronously and return success status and request ID
  let channels = getChannels()
  let config = loadConfig()
  let selectedModel = selectModelFromConfig(config, model)
  
  let apiKeyOpt = validateApiKey(selectedModel)
  if apiKeyOpt.isNone:
    return (false, "")
  
  let apiKey = apiKeyOpt.get()
  let keyPreview = if apiKey.len > 8: apiKey[0..7] & "..." else: apiKey
  info fmt"Using API key: {keyPreview} for {selectedModel.baseUrl}"
  
  let (messages, requestId, systemTokens, toolSchemaTokens) = prepareConversationMessagesWithTokens(text, selectedModel.model)
  
  # Log system prompt token usage if we can get conversation context
  try:
    let currentSession = getCurrentSession()
    if currentSession.isSome():
      let database = getGlobalDatabase()
      if database != nil:
        let conversationId = currentSession.get().conversation.id
        # We don't have messageId yet since the message hasn't been created, so use 0 for now
        logSystemPromptTokenUsage(database, conversationId, 0, selectedModel.model, $getCurrentMode(),
                                 systemTokens.basePrompt, systemTokens.modePrompt, systemTokens.environmentInfo,
                                 systemTokens.instructionFiles, systemTokens.toolInstructions, systemTokens.availableTools,
                                 systemTokens.total, toolSchemaTokens)
  except Exception as e:
    debug(fmt"Failed to log system prompt tokens: {e.msg}")
  
  info fmt"Sending prompt to {selectedModel.nickname} with {messages.len} context messages"
  
  let success = sendChatRequestAsync(channels, messages, selectedModel, requestId, apiKey)
  return (success, requestId)

proc configureAPIWorker*(modelConfig: configTypes.ModelConfig): bool =
  ## Configure the API worker with a new model configuration
  ## Configure the API worker with a new model configuration
  let channels = getChannels()
  let apiKeyOpt = validateApiKey(modelConfig)
  
  if apiKeyOpt.isNone:
    return false
  
  let configRequest = APIRequest(
    kind: arkConfigure,
    configBaseUrl: modelConfig.baseUrl,
    configApiKey: apiKeyOpt.get(),
    configModelName: modelConfig.model
  )
  
  return trySendAPIRequest(channels, configRequest)