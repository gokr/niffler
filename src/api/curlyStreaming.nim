## Curly-based Streaming HTTP Client
##
## This module provides a streaming HTTP client using the Curly library,
## optimized for Server-Sent Events (SSE) and real-time LLM API communication.
##
## Key Features:
## - Real network-level SSE streaming using Curly's ResponseStream
## - Thread-ready parallel HTTP client (libcurl-based)
## - Automatic TCP connection re-use and HTTP/2 multiplexing
## - OpenAI-compatible API support with tool calling
## - Callback-based streaming for immediate response processing
##
## Advantages over Custom Socket Implementation:
## - Leverages battle-tested libcurl for HTTP handling
## - Automatic connection pooling and reuse
## - HTTP/2 multiplexing support
## - Built-in SSL/TLS handling
## - Better error handling and robustness
##
## Design Decisions:
## - Uses Curly's blocking stream reading for thread-safe operation
## - Manual SSE parsing on top of Curly's streaming mechanism
## - Compatible with existing message types and API

import std/[json, strutils, options, strformat, logging, tables]
import curly
import ../types/[messages, config, thinking_tokens]
import ../core/log_file as logFileModule
import tool_call_parser
import thinking_token_parser

# Single long-lived Curly instance for the entire application
let curl* = newCurly()

# Global dump flag for request/response logging
var dumpEnabled {.threadvar.}: bool

# Global parser for flexible tool call format detection
var globalFlexibleParser {.threadvar.}: FlexibleParser

# Global thinking token parser for incremental processing
var globalThinkingParser {.threadvar.}: IncrementalThinkingParser

proc setDumpEnabled*(enabled: bool) =
  ## Set the global dump flag for HTTP request/response logging
  dumpEnabled = enabled

proc initGlobalParser*() =
  ## Initialize the global flexible parser
  globalFlexibleParser = newFlexibleParser()

proc initGlobalThinkingParser*(enabled: bool = true) =
  ## Initialize the global thinking token parser
  if enabled:
    globalThinkingParser = initIncrementalParser()

# Forward declaration
proc parseNonOpenAIFormat*(dataLine: string): Option[StreamChunk] {.gcsafe.}

# Thinking token processing procs
proc processThinkingContent(rawContent: string, chunk: var StreamChunk): string =
  ## Process potential thinking content in response and separate it from regular content
  let thinkingResult = detectAndParseThinkingContent(rawContent)
  
  if thinkingResult.isThinkingContent and thinkingResult.format != ttfNone:
    # Update chunk with thinking content
    if thinkingResult.thinkingContent.isSome():
      chunk.thinkingContent = thinkingResult.thinkingContent
      chunk.isThinkingContent = true
    
    # Return regular content (if any)
    return thinkingResult.regularContent.get("")
  else:
    # No thinking content found, return original content
    chunk.isThinkingContent = false
    return rawContent

proc initDumpFlag*() =
  ## Initialize the dump flag (called once per thread)
  dumpEnabled = false

proc isDumpEnabled*(): bool =
  ## Check if HTTP request/response dumping is enabled
  return dumpEnabled

type
  CurlyStreamingClient* = object
    baseUrl*: string
    apiKey*: string
    model*: string
    headers*: Table[string, string]
    
  StreamingCallback* = proc(chunk: StreamChunk) {.gcsafe.}

# SSE line parsing (same as before but with proper error handling)
proc parseSSELine(line: string): Option[StreamChunk] =
  ## Parse a single SSE line into a StreamChunk
  if line.startsWith("data: "):
    let dataLine = line[6..^1].strip()
    if dataLine == "[DONE]":
      return some(StreamChunk(
        id: "", 
        `object`: "chat.completion.chunk", 
        created: 0, 
        model: "", 
        choices: @[],
        done: true
      ))
    
    try:
      let json = parseJson(dataLine)
      
      # Parse OpenAI streaming format
      var chunk = StreamChunk(
        id: json{"id"}.getStr(""),
        `object`: json{"object"}.getStr("chat.completion.chunk"),
        created: json{"created"}.getInt(0),
        model: json{"model"}.getStr(""),
        choices: @[],
        done: false
      )
      
      # Parse choices
      if json.hasKey("choices") and json["choices"].kind == JArray:
        for choiceJson in json["choices"]:
          var choice = StreamChoice(
            index: choiceJson{"index"}.getInt(0),
            delta: ChatMessage(role: "", content: ""),
            finishReason: none(string)
          )
          
          # Parse delta
          if choiceJson.hasKey("delta"):
            let delta = choiceJson["delta"]
            choice.delta.role = delta{"role"}.getStr("")
            let rawContent = delta{"content"}.getStr("")
            
            # Parse thinking token content (Anthropic/OpenAI format)
            if delta.hasKey("thinking"):
              # Anthropic format - thinking content in delta
              let thinkingContent = delta{"thinking"}.getStr("")
              chunk.thinkingContent = some(thinkingContent)
              chunk.isThinkingContent = true
              choice.delta.content = rawContent  # Keep regular content
            elif delta.hasKey("reasoning_content"):
              # OpenAI format - reasoning content in delta
              let reasoningContent = delta{"reasoning_content"}.getStr("")
              chunk.thinkingContent = some(reasoningContent)
              chunk.isThinkingContent = true
              choice.delta.content = rawContent  # Keep regular content
            elif delta.hasKey("encrypted_thinking"):
              # Encrypted thinking content
              let encryptedThinking = delta{"encrypted_thinking"}.getStr("")
              chunk.thinkingContent = some(encryptedThinking)
              chunk.isThinkingContent = true
              chunk.isEncrypted = some(true)
              choice.delta.content = rawContent  # Keep regular content
            else:
              # No explicit thinking fields, use processThinkingContent to detect embedded thinking
              choice.delta.content = processThinkingContent(rawContent, chunk)
            
            # Parse tool calls in delta
            if delta.hasKey("tool_calls") and delta["tool_calls"].kind == JArray:
              var toolCalls: seq[LLMToolCall] = @[]
              for tcJson in delta["tool_calls"]:
                let toolCall = LLMToolCall(
                  id: tcJson{"id"}.getStr(""),
                  `type`: tcJson{"type"}.getStr("function"),
                  function: FunctionCall(
                    name: if tcJson.hasKey("function") and tcJson["function"].kind == JObject: tcJson{"function"}{"name"}.getStr("") else: "",
                    arguments: if tcJson.hasKey("function") and tcJson["function"].kind == JObject: tcJson{"function"}{"arguments"}.getStr("") else: ""
                  )
                )
                toolCalls.add(toolCall)
              choice.delta.toolCalls = some(toolCalls)
          
          # Parse finish reason
          if choiceJson.hasKey("finish_reason") and choiceJson["finish_reason"].kind != JNull:
            choice.finishReason = some(choiceJson["finish_reason"].getStr(""))
          
          chunk.choices.add(choice)
      
      # Parse thinking content at root level (some providers)
      if json.hasKey("reasoning_content"):
        chunk.thinkingContent = some(json{"reasoning_content"}.getStr(""))
        chunk.isThinkingContent = true
      
      if json.hasKey("thinking"):
        chunk.thinkingContent = some(json{"thinking"}.getStr(""))
        chunk.isThinkingContent = true
      
      if json.hasKey("encrypted_reasoning"):
        chunk.thinkingContent = some(json{"encrypted_reasoning"}.getStr(""))
        chunk.isThinkingContent = true
        chunk.isEncrypted = some(true)

      # Parse usage data if present (often sent in final streaming chunk)
      if json.hasKey("usage") and json["usage"].kind == JObject:
        let usageJson = json["usage"]
        var reasoningTokens = 0
        if usageJson.hasKey("reasoning_tokens"):
          reasoningTokens = usageJson{"reasoning_tokens"}.getInt(0)
        
        chunk.usage = some(messages.TokenUsage(
          inputTokens: usageJson{"prompt_tokens"}.getInt(0),
          outputTokens: usageJson{"completion_tokens"}.getInt(0),
          totalTokens: usageJson{"total_tokens"}.getInt(0),
          reasoningTokens: if reasoningTokens > 0: some(reasoningTokens) else: none(int)
        ))
      
      return some(chunk)
      
    except JsonParsingError as e:
      debug(fmt"Failed to parse SSE JSON, trying flexible parser: {dataLine[0..min(200, dataLine.len-1)]} - Error: {e.msg}")
      # Try flexible parsing for non-OpenAI formats
      try:
        return parseNonOpenAIFormat(dataLine)
      except Exception as flexErr:
        debug(fmt"Flexible parser also failed: {flexErr.msg}")
    except KeyError as e:
      debug(fmt"Missing expected field in SSE JSON: {e.msg} - Line: {dataLine[0..min(200, dataLine.len-1)]}")
    except ValueError as e:
      debug(fmt"Invalid value in SSE JSON: {e.msg} - Line: {dataLine[0..min(200, dataLine.len-1)]}")
      
  return none(StreamChunk)

proc parseNonOpenAIFormat*(dataLine: string): Option[StreamChunk] {.gcsafe.} =
  ## Parse non-OpenAI formats using flexible parser
  debug(fmt"Attempting to parse non-OpenAI format: {dataLine}")
  
  # Initialize parser if not already done
  if globalFlexibleParser.detectedFormat.isNone:
    initGlobalParser()
  
  # Update global thinking parser for incremental thinking token processing
  globalThinkingParser.updateIncrementalParser(dataLine)
  let thinkingContent = globalThinkingParser.getThinkingContentFromIncrementalParser()
  
  # If we have thinking content from incremental parsing, create thinking chunk
  if thinkingContent.isSome() and globalThinkingParser.isThinkingBlockComplete():
    var chunk = StreamChunk(
      choices: @[
        StreamChoice(
          index: 0,
          delta: ChatMessage(
            role: "assistant",
            content: "",
            reasoningContent: thinkingContent,
            encryptedReasoningContent: if globalThinkingParser.format.get(ttfNone) == ttfEncrypted: some("[ENCRYPTED REASONING]") else: none(string)
          ),
          finishReason: none(string)
        )
      ],
      isThinkingContent: true,
      thinkingContent: thinkingContent,
      isEncrypted: some(globalThinkingParser.format.get(ttfNone) == ttfEncrypted)
    )
    debug(fmt"Successfully parsed thinking token from incremental parsing")
    return some(chunk)
  elif thinkingContent.isSome() and not globalThinkingParser.isThinkingBlockComplete():
    # Partial thinking content, create chunk with partial content
    var chunk = StreamChunk(
      choices: @[
        StreamChoice(
          index: 0,
          delta: ChatMessage(
            role: "assistant",
            content: "",  # Regular content
            reasoningContent: thinkingContent  # Partial thinking content
          ),
          finishReason: none(string)
        )
      ],
      isThinkingContent: true,
      thinkingContent: thinkingContent,
      isEncrypted: some(globalThinkingParser.format.get(ttfNone) == ttfEncrypted)
    )
    return some(chunk)
  
  # Try to extract tool calls from the content
  let toolCalls = parseToolCallFragment(globalFlexibleParser, dataLine)
  
  if toolCalls.len > 0:
    # Create a synthetic StreamChunk for the tool calls
    var chunk = StreamChunk(choices: @[])
    var choice = StreamChoice(
      index: 0,
      delta: ChatMessage(
        role: "assistant",
        content: "",
        toolCalls: some(toolCalls)
      ),
      finishReason: none(string)
    )
    chunk.choices.add(choice)
    debug(fmt"Successfully parsed {toolCalls.len} tool calls from non-OpenAI format")
    return some(chunk)
  
  # If no tool calls found, treat as regular content
  let format = detectToolCallFormat(dataLine)
  if format != tfUnknown:
    debug(fmt"Detected format {format} but no complete tool calls yet")
  
  return none(StreamChunk)

proc newCurlyStreamingClient*(baseUrl, apiKey, model: string): CurlyStreamingClient =
  ## Create a new Curly-based streaming HTTP client
  var headers = initTable[string, string]()
  headers["Content-Type"] = "application/json"
  headers["Authorization"] = "Bearer " & apiKey
  headers["Accept"] = "text/event-stream"
  headers["Cache-Control"] = "no-cache"
  headers["User-Agent"] = "Niffler"
  # Force connection closure for better cancellation behavior
  headers["Connection"] = "close"
  
  # Add provider-specific headers
  if baseUrl.contains("openrouter.ai"):
    headers["HTTP-Referer"] = "https://niffler.ai"
    headers["X-Title"] = "Niffler"
  
  result = CurlyStreamingClient(
    baseUrl: baseUrl,
    apiKey: apiKey,
    model: model,
    headers: headers
  )

proc toJson*(req: ChatRequest): JsonNode {.gcsafe.} =
  ## Convert ChatRequest to comprehensive JSON format
  var messages: seq[JsonNode] = @[]
  
  for msg in req.messages:
    var msgJson = %*{
      "role": msg.role,
      "content": msg.content
    }
    
    # Add tool calls if present
    if msg.toolCalls.isSome():
      var toolCalls: seq[JsonNode] = @[]
      for toolCall in msg.toolCalls.get():
        toolCalls.add(%*{
          "id": toolCall.id,
          "type": toolCall.`type`,
          "function": {
            "name": toolCall.function.name,
            "arguments": toolCall.function.arguments
          }
        })
      msgJson["tool_calls"] = %toolCalls
    
    # Add tool call ID if present
    if msg.toolCallId.isSome():
      msgJson["tool_call_id"] = %msg.toolCallId.get()
    
    messages.add(msgJson)
  
  result = %*{
    "model": req.model,
    "messages": messages,
    "stream": req.stream
  }
  
  if req.maxTokens.isSome():
    result["max_tokens"] = %req.maxTokens.get()
  if req.temperature.isSome():
    result["temperature"] = %req.temperature.get()
  if req.topP.isSome():
    result["top_p"] = %req.topP.get()
  if req.topK.isSome():
    result["top_k"] = %req.topK.get()
  if req.stop.isSome():
    var stopArray = newJArray()
    for stopItem in req.stop.get():
      stopArray.add(%stopItem)
    result["stop"] = %stopArray
  if req.presencePenalty.isSome():
    result["presence_penalty"] = %req.presencePenalty.get()
  if req.frequencyPenalty.isSome():
    result["frequency_penalty"] = %req.frequencyPenalty.get()
  if req.logitBias.isSome():
    var biasObj = newJObject()
    for key, val in pairs(req.logitBias.get()):
      biasObj[$key] = %val
    result["logit_bias"] = %biasObj
  if req.seed.isSome():
    result["seed"] = %req.seed.get()
  
  # Add tools if present
  if req.tools.isSome():
    var tools: seq[JsonNode] = @[]
    for tool in req.tools.get():
      tools.add(%*{
        "type": tool.`type`,
        "function": {
          "name": tool.function.name,
          "description": tool.function.description,
          "parameters": tool.function.parameters
        }
      })
    result["tools"] = %tools

proc buildRequestBody(client: CurlyStreamingClient, request: ChatRequest): string =
  ## Build the JSON request body using comprehensive toJson
  var streamRequest = request
  streamRequest.stream = true  # Force streaming for this client
  return $streamRequest.toJson()

proc sendStreamingChatRequest*(client: var CurlyStreamingClient, request: ChatRequest, callback: StreamingCallback): (bool, Option[TokenUsage]) =
  ## Send a streaming chat request using Curly and process chunks in real-time
  ## Returns success status and usage information if available
  
  try:
    # Build request
    let requestBody = client.buildRequestBody(request)
    let endpoint = client.baseUrl & "/chat/completions"
    
    debug(fmt"Sending streaming request to {endpoint}")
    
    # Dump HTTP request if enabled
    if isDumpEnabled():
      logFileModule.logEcho ""
      logFileModule.logEcho "=== HTTP REQUEST ==="
      logFileModule.logEcho "URL: " & endpoint
      logFileModule.logEcho "Method: POST"
      logFileModule.logEcho "Headers:"
      for key, value in client.headers.pairs:
        # Mask Authorization header for security
        let displayValue = if key.toLowerAscii() == "authorization": "Bearer ***" else: value
        logFileModule.logEcho "  " & key & ": " & displayValue
      logFileModule.logEcho ""
      logFileModule.logEcho "Body:"
      logFileModule.logEcho requestBody
      logFileModule.logEcho "==================="
      logFileModule.logEcho ""
    
    # Create headers array for Curly
    var headerSeq: seq[(string, string)] = @[]
    for key, value in client.headers.pairs:
      headerSeq.add((key, value))
    
    # Make the streaming request
    let stream = curl.request("POST", endpoint, headerSeq, requestBody)
    
    var finalUsage: Option[TokenUsage] = none(TokenUsage)
    var fullResponseBody = ""  # Capture full response for dumping
    
    try:
      if stream.code != 200:
        error(fmt"HTTP request failed with status {stream.code}")
        return (false, none(TokenUsage))
      
      debug(fmt"Received HTTP {stream.code}, starting SSE processing")
      
      # Dump HTTP response headers if enabled - use logging to prevent stream contamination
      if isDumpEnabled():
        logFileModule.logEcho ""
        logFileModule.logEcho "=== HTTP RESPONSE ==="
        logFileModule.logEcho "Status: " & $stream.code
        logFileModule.logEcho "Headers:"
        logFileModule.logEcho "  Content-Type: text/event-stream"
        logFileModule.logEcho "  Transfer-Encoding: chunked"
        logFileModule.logEcho ""
        logFileModule.logEcho "Body (streaming):"
      
      # Process the stream line by line in real-time
      var lineBuffer = ""
      
      while true:
        var buffer = ""
        let bytesRead = stream.read(buffer)
        
        if bytesRead == 0:
          debug("Stream ended normally")
          break
        
        # Add received data to line buffer
        lineBuffer.add(buffer)
        
        # Capture for dumping if enabled
        if isDumpEnabled():
          fullResponseBody.add(buffer)
        
        # Process complete lines
        while "\n" in lineBuffer:
          let lineEndPos = lineBuffer.find("\n")
          let line = lineBuffer[0..<lineEndPos].strip()
          lineBuffer = lineBuffer[lineEndPos+1..^1]
          
          if line.len > 0:
            # Dump line if enabled - use logging instead of echo to prevent stream contamination
            if isDumpEnabled():
              logFileModule.logEcho line
            
            try:
              let maybeChunk = parseSSELine(line)
              if maybeChunk.isSome():
                let chunk = maybeChunk.get()
                
                # Capture usage data if present
                if chunk.usage.isSome():
                  finalUsage = chunk.usage
                  debug(fmt"Found usage data: {chunk.usage.get().totalTokens} tokens")
                
                callback(chunk)
                if chunk.done:
                  debug("SSE stream completed with [DONE]")
                  # Finalize dump
                  if isDumpEnabled():
                    logFileModule.logEcho "===================="
                    logFileModule.logEcho ""
                  return (true, finalUsage)
              else:
                debug(fmt"Failed to parse SSE line, skipping: {line[0..min(100, line.len-1)]}")
            except Exception as e:
              debug(fmt"Error processing SSE line: {e.msg}, line: {line[0..min(100, line.len-1)]}")
              # Continue processing other lines instead of failing completely
      
      # Finalize dump if no [DONE] received
      if isDumpEnabled():
        logFileModule.logEcho "===================="
        logFileModule.logEcho ""
      
      return (true, finalUsage)
      
    finally:
      stream.close()
    
  except Exception as e:
    error(fmt"Error in streaming request: {e.msg}")
    return (false, none(TokenUsage))

proc convertMessages*(messages: seq[Message]): seq[ChatMessage] =
  ## Convert internal Message types to OpenAI-compatible ChatMessage format
  result = @[]
  for msg in messages:
    var chatMsg = ChatMessage(
      role: $msg.role,
      content: msg.content
    )
    
    # Handle tool calls (assistant -> API)
    if msg.toolCalls.isSome():
      # Tool calls are already LLMToolCall - use directly without conversion
      let apiToolCalls = msg.toolCalls.get()
      chatMsg.toolCalls = some(apiToolCalls)
    
    # Handle tool call ID (tool -> API)
    if msg.toolCallId.isSome():
      chatMsg.toolCallId = msg.toolCallId
    
    result.add(chatMsg)

# Helper function to create ChatRequest (compatibility with existing API)
proc createChatRequest*(modelConfig: ModelConfig, messages: seq[Message],
                       stream: bool, tools: Option[seq[ToolDefinition]]): ChatRequest =
  ## Create a ChatRequest from the internal message types using model configuration
  return ChatRequest(
    model: modelConfig.model,
    messages: convertMessages(messages),
    maxTokens: modelConfig.maxTokens,
    temperature: modelConfig.temperature,
    topP: modelConfig.topP,
    topK: modelConfig.topK,
    stop: modelConfig.stop,
    presencePenalty: modelConfig.presencePenalty,
    frequencyPenalty: modelConfig.frequencyPenalty,
    logitBias: modelConfig.logitBias,
    seed: modelConfig.seed,
    stream: stream,
    tools: tools
  )

# Note: ResponseStream.close() is provided by Curly library directly