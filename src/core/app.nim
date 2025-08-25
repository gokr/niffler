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

import std/[strformat, logging, options, strutils, terminal, random]
import channels, history, config, system_prompt
import ../types/[messages, config as configTypes, mode]
import ../api/api

# Global mode state (thread-safe access through procedures)
var currentMode {.threadvar.}: AgentMode
var modeInitialized {.threadvar.}: bool

# Context management constants
const
  DEFAULT_MAX_CONTEXT_MESSAGES* = 20
  DEFAULT_MAX_CONTEXT_TOKENS* = 100000
  TOKEN_WARNING_THRESHOLD* = 50000
  CHARS_PER_TOKEN_ESTIMATE* = 4  # Rough estimate: 1 token ≈ 4 characters

proc estimateTokenCount*(messages: seq[Message]): int =
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

proc getConversationContext*(maxMessages: int = DEFAULT_MAX_CONTEXT_MESSAGES): seq[Message] =
  ## Get conversation context with the most recent messages
  ## Returns messages in chronological order (oldest first)
  result = getRecentMessages(maxMessages)
  debug(fmt"Retrieved {result.len} messages for conversation context")
  
  let estimatedTokens = estimateTokenCount(result)
  if estimatedTokens > TOKEN_WARNING_THRESHOLD:
    info(fmt"Context size: {estimatedTokens} tokens (approaching limits)")
  else:
    debug(fmt"Context size: {estimatedTokens} tokens")

proc truncateContextIfNeeded*(messages: seq[Message], maxTokens: int = DEFAULT_MAX_CONTEXT_TOKENS): seq[Message] =
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
  currentMode = mode
  modeInitialized = true
  debug(fmt"Mode changed to: {mode}")

proc toggleMode*(): AgentMode =
  ## Toggle between Plan and Code modes, returns new mode
  let newMode = getNextMode(getCurrentMode())
  setCurrentMode(newMode)
  return newMode

proc getModePromptIndicator*(): string =
  ## Get the mode indicator for prompt display
  let mode = getCurrentMode()
  case mode:
  of amPlan: "(plan)"
  of amCode: "(code)"

proc getModePromptColor*(): ForegroundColor =
  ## Get the mode color for prompt display
  let mode = getCurrentMode()
  case mode:
  of amPlan: fgGreen
  of amCode: fgBlue

# Cost calculation functions

proc formatCost*(cost: float): string =
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
  ## Prepare conversation context with system prompt and return messages with request ID
  var messages = getConversationContext()
  messages = truncateContextIfNeeded(messages)
  
  # Insert system message at the beginning based on current mode
  let systemMsg = createSystemMessage(getCurrentMode())
  messages.insert(systemMsg, 0)
  
  # Add the current user message to history and to the conversation context
  let userMessage = addUserMessage(text)
  messages.add(userMessage)
  
  let requestId = fmt"req_{rand(100000)}"
  debug(fmt"Prepared {messages.len} messages for {getCurrentMode()} mode (including current user message)")
  return (messages, requestId)

proc selectModelFromConfig*(config: configTypes.Config, model: string): configTypes.ModelConfig =
  ## Select model from config based on parameter or return default
  if model.len > 0:
    return getModelFromConfig(config, model)
  else:
    return config.models[0]


proc sendSinglePromptInteractiveWithId*(text: string, modelConfig: configTypes.ModelConfig): (bool, string) =
  ## Send a prompt and return both success status and request ID
  let channels = getChannels()
  
  let apiKeyOpt = validateApiKey(modelConfig)
  if apiKeyOpt.isNone:
    return (false, "")
  
  let (messages, requestId) = prepareConversationMessages(text)
  let success = sendChatRequestAsync(channels, messages, modelConfig, requestId, apiKeyOpt.get())
  return (success, requestId)


proc sendSinglePromptAsyncWithId*(text: string, model: string = ""): (bool, string) =
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