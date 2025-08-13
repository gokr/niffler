import std/[options, os, strformat]
import std/logging
import channels, history, config
import ../types/[messages, history as historyTypes, config as configTypes]
import ../api/api
import ../tools/worker

var apiWorker: APIWorker
var toolWorker: ToolWorker

proc startApp*() =
  echo "Starting Niffler..."
  
  # Initialize subsystems
  # Set up console logging  
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(lvlInfo)
  initThreadSafeChannels()
  initHistoryManager()
    
  let channels = getChannels()
  
  debug("Starting API worker thread...")
  apiWorker = startAPIWorker(channels)
  debug("Starting tool worker thread...")
  toolWorker = startToolWorker(channels)
  
  echo "Niffler is ready!"
  echo "Press Ctrl+C to exit..."
  
  while not isShutdownSignaled(channels):
    # Basic event loop - will be replaced with illwill UI in Phase 3
    sleep(100)
    
    # Check for API responses
    var response: APIResponse
    if tryReceiveAPIResponse(channels, response):
      case response.kind:
      of arkStreamChunk:
        if response.content.len > 0:
          stdout.write(response.content)
          stdout.flushFile()
      of arkStreamComplete:
        echo "\n[Request completed]"
        echo fmt"Tokens used: {response.usage.totalTokens}"
      of arkStreamError:
        echo fmt"\nError: {response.error}"
      of arkReady:
        echo "API ready for request"
    
    # Check for UI updates
    let maybeUpdate = tryReceiveUIUpdate(channels)
    if maybeUpdate.isSome():
      echo "Received UI update: ", maybeUpdate.get().kind
  
  echo "\nApplication shutting down..."
  signalShutdown(channels)
  stopAPIWorker(apiWorker)
  stopToolWorker(toolWorker)
  closeChannels(channels[])

proc sendSinglePromptInteractive*(text: string, modelConfig: configTypes.ModelConfig): bool =
  let channels = getChannels()
  
  # Get API key
  let apiKey = readKeyForModel(modelConfig)
  if apiKey.len == 0:
    echo fmt"Error: No API key found for {modelConfig.baseUrl}"
    echo "Set environment variable or configure API key"
    return false
    
  # Add user message to history
  let userMsg = addUserMessage(text)
  let messages = @[userMsg]
  
  # Generate request ID
  let requestId = fmt"req_{historyTypes.getNextSequenceId()}"
  
  return sendChatRequestAsync(channels, messages, modelConfig, requestId, apiKey)

proc sendSinglePromptAsync*(text: string, model: string = ""): bool =
  let channels = getChannels()
  let config = loadConfig()
  
  let selectedModel = if model.len > 0:
    getModelFromConfig(config, model)
  else:
    config.models[0]
  
  # Get API key
  let apiKey = readKeyForModel(selectedModel)
  if apiKey.len == 0:
    echo fmt"Error: No API key found for {selectedModel.baseUrl}"
    echo "Set environment variable or configure API key"
    return false
  
  # Debug: Log the API key being used (without the full key for security)
  let keyPreview = if apiKey.len > 8: apiKey[0..7] & "..." else: apiKey
  echo fmt"Using API key: {keyPreview} for {selectedModel.baseUrl}"
    
  # Add user message to history
  let userMsg = addUserMessage(text)
  let messages = @[userMsg]
  
  # Generate request ID
  let requestId = fmt"req_{historyTypes.getNextSequenceId()}"
  
  echo fmt"Sending prompt to {selectedModel.nickname}..."
  
  return sendChatRequestAsync(channels, messages, selectedModel, requestId, apiKey)

proc configureAPIWorker*(modelConfig: configTypes.ModelConfig): bool =
  ## Configure the API worker with a new model configuration
  let channels = getChannels()
  let apiKey = readKeyForModel(modelConfig)
  
  if apiKey.len == 0:
    return false
  
  let configRequest = APIRequest(
    kind: arkConfigure,
    configBaseUrl: modelConfig.baseUrl,
    configApiKey: apiKey,
    configModelName: modelConfig.model
  )
  
  return trySendAPIRequest(channels, configRequest)
