## Thinking Token Parser for Multi-Provider Support
##
## This module provides comprehensive thinking token parsing for multiple LLM providers,
## including Anthropic XML thinking blocks and OpenAI native reasoning_content fields.
## It integrates with the existing streaming infrastructure to provide real-time
## thinking token processing with minimal overhead.
##
## Key Features:
## - Anthropic XML thinking block parser with streaming support
## - OpenAI reasoner_content field handler
## - Real-time thinking content extraction during streaming
## - Provider detection and automatic format selection
## - Efficient buffering for partial thinking blocks

import std/[strutils, json, options]
import ../types/[messages, thinking_tokens]

type
  # Thinking token parsing result
  ThinkingParseResult* = object
    isThinkingContent*: bool                # Whether this is thinking content
    thinkingContent*: Option[string]        # Extracted thinking content
    regularContent*: Option[string]         # Regular content (if mixed)
    format*: ThinkingTokenFormat            # Detected format
    isComplete*: bool                       # Whether thinking block is complete
  
  # Thinking token parser state
  ThinkingParser* = object
    buffer*: string                         # Buffer for partial content
    detectedFormat*: Option[ThinkingTokenFormat]
    xmlDepth*: int                          # Track XML nesting for Anthropic
    inThinkingBlock*: bool                  # Currently processing thinking block
    thinkingContent*: string                # Accumulated thinking content
    providerSpecific*: Option[JsonNode]     # Provider-specific metadata
    
proc detectThinkingFormatFromJson*(json: JsonNode): ThinkingTokenFormat =
  ## Detect thinking token format from JSON response
  if json.hasKey("thinking") or json.hasKey("reasoning"):
    return ttfAnthropic
    
  if json.hasKey("reasoning_content") or json.hasKey("thinking_content"):
    return ttfOpenAI
    
  if json.hasKey("encrypted_reasoning") or json.hasKey("redacted_thinking"):
    return ttfEncrypted
    
  return ttfNone

proc parseAnthropicThinkingBlock*(content: string): ThinkingParseResult =
  ## Parse Anthropic XML-style thinking blocks
  result.format = ttfAnthropic
  result.isThinkingContent = false
  
  let contentLower = content.toLowerAscii()
  
  # Check for opening <thinking> tag
  let startPos = contentLower.find("<thinking>")
  if startPos >= 0:
    # Check for corresponding closing tag
    let endPos = contentLower.find("</thinking>")
    if endPos > startPos:
      # Complete thinking block
      result.isThinkingContent = true
      result.isComplete = true
      
      # Extract thinking content
      let thinkingStart = startPos + 10  # Length of "<thinking>"
      result.thinkingContent = some(content[thinkingStart..<endPos].strip())
      
      # Extract remaining content (if any)
      let beforeThinking = content[0..<startPos].strip()
      let afterThinking = content[endPos + 11..^1].strip()  # Length of "</thinking>"
      
      if beforeThinking.len > 0 and afterThinking.len > 0:
        result.regularContent = some(beforeThinking & afterThinking)
      elif beforeThinking.len > 0:
        result.regularContent = some(beforeThinking)
      elif afterThinking.len > 0:
        result.regularContent = some(afterThinking)
      else:
        result.regularContent = none(string)
    else:
      # Incomplete thinking block - accumulate
      result.isThinkingContent = true
      result.isComplete = false
      
      # Find where thinking content starts
      let thinkingStart = startPos + 10
      result.thinkingContent = some(content[thinkingStart..^1].strip())
      result.regularContent = some(content[0..<startPos].strip())
  else:
    # No thinking block found, check for redacted thinking
    let redactedStart = contentLower.find("<redacted_thinking>")
    if redactedStart >= 0:
      let redactedEnd = contentLower.find("</redacted_thinking>")
      if redactedEnd > redactedStart:
        result.isThinkingContent = true
        result.isComplete = true
        result.format = ttfEncrypted
        
        # let encryptedStart = redactedStart + 19  # Length of "<redacted_thinking>" (unused)
        result.thinkingContent = some("[ENCRYPTED REASONING]")
        result.regularContent = some(content[0..<redactedStart] & content[redactedEnd + 20..^1])
      else:
        # Incomplete encrypted block
        result.isThinkingContent = true
        result.isComplete = false
        result.format = ttfEncrypted
        result.thinkingContent = some("[PARTIAL ENCRYPTED REASONING]")
        result.regularContent = some(content[0..<redactedStart])

proc parseOpenAIReasoningContent*(content: string): ThinkingParseResult =
  ## Parse OpenAI native reasoning content
  result.format = ttfOpenAI
  result.isThinkingContent = false
  
  # OpenAI reasoning comes in JSON format
  try:
    let jsonContent = parseJson(content)
    
    if jsonContent.hasKey("reasoning_content"):
      result.isThinkingContent = true
      result.isComplete = true
      result.thinkingContent = some(jsonContent{"reasoning_content"}.getStr())
      
      # Extract any regular content
      if jsonContent.hasKey("content"):
        result.regularContent = some(jsonContent{"content"}.getStr())
    
    # Handle encrypted reasoning
    if jsonContent.hasKey("encrypted_reasoning"):
      result.isThinkingContent = true
      result.isComplete = true
      result.format = ttfEncrypted
      result.thinkingContent = some(jsonContent{"encrypted_reasoning"}.getStr())
  
  except JsonParsingError:
    # Non-JSON content, might be partial reasoning
    if "reasoning_content" in content.toLowerAscii():
      result.isThinkingContent = true
      result.isComplete = false
      # Try to extract partial reasoning content
      let reasoningPos = content.toLowerAscii().find("reasoning_content")
      if reasoningPos >= 0:
        result.thinkingContent = some(content[reasoningPos..^1])

proc parseThinkingContent*(content: string, format: ThinkingTokenFormat): ThinkingParseResult =
  ## Parse thinking content based on format
  result.format = format
  
  case format
  of ttfAnthropic:
    result = parseAnthropicThinkingBlock(content)
  of ttfOpenAI:
    result = parseOpenAIReasoningContent(content)
  of ttfEncrypted:
    # Handle encrypted content as thinking content
    result.isThinkingContent = true
    result.isComplete = true
    result.thinkingContent = some("[ENCRYPTED REASONING]")
    result.regularContent = none(string)
  of ttfNone:
    # No thinking content
    result.isThinkingContent = false
    result.isComplete = true
    result.regularContent = some(content)

proc detectAndParseThinkingContent*(content: string): ThinkingParseResult =
  ## Automatically detect format and parse thinking content
  var detectedFormat = ttfNone
  
  # Quick format detection
  let contentLower = content.toLowerAscii()
  if "<thinking>" in contentLower or "<redacted_thinking>" in contentLower:
    detectedFormat = ttfAnthropic
  elif "reasoning_content" in contentLower or "encrypted_reasoning" in contentLower:
    try:
      let jsonContent = parseJson(content)
      if jsonContent.hasKey("reasoning_content") or jsonContent.hasKey("encrypted_reasoning"):
        detectedFormat = ttfOpenAI
      else:
        detectedFormat = ttfNone
    except JsonParsingError:
      # Assume OpenAI format even if JSON parsing fails
      detectedFormat = ttfOpenAI
  elif "{" in contentLower and "}" in contentLower:
    # JSON-like content with possible reasoning
    try:
      let jsonContent = parseJson(content)
      if jsonContent.hasKey("reasoning_content"):
        detectedFormat = ttfOpenAI
    except:
      detectedFormat = ttfNone
  
  return parseThinkingContent(content, detectedFormat)

proc isThinkingContent*(parseResult: ThinkingParseResult): bool {.inline.} =
  ## Check if parsing result contains thinking content
  parseResult.isThinkingContent

proc hasValidThinkingContent*(parseResult: ThinkingParseResult): bool {.inline.} =
  ## Check if result has valid thinking content
  parseResult.isThinkingContent and parseResult.thinkingContent.isSome() and parseResult.thinkingContent.get().len > 0

proc extractThinkingContentForStreaming*(chunk: StreamChunk): ThinkingParseResult =
  ## Extract thinking content from streaming chunk
  if chunk.thinkingContent.isSome() and chunk.isThinkingContent:
    # Chunk already has thinking content from streaming parser
    return ThinkingParseResult(
      isThinkingContent: true,
      thinkingContent: chunk.thinkingContent,
      format: ttfOpenAI,  # Assumed for streaming chunks
      isComplete: false,
      regularContent: none(string)
    )
  
  # Parse regular content for embedded thinking tokens
  return detectAndParseThinkingContent(chunk.choices[0].delta.content)

# Advanced parsing with incremental updates

type
  IncrementalThinkingParser* = object
    buffer*: string
    format*: Option[ThinkingTokenFormat]
    accumulatedThinking*: string
    isInThinkingBlock*: bool
    startMarkerFound*: bool
    endMarkerFound*: bool
    
proc initIncrementalParser*(format: ThinkingTokenFormat = ttfNone): IncrementalThinkingParser {.inline.} =
  ## Initialize incremental thinking token parser
  return IncrementalThinkingParser(
    buffer: "",
    format: if format != ttfNone: some(format) else: none(ThinkingTokenFormat),
    accumulatedThinking: "",
    isInThinkingBlock: false,
    startMarkerFound: false,
    endMarkerFound: false
  )

proc updateIncrementalParser*(parser: var IncrementalThinkingParser, newContent: string) {.inline.} =
  ## Update parser with new streaming content
  parser.buffer.add(newContent)
  
  # Auto-detect format if not set
  if parser.format.isNone():
    let detected = detectAndParseThinkingContent(newContent)
    if detected.format != ttfNone:
      parser.format = some(detected.format)
  
  # Update based on format
  case parser.format.get(ttfNone)
  of ttfAnthropic:
    parser.isInThinkingBlock = "<thinking>" in parser.buffer
    parser.startMarkerFound = "<thinking>" in parser.buffer
    parser.endMarkerFound = "</thinking>" in parser.buffer
    
    if parser.isInThinkingBlock:
      # Extract thinking content from buffer
      let startPos = parser.buffer.toLowerAscii().find("<thinking>")
      let endPos = parser.buffer.toLowerAscii().find("</thinking>")
      
      if startPos >= 0:
        let thinkingStart = startPos + 10  # Length of "<thinking>"
        if endPos > startPos:
          parser.accumulatedThinking = parser.buffer[thinkingStart..<endPos]
        else:
          parser.accumulatedThinking = parser.buffer[thinkingStart..^1]
  
  of ttfOpenAI:
    parser.isInThinkingBlock = parser.buffer.contains("reasoning_content")
    if parser.isInThinkingBlock:
      try:
        let jsonContent = parseJson(parser.buffer)
        if jsonContent.hasKey("reasoning_content"):
          parser.accumulatedThinking = jsonContent{"reasoning_content"}.getStr()
      except:
        # Non-JSON content, try string extraction
        let reasoningPos = parser.buffer.toLowerAscii().find("reasoning_content")
        if reasoningPos >= 0:
          parser.accumulatedThinking = parser.buffer[reasoningPos..^1]
  
  of ttfEncrypted:
    parser.isInThinkingBlock = parser.buffer.contains("encrypted_reasoning") or 
                               parser.buffer.contains("redacted_thinking")
    if parser.isInThinkingBlock:
      parser.accumulatedThinking = "[ENCRYPTED REASONING]"
  
  of ttfNone:
    discard  # No thinking content

proc getThinkingContentFromIncrementalParser*(parser: IncrementalThinkingParser): Option[string] {.inline.} =
  ## Extract current thinking content from incremental parser
  if parser.accumulatedThinking.len > 0:
    return some(parser.accumulatedThinking)
  else:
    return none(string)

proc isThinkingBlockComplete*(parser: IncrementalThinkingParser): bool {.inline.} =
  ## Check if thinking block is complete
  case parser.format.get(ttfNone)
  of ttfAnthropic: return parser.endMarkerFound
  of ttfOpenAI: return true  # OpenAI format doesn't have explicit completion markers
  of ttfEncrypted: return true  # Encrypted content is considered complete
  of ttfNone: return false