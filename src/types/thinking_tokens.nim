## Thinking Token Support Types and Utilities
##
## This module provides comprehensive thinking token support for Niffler,
## including multi-provider thinking token processing, budget management,
## and streaming handling for next-generation reasoning models.
##
## Key Features:
## - Multi-provider thinking token support (Anthropic, OpenAI, etc.)
## - Thinking token budget management with configurable limits
## - Streaming thinking token processing with real-time display
## - Encryption support for privacy-preserving reasoning models
## - Provider-specific metadata handling

import std/[options, strutils, json, logging, times, strformat]
import ../types/config
import ../types/messages  # Import ThinkingContent and related types

type
  # Provider-specific thinking token formats
  ThinkingTokenFormat* = enum
    ttfNone = "none"
    ttfAnthropic = "anthropic"
    ttfOpenAI = "openai"
    ttfEncrypted = "encrypted"
    
  # Thinking token processing state
  ThinkingTokenState* = enum
    ttsIdle = "idle"
    ttsActive = "active"
    ttsComplete = "complete"
    ttsError = "error"
    
  # Thinking token streaming chunk
  ThinkingChunk* = object
    content*: string                    # Thinking content fragment
    isFinal*: bool                      # Whether this is the final chunk
    timestamp*: float                   # Timestamp for ordering
    provider*: ThinkingTokenFormat      # Provider format
    
  # Thinking token budget manager
  ThinkingBudgetManager* = object
    maxTokens*: int                     # Maximum allowed thinking tokens
    currentTokens*: int                 # Currently used tokens
    budgetLevel*: ReasoningLevel        # Budget level (low/medium/high)
    isEnabled*: bool                    # Whether thinking tokens are enabled
    
  # Provider detection result
  ProviderDetectionResult* = object
    format*: ThinkingTokenFormat        # Detected format
    confidence*: float                  # Confidence level (0.0-1.0)
    detectedFrom*: string               # What triggered the detection
    
  # Thinking token importance levels for windowing
  ThinkingImportance* = enum
    tiLow = "low"        # Routine thinking, can be discarded first
    tiMedium = "medium"  # Standard reasoning, preserve in context
    tiHigh = "high"      # Critical insights, should be preserved
    tiEssential = "essential"  # Core reasoning chain, must preserve
    
  # Thinking token with metadata for windowing
  ThinkingToken* = object
    content*: string                 # The actual thinking content
    id*: string                     # Unique identifier
    timestamp*: float               # When this token was created
    importance*: ThinkingImportance # Importance level for preservation
    provider*: ThinkingTokenFormat  # Which provider generated this
    contextId*: string              # Context/conversation identifier
    tokenCount*: int                # Estimated token count
    keywords*: seq[string]          # Key concepts in this thinking
    
  # Context-aware thinking window manager
  ThinkingWindowManager* = object
    maxSize*: int                   # Maximum tokens to preserve
    currentSize*: int               # Current token count in window
    tokens*: seq[ThinkingToken]     # Tokens in the current window
    importanceWeights*: array[ThinkingImportance, float]  # Weight factors for each importance level
    
# Utility functions

proc detectThinkingTokenFormat*(content: string): ProviderDetectionResult {.inline.} =
  ## Detect thinking token format from content
  let contentLower = content.toLowerAscii()
  
  # Anthropic format detection
  if "<thinking>" in contentLower and "</thinking>" in contentLower:
    return ProviderDetectionResult(
      format: ttfAnthropic,
      confidence: 0.9,
      detectedFrom: "Anthropic XML thinking tags"
    )
  
  # OpenAI format detection
  if "reasoning_content" in contentLower:
    return ProviderDetectionResult(
      format: ttfOpenAI,
      confidence: 0.9,
      detectedFrom: "OpenAI reasoning_content field"
    )
  
  # Encrypted format detection
  if "encrypted_reasoning" in contentLower or "redacted_thinking" in contentLower:
    return ProviderDetectionResult(
      format: ttfEncrypted,
      confidence: 0.9,
      detectedFrom: "Encrypted reasoning content"
    )
  
  # Generic thinking indicators
  if "thinking:" in contentLower or "reasoning:" in contentLower:
    return ProviderDetectionResult(
      format: ttfAnthropic,
      confidence: 0.3,
      detectedFrom: "Generic thinking indicators"
    )
  
  return ProviderDetectionResult(
    format: ttfNone,
    confidence: 1.0,
    detectedFrom: "No thinking tokens detected"
  )

proc getReasoningLevelBudget*(level: ReasoningLevel): int {.inline.} =
  ## Get token budget for reasoning level
  case level
  of rlLow: return 2048
  of rlMedium: return 4096
  of rlHigh: return 8192
  of rlNone: return 0

proc parseThinkingContent*(content: string, format: ThinkingTokenFormat): Option[ThinkingContent] =
  ## Parse thinking content based on detected format
  case format
  of ttfAnthropic:
    # Parse XML-style thinking blocks
    if "<thinking>" in content:
      let startPos = content.find("<thinking>")
      let endPos = content.find("</thinking>")
      if startPos >= 0 and endPos > startPos:
        let thinkingStart = startPos + 10  # Length of "<thinking>"
        let thinkingContent = content[thinkingStart..<endPos].strip()
        return some(ThinkingContent(
          reasoningContent: some(thinkingContent),
          encryptedReasoningContent: none(string),
          reasoningId: none(string),
          providerSpecific: none(JsonNode)
        ))
  
  of ttfOpenAI:
    # Parse OpenAI-style reasoning_content
    if "reasoning_content" in content:
      try:
        let jsonContent = parseJson(content)
        if jsonContent.hasKey("reasoning_content"):
          let reasoningContent = jsonContent{"reasoning_content"}.getStr()
          let reasoningId = if jsonContent.hasKey("reasoning_id"): some(jsonContent{"reasoning_id"}.getStr()) else: none(string)
          return some(ThinkingContent(
            reasoningContent: some(reasoningContent),
            encryptedReasoningContent: none(string),
            reasoningId: reasoningId,
            providerSpecific: none(JsonNode)
          ))
      except JsonParsingError:
        debug("Failed to parse OpenAI reasoning content: " & getCurrentExceptionMsg())
  
  of ttfEncrypted:
    # Handle encrypted thinking content
    if "encrypted_reasoning" in content or "redacted_thinking" in content:
      let encryptedReasoning = content  # Store as-is for encryption handling
      return some(ThinkingContent(
        reasoningContent: none(string),
        encryptedReasoningContent: some(encryptedReasoning),
        reasoningId: none(string),
        providerSpecific: none(JsonNode)
      ))
  
  of ttfNone:
    discard  # No thinking content to parse
  
  return none(ThinkingContent)

proc createThinkingChunk*(content: string, isFinal: bool = false, provider: ThinkingTokenFormat = ttfNone): ThinkingChunk {.inline.} =
  ## Create a thinking chunk for streaming processing
  return ThinkingChunk(
    content: content,
    isFinal: isFinal,
    timestamp: epochTime(),
    provider: provider
  )

proc initThinkingBudgetManager*(level: ReasoningLevel = rlMedium, enabled: bool = true): ThinkingBudgetManager {.inline.} =
  ## Initialize a thinking budget manager
  return ThinkingBudgetManager(
    maxTokens: getReasoningLevelBudget(level),
    currentTokens: 0,
    budgetLevel: level,
    isEnabled: enabled
  )

proc canProcessThinkingToken*(manager: var ThinkingBudgetManager, tokenCount: int): bool =
  ## Check if we can process thinking tokens within budget
  if manager.isEnabled:
    manager.currentTokens + tokenCount <= manager.maxTokens
  else:
    false

proc addThinkingTokens*(manager: var ThinkingBudgetManager, tokenCount: int) =
  ## Add thinking tokens to current usage
  manager.currentTokens += tokenCount

proc getRemainingThinkingBudget*(manager: ThinkingBudgetManager): int =
  ## Get remaining thinking token budget
  if manager.isEnabled:
    manager.maxTokens - manager.currentTokens
  else:
    0

proc resetThinkingBudget(manager: var ThinkingBudgetManager) {.used.} =
  ## Reset thinking token usage
  manager.currentTokens = 0

# JSON marshalling support

proc `$`*(thinkingLevel: ReasoningLevel): string =
  ## Convert ReasoningLevel to string
  case thinkingLevel
  of rlLow: "low"
  of rlMedium: "medium"
  of rlHigh: "high"
  of rlNone: "none"

proc parseReasoningLevel*(value: string): ReasoningLevel =
  ## Parse string to ReasoningLevel
  case value.toLowerAscii()
  of "low": rlLow
  of "medium": rlMedium
  of "high": rlHigh
  of "none": rlNone
  else: rlLow  # Default to low if unknown

# Convenience functions

proc getThinkingBudgetFromConfig*(modelConfig: ModelConfig, globalDefault: ReasoningLevel = rlMedium): ReasoningLevel =
  ## Get reasoning budget from model configuration, with fallback to global default
  if modelConfig.reasoning.isSome:
    return modelConfig.reasoning.get()
  else:
    return globalDefault

proc getThinkingBudgetFromModel*(model: string): ReasoningLevel {.deprecated: "Use getThinkingBudgetFromConfig instead".} =
  ## Get default reasoning budget based on model capabilities 
  ## DEPRECATED: Use getThinkingBudgetFromConfig with proper ModelConfig instead
  let modelLower = model.toLowerAscii()
  
  # Advanced models with good reasoning support
  if "claude-3" in modelLower or "gpt-4" in modelLower or "o1" in modelLower:
    rlHigh
  elif "claude" in modelLower or "gpt-4" in modelLower or "deepseek-r1" in modelLower:
    rlMedium
  elif "gpt-3" in modelLower or "qwen" in modelLower:
    rlLow
  else:
    rlMedium  # Default to medium for unknown models

# Thinking Window Management Functions

proc estimateTokenCount*(content: string): int {.inline.} =
  ## Rough estimation of token count (approximately 4 characters per token)
  max(1, content.len div 4)

proc generateUniqueId*(): string {.inline.} =
  ## Generate a simple unique ID for thinking tokens
  $epochTime()

proc extractKeywords*(content: string, maxKeywords: int = 5): seq[string] =
  ## Simple keyword extraction (remove common words)
  let commonWords = ["the", "and", "or", "but", "in", "on", "at", "to", "for", "of", "with", "by", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does", "did", "will", "would", "could", "should", "may", "might", "can", "this", "that", "these", "those", "a", "an"]
  let words = content.toLowerAscii().split()
  var keywords: seq[string] = @[]
  
  for word in words:
    let cleanWord = word.strip(chars = {'!', '?', '.', ',', ';', ':', '"', '\'', '(', ')', '[', ']', '{', '}'})
    if cleanWord.len > 3 and cleanWord notin commonWords and cleanWord notin keywords:
      keywords.add(cleanWord)
      if keywords.len >= maxKeywords:
        break
  
  return keywords

proc classifyThinkingImportance*(content: string): ThinkingImportance =
  ## Classify thinking content importance based on keywords and patterns
  let contentLower = content.toLowerAscii()
  
  # Essential indicators
  if "critical" in contentLower or "essential" in contentLower or "must" in contentLower or "crucial" in contentLower:
    return tiEssential
  
  # High importance indicators
  if "important" in contentLower or "key" in contentLower or "significant" in contentLower or "insight" in contentLower:
    return tiHigh
  
  # Low importance indicators  
  if "obvious" in contentLower or "simple" in contentLower or "straightforward" in contentLower or "trivial" in contentLower:
    return tiLow
  
  # Default to medium
  return tiMedium

proc createThinkingToken*(content: string, importance: ThinkingImportance = tiMedium, provider: ThinkingTokenFormat = ttfNone): ThinkingToken =
  ## Create a thinking token with metadata
  return ThinkingToken(
    content: content,
    id: generateUniqueId(),
    timestamp: epochTime(),
    importance: importance,
    provider: provider,
    contextId: "default",
    tokenCount: estimateTokenCount(content),
    keywords: extractKeywords(content)
  )

proc initThinkingWindowManager*(maxSize: int = 4096): ThinkingWindowManager =
  ## Initialize a thinking window manager
  return ThinkingWindowManager(
    maxSize: maxSize,
    currentSize: 0,
    tokens: @[],
    importanceWeights: [tiLow: 1.0, tiMedium: 2.0, tiHigh: 4.0, tiEssential: 8.0]
  )

proc addTokenToWindow*(window: var ThinkingWindowManager, token: ThinkingToken): bool =
  ## Add a token to the window, handling overflow as needed
  if window.maxSize <= 0:
    return false
  
  if token.tokenCount > window.maxSize:
    return false  # Token too large for window
  
  # Make space if needed
  while window.currentSize + token.tokenCount > window.maxSize and window.tokens.len > 0:
    # Remove least important token
    var minImportanceIdx = 0
    for i in 1..<window.tokens.len:
      if ord(window.tokens[i].importance) < ord(window.tokens[minImportanceIdx].importance):
        minImportanceIdx = i
    
    window.currentSize -= window.tokens[minImportanceIdx].tokenCount
    window.tokens.delete(minImportanceIdx)
  
  # Add the new token
  window.tokens.add(token)
  window.currentSize += token.tokenCount
  return true

proc getImportantTokens*(window: ThinkingWindowManager, minImportance: ThinkingImportance): seq[ThinkingToken] =
  ## Get tokens with at least the specified importance level
  result = @[]
  for token in window.tokens:
    if ord(token.importance) >= ord(minImportance):
      result.add(token)

proc getWindowSummary*(window: ThinkingWindowManager): string =
  ## Get a summary of the current window state
  return &"Thinking Window Summary: {window.tokens.len} tokens, {window.currentSize}/{window.maxSize} tokens used"

proc clearWindow*(window: var ThinkingWindowManager) =
  ## Clear all tokens from the window
  window.tokens = @[]
  window.currentSize = 0