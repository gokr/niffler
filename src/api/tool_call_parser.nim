import std/[strutils, json, options, times, logging, random, strformat]
import ../types/messages

type
  ToolFormat* = enum
    tfOpenAI = "openai"
    tfAnthropic = "anthropic" 
    tfQwenXML = "qwen_xml"
    tfUnknown = "unknown"
    
  FlexibleParser* = object
    xmlBuffer*: string
    detectedFormat*: Option[ToolFormat]
    lastFormatCheck*: float

# Format detection based on content patterns
proc detectToolCallFormat*(content: string): ToolFormat =
  ## Detect tool call format from response content
  let contentLower = content.toLowerAscii()
  
  # OpenAI JSON format - look for specific JSON structure
  if "\"tool_calls\"" in content and "\"function\"" in content and "\"arguments\"" in content:
    return tfOpenAI
  
  # Qwen3 XML format - specific malformed XML pattern
  if "<tool_call>" in content and "<function=" in content and "<parameter=" in content:
    return tfQwenXML
  
  # Standard Anthropic XML format  
  if ("<invoke " in content and "name=" in content) or "<tool_use>" in content:
    return tfAnthropic
  
  # Fallback XML detection for other variants
  if ("<function" in contentLower and "name=" in contentLower) or 
     ("<tool" in contentLower and ("call" in contentLower or "use" in contentLower)):
    return tfQwenXML  # Treat unknown XML as Qwen variant for robustness
  
  return tfUnknown

# OpenAI JSON tool call validation (existing logic)
proc isValidJson*(content: string): bool =
  ## Check if content is valid JSON
  try:
    discard parseJson(content)
    return true
  except JsonParsingError:
    return false

proc isCompleteJson*(content: string): bool =
  ## Check if JSON content appears complete
  if not isValidJson(content):
    return false
  let trimmed = content.strip()
  return trimmed.startsWith("{") and trimmed.endsWith("}")

# XML tool call validation
proc isValidXML*(content: string): bool =
  ## Basic XML validity check - look for matching tags
  let openTags = content.count('<')
  let closeTags = content.count('>')
  return openTags > 0 and openTags == closeTags

proc isCompleteXML*(content: string): bool =
  ## Check if XML tool call appears complete
  let trimmed = content.strip()
  
  # Qwen format: <tool_call>...<function=name>...<parameter=key>value</parameter>...</function></tool_call>
  if trimmed.contains("<tool_call>"):
    return trimmed.contains("</tool_call>")
  
  # Anthropic format: <invoke name="...">...</invoke>
  if trimmed.contains("<invoke "):
    return trimmed.contains("</invoke>")
  
  # Generic XML block
  if trimmed.startsWith("<") and trimmed.contains(">"):
    return trimmed.endsWith(">")
    
  return false

# Generate unique tool call ID
proc generateToolCallId*(): string =
  ## Generate unique tool call ID
  let timestamp = getTime().toUnix()
  return "call_" & $timestamp & "_" & $rand(9999)

# Parse Qwen3's specific XML format
proc parseQwenXMLFragment*(content: string): seq[LLMToolCall] =
  ## Parse Qwen3's XML format: <tool_call><function=name><parameter=key>value</parameter></function></tool_call>
  result = @[]
  
  debug("Parsing Qwen XML fragment: " & content)
  
  # Simple string-based parsing for Qwen3 format
  if "<tool_call>" in content and "<function=" in content:
    # Extract function name
    var toolName = ""
    let funcStart = content.find("<function=")
    if funcStart >= 0:
      let nameStart = funcStart + 10  # length of "<function="
      let nameEnd = content.find(">", nameStart)
      if nameEnd > nameStart:
        toolName = content[nameStart..<nameEnd]
    
    if toolName.len > 0:
      # Extract parameters
      var args = %*{}
      var searchPos = 0
      while true:
        let paramStart = content.find("<parameter=", searchPos)
        if paramStart < 0: break
        
        let nameStart = paramStart + 11  # length of "<parameter="
        let nameEnd = content.find(">", nameStart)
        if nameEnd <= nameStart: break
        
        let paramName = content[nameStart..<nameEnd]
        let valueStart = nameEnd + 1
        let valueEnd = content.find("</parameter>", valueStart)
        if valueEnd <= valueStart: break
        
        let paramValue = content[valueStart..<valueEnd]
        args[paramName] = %paramValue
        debug(fmt"Parameter: {paramName} = {paramValue}")
        
        searchPos = valueEnd + 12  # length of "</parameter>"
      
      # Create normalized tool call
      let toolCall = LLMToolCall(
        id: generateToolCallId(),
        `type`: "function",
        function: FunctionCall(
          name: toolName,
          arguments: $args
        )
      )
      
      result.add(toolCall)
      debug(fmt"Created tool call: {toolName} with args: {$args}")

# Parse Anthropic's XML format  
proc parseAnthropicXMLFragment*(content: string): seq[LLMToolCall] =
  ## Parse Anthropic XML format: <invoke name="tool_name"><parameter name="key">value</parameter></invoke>
  result = @[]
  
  # Simple string-based parsing for Anthropic format
  if "<invoke " in content and "name=" in content:
    # Extract tool name from <invoke name="toolname">
    var toolName = ""
    let invokeStart = content.find("<invoke ")
    if invokeStart >= 0:
      let nameStart = content.find("name=", invokeStart)
      if nameStart > invokeStart:
        # Skip past name=" or name='
        let quoteStart = nameStart + 5
        let quoteChar = if content[quoteStart] == '"': '"' else: '\''
        let nameValueStart = quoteStart + 1
        let nameEnd = content.find(quoteChar, nameValueStart)
        if nameEnd > nameValueStart:
          toolName = content[nameValueStart..<nameEnd]
    
    if toolName.len > 0:
      # Extract parameters
      var args = %*{}
      var searchPos = 0
      while true:
        let paramStart = content.find("<parameter ", searchPos)
        if paramStart < 0: break
        
        let nameAttr = content.find("name=", paramStart)
        if nameAttr < 0: break
        
        let quoteStart = nameAttr + 5
        let quoteChar = if content[quoteStart] == '"': '"' else: '\''
        let paramNameStart = quoteStart + 1
        let paramNameEnd = content.find(quoteChar, paramNameStart)
        if paramNameEnd <= paramNameStart: break
        
        let paramName = content[paramNameStart..<paramNameEnd]
        let valueStart = content.find(">", paramNameEnd) + 1
        let valueEnd = content.find("</parameter>", valueStart)
        if valueEnd <= valueStart: break
        
        let paramValue = content[valueStart..<valueEnd]
        args[paramName] = %paramValue
        
        searchPos = valueEnd + 12  # length of "</parameter>"
      
      result.add(LLMToolCall(
        id: generateToolCallId(),
        `type`: "function",
        function: FunctionCall(
          name: toolName,
          arguments: $args
        )
      ))

# Error recovery for malformed tool calls
proc recoverMalformedToolCall*(content: string): Option[LLMToolCall] =
  ## Attempt to recover tool information from malformed XML
  debug("Attempting to recover malformed tool call from: " & content)
  
  var toolName = ""
  var params = %*{}
  
  # Strategy 1: Extract tool name using simple string matching
  if "<function=" in content:
    let start = content.find("<function=") + 10
    let endPos = content.find(">", start)
    if endPos > start:
      toolName = content[start..<endPos]
  elif "name=" in content:
    let nameStart = content.find("name=") + 5
    if nameStart < content.len:
      let quoteChar = if content[nameStart] == '"': '"' else: '\''
      let valueStart = nameStart + 1
      let valueEnd = content.find(quoteChar, valueStart)
      if valueEnd > valueStart:
        toolName = content[valueStart..<valueEnd]
  
  if toolName.len == 0:
    debug("Could not extract tool name from malformed content")
    return none(LLMToolCall)
  
  # Strategy 2: Extract parameters with simple string matching
  var searchPos = 0
  while true:
    let paramStart = content.find("<parameter=", searchPos)
    if paramStart < 0: break
    
    let nameStart = paramStart + 11
    let nameEnd = content.find(">", nameStart)
    if nameEnd <= nameStart: break
    
    let paramName = content[nameStart..<nameEnd]
    let valueStart = nameEnd + 1
    let valueEnd = content.find("</parameter>", valueStart)
    if valueEnd > valueStart:
      let paramValue = content[valueStart..<valueEnd]
      params[paramName] = %paramValue
    
    searchPos = if valueEnd > 0: valueEnd + 12 else: nameEnd + 1
  
  debug(fmt"Recovered tool: {toolName} with params: {$params}")
  
  return some(LLMToolCall(
    id: generateToolCallId(),
    `type`: "function",
    function: FunctionCall(
      name: toolName,
      arguments: $params
    )
  ))

# Format-aware validation functions
proc isValidToolCall*(content: string, format: ToolFormat): bool =
  ## Check if tool call content is valid for the given format
  case format:
  of tfOpenAI: return isValidJson(content)
  of tfAnthropic, tfQwenXML: return isValidXML(content)
  of tfUnknown: return isValidJson(content) or isValidXML(content)

proc isCompleteToolCall*(content: string, format: ToolFormat): bool =
  ## Check if tool call content is complete for the given format
  case format:
  of tfOpenAI: return isCompleteJson(content)
  of tfAnthropic, tfQwenXML: return isCompleteXML(content)
  of tfUnknown: return isCompleteJson(content) or isCompleteXML(content)

# Main flexible parser
proc parseToolCallFragment*(parser: var FlexibleParser, content: string): seq[LLMToolCall] =
  ## Parse tool call fragment with automatic format detection
  result = @[]
  
  # Detect format if not yet determined
  if parser.detectedFormat.isNone:
    let format = detectToolCallFormat(content)
    parser.detectedFormat = some(format)
    debug(fmt"Detected tool call format: {format}")
  
  let format = parser.detectedFormat.get()
  
  # Route to appropriate parser
  case format:
  of tfOpenAI:
    # For OpenAI format, parse JSON directly 
    try:
      discard parseJson(content)
      # Handle OpenAI tool call structure - this would need existing parsing logic
      # For now, return empty and let existing system handle it
      result = @[]
    except JsonParsingError:
      debug("Failed to parse OpenAI JSON format: " & getCurrentExceptionMsg())
  
  of tfQwenXML:
    parser.xmlBuffer.add(content)
    if isCompleteXML(parser.xmlBuffer):
      result = parseQwenXMLFragment(parser.xmlBuffer)
      if result.len > 0:
        parser.xmlBuffer = ""  # Clear buffer after successful parse
  
  of tfAnthropic:
    parser.xmlBuffer.add(content) 
    if isCompleteXML(parser.xmlBuffer):
      result = parseAnthropicXMLFragment(parser.xmlBuffer)
      if result.len > 0:
        parser.xmlBuffer = ""
  
  of tfUnknown:
    # Try both formats and recovery
    try:
      discard parseJson(content)
      # If JSON parses, assume OpenAI format
      parser.detectedFormat = some(tfOpenAI)
    except JsonParsingError:
      # Try XML recovery
      let recovered = recoverMalformedToolCall(content)
      if recovered.isSome:
        result = @[recovered.get()]
        parser.detectedFormat = some(tfQwenXML)

# Initialize flexible parser
proc newFlexibleParser*(): FlexibleParser =
  ## Create new flexible parser instance
  result = FlexibleParser(
    xmlBuffer: "",
    detectedFormat: none(ToolFormat),
    lastFormatCheck: 0.0
  )