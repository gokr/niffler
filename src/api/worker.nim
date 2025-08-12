import std/[options, strformat, os]
when compileOption("threads"):
  import std/typedthreads
else:
  {.error: "This module requires threads support. Compile with --threads:on".}
import ../types/[messages, config]
import ../core/[channels, logging, config as configCore]
import http_client

type
  APIWorker* = object
    thread: Thread[ptr ThreadChannels]
    client: OpenAICompatibleClient
    isRunning: bool

proc apiWorkerProc(channels: ptr ThreadChannels) {.thread, gcsafe.} =
  logInfo("api-worker", "API worker thread started")
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
          logInfo("api-worker", "Received shutdown signal")
          break
          
        of arkConfigure:
          try:
            currentClient = some(newOpenAICompatibleClient(
              request.configBaseUrl,
              request.configApiKey,
              request.configModelName
            ))
            logInfo("api-worker", fmt"API client configured for {request.configBaseUrl}")
          except Exception as e:
            logError("api-worker", fmt"Failed to configure API client: {e.msg}")
          
        of arkChatRequest:
          logInfo("api-worker", fmt"Processing chat request: {request.requestId}")
          
          # Initialize client with request parameters if not already configured
          if currentClient.isNone():
            try:
              currentClient = some(newOpenAICompatibleClient(
                request.baseUrl,
                request.apiKey,
                request.model
              ))
              logInfo("api-worker", fmt"API client initialized for {request.baseUrl}")
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
              stream = false  # Start with non-streaming for simplicity
            )
            
            logDebug("api-worker", fmt"Sending request to {request.baseUrl}")
            let response = client.sendChatRequest(chatRequest)
            
            # Send the complete response as stream chunks for consistency
            if response.choices.len > 0:
              let content = response.choices[0].message.content
              
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
                finishReason: response.choices[0].finishReason.get("stop")
              )
              sendAPIResponse(channels, completeResponse)
              
              logInfo("api-worker", fmt"Request {request.requestId} completed successfully")
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
            logError("api-worker", fmt"Request {request.requestId} failed: {e.msg}")
        
        of arkStreamCancel:
          logInfo("api-worker", fmt"Canceling stream: {request.cancelRequestId}")
          # TODO: Implement stream cancellation
          
      else:
        # No requests, sleep briefly
        sleep(10)
    
  except Exception as e:
    logFatal("api-worker", fmt"API worker thread crashed: {e.msg}")
  finally:
    if currentClient.isSome():
      currentClient.get().close()
    decrementActiveThreads(channels)
    logInfo("api-worker", "API worker thread stopped")

proc startAPIWorker*(channels: ptr ThreadChannels): APIWorker =
  result.isRunning = true
  createThread(result.thread, apiWorkerProc, channels)
  logInfo("api-main", "API worker thread started")

proc stopAPIWorker*(worker: var APIWorker) =
  if worker.isRunning:
    joinThread(worker.thread)
    worker.isRunning = false
    logInfo("api-main", "API worker thread stopped")

proc initializeAPIClient*(worker: var APIWorker, config: ModelConfig) =
  # This will be called when we have configuration loaded
  # For now, just log the configuration
  logInfo("api-worker", fmt"Would initialize client for: {config.baseUrl}")

proc sendChatRequestAsync*(channels: ptr ThreadChannels, messages: seq[Message], 
                          modelConfig: ModelConfig, requestId: string, apiKey: string,
                          maxTokens: int = 2048, temperature: float = 0.7): bool =
  let request = APIRequest(
    kind: arkChatRequest,
    requestId: requestId,
    messages: messages,
    model: modelConfig.model,
    maxTokens: maxTokens,
    temperature: temperature,
    baseUrl: modelConfig.baseUrl,
    apiKey: apiKey
  )
  
  return trySendAPIRequest(channels, request)