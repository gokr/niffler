import std/[json, strutils, httpclient, options, strformat, tables]
import ../types/messages
import std/logging

proc isDebugEnabled*(): bool =
  ## Check if debug logging is enabled
  getLogFilter() <= lvlDebug

type
  OpenAICompatibleClient* = object
    client: HttpClient
    baseUrl*: string
    apiKey*: string
    model*: string

  ChatRequest* = object
    model*: string
    messages*: seq[ChatMessage]
    maxTokens*: Option[int]
    temperature*: Option[float]
    stream*: bool
    tools*: Option[seq[ToolDefinition]]

  ChatMessage* = object
    role*: string
    content*: string
    toolCalls*: Option[seq[ChatToolCall]]
    toolCallId*: Option[string]

  ChatToolCall* = object
    id*: string
    `type`*: string
    function*: ChatFunction

  ChatFunction* = object
    name*: string
    arguments*: string

  ChatResponse* = object
    id*: string
    `object`*: string
    created*: int64
    model*: string
    choices*: seq[ChatChoice]
    usage*: Option[TokenUsage]

  ChatChoice* = object
    index*: int
    message*: ChatMessage
    finishReason*: Option[string]

  StreamChunk* = object
    id: string
    `object`: string
    created: int64
    model: string
    choices: seq[StreamChoice]

  StreamChoice* = object
    index: int
    delta: ChatMessage
    finishReason: Option[string]

proc newOpenAICompatibleClient*(baseUrl: string, apiKey: string, model: string): OpenAICompatibleClient =
  result.client = newHttpClient()
  result.baseUrl = baseUrl
  result.apiKey = apiKey
  result.model = model
  
  # Set headers
  result.client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": "Bearer " & apiKey
  })
  
  # Add OpenRouter-specific headers if using OpenRouter
  if baseUrl.contains("openrouter.ai"):
    result.client.headers["HTTP-Referer"] = "https://niffler.chat"
    result.client.headers["X-Title"] = "Niffler"
  
  # Debug: Log the authorization header (without the full key for security)
  let authHeader = "Bearer " & (if apiKey.len > 8: apiKey[0..7] & "..." else: apiKey)
  debug(fmt"Authorization header: {authHeader}")

proc close*(client: var OpenAICompatibleClient) =
  client.client.close()

proc convertMessages*(messages: seq[Message]): seq[ChatMessage] =
  result = @[]
  for msg in messages:
    var chatMsg = ChatMessage(
      role: $msg.role,
      content: msg.content
    )
    
    # Handle tool calls (assistant -> API)
    if msg.toolCalls.isSome():
      var apiToolCalls: seq[ChatToolCall] = @[]
      for toolCall in msg.toolCalls.get():
        apiToolCalls.add(ChatToolCall(
          id: toolCall.id,
          `type`: toolCall.`type`,
          function: ChatFunction(
            name: toolCall.function.name,
            arguments: toolCall.function.arguments
          )
        ))
      chatMsg.toolCalls = some(apiToolCalls)
    
    # Handle tool call ID (tool -> API)
    if msg.toolCallId.isSome():
      chatMsg.toolCallId = msg.toolCallId
    
    result.add(chatMsg)

# GC-safe helper for JSON conversion - cast to bypass GC safety for JSON string conversion
proc jsonValueToString(value: JsonNode): string {.gcsafe.} =
  {.cast(gcsafe).}:
    return $value

proc createChatRequest*(model: string, messages: seq[Message], maxTokens: Option[int] = none(int), 
                       temperature: Option[float] = none(float), stream: bool = false, 
                       tools: Option[seq[ToolDefinition]] = none(seq[ToolDefinition])): ChatRequest =
  result.model = model
  result.messages = convertMessages(messages)
  result.maxTokens = maxTokens
  result.temperature = temperature
  result.stream = stream
  result.tools = tools

proc toJson*(req: ChatRequest): JsonNode =
  {.cast(gcsafe).}:
    result = newJObject()
    result["model"] = newJString(req.model)
    
    var messagesArray = newJArray()
    for msg in req.messages:
      var msgObj = newJObject()
      msgObj["role"] = newJString(msg.role)
      msgObj["content"] = newJString(msg.content)
      
      # Add tool calls if present
      if msg.toolCalls.isSome():
        var toolCallsArray = newJArray()
        for toolCall in msg.toolCalls.get():
          var toolCallObj = newJObject()
          toolCallObj["id"] = newJString(toolCall.id)
          toolCallObj["type"] = newJString(toolCall.`type`)
          var functionObj = newJObject()
          functionObj["name"] = newJString(toolCall.function.name)
          functionObj["arguments"] = newJString(toolCall.function.arguments)
          toolCallObj["function"] = functionObj
          toolCallsArray.add(toolCallObj)
        msgObj["tool_calls"] = toolCallsArray
      
      # Add tool call ID if present
      if msg.toolCallId.isSome():
        msgObj["tool_call_id"] = newJString(msg.toolCallId.get())
      
      messagesArray.add(msgObj)
    result["messages"] = messagesArray
    
    if req.maxTokens.isSome():
      result["max_tokens"] = newJInt(req.maxTokens.get())
    if req.temperature.isSome():
      result["temperature"] = newJFloat(req.temperature.get())
    
    # Add tools if present
    if req.tools.isSome():
      var toolsArray = newJArray()
      for tool in req.tools.get():
        var toolObj = newJObject()
        toolObj["type"] = newJString(tool.`type`)
        var functionObj = newJObject()
        functionObj["name"] = newJString(tool.function.name)
        functionObj["description"] = newJString(tool.function.description)
        functionObj["parameters"] = parseJson($tool.function.parameters)
        toolObj["function"] = functionObj
        toolsArray.add(toolObj)
      result["tools"] = toolsArray
    
    result["stream"] = newJBool(req.stream)

proc fromJson*(node: JsonNode, T: typedesc[ChatResponse]): ChatResponse =
  result.id = node["id"].getStr()
  result.`object` = node["object"].getStr()
  result.created = node["created"].getInt()
  result.model = node["model"].getStr()
  
  result.choices = @[]
  for choiceNode in node["choices"]:
    let messageNode = choiceNode["message"]
    var message = ChatMessage(
      role: messageNode["role"].getStr(),
      content: messageNode["content"].getStr()
    )
    
    # Parse tool calls if present
    if messageNode.hasKey("tool_calls") and messageNode["tool_calls"].kind == JArray:
      var toolCalls: seq[ChatToolCall] = @[]
      for toolCallNode in messageNode["tool_calls"]:
        let functionNode = toolCallNode["function"]
        toolCalls.add(ChatToolCall(
          id: toolCallNode["id"].getStr(),
          `type`: toolCallNode["type"].getStr(),
          function: ChatFunction(
            name: functionNode["name"].getStr(),
            arguments: functionNode["arguments"].getStr()
          )
        ))
      message.toolCalls = some(toolCalls)
    
    var choice = ChatChoice(
      index: choiceNode["index"].getInt(),
      message: message
    )
    if choiceNode.hasKey("finish_reason") and choiceNode["finish_reason"].kind != JNull:
      choice.finishReason = some(choiceNode["finish_reason"].getStr())
    result.choices.add(choice)
  
  if node.hasKey("usage"):
    let usageNode = node["usage"]
    result.usage = some(TokenUsage(
      promptTokens: usageNode["prompt_tokens"].getInt(),
      completionTokens: usageNode["completion_tokens"].getInt(),
      totalTokens: usageNode["total_tokens"].getInt()
    ))

proc fromJson*(node: JsonNode, T: typedesc[StreamChunk]): StreamChunk =
  result.id = node["id"].getStr()
  result.`object` = node["object"].getStr()
  result.created = node["created"].getInt()
  result.model = node["model"].getStr()
  
  result.choices = @[]
  for choiceNode in node["choices"]:
    var choice = StreamChoice(
      index: choiceNode["index"].getInt()
    )
    
    if choiceNode.hasKey("delta"):
      let delta = choiceNode["delta"]
      choice.delta = ChatMessage()
      if delta.hasKey("role"):
        choice.delta.role = delta["role"].getStr()
      if delta.hasKey("content"):
        choice.delta.content = delta["content"].getStr()
      
      # Parse tool calls in delta
      if delta.hasKey("tool_calls") and delta["tool_calls"].kind == JArray:
        var toolCalls: seq[ChatToolCall] = @[]
        for toolCallNode in delta["tool_calls"]:
          var toolCall = ChatToolCall(
            id: if toolCallNode.hasKey("id"): toolCallNode["id"].getStr() else: "",
            `type`: if toolCallNode.hasKey("type"): toolCallNode["type"].getStr() else: "function"
          )
          if toolCallNode.hasKey("function"):
            let functionNode = toolCallNode["function"]
            toolCall.function = ChatFunction(
              name: if functionNode.hasKey("name"): functionNode["name"].getStr() else: "",
              arguments: if functionNode.hasKey("arguments"): functionNode["arguments"].getStr() else: ""
            )
          toolCalls.add(toolCall)
        choice.delta.toolCalls = some(toolCalls)
    
    if choiceNode.hasKey("finish_reason") and choiceNode["finish_reason"].kind != JNull:
      choice.finishReason = some(choiceNode["finish_reason"].getStr())
    
    result.choices.add(choice)

proc sendChatRequest*(client: var OpenAICompatibleClient, request: ChatRequest): ChatResponse {.gcsafe.} =
  let url = client.baseUrl & "/chat/completions"
  let jsonBody = $request.toJson()
  
  # Instrumentation: Print the full HTTP request to stdout (only in debug mode)
  if isDebugEnabled():
    echo ""
    echo "=== HTTP REQUEST ==="
    echo "URL: " & url
    echo "Method: POST"
    echo "Headers:"
    for key, value in client.client.headers:
      # Mask Authorization header for security
      let displayValue = if key.toLowerAscii() == "authorization": "Bearer ***" else: value
      echo "  " & key & ": " & displayValue
    echo ""
    echo "Body:"
    echo jsonBody
    echo "==================="
    echo ""
  
  debug(fmt"Sending request to {url}")
  debug(fmt"Request body: {jsonBody}")
  
  try:
    let response = client.client.request(url, httpMethod = HttpPost, body = jsonBody)
    
    # Instrumentation: Print the full HTTP response to stdout (only in debug mode)
    if isDebugEnabled():
      echo ""
      echo "=== HTTP RESPONSE ==="
      echo "Status: " & response.status
      echo "Headers:"
      for key, value in response.headers:
        echo "  " & key & ": " & value
      echo ""
      echo "Body:"
      echo response.body
      echo "===================="
      echo ""
    
    if response.status.startsWith("2"):
      let responseJson = parseJson(response.body)
      result = responseJson.fromJson(ChatResponse)
      debug(fmt"Received response: {response.body}")
    else:
      let errorMsg = fmt"API request failed with status {response.status}: {response.body}"
      raise newException(IOError, errorMsg)
      
  except Exception as e:
    let errorMsg = fmt"HTTP request failed: {e.msg}"
    raise newException(IOError, errorMsg)

proc sendStreamingChatRequest*(client: var OpenAICompatibleClient, request: ChatRequest, 
                              onChunk: proc(chunk: StreamChunk)): string =
  var streamRequest = request
  streamRequest.stream = true
  
  let url = client.baseUrl & "/chat/completions"
  let jsonBody = $streamRequest.toJson()
  
  debug(fmt"Sending streaming request to {url}")
  
  try:
    let response = client.client.request(url, httpMethod = HttpPost, body = jsonBody)
    
    if not response.status.startsWith("2"):
      let errorMsg = fmt"API request failed with status {response.status}: {response.body}"
      raise newException(IOError, errorMsg)
    
    # Parse Server-Sent Events (SSE) stream
    var fullContent = ""
    let lines = response.body.splitLines()
    
    for line in lines:
      if line.startsWith("data: "):
        let dataLine = line[6..^1].strip()
        
        if dataLine == "[DONE]":
          debug("Stream completed")
          break
        
        if dataLine.len > 0:
          try:
            let chunkJson = parseJson(dataLine)
            let chunk = chunkJson.fromJson(StreamChunk)
            
            if chunk.choices.len > 0 and chunk.choices[0].delta.content.len > 0:
              fullContent.add(chunk.choices[0].delta.content)
            
            onChunk(chunk)
          except JsonParsingError:
            warn(fmt"Failed to parse chunk: {dataLine}")
          except Exception as e:
            warn(fmt"Error processing chunk: {e.msg}")
    
    return fullContent
    
  except Exception as e:
    let errorMsg = fmt"Streaming request failed: {e.msg}"
    raise newException(IOError, errorMsg)