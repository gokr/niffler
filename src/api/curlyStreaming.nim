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
import ../types/[messages, config]
import ../core/log_file as logFileModule

# Single long-lived Curly instance for the entire application
let curl* = newCurly()

# Global dump flag for request/response logging
var dumpEnabled {.threadvar.}: bool

proc setDumpEnabled*(enabled: bool) =
  ## Set the global dump flag for HTTP request/response logging
  dumpEnabled = enabled

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
      if json.hasKey("choices"):
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
            choice.delta.content = delta{"content"}.getStr("")
            
            # Parse tool calls in delta
            if delta.hasKey("tool_calls"):
              var toolCalls: seq[LLMToolCall] = @[]
              for tcJson in delta["tool_calls"]:
                let toolCall = LLMToolCall(
                  id: tcJson{"id"}.getStr(""),
                  `type`: tcJson{"type"}.getStr("function"),
                  function: FunctionCall(
                    name: tcJson{"function"}{"name"}.getStr(""),
                    arguments: tcJson{"function"}{"arguments"}.getStr("")
                  )
                )
                toolCalls.add(toolCall)
              choice.delta.toolCalls = some(toolCalls)
          
          # Parse finish reason
          if choiceJson.hasKey("finish_reason") and choiceJson["finish_reason"].kind != JNull:
            choice.finishReason = some(choiceJson["finish_reason"].getStr(""))
          
          chunk.choices.add(choice)
      
      # Parse usage data if present (often sent in final streaming chunk)
      if json.hasKey("usage"):
        let usageJson = json["usage"]
        chunk.usage = some(messages.TokenUsage(
          inputTokens: usageJson{"prompt_tokens"}.getInt(0),
          outputTokens: usageJson{"completion_tokens"}.getInt(0),
          totalTokens: usageJson{"total_tokens"}.getInt(0)
        ))
      
      return some(chunk)
      
    except JsonParsingError:
      debug(fmt"Failed to parse SSE JSON: {dataLine}")
    except KeyError:
      debug(fmt"Missing expected field in SSE JSON: {dataLine}")
    except ValueError:
      debug(fmt"Invalid value in SSE JSON: {dataLine}")
      
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
      
      # Dump HTTP response headers if enabled
      if isDumpEnabled():
        echo ""
        echo "=== HTTP RESPONSE ==="
        echo "Status: " & $stream.code
        echo "Headers:"
        echo "  Content-Type: text/event-stream"
        echo "  Transfer-Encoding: chunked"
        echo ""
        echo "Body (streaming):"
      
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
            # Dump line if enabled
            if isDumpEnabled():
              echo line
            
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