## CLI User Interface
##
## This module provides the command-line user interface for Niffler, handling
## both interactive mode and single prompt execution.
##
## Key Features:
## - Interactive chat mode with real-time streaming display
## - Command system with `/` prefix for meta operations
## - Single prompt execution for CLI scripting
## - Model switching and configuration
## - History management and conversation context
##
## Interactive Commands:
## - `/help` - Show available commands
## - `/models` - List available models  
## - `/model <name>` - Switch to different model
## - `/clear` - Clear conversation history
## - `/exit`, `/quit` - Exit application
##
## Design Decisions:
## - Simple terminal-based interface using basic I/O
## - Command prefix system to avoid conflicts with natural language
## - System initialization shared between interactive and single-shot modes
## - Real-time streaming display for immediate feedback

import std/[os, strutils, strformat, terminal]
import std/logging
import ../core/[app, channels, history, config]
import ../types/[messages, config as configTypes]
import ../api/api
import ../api/curlyStreaming
import ../tools/worker
import enhanced

proc getUserName*(): string =
  ## Get the current user's name
  result = getEnv("USER", getEnv("USERNAME", "User"))

proc writeColored*(text: string, color: ForegroundColor, style: Style = styleBright) =
  ## Write colored text to stdout
  stdout.styledWrite(color, style, text)
  stdout.flushFile()

proc initializeAppSystems*(level: Level, dump: bool = false) =
  ## Initialize common app systems
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(level)
  initThreadSafeChannels()
  initHistoryManager()
  # Store dump setting for later use by HTTP clients
  initDumpFlag()
  setDumpEnabled(dump)

proc startInteractiveUI*(model: string = "", level: Level, dump: bool = false, illwill: bool = false) =
  ## Start the interactive terminal UI (enhanced or basic fallback)
  
  # Try to start enhanced UI first
  if illwill:
    try:
      startEnhancedInteractiveUI(model, level, dump)
      return
    except Exception as e:
      error(fmt"Enhanced UI failed to start: {e.msg}")
      echo "Falling back to basic CLI..."
  
  # Fallback to basic CLI
  echo "Starting Niffler interactive mode..."
  echo "Type your messages and press Enter to send. Type '/exit' or '/quit' to leave."
  echo "Use '/model <name>' to switch models. Type '/help' for more commands."
  echo ""
  
  # Initialize the app systems
  initializeAppSystems(level, dump)
  
  let channels = getChannels()
  let config = loadConfig()
  
  # Select initial model based on parameter or default
  var currentModel = if model.len > 0:
    block:
      var found = false
      var selectedModel = config.models[0]  # fallback
      for m in config.models:
        if m.nickname == model:
          selectedModel = m
          found = true
          break
      if not found:
        echo fmt"Warning: Model '{model}' not found, using default: {config.models[0].nickname}"
      selectedModel
  else:
    if config.models.len > 0: config.models[0] else: 
      quit("No models configured. Please run 'niffler init' first.")
  
  echo fmt"Using model: {currentModel.nickname} ({currentModel.model})"
  echo ""
  
  # Start API worker
  var apiWorker = startAPIWorker(channels, level, dump)
  
  # Configure API worker with initial model
  if not configureAPIWorker(currentModel):
    echo fmt"Warning: Failed to configure API worker with model {currentModel.nickname}. Check API key."
  
  # Get user name for prompts
  let userName = getUserName()
  
  # Interactive loop
  var running = true
  while running:
    # Show colored user prompt
    writeColored(fmt"{userName}: ", fgCyan)
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
              # Configure API worker with new model
              if configureAPIWorker(currentModel):
                echo fmt"Switched to model: {currentModel.nickname} ({currentModel.model})"
              else:
                echo fmt"Error: Failed to configure model {currentModel.nickname}. Check API key."
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
      
      writeColored(fmt"{currentModel.nickname}: ", fgGreen)
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

proc sendSinglePrompt*(text: string, model: string, level: Level, dump: bool = false) =
  ## Send a single prompt and return response
  if text.len == 0:
    echo "Error: No prompt text provided"
    return
    
  # Initialize the app systems but don't start the full UI loop
  
  initializeAppSystems(level, dump)
  
  let channels = getChannels()
  
  # Start API worker
  var apiWorker = startAPIWorker(channels, level, dump)
  
  # Start tool worker
  var toolWorker = startToolWorker(channels, level, dump)
  
  if sendSinglePromptAsync(text, model):
    debug "Request sent, waiting for response..."
    
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
          info fmt"Tokens used: {response.usage.totalTokens}"
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
  stopToolWorker(toolWorker)
  closeChannels(channels[])