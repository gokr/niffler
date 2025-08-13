import std/[strformat, logging]
import channels, history, config
import ../types/[messages, history as historyTypes, config as configTypes]
import ../api/api

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
  info fmt"Using API key: {keyPreview} for {selectedModel.baseUrl}"
    
  # Add user message to history
  let userMsg = addUserMessage(text)
  let messages = @[userMsg]
  
  # Generate request ID
  let requestId = fmt"req_{historyTypes.getNextSequenceId()}"
  
  info fmt"Sending prompt to {selectedModel.nickname}..."
  
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
