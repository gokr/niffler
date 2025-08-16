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

import std/[os, strutils, strformat, terminal, options, times]
import std/logging
when defined(posix):
  import posix
import noise
import ../core/[app, channels, history, config, database]
import ../types/[messages, config as configTypes]
import ../api/api
import ../api/curlyStreaming
import ../tools/worker
import tui

# Global database backend
var globalDatabase: DatabaseBackend = nil

# Global noise instance for enhanced input
var noiseInstance: Option[Noise] = none(Noise)

proc getUserName*(): string =
  ## Get the current user's name
  result = getEnv("USER", getEnv("USERNAME", "User"))

proc getGlobalDatabase*(): DatabaseBackend =
  ## Get the global database backend instance
  result = globalDatabase

proc initializeNoiseInput(): bool =
  ## Initialize noise with history and completion support
  try:
    var noise = Noise.init()
    
    # Load history from database if available
    if globalDatabase != nil:
      try:
        let recentPrompts = getRecentPrompts(globalDatabase, 100)
        for prompt in recentPrompts:
          noise.historyAdd(prompt)
      except Exception as e:
        debug(fmt"Could not load history from database: {e.msg}")
    
    # TODO: Add completion callback when we figure out the correct API
    noiseInstance = some(noise)
    return true
  except Exception as e:
    debug(fmt"Failed to initialize noise: {e.msg}")
    return false

proc readInputLine(prompt: string): string =
  ## Read input with enhanced features (noise) or fallback to basic input
  if noiseInstance.isSome():
    try:
      var noise = noiseInstance.get()
      
      # Create a colored prompt using Styler - can't be backspaced over
      let styledPrompt = Styler.init(fgBlue, prompt)
      noise.setPrompt(styledPrompt)
      
      # Use noise readline with proper prompt handling
      if noise.readLine():
        let input = noise.getLine()
        if input.len > 0:
          noise.historyAdd(input)
          # Update the option with the modified noise instance
          noiseInstance = some(noise)
        return input
      else:
        # EOF, Ctrl+D, or Ctrl+C - treat as exit signal
        raise newException(EOFError, "User requested exit")
    except EOFError:
      # Re-raise EOF errors (Ctrl+C, Ctrl+D)
      raise
    except Exception as e:
      debug(fmt"Noise readline failed, falling back to basic input: {e.msg}")
      # Fall through to basic input
  
  # Fallback to basic input with colored prompt
  stdout.styledWrite(fgBlue, styleBright, prompt)
  stdout.flushFile()
  return stdin.readLine()

when defined(posix):
  # Global flag to track if we're suspended
  var suspended = false
  
  proc handleSIGTSTP(sig: cint) {.noconv.} =
    ## Handle Ctrl+Z (SIGTSTP) - suspend to background
    suspended = true
    # Send SIGSTOP to ourselves to actually suspend
    discard kill(getpid(), SIGSTOP)
  
  proc handleSIGCONT(sig: cint) {.noconv.} =
    ## Handle SIGCONT - resume from background
    suspended = false
    # Clear the line and redraw prompt when resuming
    stdout.write("\r\e[K")  # Clear current line
    stdout.flushFile()

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
  
  # Initialize database backend
  try:
    let config = loadConfig()
    if config.database.isSome():
      globalDatabase = createDatabaseBackend(config.database.get())
      if globalDatabase != nil:
        debug("Database backend initialized successfully")
      else:
        debug("Database backend disabled in configuration")
    else:
      debug("No database configuration found")
      globalDatabase = nil
  except Exception as e:
    error(fmt"Failed to initialize database backend: {e.msg}")
    globalDatabase = nil
  
  # Initialize enhanced input with noise
  if initializeNoiseInput():
    debug("Enhanced input (noise) initialized successfully")
  else:
    debug("Enhanced input initialization failed, will use basic input")
  
  # Set up signal handlers for Ctrl+Z support (POSIX only)
  when defined(posix):
    signal(SIGTSTP, handleSIGTSTP)
    signal(SIGCONT, handleSIGCONT)

proc startInteractiveUI*(model: string = "", level: Level, dump: bool = false, tui: bool = false) =
  ## Start the interactive terminal UI (TUI, enhanced, or basic fallback)
  
  # Try TUI mode first if requested
  if tui:
    try:
      startTUIMode(model, level, dump, globalDatabase)
      return
    except Exception as e:
      error(fmt"TUI mode failed to start: {e.msg}")
      echo "Falling back to basic CLI..."
  
  # Fallback to basic CLI
  echo "Type '/help' for help and '/exit' or '/quit' to leave."
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
  
  # Start tool worker
  var toolWorker = startToolWorker(channels, level, dump)
  
  # Configure API worker with initial model
  if not configureAPIWorker(currentModel):
    echo fmt"Warning: Failed to configure API worker with model {currentModel.nickname}. Check API key."
  
  # Get user name for prompts
  let userName = getUserName()
  
  # Interactive loop
  var running = true
  while running:
    try:
      # Read user input with enhanced features (history, completion, cursor keys)
      let input = readInputLine(fmt"{userName}: ").strip()
      
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
                
                # Log the prompt exchange to database
                if globalDatabase != nil:
                  try:
                    let dateStr = now().format("yyyy-MM-dd")
                    let sessionId = fmt"session_{getUserName()}_{dateStr}"
                    logPromptHistory(globalDatabase, input, responseText, currentModel.nickname, sessionId)
                  except Exception as e:
                    debug(fmt"Failed to log prompt to database: {e.msg}")
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
    except EOFError:
      # Handle Ctrl+C, Ctrl+D gracefully
      running = false
  
  echo "Goodbye!"
  
  # Cleanup
  signalShutdown(channels)
  stopAPIWorker(apiWorker)
  stopToolWorker(toolWorker)
  closeChannels(channels[])
  
  # Close database connection
  if globalDatabase != nil:
    globalDatabase.close()
    globalDatabase = nil
  
  # Cleanup noise instance
  if noiseInstance.isSome():
    noiseInstance = none(Noise)

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
    var responseText = ""
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
            responseText.add(response.content)
        of arkStreamComplete:
          echo "\n"
          info fmt"Tokens used: {response.usage.totalTokens}"
          
          # Log the prompt exchange to database
          if globalDatabase != nil and responseText.len > 0:
            try:
              let config = loadConfig()
              let selectedModel = if model.len > 0:
                getModelFromConfig(config, model)
              else:
                config.models[0]
              let dateStr = now().format("yyyy-MM-dd")
              let sessionId = fmt"session_{getUserName()}_{dateStr}"
              logPromptHistory(globalDatabase, text, responseText, selectedModel.nickname, sessionId)
            except Exception as e:
              debug(fmt"Failed to log prompt to database: {e.msg}")
          
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
  
  # Close database connection
  if globalDatabase != nil:
    globalDatabase.close()
    globalDatabase = nil
  
  # Cleanup noise instance
  if noiseInstance.isSome():
    noiseInstance = none(Noise)