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
import channels, conversation_manager, config, system_prompt, database
import ../types/[messages, config as configTypes, mode]
import ../api/api
import ../tools/common
when defined(posix):
  import posix

# Global mode state (thread-safe access through procedures)
var currentMode {.threadvar.}: AgentMode
var modeInitialized {.threadvar.}: bool

# Forward declaration
proc captureCurrentDirectoryState(database: DatabaseBackend, conversationId: int)

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
  ## Rough token count estimation for context management
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

# Mode Management Functions

proc initializeModeState*() =
  ## Initialize mode state for the current thread
  if not modeInitialized:
    currentMode = getDefaultMode()
    modeInitialized = true
    debug(fmt"Mode state initialized to: {currentMode}")

proc getCurrentMode*(): AgentMode =
  ## Get the current agent mode (thread-safe)
  if not modeInitialized:
    initializeModeState()
  return currentMode

proc setCurrentMode*(mode: AgentMode) =
  ## Set the current agent mode (thread-safe)
  let previousMode = getCurrentMode()
  currentMode = mode
  modeInitialized = true
  debug(fmt"Mode changed from {previousMode} to: {mode}")
  
  # Persist mode change to current conversation if available
  try:
    debug("setCurrentMode: About to call getCurrentSession()")
    let currentSession = getCurrentSession()
    debug(fmt"setCurrentMode: getCurrentSession() returned, isSome: {currentSession.isSome()}")
    if currentSession.isSome():
      let database = getGlobalDatabase()
      if database != nil:
        let conversationId = currentSession.get().conversation.id
        updateConversationMode(database, conversationId, mode)
        debug(fmt"Persisted mode change to database for conversation {conversationId}")
        
        # Handle plan mode protection when entering plan mode
        if mode == amPlan and previousMode != amPlan:
          captureCurrentDirectoryState(database, conversationId)
        # Clear plan mode protection when exiting plan mode
        elif previousMode == amPlan and mode != amPlan:
          let success = clearPlanModeProtection(database, conversationId)
          if success:
            debug("Plan mode protection cleared when exiting to code mode")
        
  except Exception as e:
    debug(fmt"Failed to persist mode change to database: {e.msg}")

proc captureCurrentDirectoryState(database: DatabaseBackend, conversationId: int) =
  ## Capture the current directory state for plan mode protection
  try:
    let currentDir = getCurrentDir()
    var protectedFiles: seq[string] = @[]
    
    # Walk the directory tree and collect all files
    for kind, path in walkDir(currentDir):
      case kind:
      of pcFile, pcLinkToFile:
        # Convert to relative path for consistency
        let relativePath = relativePath(path, currentDir)
        protectedFiles.add(relativePath)
      else:
        discard
    
    # Also check subdirectories recursively (but limit depth to avoid performance issues)
    proc addFilesRecursively(dir: string, maxDepth: int = 3, currentDepth: int = 0) =
      if currentDepth >= maxDepth:
        return
      
      try:
        for kind, path in walkDir(dir):
          case kind:
          of pcFile, pcLinkToFile:
            let relativePath = relativePath(path, currentDir)
            if relativePath notin protectedFiles:
              protectedFiles.add(relativePath)
          of pcDir, pcLinkToDir:
            # Skip hidden directories and common ignore patterns
            let dirName = extractFilename(path)
            if not dirName.startsWith(".") and dirName notin @["node_modules", "target", "build", "__pycache__"]:
              addFilesRecursively(path, maxDepth, currentDepth + 1)
      except OSError as e:
        # Skip directories we can't read
        debug(fmt"Cannot read directory {dir}: {e.msg}")
    
    addFilesRecursively(currentDir)
    
    # Set the plan mode protection with captured files
    let success = setPlanModeProtection(database, conversationId, protectedFiles)
    if success:
      info(fmt"Plan mode protection enabled with {protectedFiles.len} protected files")
    else:
      warn("Failed to enable plan mode protection")
      
  except Exception as e:
    error(fmt"Failed to capture directory state for plan mode protection: {e.msg}")

proc toggleMode*(): AgentMode =
  ## Toggle between Plan and Code modes, returns new mode
  let newMode = getNextMode(getCurrentMode())
  setCurrentMode(newMode)
  return newMode

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

proc prepareConversationMessages*(text: string): (seq[Message], string) =
  ## Prepare conversation context with system prompt and process @ file references
  ## Returns messages with context and unique request ID
  ## Prepare conversation context with system prompt and return messages with request ID
  var messages = getConversationContext()
  messages = truncateContextIfNeeded(messages)
  
  # Insert system message at the beginning based on current mode
  let systemMsg = createSystemMessage(getCurrentMode())
  messages.insert(systemMsg, 0)
  
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
  return (messages, requestId)

proc selectModelFromConfig*(config: configTypes.Config, model: string): configTypes.ModelConfig =
  ## Select model from config based on parameter or return default model
  ## Select model from config based on parameter or return default
  if model.len > 0:
    return getModelFromConfig(config, model)
  else:
    return config.models[0]


proc sendSinglePromptInteractiveWithId*(text: string, modelConfig: configTypes.ModelConfig): (bool, string) =
  ## Send a prompt interactively and return success status and request ID
  ## Send a prompt and return both success status and request ID
  let channels = getChannels()
  
  let apiKeyOpt = validateApiKey(modelConfig)
  if apiKeyOpt.isNone:
    return (false, "")
  
  let (messages, requestId) = prepareConversationMessages(text)
  let success = sendChatRequestAsync(channels, messages, modelConfig, requestId, apiKeyOpt.get())
  return (success, requestId)


proc sendSinglePromptAsyncWithId*(text: string, model: string = ""): (bool, string) =
  ## Send a prompt asynchronously and return success status and request ID
  ## Send a prompt and return both success status and request ID
  let channels = getChannels()
  let config = loadConfig()
  let selectedModel = selectModelFromConfig(config, model)
  
  let apiKeyOpt = validateApiKey(selectedModel)
  if apiKeyOpt.isNone:
    return (false, "")
  
  let apiKey = apiKeyOpt.get()
  let keyPreview = if apiKey.len > 8: apiKey[0..7] & "..." else: apiKey
  info fmt"Using API key: {keyPreview} for {selectedModel.baseUrl}"
  
  let (messages, requestId) = prepareConversationMessages(text)
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