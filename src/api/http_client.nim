import std/[json, strutils, httpclient, options, strformat, tables]
import ../types/[config, messages]
import ../core/logging

type
  OpenAICompatibleClient* = object
    client: HttpClient
    baseUrl: string
    apiKey: string
    model: string

  ChatRequest* = object
    model: string
    messages: seq[ChatMessage]
    maxTokens: Option[int]
    temperature: Option[float]
    stream: bool

  ChatMessage* = object
    role*: string
    content*: string

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

proc close*(client: var OpenAICompatibleClient) =
  client.client.close()

proc convertMessages*(messages: seq[Message]): seq[ChatMessage] =
  result = @[]
  for msg in messages:
    var chatMsg = ChatMessage(
      role: $msg.role,
      content: msg.content
    )
    result.add(chatMsg)

proc createChatRequest*(model: string, messages: seq[Message], maxTokens: Option[int] = none(int), 
                       temperature: Option[float] = none(float), stream: bool = false): ChatRequest =
  result.model = model
  result.messages = convertMessages(messages)
  result.maxTokens = maxTokens
  result.temperature = temperature
  result.stream = stream

proc toJson*(req: ChatRequest): JsonNode =
  result = newJObject()
  result["model"] = newJString(req.model)
  
  var messagesArray = newJArray()
  for msg in req.messages:
    var msgObj = newJObject()
    msgObj["role"] = newJString(msg.role)
    msgObj["content"] = newJString(msg.content)
    messagesArray.add(msgObj)
  result["messages"] = messagesArray
  
  if req.maxTokens.isSome():
    result["max_tokens"] = newJInt(req.maxTokens.get())
  if req.temperature.isSome():
    result["temperature"] = newJFloat(req.temperature.get())
  
  result["stream"] = newJBool(req.stream)

proc fromJson*(node: JsonNode, T: typedesc[ChatResponse]): ChatResponse =
  result.id = node["id"].getStr()
  result.`object` = node["object"].getStr()
  result.created = node["created"].getInt()
  result.model = node["model"].getStr()
  
  result.choices = @[]
  for choiceNode in node["choices"]:
    var choice = ChatChoice(
      index: choiceNode["index"].getInt(),
      message: ChatMessage(
        role: choiceNode["message"]["role"].getStr(),
        content: choiceNode["message"]["content"].getStr()
      )
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
    
    if choiceNode.hasKey("finish_reason") and choiceNode["finish_reason"].kind != JNull:
      choice.finishReason = some(choiceNode["finish_reason"].getStr())
    
    result.choices.add(choice)

proc sendChatRequest*(client: var OpenAICompatibleClient, request: ChatRequest): ChatResponse =
  let url = client.baseUrl & "/chat/completions"
  let jsonBody = $request.toJson()
  
  logDebug("api-client", fmt"Sending request to {url}")
  logDebug("api-client", fmt"Request body: {jsonBody}")
  
  try:
    let response = client.client.request(url, httpMethod = HttpPost, body = jsonBody)
    
    if response.status.startsWith("2"):
      let responseJson = parseJson(response.body)
      result = responseJson.fromJson(ChatResponse)
      logDebug("api-client", fmt"Received response: {response.body}")
    else:
      let errorMsg = fmt"API request failed with status {response.status}: {response.body}"
      logError("api-client", errorMsg)
      raise newException(IOError, errorMsg)
      
  except Exception as e:
    let errorMsg = fmt"HTTP request failed: {e.msg}"
    logError("api-client", errorMsg)
    raise newException(IOError, errorMsg)

proc sendStreamingChatRequest*(client: var OpenAICompatibleClient, request: ChatRequest, 
                              onChunk: proc(chunk: StreamChunk)): string =
  var streamRequest = request
  streamRequest.stream = true
  
  let url = client.baseUrl & "/chat/completions"
  let jsonBody = $streamRequest.toJson()
  
  logDebug("api-client", fmt"Sending streaming request to {url}")
  
  try:
    let response = client.client.request(url, httpMethod = HttpPost, body = jsonBody)
    
    if not response.status.startsWith("2"):
      let errorMsg = fmt"API request failed with status {response.status}: {response.body}"
      logError("api-client", errorMsg)
      raise newException(IOError, errorMsg)
    
    # Parse Server-Sent Events (SSE) stream
    var fullContent = ""
    let lines = response.body.splitLines()
    
    for line in lines:
      if line.startsWith("data: "):
        let dataLine = line[6..^1].strip()
        
        if dataLine == "[DONE]":
          logDebug("api-client", "Stream completed")
          break
        
        if dataLine.len > 0:
          try:
            let chunkJson = parseJson(dataLine)
            let chunk = chunkJson.fromJson(StreamChunk)
            
            if chunk.choices.len > 0 and chunk.choices[0].delta.content.len > 0:
              fullContent.add(chunk.choices[0].delta.content)
            
            onChunk(chunk)
          except JsonParsingError:
            logWarn("api-client", fmt"Failed to parse chunk: {dataLine}")
          except Exception as e:
            logWarn("api-client", fmt"Error processing chunk: {e.msg}")
    
    return fullContent
    
  except Exception as e:
    let errorMsg = fmt"Streaming request failed: {e.msg}"
    logError("api-client", errorMsg)
    raise newException(IOError, errorMsg)