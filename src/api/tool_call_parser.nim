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
  ## Detect tool call format from response content patterns
  ## Supports OpenAI JSON, Anthropic XML, and various Qwen/GLM XML variants
  ## Detect tool call format from response content
  let contentLower = content.toLowerAscii()
  
  # OpenAI JSON format - look for specific JSON structure
  if "\"tool_calls\"" in content and "\"function\"" in content and "\"arguments\"" in content:
    return tfOpenAI
  
  # GLM format from Chutes - <toolcall> with <argkey>/<argvalue> pairs
  if "<toolcall>" in content and "<argkey>" in content and "<argvalue>" in content:
    return tfQwenXML  # Treat GLM format as Qwen variant for now
  
  # GLM-4.5 format - <tool_call> with <arg_key>/<arg_value> pairs  
  if "<tool_call>" in content and "<arg_key>" in content and "<arg_value>" in content:
    return tfQwenXML  # Treat GLM-4.5 format as Qwen variant for now
  
  # Qwen3 XML format - specific malformed XML pattern
  if ("<tool_call>" in content and "<function=" in content and "<parameter=" in content) or
     ("<toolcall>" in content and "<function=" in content and "<parameter=" in content):
    return tfQwenXML
  
  # Standard Anthropic XML format  
  if ("<invoke " in content and "name=" in content) or "<tool_use>" in content:
    return tfAnthropic
  
  # Fallback XML detection for other variants
  if ("<function" in contentLower and "name=" in contentLower) or 
     ("<tool" in contentLower and ("call" in contentLower or "use" in contentLower)):
    return tfQwenXML  # Treat unknown XML as Qwen variant for robustness
  
  # Fallback: if content looks like JSON (has braces and common JSON keys), treat as OpenAI
  if content.startsWith("{") and content.endsWith("}") and 
     ("\"path\"" in content or "\"operation\"" in content or "\"content\"" in content or "\"text\"" in content):
    return tfOpenAI
  
  return tfUnknown

# OpenAI JSON tool call validation (existing logic)
proc isValidJson*(content: string): bool =
  ## Check if content is valid JSON (used for OpenAI format validation)
  ## Check if content is valid JSON
  try:
    discard parseJson(content)
    return true
  except JsonParsingError:
    return false

proc isCompleteJson*(content: string): bool =
  ## Check if JSON content appears complete with matching braces
  ## Check if JSON content appears complete
  if not isValidJson(content):
    return false
  let trimmed = content.strip()
  return trimmed.startsWith("{") and trimmed.endsWith("}")

# XML tool call validation
proc isValidXML*(content: string): bool =
  ## Basic XML validity check - count matching angle brackets
  ## Basic XML validity check - look for matching tags
  let openTags = content.count('<')
  let closeTags = content.count('>')
  return openTags > 0 and openTags == closeTags

proc isCompleteXML*(content: string): bool =
  ## Check if XML tool call appears complete with closing tags
  ## Check if XML tool call appears complete
  let trimmed = content.strip()
  
  # Qwen format: <tool_call>...<function=name>...<parameter=key>value</parameter>...</function></tool_call>
  # GLM-4.5 format: <tool_call>name<arg_key>key</arg_key><arg_value>value</arg_value></tool_call>
  if trimmed.contains("<tool_call>"):
    return trimmed.contains("</tool_call>")
  
  # Alternative Qwen format: <toolcall>...<function=name>...<parameter=key>value</parameter>...</function></toolcall>
  if trimmed.contains("<toolcall>"):
    return trimmed.contains("</toolcall>")
  
  # Anthropic format: <invoke name="...">...</invoke>
  if trimmed.contains("<invoke "):
    return trimmed.contains("</invoke>")
  
  # Generic XML block
  if trimmed.startsWith("<") and trimmed.contains(">"):
    return trimmed.endsWith(">")
    
  return false

# Generate unique tool call ID
proc generateToolCallId*(): string =
  ## Generate unique tool call ID with timestamp and random component
  ## Generate unique tool call ID
  let timestamp = getTime().toUnix()
  return "call_" & $timestamp & "_" & $rand(9999)

# Parse Qwen3's specific XML format
proc parseQwenXMLFragment*(content: string): seq[LLMToolCall] =
  ## Parse Qwen3's XML format and GLM variants with different tag structures
  ## Supports: <tool_call>, <toolcall>, <arg_key>/<arg_value>, <argkey>/<argvalue>
  ## Parse Qwen3's XML format: <tool_call><function=name><parameter=key>value</parameter></function></tool_call>
  result = @[]
  
  debug("Parsing Qwen XML fragment: " & content)
  
  # Handle GLM-4.5 format: <tool_call>toolname<arg_key>key1</arg_key><arg_value>value1</arg_value></tool_call>
  if "<tool_call>" in content and "<arg_key>" in content and "<arg_value>" in content:
    # Extract tool name (text between <tool_call> and first <arg_key>)
    let toolcallStart = content.find("<tool_call>")
    let argkeyStart = content.find("<arg_key>")
    if toolcallStart >= 0 and argkeyStart > toolcallStart:
      let toolNameStart = toolcallStart + 11  # length of "<tool_call>"
      var toolName = content[toolNameStart..<argkeyStart].strip()
      
      # Handle case where tool name might be on same line as opening tag
      if toolName.startsWith(">"):
        toolName = toolName[1..^1].strip()
      
      if toolName.len > 0:
        # Extract parameters using arg_key/arg_value pairs
        var args = %*{}
        var searchPos = 0
        while true:
          let argkeyStart = content.find("<arg_key>", searchPos)
          if argkeyStart < 0: break
          
          let argkeyEndStart = argkeyStart + 9  # length of "<arg_key>"
          let argkeyEnd = content.find("</arg_key>", argkeyEndStart)
          if argkeyEnd <= argkeyEndStart: break
          
          let paramName = content[argkeyEndStart..<argkeyEnd].strip()
          
          let argvalueStart = content.find("<arg_value>", argkeyEnd)
          if argvalueStart < 0: break
          
          let argvalueEndStart = argvalueStart + 11  # length of "<arg_value>"
          let argvalueEnd = content.find("</arg_value>", argvalueEndStart)
          if argvalueEnd <= argvalueEndStart: break
          
          let paramValue = content[argvalueEndStart..<argvalueEnd].strip()
          args[paramName] = %paramValue
          debug(fmt"GLM-4.5 Parameter: {paramName} = {paramValue}")
          
          searchPos = argvalueEnd + 12  # length of "</arg_value>"
        
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
        debug(fmt"Created GLM-4.5 tool call: {toolName} with args: {$args}")
        return result  # Return early since we found GLM-4.5 format
  
  # Handle original GLM format: <toolcall>toolname<argkey>key1</argkey><argvalue>value1</argvalue></toolcall>
  if "<toolcall>" in content and "<argkey>" in content and "<argvalue>" in content:
    # Extract tool name (text between <toolcall> and first <argkey>)
    let toolcallStart = content.find("<toolcall>")
    let argkeyStart = content.find("<argkey>")
    if toolcallStart >= 0 and argkeyStart > toolcallStart:
      let toolNameStart = toolcallStart + 10  # length of "<toolcall>"
      var toolName = content[toolNameStart..<argkeyStart].strip()
      
      # Handle case where tool name might be on same line as opening tag
      if toolName.startsWith(">"):
        toolName = toolName[1..^1].strip()
      
      if toolName.len > 0:
        # Extract parameters using argkey/argvalue pairs
        var args = %*{}
        var searchPos = 0
        while true:
          let argkeyStart = content.find("<argkey>", searchPos)
          if argkeyStart < 0: break
          
          let argkeyEndStart = argkeyStart + 8  # length of "<argkey>"
          let argkeyEnd = content.find("</argkey>", argkeyEndStart)
          if argkeyEnd <= argkeyEndStart: break
          
          let paramName = content[argkeyEndStart..<argkeyEnd].strip()
          
          let argvalueStart = content.find("<argvalue>", argkeyEnd)
          if argvalueStart < 0: break
          
          let argvalueEndStart = argvalueStart + 10  # length of "<argvalue>"
          let argvalueEnd = content.find("</argvalue>", argvalueEndStart)
          if argvalueEnd <= argvalueEndStart: break
          
          let paramValue = content[argvalueEndStart..<argvalueEnd].strip()
          args[paramName] = %paramValue
          debug(fmt"GLM Parameter: {paramName} = {paramValue}")
          
          searchPos = argvalueEnd + 11  # length of "</argvalue>"
        
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
        debug(fmt"Created GLM tool call: {toolName} with args: {$args}")
        return result  # Return early since we found GLM format
  
  # Simple string-based parsing for Qwen3 format (both <tool_call> and <toolcall>)
  if (("<tool_call>" in content) or ("<toolcall>" in content)) and "<function=" in content:
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
  ## Attempt to recover tool information from malformed XML using various strategies
  ## Handles partial tags, missing quotes, and incomplete structures
  ## Attempt to recover tool information from malformed XML
  debug("Attempting to recover malformed tool call from: " & content)
  
  var toolName = ""
  var params = %*{}
  
  # Strategy 1: Handle GLM-4.5 format first
  if "<tool_call>" in content and "<arg_key>" in content:
    # Extract tool name (text between <tool_call> and first <arg_key>)
    let toolcallStart = content.find("<tool_call>")
    let argkeyStart = content.find("<arg_key>")
    if toolcallStart >= 0 and argkeyStart > toolcallStart:
      let toolNameStart = toolcallStart + 11  # length of "<tool_call>"
      toolName = content[toolNameStart..<argkeyStart].strip()
      
      # Handle case where tool name might be on same line as opening tag
      if toolName.startsWith(">"):
        toolName = toolName[1..^1].strip()
  # Strategy 1b: Handle original GLM format
  elif "<toolcall>" in content and "<argkey>" in content:
    # Extract tool name (text between <toolcall> and first <argkey>)
    let toolcallStart = content.find("<toolcall>")
    let argkeyStart = content.find("<argkey>")
    if toolcallStart >= 0 and argkeyStart > toolcallStart:
      let toolNameStart = toolcallStart + 10  # length of "<toolcall>"
      toolName = content[toolNameStart..<argkeyStart].strip()
      
      # Handle case where tool name might be on same line as opening tag
      if toolName.startsWith(">"):
        toolName = toolName[1..^1].strip()
  
  # Strategy 2: Extract tool name using simple string matching (fallback)
  if toolName.len == 0:
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
  
  # Strategy 3: Extract parameters - handle GLM-4.5 format first
  if "<arg_key>" in content and "<arg_value>" in content:
    # Extract parameters using arg_key/arg_value pairs (GLM-4.5 format)
    var searchPos = 0
    while true:
      let argkeyStart = content.find("<arg_key>", searchPos)
      if argkeyStart < 0: break
      
      let argkeyEndStart = argkeyStart + 9  # length of "<arg_key>"
      let argkeyEnd = content.find("</arg_key>", argkeyEndStart)
      if argkeyEnd <= argkeyEndStart: break
      
      let paramName = content[argkeyEndStart..<argkeyEnd].strip()
      
      let argvalueStart = content.find("<arg_value>", argkeyEnd)
      if argvalueStart < 0: break
      
      let argvalueEndStart = argvalueStart + 11  # length of "<arg_value>"
      let argvalueEnd = content.find("</arg_value>", argvalueEndStart)
      if argvalueEnd <= argvalueEndStart: break
      
      let paramValue = content[argvalueEndStart..<argvalueEnd].strip()
      params[paramName] = %paramValue
      
      searchPos = argvalueEnd + 12  # length of "</arg_value>"
  elif "<argkey>" in content and "<argvalue>" in content:
    # Extract parameters using argkey/argvalue pairs (original GLM format)
    var searchPos = 0
    while true:
      let argkeyStart = content.find("<argkey>", searchPos)
      if argkeyStart < 0: break
      
      let argkeyEndStart = argkeyStart + 8  # length of "<argkey>"
      let argkeyEnd = content.find("</argkey>", argkeyEndStart)
      if argkeyEnd <= argkeyEndStart: break
      
      let paramName = content[argkeyEndStart..<argkeyEnd].strip()
      
      let argvalueStart = content.find("<argvalue>", argkeyEnd)
      if argvalueStart < 0: break
      
      let argvalueEndStart = argvalueStart + 10  # length of "<argvalue>"
      let argvalueEnd = content.find("</argvalue>", argvalueEndStart)
      if argvalueEnd <= argvalueEndStart: break
      
      let paramValue = content[argvalueEndStart..<argvalueEnd].strip()
      params[paramName] = %paramValue
      
      searchPos = argvalueEnd + 11  # length of "</argvalue>"
  else:
    # Extract parameters with simple string matching (fallback)
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
  ## Check if tool call content is valid for the specified format
  ## Check if tool call content is valid for the given format
  case format:
  of tfOpenAI: return isValidJson(content)
  of tfAnthropic, tfQwenXML: return isValidXML(content)
  of tfUnknown: return isValidJson(content) or isValidXML(content)

proc isCompleteToolCall*(content: string, format: ToolFormat): bool =
  ## Check if tool call content is complete for the specified format
  ## Check if tool call content is complete for the given format
  case format:
  of tfOpenAI: return isCompleteJson(content)
  of tfAnthropic, tfQwenXML: return isCompleteXML(content)
  of tfUnknown: return isCompleteJson(content) or isCompleteXML(content)

# Main flexible parser
proc parseToolCallFragment*(parser: var FlexibleParser, content: string): seq[LLMToolCall] =
  ## Parse tool call fragment with automatic format detection and buffering
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
  ## Create new flexible parser instance for multi-format tool call parsing
  ## Create new flexible parser instance
  result = FlexibleParser(
    xmlBuffer: "",
    detectedFormat: none(ToolFormat),
    lastFormatCheck: 0.0
  )