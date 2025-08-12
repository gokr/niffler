import std/[os, strutils, strformat]
import ../core/[app, logging, channels, history, config]
import ../types/[messages, config as configTypes]
import ../api/worker

proc startInteractiveUI*() =
  ## Start the interactive terminal UI
  echo "Starting Niffler interactive mode..."
  echo "Type your messages and press Enter to send. Type 'exit' or 'quit' to leave."
  echo "Use '/model <name>' to switch models. Type '/help' for more commands."
  echo ""
  
  # Initialize the app systems
  
  initLogger(llInfo)  # Default to INFO level unless debug is enabled
  initThreadSafeChannels()
  initHistoryManager()
  
  let channels = getChannels()
  let config = loadConfig()
  var currentModel = if config.models.len > 0: config.models[0] else: 
    quit("No models configured. Please run 'niffler init' first.")
  
  echo fmt"Using model: {currentModel.nickname} ({currentModel.model})"
  echo ""
  
  # Start API worker
  var apiWorker = startAPIWorker(channels)
  
  # Interactive loop
  var running = true
  while running:
    # Show prompt
    stdout.write("You: ")
    stdout.flushFile()
    
    # Read user input
    let input = stdin.readLine().strip()
    
    if input.len == 0:
      continue
    
    # Handle commands
    if input.startsWith("/"):
      let parts = input[1..^1].split(' ', 1)
      let cmd = parts[0].toLower()
      
      case cmd:
      of "exit", "quit":
        running = false
        continue
      of "help":
        echo ""
        echo "Available commands:"
        echo "  /exit, /quit - Exit Niffler"
        echo "  /model <name> - Switch to a different model"
        echo "  /models - List available models"
        echo "  /clear - Clear conversation history"
        echo "  /help - Show this help"
        echo ""
        continue
      of "models":
        echo ""
        echo "Available models:"
        for model in config.models:
          let marker = if model.nickname == currentModel.nickname: " (current)" else: ""
          echo fmt"  {model.nickname} - {model.model}{marker}"
        echo ""
        continue
      of "model":
        if parts.len > 1:
          let modelName = parts[1]
          var found = false
          for model in config.models:
            if model.nickname == modelName:
              currentModel = model
              found = true
              echo fmt"Switched to model: {currentModel.nickname} ({currentModel.model})"
              echo ""
              break
          if not found:
            echo fmt"Model '{modelName}' not found. Use '/models' to see available models."
            echo ""
        else:
          echo "Usage: /model <name>"
          echo ""
        continue
      of "clear":
        clearHistory()
        echo "Conversation history cleared."
        echo ""
        continue
      else:
        echo fmt"Unknown command: /{cmd}. Type '/help' for available commands."
        echo ""
        continue
    
    # Regular message - send to API
    if sendSinglePromptInteractive(input, currentModel):
      # Wait for response and display it
      var responseText = ""
      var responseReceived = false
      var attempts = 0
      const maxAttempts = 600  # 60 seconds with 100ms sleep
      
      stdout.write("Niffler: ")
      stdout.flushFile()
      
      while not responseReceived and attempts < maxAttempts:
        var response: APIResponse
        if tryReceiveAPIResponse(channels, response):
          case response.kind:
          of arkStreamChunk:
            if response.content.len > 0:
              stdout.write(response.content)
              stdout.flushFile()
              responseText.add(response.content)
          of arkStreamComplete:
            echo ""
            echo fmt"[{response.usage.totalTokens} tokens]"
            echo ""
            # Add assistant response to history
            if responseText.len > 0:
              discard addAssistantMessage(responseText)
            responseReceived = true
          of arkStreamError:
            echo fmt"Error: {response.error}"
            echo ""
            responseReceived = true
          of arkReady:
            discard  # Just ignore ready responses
        
        if not responseReceived:
          sleep(100)
          inc attempts
      
      if not responseReceived:
        echo "Timeout waiting for response"
        echo ""
    else:
      echo "Failed to send message"
      echo ""
  
  echo "Goodbye!"
  
  # Cleanup
  signalShutdown(channels)
  stopAPIWorker(apiWorker)
  closeChannels(channels[])

proc sendSinglePrompt*(text: string, model: string) =
  ## Send a single prompt and return response
  if text.len == 0:
    echo "Error: No prompt text provided"
    return
    
  # Initialize the app systems but don't start the full UI loop
  
  initLogger(llInfo)
  initThreadSafeChannels()
  initHistoryManager()
  
  let channels = getChannels()
  
  # Start API worker
  var apiWorker = startAPIWorker(channels)
  
  echo "Sending prompt..."
  if sendSinglePromptAsync(text, model):
    echo "Request sent, waiting for response..."
    
    # Wait for response with timeout
    var responseReceived = false
    var attempts = 0
    const maxAttempts = 300  # 30 seconds with 100ms sleep
    
    while not responseReceived and attempts < maxAttempts:
      var response: APIResponse
      if tryReceiveAPIResponse(channels, response):
        case response.kind:
        of arkStreamChunk:
          if response.content.len > 0:
            stdout.write(response.content)
            stdout.flushFile()
        of arkStreamComplete:
          echo "\n"
          echo fmt"[Tokens: {response.usage.totalTokens}]"
          responseReceived = true
        of arkStreamError:
          echo fmt"Error: {response.error}"
          responseReceived = true
        of arkReady:
          discard  # Just ignore ready responses
      
      if not responseReceived:
        sleep(100)
        inc attempts
    
    if not responseReceived:
      echo "Timeout waiting for response"
  else:
    echo "Failed to send request"
    
  # Cleanup
  signalShutdown(channels)
  stopAPIWorker(apiWorker)
  closeChannels(channels[])