import std/[options, strformat, os]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}
import ../types/[messages, config]
import std/logging
import ../core/channels
import http_client
import ../tools/schemas

type
  ThreadParams = ref object
    channels: ptr ThreadChannels
    debug: bool
    
  APIWorker* = object
    thread: Thread[ThreadParams]
    client: OpenAICompatibleClient
    isRunning: bool

# Helper function to convert ChatToolCall to LLMToolCall
proc convertToLLMToolCalls*(chatToolCalls: seq[ChatToolCall]): seq[LLMToolCall] =
  result = @[]
  for chatCall in chatToolCalls:
    result.add(LLMToolCall(
      id: chatCall.id,
      `type`: chatCall.`type`,
      function: FunctionCall(
        name: chatCall.function.name,
        arguments: chatCall.function.arguments
      )
    ))

proc apiWorkerProc(params: ThreadParams) {.thread, gcsafe.} =
  # Initialize logging for this thread
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(if params.debug: lvlDebug else: lvlInfo)
  
  let channels = params.channels
  
  debug("API worker thread started")
  incrementActiveThreads(channels)
  
  var currentClient: Option[OpenAICompatibleClient] = none(OpenAICompatibleClient)
  
  try:
    while not isShutdownSignaled(channels):
      # Check for API requests
      let maybeRequest = tryReceiveAPIRequest(channels)
      
      if maybeRequest.isSome():
        let request = maybeRequest.get()
        
        case request.kind:
        of arkShutdown:
          debug("Received shutdown signal")
          break
          
        of arkConfigure:
          try:
            currentClient = some(newOpenAICompatibleClient(
              request.configBaseUrl,
              request.configApiKey,
              request.configModelName
            ))
            debug(fmt"API client configured for {request.configBaseUrl}")
          except Exception as e:
            debug(fmt"Failed to configure API client: {e.msg}")
          
        of arkChatRequest:
          debug(fmt"Processing chat request: {request.requestId}")
          
          # Initialize client with request parameters, or reconfigure if needed
          var needsNewClient = false
          if currentClient.isNone():
            needsNewClient = true
          else:
            # Check if current client configuration matches request
            var client = currentClient.get()
            if client.baseUrl != request.baseUrl or client.model != request.model:
              needsNewClient = true
              # Close existing client
              client.close()
              currentClient = none(OpenAICompatibleClient)
          
          if needsNewClient:
            try:
              currentClient = some(newOpenAICompatibleClient(
                request.baseUrl,
                request.apiKey,
                request.model
              ))
              debug(fmt"API client initialized for {request.baseUrl}")
            except Exception as e:
              let errorResponse = APIResponse(
                requestId: request.requestId,
                kind: arkStreamError,
                error: fmt"Failed to initialize API client: {e.msg}"
              )
              sendAPIResponse(channels, errorResponse)
              continue
          
          # Send ready response
          let readyResponse = APIResponse(
            requestId: request.requestId,
            kind: arkReady
          )
          sendAPIResponse(channels, readyResponse)
          
          try:
            # Create and send HTTP request
            var client = currentClient.get()
            let chatRequest = createChatRequest(
              request.model,
              request.messages,
              some(request.maxTokens),
              some(request.temperature),
              stream = false,  # Start with non-streaming for simplicity
              tools = if request.enableTools: request.tools else: none(seq[ToolDefinition])
            )
            
            debug(fmt"Sending request to {request.baseUrl}")
            if request.enableTools:
              let toolCount = if request.tools.isSome(): request.tools.get().len else: 0
              debug(fmt"Tools enabled: {toolCount} tools available to LLM")
            let response = client.sendChatRequest(chatRequest)
            
            # Process the response and handle tool calls
            if response.choices.len > 0:
              let choice = response.choices[0]
              let message = choice.message
              
              # Check for tool calls in the response
              if message.toolCalls.isSome() and message.toolCalls.get().len > 0:
                debug(fmt"Found {message.toolCalls.get().len} tool calls in response")
                
                # Send assistant message with tool calls
                let assistantResponse = APIResponse(
                  requestId: request.requestId,
                  kind: arkStreamChunk,
                  content: message.content,
                  done: false,
                  toolCalls: some(convertToLLMToolCalls(message.toolCalls.get()))
                )
                sendAPIResponse(channels, assistantResponse)
                
                # Execute each tool call
                var allToolResults: seq[Message] = @[]
                for toolCall in message.toolCalls.get():
                  debug(fmt"Executing tool call: {toolCall.function.name}")
                  
                  # Send tool request to tool worker
                  let toolRequest = ToolRequest(
                    kind: trkExecute,
                    requestId: toolCall.id,
                    toolName: toolCall.function.name,
                    arguments: toolCall.function.arguments
                  )
                  debug("TOOL REQUEST: " & $toolRequest)
                  
                  if trySendToolRequest(channels, toolRequest):
                    # Wait for tool response
                    var attempts = 0
                    while attempts < 300:  # Timeout after ~30 seconds
                      let maybeResponse = tryReceiveToolResponse(channels)
                      if maybeResponse.isSome():
                        let toolResponse = maybeResponse.get()
                        debug("TOOL RESPONSE: " & $toolResponse)
                        if toolResponse.requestId == toolCall.id:
                          # Create tool result message
                          let toolContent = if toolResponse.kind == trkResult: toolResponse.output else: fmt"Error: {toolResponse.error}"
                          debug(fmt"Tool result received for {toolCall.function.name}: {toolContent[0..min(200, toolContent.len-1)]}...")
                          
                          let toolResultMsg = Message(
                            role: mrTool,
                            content: toolContent,
                            toolCallId: some(toolCall.id)
                          )
                          allToolResults.add(toolResultMsg)
                          break
                      sleep(100)
                      attempts += 1
                    
                    if attempts >= 300:
                      # Tool execution timed out
                      let errorMsg = Message(
                        role: mrTool,
                        content: "Error: Tool execution timed out",
                        toolCallId: some(toolCall.id)
                      )
                      allToolResults.add(errorMsg)
                  else:
                    # Failed to send tool request
                    let errorMsg = Message(
                      role: mrTool,
                      content: "Error: Failed to send tool request",
                      toolCallId: some(toolCall.id)
                    )
                    allToolResults.add(errorMsg)
                
                # Send tool results back to LLM for continuation
                if allToolResults.len > 0:
                  debug(fmt"Sending {allToolResults.len} tool results back to LLM")
                  
                  # Add tool results to conversation and continue
                  var updatedMessages = request.messages
                  
                  # Add the assistant message with tool calls
                  updatedMessages.add(Message(
                    role: mrAssistant,
                    content: message.content,
                    toolCalls: some(convertToLLMToolCalls(message.toolCalls.get()))
                  ))
                  # Add all tool result messages
                  for toolResult in allToolResults:
                    updatedMessages.add(toolResult)
                  # Create follow-up request to continue conversation
                  debug(fmt"Creating follow-up request with {updatedMessages.len} messages")
                  let followUpRequest = createChatRequest(
                    request.model,
                    updatedMessages,
                    some(request.maxTokens),
                    some(request.temperature),
                    stream = false,
                    tools = if request.enableTools: request.tools else: none(seq[ToolDefinition])
                  )
                  
                  debug("Sending follow-up request to LLM with tool results...")
                  let followUpResponse = client.sendChatRequest(followUpRequest)
                  debug(fmt"Follow-up response received, {followUpResponse.choices.len} choices")
                  if followUpResponse.choices.len > 0:
                    let finalContent = followUpResponse.choices[0].message.content
                    
                    # Send final response
                    let finalChunkResponse = APIResponse(
                      requestId: request.requestId,
                      kind: arkStreamChunk,
                      content: finalContent,
                      done: true
                    )
                    sendAPIResponse(channels, finalChunkResponse)
                    
                    # Send completion
                    var usage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
                    if followUpResponse.usage.isSome():
                      usage = followUpResponse.usage.get()
                      
                    let completeResponse = APIResponse(
                      requestId: request.requestId,
                      kind: arkStreamComplete,
                      usage: usage,
                      finishReason: followUpResponse.choices[0].finishReason.get("stop")
                    )
                    sendAPIResponse(channels, completeResponse)
                    
                    debug(fmt"Tool calling conversation completed for request {request.requestId}")
                    debug("Successfully sent final response back to user")
                else:
                  # No valid tool results, send error
                  let errorResponse = APIResponse(
                    requestId: request.requestId,
                    kind: arkStreamError,
                    error: "Failed to execute tool calls"
                  )
                  sendAPIResponse(channels, errorResponse)
              else:
                # No tool calls, regular response
                let content = message.content
                
                # Send content as a single chunk
                let chunkResponse = APIResponse(
                  requestId: request.requestId,
                  kind: arkStreamChunk,
                  content: content,
                  done: true
                )
                sendAPIResponse(channels, chunkResponse)
                
                # Send completion response  
                var usage = TokenUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
                if response.usage.isSome():
                  usage = response.usage.get()
                  
                let completeResponse = APIResponse(
                  requestId: request.requestId,
                  kind: arkStreamComplete,
                  usage: usage,
                  finishReason: choice.finishReason.get("stop")
                )
                sendAPIResponse(channels, completeResponse)
                
                debug(fmt"Request {request.requestId} completed successfully")
            else:
              let errorResponse = APIResponse(
                requestId: request.requestId,
                kind: arkStreamError,
                error: "No response choices returned from API"
              )
              sendAPIResponse(channels, errorResponse)
            
          except Exception as e:
            let errorResponse = APIResponse(
              requestId: request.requestId,
              kind: arkStreamError,
              error: fmt"API request failed: {e.msg}"
            )
            sendAPIResponse(channels, errorResponse)
            debug(fmt"Request {request.requestId} failed: {e.msg}")
        
        of arkStreamCancel:
          debug(fmt"Canceling stream: {request.cancelRequestId}")
          # TODO: Implement stream cancellation
          
      else:
        # No requests, sleep briefly
        sleep(10)
    
  except Exception as e:
    fatal(fmt"API worker thread crashed: {e.msg}")
  finally:
    if currentClient.isSome():
      currentClient.get().close()
    decrementActiveThreads(channels)
    debug("API worker thread stopped")

proc startAPIWorker*(channels: ptr ThreadChannels, debug: bool = false): APIWorker =
  result.isRunning = true
  let params = ThreadParams(channels: channels, debug: debug)
  createThread(result.thread, apiWorkerProc, params)
  debug("API worker thread started")

proc stopAPIWorker*(worker: var APIWorker) =
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false
    debug("API worker thread stopped")

proc initializeAPIClient*(worker: var APIWorker, config: ModelConfig) =
  # This will be called when we have configuration loaded
  # For now, just log the configuration
  debug(fmt"Would initialize client for: {config.baseUrl}")

proc sendChatRequestAsync*(channels: ptr ThreadChannels, messages: seq[Message], 
                          modelConfig: ModelConfig, requestId: string, apiKey: string,
                          maxTokens: int = 2048, temperature: float = 0.7): bool =
  let toolSchemas = getAllToolSchemas()
  debug(fmt"Preparing chat request with {toolSchemas.len} available tools")
  
  let request = APIRequest(
    kind: arkChatRequest,
    requestId: requestId,
    messages: messages,
    model: modelConfig.model,
    maxTokens: maxTokens,
    temperature: temperature,
    baseUrl: modelConfig.baseUrl,
    apiKey: apiKey,
    enableTools: true,
    tools: some(toolSchemas)
  )
  
  return trySendAPIRequest(channels, request)