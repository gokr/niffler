## Public tokenizer API for Niffler
## Provides high-level interface for token counting with caching and model support
## Integrates the minbpe port for accurate token estimation

import std/[tables, strformat, logging, times, os, options]
import base, basic, gpt4
import ../core/database

type
  TokenizerKind* = enum
    tkBasic,      ## Basic BPE tokenizer
    tkGPT4,       ## GPT-4 compatible tokenizer
    tkEstimation  ## Simple estimation tokenizer

  TokenizerConfig* = object
    kind*: TokenizerKind
    vocabFile*: string  ## Path to vocabulary file (for GPT4)
    vocabSize*: int     ## Vocabulary size (for Basic)

  CachedTokenizer = object
    tokenizer: Tokenizer
    lastUsed: DateTime
    kind: TokenizerKind

var
  tokenizerCache = initTable[string, CachedTokenizer]()
  cacheMaxAge = initDuration(minutes = 30) ## Cache tokenizers for 30 minutes

# === Dynamic Correction Factor System (Database-backed) ===

proc recordTokenCountCorrection*(modelName: string, estimatedTokens: int, actualTokens: int) =
  ## Record a correction sample to improve future estimates using database storage
  ## This should be called when we receive actual token counts from LLM APIs
  if estimatedTokens <= 0 or actualTokens <= 0:
    return  # Invalid data, skip
  
  let database = getGlobalDatabase()
  if database == nil:
    debug("No database available for token correction recording")
    return
  
  recordTokenCorrectionToDB(database, modelName, estimatedTokens, actualTokens)

proc applyCorrectionFactor*(modelName: string, estimatedTokens: int): int =
  ## Apply learned correction factor to improve token estimate using database
  let database = getGlobalDatabase()
  if database == nil:
    return estimatedTokens  # No database, no correction
  
  let correctionFactor = getCorrectionFactorFromDB(database, modelName)
  if correctionFactor.isSome():
    let factor = correctionFactor.get()
    let correctedCount = (estimatedTokens.float * factor).int
    debug(fmt"Applied {factor:.3f} correction factor to {modelName}: {estimatedTokens} -> {correctedCount}")
    return correctedCount
  
  return estimatedTokens  # No correction available

proc getCorrectionStats*(): seq[TokenCorrectionFactor] =
  ## Get all correction statistics from database
  let database = getGlobalDatabase()
  if database == nil:
    return @[]
  
  return getAllCorrectionFactorsFromDB(database)

proc clearCorrectionData*() =
  ## Clear all correction data from database
  let database = getGlobalDatabase()
  if database == nil:
    return
  
  clearAllCorrectionFactorsFromDB(database)

# === End Correction System ===

proc getTokenizer*(config: TokenizerConfig): Tokenizer =
  ## Get or create a tokenizer with caching
  let cacheKey = fmt"{config.kind}:{config.vocabFile}:{config.vocabSize}"
  let currentTime = now()
  
  # Check cache first
  if cacheKey in tokenizerCache:
    let cached = tokenizerCache[cacheKey]
    if currentTime - cached.lastUsed < cacheMaxAge:
      # Update last used time
      tokenizerCache[cacheKey].lastUsed = currentTime
      return cached.tokenizer
  
  # Create new tokenizer
  var tokenizer: Tokenizer
  
  case config.kind:
  of tkBasic:
    tokenizer = newBasicTokenizer()
  of tkGPT4:
    let gpt4Tok = newGPT4Tokenizer() 
    if config.vocabFile.len > 0 and fileExists(config.vocabFile):
      try:
        gpt4Tok.loadFromVocabFile(config.vocabFile)
        debug(fmt"Loaded GPT-4 tokenizer from {config.vocabFile}")
      except Exception as e:
        warn(fmt"Failed to load vocabulary file {config.vocabFile}: {e.msg}")
        # Fall back to estimation tokenizer
        discard  # Use default empty tokenizer
    tokenizer = gpt4Tok
  of tkEstimation:
    tokenizer = createEstimationTokenizer()
  
  # Cache the tokenizer
  tokenizerCache[cacheKey] = CachedTokenizer(
    tokenizer: tokenizer,
    lastUsed: currentTime,
    kind: config.kind
  )
  
  return tokenizer

proc countTokens*(text: string, config: TokenizerConfig): int =
  ## Count tokens in text using the specified tokenizer configuration
  if text.len == 0:
    return 0
  
  try:
    let tokenizer = getTokenizer(config)
    let tokens = tokenizer.encode(text)
    return tokens.len
  except Exception as e:
    error(fmt"Token counting failed: {e.msg}")
    # Fall back to character-based estimation
    return text.len div 4

proc estimateTokens*(text: string): int =
  ## Quick token estimation using the built-in estimation tokenizer
  ## This is the fastest method, good for real-time use
  let config = TokenizerConfig(kind: tkEstimation)
  return countTokens(text, config)

proc countTokensGPT4*(text: string, vocabFile: string = ""): int =
  ## Count tokens using GPT-4 compatible tokenizer
  ## Provides high accuracy for OpenAI models
  let config = TokenizerConfig(kind: tkGPT4, vocabFile: vocabFile)
  return countTokens(text, config)

proc countTokensBasic*(text: string, trainText: string = "", vocabSize: int = 4096): int =
  ## Count tokens using basic BPE tokenizer
  ## Can be trained on custom text for domain-specific tokenization
  let config = TokenizerConfig(kind: tkBasic, vocabSize: vocabSize)
  let tokenizer = getTokenizer(config)
  
  # Train if training text provided and not already trained
  if trainText.len > 0:
    let basicTok = cast[BasicTokenizer](tokenizer)
    if basicTok.merges.len == 0:  # Not yet trained
      try:
        basicTok.train(trainText, vocabSize)
        debug(fmt"Trained basic tokenizer with vocab size {vocabSize}")
      except Exception as e:
        warn(fmt"Training failed: {e.msg}")
  
  return countTokens(text, config)

proc clearTokenizerCache*() =
  ## Clear the tokenizer cache to free memory
  tokenizerCache.clear()
  debug("Tokenizer cache cleared")

proc cleanupTokenizerCache*() =
  ## Remove expired tokenizers from cache
  let currentTime = now()
  var toRemove = newSeq[string]()
  
  for key, cached in tokenizerCache:
    if currentTime - cached.lastUsed >= cacheMaxAge:
      toRemove.add(key)
  
  for key in toRemove:
    tokenizerCache.del(key)
  
  if toRemove.len > 0:
    debug(fmt"Cleaned up {toRemove.len} expired tokenizers from cache")

# Universal token counting with dynamic correction

proc countTokensForModel*(text: string, modelName: string): int =
  ## Universal token counting for any LLM model
  ## Uses BPE estimation with model-specific dynamic correction factor
  ## This works for all modern LLMs since they all use BPE-based tokenization
  let baseCount = estimateTokens(text)
  return applyCorrectionFactor(modelName, baseCount)

when isMainModule:
  # Test the tokenizer API
  echo "Testing Niffler tokenizer API..."
  
  let testText = "Hello, world! This is a test of the tokenization system."
  
  echo fmt"Text: '{testText}'"
  echo fmt"Character count: {testText.len}"
  echo fmt"BPE estimation: {estimateTokens(testText)} tokens"
  echo fmt"Character/4 estimate: {testText.len div 4} tokens"
  
  # Test universal model token counting  
  echo "GPT-4 estimate: " & $countTokensForModel(testText, "gpt-4") & " tokens"
  echo "Qwen estimate: " & $countTokensForModel(testText, "qwen-plus") & " tokens" 
  echo "GLM estimate: " & $countTokensForModel(testText, "glm-4") & " tokens"
  echo "DeepSeek estimate: " & $countTokensForModel(testText, "deepseek-chat") & " tokens"
  
  echo "Tokenizer API test complete."