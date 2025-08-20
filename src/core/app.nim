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

import std/[strformat, logging, options]
import channels, history, config
import ../types/[messages, history as historyTypes, config as configTypes]
import ../api/api

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

# Cost calculation functions
proc calculateContextCost*(messages: seq[Message], modelConfig: configTypes.ModelConfig): configTypes.CostTracking =
  ## Calculate the actual cost for a conversation context
  let tokens = estimateTokenCount(messages)
  
  result = configTypes.CostTracking(
    inputCostPerMToken: modelConfig.inputCostPerMToken,
    outputCostPerMToken: modelConfig.outputCostPerMToken,
    totalInputCost: 0.0,
    totalOutputCost: 0.0,
    totalCost: 0.0,
    usage: configTypes.CostTokenUsage(
      inputTokens: tokens,
      outputTokens: 0,
      totalTokens: tokens
    )
  )
  
  # Calculate input cost if available (convert per-million-tokens to per-token)
  if modelConfig.inputCostPerMToken.isSome():
    let costPerToken = modelConfig.inputCostPerMToken.get() / 1_000_000.0
    result.totalInputCost = tokens.float * costPerToken
    result.totalCost = result.totalInputCost

proc estimateResponseCost*(inputTokens: int, avgResponseTokens: int, modelConfig: configTypes.ModelConfig): configTypes.CostTracking =
  ## Estimate the total cost including response tokens
  result = configTypes.CostTracking(
    inputCostPerMToken: modelConfig.inputCostPerMToken,
    outputCostPerMToken: modelConfig.outputCostPerMToken,
    totalInputCost: 0.0,
    totalOutputCost: 0.0,
    totalCost: 0.0,
    usage: configTypes.CostTokenUsage(
      inputTokens: inputTokens,
      outputTokens: avgResponseTokens,
      totalTokens: inputTokens + avgResponseTokens
    )
  )
  
  # Calculate costs if available (convert per-million-tokens to per-token)
  if modelConfig.inputCostPerMToken.isSome():
    let inputCostPerToken = modelConfig.inputCostPerMToken.get() / 1_000_000.0
    result.totalInputCost = inputTokens.float * inputCostPerToken
    result.totalCost += result.totalInputCost
  
  if modelConfig.outputCostPerMToken.isSome():
    let outputCostPerToken = modelConfig.outputCostPerMToken.get() / 1_000_000.0
    result.totalOutputCost = avgResponseTokens.float * outputCostPerToken
    result.totalCost += result.totalOutputCost

proc formatCost*(cost: float): string =
  ## Format cost as currency (assumes USD)
  if cost < 0.01:
    return fmt"${cost:.6f}"
  elif cost < 0.1:
    return fmt"${cost:.4f}"
  else:
    return fmt"${cost:.2f}"

proc sendSinglePromptInteractive*(text: string, modelConfig: configTypes.ModelConfig): bool =
  let channels = getChannels()
  
  # Get API key
  let apiKey = readKeyForModel(modelConfig)
  if apiKey.len == 0:
    echo fmt"Error: No API key found for {modelConfig.baseUrl}"
    echo "Set environment variable or configure API key"
    return false
    
  # Add user message to history
  let userMsg = addUserMessage(text)
  
  # Get full conversation context instead of just the current message
  var messages = getConversationContext()
  messages = truncateContextIfNeeded(messages)
  
  # Generate request ID
  let requestId = fmt"req_{historyTypes.getNextSequenceId()}"
  
  return sendChatRequestAsync(channels, messages, modelConfig, requestId, apiKey)

proc sendSinglePromptInteractiveWithId*(text: string, modelConfig: configTypes.ModelConfig): (bool, string) =
  ## Send a prompt and return both success status and request ID
  let channels = getChannels()
  
  # Get API key
  let apiKey = readKeyForModel(modelConfig)
  if apiKey.len == 0:
    echo fmt"Error: No API key found for {modelConfig.baseUrl}"
    echo "Set environment variable or configure API key"
    return (false, "")
    
  # Add user message to history
  let userMsg = addUserMessage(text)
  
  # Get full conversation context instead of just the current message
  var messages = getConversationContext()
  messages = truncateContextIfNeeded(messages)
  
  # Generate request ID
  let requestId = fmt"req_{historyTypes.getNextSequenceId()}"
  
  let success = sendChatRequestAsync(channels, messages, modelConfig, requestId, apiKey)
  return (success, requestId)

proc sendSinglePromptAsync*(text: string, model: string = ""): bool =
  let channels = getChannels()
  let config = loadConfig()
  
  let selectedModel = if model.len > 0:
    getModelFromConfig(config, model)
  else:
    config.models[0]
  
  # Get API key
  let apiKey = readKeyForModel(selectedModel)
  if apiKey.len == 0:
    echo fmt"Error: No API key found for {selectedModel.baseUrl}"
    echo "Set environment variable or configure API key"
    return false
  
  # Debug: Log the API key being used (without the full key for security)
  let keyPreview = if apiKey.len > 8: apiKey[0..7] & "..." else: apiKey
  info fmt"Using API key: {keyPreview} for {selectedModel.baseUrl}"
    
  # Add user message to history
  let userMsg = addUserMessage(text)
  
  # Get full conversation context instead of just the current message
  var messages = getConversationContext()
  messages = truncateContextIfNeeded(messages)
  
  # Generate request ID
  let requestId = fmt"req_{historyTypes.getNextSequenceId()}"
  
  info fmt"Sending prompt to {selectedModel.nickname} with {messages.len} context messages"
  
  return sendChatRequestAsync(channels, messages, selectedModel, requestId, apiKey)

proc sendSinglePromptAsyncWithId*(text: string, model: string = ""): (bool, string) =
  ## Send a prompt and return both success status and request ID
  let channels = getChannels()
  let config = loadConfig()
  
  let selectedModel = if model.len > 0:
    getModelFromConfig(config, model)
  else:
    config.models[0]
  
  # Get API key
  let apiKey = readKeyForModel(selectedModel)
  if apiKey.len == 0:
    echo fmt"Error: No API key found for {selectedModel.baseUrl}"
    echo "Set environment variable or configure API key"
    return (false, "")
  
  # Debug: Log the API key being used (without the full key for security)
  let keyPreview = if apiKey.len > 8: apiKey[0..7] & "..." else: apiKey
  info fmt"Using API key: {keyPreview} for {selectedModel.baseUrl}"
    
  # Add user message to history
  let userMsg = addUserMessage(text)
  
  # Get full conversation context instead of just the current message
  var messages = getConversationContext()
  messages = truncateContextIfNeeded(messages)
  
  # Generate request ID
  let requestId = fmt"req_{historyTypes.getNextSequenceId()}"
  
  info fmt"Sending prompt to {selectedModel.nickname} with {messages.len} context messages"
  
  let success = sendChatRequestAsync(channels, messages, selectedModel, requestId, apiKey)
  return (success, requestId)

proc configureAPIWorker*(modelConfig: configTypes.ModelConfig): bool =
  ## Configure the API worker with a new model configuration
  let channels = getChannels()
  let apiKey = readKeyForModel(modelConfig)
  
  if apiKey.len == 0:
    return false
  
  let configRequest = APIRequest(
    kind: arkConfigure,
    configBaseUrl: modelConfig.baseUrl,
    configApiKey: apiKey,
    configModelName: modelConfig.model
  )
  
  return trySendAPIRequest(channels, configRequest)
