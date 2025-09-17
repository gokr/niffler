## Heuristic Token Estimation Module
## Based on tokenx library approach - fast, lightweight token counting using intelligent heuristics
## Provides 7-16% accuracy without requiring tokenizer training

import std/[re, unicode, strutils, tables, options]

type
  LanguageConfig* = object
    ## Language-specific token estimation configuration
    pattern*: Regex           ## Regular expression to detect the language
    averageCharsPerToken*: float  ## Average number of characters per token for this language

  EstimationOptions* = object
    ## Configuration options for token estimation
    defaultCharsPerToken*: float      ## Default average characters per token when no language-specific rule applies
    languageConfigs*: seq[LanguageConfig]  ## Custom language configurations to override defaults

# Regular expression patterns for different text types
let PATTERNS = {
  "whitespace": re(r"^\s+$"),
  "numeric": re(r"^\d+(?:[.,]\d+)*$"),
  "punctuation": re(r"[.,!?;(){}[\]<>:/\\|@#$%^&*+=`~-]"),
  "alphanumeric": re(r"^[a-zA-Z0-9À-ÖØ-öø-ÿ]+$")
}.toTable

# Pattern for splitting text into segments (whitespace and punctuation)
let TOKEN_SPLIT_PATTERN = re(r"(\s+|[.,!?;(){}[\]<>:/\\|@#$%^&*+=`~-]+)")

# Default configuration constants
const DEFAULT_CHARS_PER_TOKEN = 6.0
const SHORT_TOKEN_THRESHOLD = 3

# Default language-specific token estimation rules
let DEFAULT_LANGUAGE_CONFIGS = @[
  LanguageConfig(pattern: re(r"[äöüßẞ]", {reIgnoreCase}), averageCharsPerToken: 3.0),           # German
  LanguageConfig(pattern: re(r"[éèêëàâîïôûùüÿçœæáíóúñ]", {reIgnoreCase}), averageCharsPerToken: 3.0), # French/Spanish
  LanguageConfig(pattern: re(r"[ąćęłńóśźżěščřžýůúďťň]", {reIgnoreCase}), averageCharsPerToken: 3.5)  # Polish/Czech
]

proc getCharacterCount(text: string): int =
  ## Get the actual Unicode character count (handles multi-byte characters correctly)
  var count = 0
  for rune in text.runes:
    inc count
  return count

proc containsCJKCharacters(text: string): bool =
  ## Check if text contains CJK (Chinese, Japanese, Korean) characters
  ## Using Unicode code point ranges for CJK detection
  for rune in text.runes:
    let code = rune.int32
    # CJK Unified Ideographs, Hiragana, Katakana, Hangul
    if (code >= 0x4E00 and code <= 0x9FFF) or    # CJK Unified Ideographs
       (code >= 0x3400 and code <= 0x4DBF) or    # CJK Extension A
       (code >= 0x3040 and code <= 0x309F) or    # Hiragana
       (code >= 0x30A0 and code <= 0x30FF) or    # Katakana
       (code >= 0xAC00 and code <= 0xD7AF):      # Hangul
      return true
  return false

proc getLanguageSpecificCharsPerToken(segment: string, languageConfigs: seq[LanguageConfig]): Option[float] =
  ## Find language-specific characters-per-token ratio for a text segment
  for config in languageConfigs:
    if segment.contains(config.pattern):
      return some(config.averageCharsPerToken)
  return none(float)

proc estimateSegmentTokens(segment: string, languageConfigs: seq[LanguageConfig], defaultCharsPerToken: float): int =
  ## Estimate token count for a single text segment using heuristic rules
  
  # Skip whitespace segments
  if segment.contains(PATTERNS["whitespace"]):
    return 0
  
  # CJK characters: typically 1 character = 1 token
  if containsCJKCharacters(segment):
    return getCharacterCount(segment)
  
  # Numeric patterns: entire number = 1 token
  if segment.contains(PATTERNS["numeric"]):
    return 1
  
  # Short tokens (3 characters or less): 1 token
  if segment.len <= SHORT_TOKEN_THRESHOLD:
    return 1
  
  # Punctuation: smart chunking based on length
  if segment.contains(PATTERNS["punctuation"]):
    return if segment.len > 1: (segment.len + 1) div 2 else: 1
  
  # Alphanumeric text: use language-specific or default ratio
  if segment.contains(PATTERNS["alphanumeric"]):
    let charsPerToken = getLanguageSpecificCharsPerToken(segment, languageConfigs).get(defaultCharsPerToken)
    return max(1, (segment.len.float / charsPerToken).int)
  
  # Fallback: treat as individual characters (for mixed/unknown content)
  return getCharacterCount(segment)

proc estimateTokenCount*(text: string, options: EstimationOptions = EstimationOptions()): int =
  ## Estimate the number of tokens in a text string using heuristic rules
  ## This is the main function that provides fast, accurate token estimation
  if text.len == 0:
    return 0
  
  let defaultCharsPerToken = if options.defaultCharsPerToken > 0: options.defaultCharsPerToken else: DEFAULT_CHARS_PER_TOKEN
  let languageConfigs = if options.languageConfigs.len > 0: options.languageConfigs else: DEFAULT_LANGUAGE_CONFIGS
  
  # Split text into segments using whitespace and punctuation patterns
  let segments = text.split(TOKEN_SPLIT_PATTERN)
  var tokenCount = 0
  
  for segment in segments:
    if segment.len > 0:  # Skip empty segments
      tokenCount += estimateSegmentTokens(segment, languageConfigs, defaultCharsPerToken)
  
  return tokenCount

proc isWithinTokenLimit*(text: string, tokenLimit: int, options: EstimationOptions = EstimationOptions()): bool =
  ## Check if the estimated token count of the input is within a specified token limit
  return estimateTokenCount(text, options) <= tokenLimit

proc extractSegmentPart(segment: string, segmentTokenStart: int, segmentTokenCount: int, 
                       targetStart: int, targetEnd: int): string =
  ## Extract a portion of a segment based on token positions
  if segmentTokenCount == 0:
    return if segmentTokenStart >= targetStart and segmentTokenStart < targetEnd: segment else: ""
  
  let segmentTokenEnd = segmentTokenStart + segmentTokenCount
  if segmentTokenStart >= targetEnd or segmentTokenEnd <= targetStart:
    return ""
  
  let overlapStart = max(0, targetStart - segmentTokenStart)
  let overlapEnd = min(segmentTokenCount, targetEnd - segmentTokenStart)
  
  if overlapStart == 0 and overlapEnd == segmentTokenCount:
    return segment
  
  let charStart = (overlapStart.float / segmentTokenCount.float * segment.len.float).int
  let charEnd = (overlapEnd.float / segmentTokenCount.float * segment.len.float).int
  return segment[charStart..<min(charEnd, segment.len)]

proc sliceByTokens*(text: string, start: int = 0, `end`: int = -1, 
                    options: EstimationOptions = EstimationOptions()): string =
  ## Extract a portion of text based on token positions, similar to string slicing
  ## Supports both positive and negative indices
  if text.len == 0:
    return ""
  
  let defaultCharsPerToken = if options.defaultCharsPerToken > 0: options.defaultCharsPerToken else: DEFAULT_CHARS_PER_TOKEN
  let languageConfigs = if options.languageConfigs.len > 0: options.languageConfigs else: DEFAULT_LANGUAGE_CONFIGS
  
  # Handle negative indices by calculating total tokens first
  var totalTokens = 0
  if start < 0 or `end` < 0:
    totalTokens = estimateTokenCount(text, options)
  
  # Normalize indices
  let normalizedStart = if start < 0: max(0, totalTokens + start) else: max(0, start)
  let normalizedEnd = if `end` < 0: 
                        max(0, totalTokens + `end`)
                      elif `end` == -1: 
                        int.high 
                      else: 
                        `end`
  
  if normalizedStart >= normalizedEnd:
    return ""
  
  # Use same splitting logic as estimateTokenCount for consistency
  let segments = text.split(TOKEN_SPLIT_PATTERN)
  var parts: seq[string] = @[]
  var currentTokenPos = 0
  
  for segment in segments:
    if segment.len > 0 and currentTokenPos < normalizedEnd:
      let tokenCount = estimateSegmentTokens(segment, languageConfigs, defaultCharsPerToken)
      let extracted = extractSegmentPart(segment, currentTokenPos, tokenCount, normalizedStart, normalizedEnd)
      if extracted.len > 0:
        parts.add(extracted)
      currentTokenPos += tokenCount
  
  return parts.join("")

# Convenience functions with default options
proc estimateTokenCountSimple*(text: string): int =
  ## Simple token estimation with default settings
  return estimateTokenCount(text)

proc estimateTokenCountCustom*(text: string, charsPerToken: float): int =
  ## Token estimation with custom characters-per-token ratio
  let options = EstimationOptions(defaultCharsPerToken: charsPerToken)
  return estimateTokenCount(text, options)

when isMainModule:
  # Test the heuristic estimation functions
  echo "Testing Heuristic Token Estimation..."
  
  let testTexts = @[
    "Hello, world!",
    "The quick brown fox jumps over the lazy dog.",
    "Die pünktlich gewünschte Trüffelfüllung im übergestülpten Würzkümmel-Würfel",
    "こんにちは世界",  # Japanese
    "123,456.78",
    "function calculateTotal(items) { return items.reduce((sum, item) => sum + item.price, 0); }"
  ]
  
  for text in testTexts:
    let tokens = estimateTokenCount(text)
    let charDiv4 = text.len div 4
    echo fmt("Text: '{text}'")
    echo fmt("  Length: {text.len} chars")
    echo fmt("  Heuristic estimate: {tokens} tokens")
    echo fmt("  Char/4 estimate: {charDiv4} tokens")
    echo fmt("  Ratio: {tokens.float / charDiv4.float:.2f}x")
    echo ""