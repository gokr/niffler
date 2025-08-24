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
## - `/model <name>` - Switch to different model
## - `/clear` - Clear conversation history
## - `/exit`, `/quit` - Exit application
##
## Design Decisions:
## - Simple terminal-based interface using basic I/O
## - Command prefix system to avoid conflicts with natural language
## - System initialization shared between interactive and single-shot modes
## - Real-time streaming display for immediate feedback

import std/[os, strutils, strformat, terminal, options, times, algorithm]
import std/logging
when defined(posix):
  import posix
import linecross
import ../core/[app, channels, history, config, database]
import ../core/log_file as logFileModule
import ../types/[messages, config as configTypes]
import ../api/api
import ../api/curlyStreaming
import ../tools/worker
import commands
import theme
import markdown_cli

# State for input box rendering
var currentInputText: string = ""
var currentModelName: string = ""
var isProcessing: bool = false
var inputTokens: int = 0
var outputTokens: int = 0

proc getUserName*(): string =
  ## Get the current user's name
  result = getEnv("USER", getEnv("USERNAME", "User"))


proc detectCompletionContext*(text: string, cursorPos: int): tuple[contextType: string, prefix: string, startPos: int] =
  ## Detect completion context based on cursor position and surrounding text
  # nim-noise might pass just the word being completed, so check if it starts with / or @
  if text.len > 0 and text[0] == '/':
    # Command completion - remove the leading /
    let prefix = if text.len > 1: text[1..^1] else: ""
    return ("command", prefix, 0)
  elif text == "/":
    # Special case: just a slash, show all commands
    return ("command", "", 0)
  elif text.len > 0 and text[0] == '@':
    # Mention completion - remove the leading @
    let prefix = if text.len > 1: text[1..^1] else: ""
    return ("mention", prefix, 0)
  
  # Fallback: look backward from cursor to find completion triggers  
  var searchPos = min(cursorPos - 1, text.len - 1)
  
  # Find the start of the current word/token
  while searchPos >= 0:
    let ch = text[searchPos]
    if ch in {' ', '\t', '\n'}:
      break
    if ch == '/':
      # Command completion context
      let prefix = if searchPos + 1 < text.len: text[searchPos + 1..min(cursorPos - 1, text.len - 1)] else: ""
      return ("command", prefix, searchPos)
    elif ch == '@':
      # Mention/user completion context  
      let prefix = if searchPos + 1 < text.len: text[searchPos + 1..min(cursorPos - 1, text.len - 1)] else: ""
      return ("mention", prefix, searchPos)
    searchPos -= 1
  
  return ("none", "", -1)


proc nifflerCompletionHook(buf: string, completions: var Completions) =
  ## Completion hook for linecross that handles / and @ completion
  debug(fmt"=== COMPLETION HOOK DEBUG ===")
  debug(fmt"Buffer text received: '{buf}'")
  debug(fmt"Text length: {buf.len}")
  
  let cursorPos = buf.len  # linecross gives us the current buffer
  let (contextType, prefix, startPos) = detectCompletionContext(buf, cursorPos)
  
  debug(fmt"Context type: '{contextType}', prefix: '{prefix}', startPos: {startPos}")
  debug(fmt"==============================")
  
  case contextType:
  of "command":
    # Parse the command and arguments
    let parts = prefix.split(' ', 1)  # Split into command and rest
    if parts.len == 1:
      # Just completing the command name
      let commandCompletions = getCommandCompletions(parts[0])
      debug(fmt"Found {commandCompletions.len} command completions for prefix '{parts[0]}'")
      for cmd in commandCompletions:
        debug(fmt"Adding completion: '{cmd.name}'")
        addCompletion(completions, cmd.name, cmd.description)
    else:
      # Completing command arguments
      let command = parts[0]
      let argPrefix = parts[1]
      debug(fmt"Completing arguments for command '{command}' with prefix '{argPrefix}'")
      
      case command:
      of "model":
        # Complete model names
        let config = loadConfig()
        for model in config.models:
          if model.nickname.toLower().startsWith(argPrefix.toLower()):
            debug(fmt"Adding model completion: '{model.nickname}'")
            addCompletion(completions, model.nickname, model.model)
      of "theme":
        # Complete theme names
        let availableThemes = getAvailableThemes()
        for themeName in availableThemes:
          if themeName.toLower().startsWith(argPrefix.toLower()):
            debug(fmt"Adding theme completion: '{themeName}'")
            addCompletion(completions, themeName, "Theme: " & themeName)
      else:
        # No argument completion for this command
        debug(fmt"No argument completion available for command '{command}'")
  of "mention": 
    # User/mention completion for @
    # For now, add some example mentions - this could be extended
    let mentions = @["user", "assistant", "system", "claude", "gpt"]
    for mention in mentions:
      if mention.startsWith(prefix.toLower()):
        debug(fmt"Adding mention completion: {mention}")
        addCompletion(completions, mention, "Mention: " & mention)
  else:
    debug("No completion context found")

# Forward declaration
proc nifflerCustomKeyHook(keyCode: int, buffer: string): bool

proc initializeLinecrossInput(database: DatabaseBackend): bool =
  ## Initialize linecross with history and completion support
  try:
    # Initialize linecross with full features for good editing experience
    initLinecross(FullFeatures)
    
    # Set up completion callback for commands and mentions
    registerCompletionCallback(nifflerCompletionHook)
    
    # Configure prompt colors to match current blue style
    setPromptColor(getModePromptColor(), {styleBright})
    
    # Load history from database if available
    if database != nil:
      try:
        let recentPrompts = getRecentPrompts(database, 100)
        for prompt in recentPrompts:
          addToHistory(prompt)
        debug(fmt"Loaded {recentPrompts.len} prompts from database into linecross history")
      except Exception as e:
        debug(fmt"Could not load history from database: {e.msg}")
    
    return true
  except Exception as e:
    debug(fmt"Failed to initialize linecross: {e.msg}")
    raise newException(OSError, fmt"Failed to initialize enhanced input (linecross): {e.msg}")

proc readInputLine(prompt: string): string =
  ## Read input with linecross
  try:
    let input = readline(prompt)
    return input
  except EOFError:
    # Re-raise EOF errors (Ctrl+C, Ctrl+D)
    raise

when defined(posix):
  # Global flag to track if we're suspended
  var suspended = false
  # Global state for stream cancellation
  var currentActiveRequestId = ""
  var currentChannels: ptr ThreadChannels = nil
  var streamCancellationRequested = false
  
  proc handleSIGTSTP(sig: cint) {.noconv.} =
    ## Handle Ctrl+Z (SIGTSTP) - suspend to background
    suspended = true
    # Reset signal handler to default and resend signal for proper suspension
    signal(SIGTSTP, SIG_DFL)
    discard kill(getpid(), SIGTSTP)
  
  proc handleSIGCONT(sig: cint) {.noconv.} =
    ## Handle SIGCONT - resume from background
    suspended = false
    # Reinstall SIGTSTP handler
    signal(SIGTSTP, handleSIGTSTP)
    # Clear the line and redraw prompt when resuming
    stdout.write("\r\e[K")  # Clear current line
    stdout.flushFile()
  
  proc handleSIGINT(sig: cint) {.noconv.} =
    ## Handle Ctrl+C (SIGINT) - cancel stream or exit
    if currentActiveRequestId.len > 0 and currentChannels != nil:
      # We have an active stream, cancel it
      streamCancellationRequested = true
      isProcessing = false  # Reset processing state
      let cancelRequest = APIRequest(
        kind: arkStreamCancel,
        cancelRequestId: currentActiveRequestId
      )
      if trySendAPIRequest(currentChannels, cancelRequest):
        echo "\n\x1b[31m⚠️ Response stopped by user, token generation may continue briefly\x1b[0m"
        currentActiveRequestId = ""
      else:
        echo "\n⚠️ Failed to cancel stream"
    else:
      # No active stream, exit normally
      echo "\nGoodbye!"
      quit(0)

proc writeColored*(text: string, color: ForegroundColor, style: Style = styleBright) =
  ## Write colored text to stdout (deprecated - use writeToConversationArea instead)
  stdout.styledWrite(color, style, text)
  stdout.flushFile()

proc generatePrompt*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()): string =
  ## Generate a rich prompt string with token counts, context info, and cost
  let contextMessages = history.getConversationContext()
  let contextSize = estimateTokenCount(contextMessages)
  let maxContext = if modelConfig.context > 0: modelConfig.context else: 128000
  let sessionTotal = inputTokens + outputTokens
  let statusIndicator = if isProcessing: "⚡" else: ""
  let modeIndicator = getModePromptIndicator()

  if sessionTotal > 0:
    # Create context usage bar
    let contextPercent = if maxContext > 0: min(100, (contextSize * 100) div maxContext) else: 0
    let barWidth = 10
    let filledBars = if barWidth > 0: (contextPercent * barWidth) div 100 else: 0
    let contextBar = "█".repeat(filledBars) & "░".repeat(barWidth - filledBars)
    
    # Calculate session cost if available using real token data
    let sessionTokens = getSessionTokens()
    var sessionCost = 0.0
    
    if modelConfig.inputCostPerMToken.isSome() and sessionTokens.inputTokens > 0:
      let inputCostPerToken = modelConfig.inputCostPerMToken.get() / 1_000_000.0
      sessionCost += sessionTokens.inputTokens.float * inputCostPerToken
    
    if modelConfig.outputCostPerMToken.isSome() and sessionTokens.outputTokens > 0:
      let outputCostPerToken = modelConfig.outputCostPerMToken.get() / 1_000_000.0
      sessionCost += sessionTokens.outputTokens.float * outputCostPerToken
    
    let costInfo = if sessionCost > 0: fmt" {formatCost(sessionCost)}" else: ""
    return fmt"{statusIndicator}↑{inputTokens} ↓{outputTokens} [{contextBar}]{contextPercent}%{costInfo} {currentModelName}{modeIndicator} > "
  else:
    return fmt"{statusIndicator}{currentModelName}{modeIndicator} > "

proc writeToConversationArea*(text: string, color: ForegroundColor = fgWhite, style: Style = styleBright, useMarkdown: bool = false) =
  ## Write text to conversation area with automatic newline and optional markdown rendering
  if useMarkdown:
    # Render markdown and output directly (markdown rendering includes its own colors)
    let renderedText = renderMarkdownTextCLI(text)
    stdout.write(renderedText & "\n")
  elif color != fgWhite or style != styleBright:
    stdout.styledWrite(color, style, text & "\n")
  else:
    stdout.write(text & "\n")
  stdout.flushFile()

proc updateTokenCounts*(newInputTokens: int, newOutputTokens: int) =
  ## Update token counts in central history storage
  updateSessionTokens(newInputTokens, newOutputTokens)
  # Also update UI state for prompt display
  inputTokens = newInputTokens
  outputTokens = newOutputTokens

proc nifflerCustomKeyHook(keyCode: int, buffer: string): bool =
  ## Custom key hook for handling special key combinations like Shift+Tab
  if keyCode == ShiftTab:
    # Toggle mode and immediately update prompt, it is refreshed by linecross
    discard toggleMode()
    setPrompt(generatePrompt())
    setPromptColor(getModePromptColor(), {styleBright})
    return true  # Key was handled
  return false  # Key not handled, continue with default processing

proc readInputWithPrompt*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()): string =
  ## Read input with prompt showing current state  
  let prompt = generatePrompt(modelConfig)
  currentInputText = readInputLine(prompt).strip()
  return currentInputText

proc startCLIMode*(modelConfig: configTypes.ModelConfig, database: DatabaseBackend, level: Level, dump: bool = false) =
  ## Start the CLI mode with enhanced interface
  
  # Load configuration to get theme settings
  let config = loadConfig()
  loadThemesFromConfig(config)
  let markdownEnabled = isMarkdownEnabled(config)
  
  # Initialize enhanced input with linecross - fail if not available
  if not initializeLinecrossInput(database):
    raise newException(OSError, "Failed to initialize enhanced input")
  
  # Initialize command system
  initializeCommands()
  
  # Set up signal handlers for Ctrl+Z and Ctrl+C support (POSIX only)
  when defined(posix):
    signal(SIGTSTP, handleSIGTSTP)
    signal(SIGCONT, handleSIGCONT)
    signal(SIGINT, handleSIGINT)
  
  let channels = getChannels()
  
  # Set up global state for stream cancellation
  when defined(posix):
    currentChannels = channels
  
  # Use the provided model configuration
  var currentModel = modelConfig
  
  # Display welcome message in conversation area
  writeToConversationArea("Welcome to Niffler! ", fgCyan, styleBright)
  writeToConversationArea("Type '/help' for help and '/exit' or '/quit' to leave.\n")
  writeToConversationArea("Press Ctrl+C to stop stream display or exit.\n")
  writeToConversationArea(fmt"Using model: {currentModel.nickname} ({currentModel.model})", fgGreen)
  writeToConversationArea("\n")
  
  # Initialize global state for enhanced CLI
  currentModelName = currentModel.nickname
  currentInputText = ""
  isProcessing = false
  inputTokens = 0
  outputTokens = 0
  
  initializeModeState()
  
  # Get database pool for cross-thread history sharing
  let pool = if database != nil: database.pool else: nil
  
  # Initialize history manager with pool
  let conversationId = startNewConversation().int
  initHistoryManager(pool, conversationId)
  
  # Start API worker with pool
  var apiWorker = startAPIWorker(channels, level, dump, database, pool)
  
  # Start tool worker with pool
  var toolWorker = startToolWorker(channels, level, dump, database, pool)
  
  # Configure API worker with initial model
  if not configureAPIWorker(currentModel):
    echo fmt"Warning: Failed to configure API worker with model {currentModel.nickname}. Check API key."
  
  # Get user name for prompts
  let userName = getUserName()
  
  proc nifflerCustomKeyHook(keyCode: int, buffer: string): bool =
    ## Custom key hook for handling special key combinations like Shift+Tab
    if keyCode == ShiftTab:
      # Toggle mode silently - the prompt will update on next input
      discard toggleMode()
      setPrompt(generatePrompt(currentModel))
      setPromptColor(getModePromptColor())
      return true  # Key was handled
    return false  # Key not handled, continue with default processing

  # Set up custom key callback for shift-tab etc
  registerCustomKeyCallback(nifflerCustomKeyHook)

  # Interactive loop
  var running = true
  while running:
    try:
      # Read user input with dynamic prompt
      let input = readInputWithPrompt(currentModel)
      
      if input.len == 0:
        continue
      
      # Handle commands using the command system
      if input.startsWith("/"):
        let (command, args) = parseCommand(input)
        if command.len > 0:
          let res = executeCommand(command, args, currentModel)
          
          # Display command result with markdown if enabled
          writeToConversationArea(res.message, fgWhite, styleBright, markdownEnabled)
          writeToConversationArea("")
          
          # Handle special commands that need additional actions
          if res.success:
            if command == "model":
              # Reconfigure API worker with new model
              currentModelName = currentModel.nickname
              if not configureAPIWorker(currentModel):
                writeToConversationArea(fmt"Warning: Failed to configure API worker with model {currentModel.nickname}. Check API key.")
                writeToConversationArea("")
          
          if res.shouldExit:
            running = false
          
          continue
        else:
          writeToConversationArea("Invalid command format")
          writeToConversationArea("")
          continue
      
      # Regular message - send to API
      let (success, requestId) = sendSinglePromptInteractiveWithId(input, currentModel)
      if success:
        # Track the request for cancellation
        when defined(posix):
          currentActiveRequestId = requestId
          streamCancellationRequested = false
        
        # Wait for response and display it
        var responseText = ""
        var responseReceived = false
        var hadToolCalls = false  # Track if this conversation involved tool calls
        var attempts = 0
        const maxAttempts = 600  # 60 seconds with 100ms sleep
        
        # Show processing status
        isProcessing = true
        
        # Write model name in conversation area (nim-noise already showed user input)
        # Not needed since we now have it in the prompt: writeToConversationArea(fmt"{currentModel.nickname}: ", fgGreen)
        
        while not responseReceived and attempts < maxAttempts:
          # Check for cancellation request
          when defined(posix):
            if streamCancellationRequested:
              responseReceived = true
              isProcessing = false  # Reset processing state
              currentActiveRequestId = ""
              break
          
          var response: APIResponse
          if tryReceiveAPIResponse(channels, response):
            # Validate that this response belongs to our current request
            if response.requestId != requestId:
              debug(fmt"Ignoring response from request {response.requestId} (current: {requestId})")
              continue  # Skip processing this response
            
            case response.kind:
            of arkStreamChunk:
              # Check if this chunk contains tool calls
              if response.toolCalls.isSome():
                hadToolCalls = true
                debug("DEBUG: Tool calls detected in UI - will not add duplicate assistant message to history")
              
              if response.content.len > 0:
                responseText.add(response.content)
                # Apply real-time markdown rendering if enabled
                if markdownEnabled:
                  let renderedChunk = renderMarkdownTextCLIStream(response.content)
                  stdout.write(renderedChunk)
                else:
                  stdout.write(response.content)
                stdout.flushFile()
            of arkStreamComplete:
              writeToConversationArea("")  # Add final newline
              # Update token counts with new response (prompt will show tokens)
              isProcessing = false
              updateTokenCounts(response.usage.inputTokens, response.usage.outputTokens)
              # Add assistant response to history only if no tool calls were involved
              # (API worker already handles history for tool call conversations)
              if responseText.len > 0 and not hadToolCalls:
                debug("DEBUG: Adding assistant message to history (no tool calls detected)")
                discard addAssistantMessage(responseText)
              elif hadToolCalls:
                debug("DEBUG: Skipping assistant message addition - tool calls already handled by API worker")
              
              # Log the prompt exchange to database
              if database != nil:
                try:
                  let dateStr = now().format("yyyy-MM-dd")
                  let sessionId = fmt"session_{getUserName()}_{dateStr}"
                  logPromptHistory(database, input, responseText, currentModel.nickname, sessionId)
                except Exception as e:
                  debug(fmt"Failed to log prompt to database: {e.msg}")
              responseReceived = true
              when defined(posix):
                currentActiveRequestId = ""
            of arkStreamError:
              writeToConversationArea(fmt"Error: {response.error}", fgRed)
              isProcessing = false
              responseReceived = true
              when defined(posix):
                currentActiveRequestId = ""
            of arkReady:
              discard  # Just ignore ready responses
          
          if not responseReceived:
            sleep(100)
            inc attempts
        
        if not responseReceived:
          writeToConversationArea("Timeout waiting for response", fgRed)
          isProcessing = false
          when defined(posix):
            currentActiveRequestId = ""
      else:
        writeToConversationArea("Failed to send message", fgRed)
    except EOFError:
      # Handle Ctrl+C, Ctrl+D gracefully
      running = false
  
  # Cleanup
  signalShutdown(channels)
  stopAPIWorker(apiWorker)
  stopToolWorker(toolWorker)
  closeChannels(channels[])
  
  # Close database connection
  if database != nil:
    database.close()
  
  # Close log file if active
  if logFileModule.isLoggingActive():
    let logManager = logFileModule.getGlobalLogManager()
    logManager.closeLogFile()
  
  # Linecross cleanup is automatic

proc sendSinglePrompt*(text: string, model: string, level: Level, dump: bool = false, logFile: string = "") =
  ## Send a single prompt and return response
  if text.len == 0:
    echo "Error: No prompt text provided"
    return
    
  # Initialize the app systems but don't start the full UI loop
  if logFile.len > 0:
    # Setup file and console logging
    let logManager = logFileModule.initLogFileManager(logFile)
    logFileModule.setGlobalLogManager(logManager)
    logManager.activateLogFile()
    let logger = logFileModule.newFileAndConsoleLogger(logManager)
    addHandler(logger)
  else:
    # Setup console-only logging
    let consoleLogger = newConsoleLogger()
    addHandler(consoleLogger)
  
  setLogFilter(level)
  initThreadSafeChannels()
  initDumpFlag()
  setDumpEnabled(dump)
  
  # Initialize database
  let database = initializeGlobalDatabase(level)
  
  # Get database pool for cross-thread history sharing
  let pool = if database != nil: database.pool else: nil
  
  # Initialize history manager with pool
  let conversationId = startNewConversation().int
  initHistoryManager(pool, conversationId)
  
  let channels = getChannels()
  
  # Start API worker with pool
  var apiWorker = startAPIWorker(channels, level, dump, database, pool)
  
  # Start tool worker with pool
  var toolWorker = startToolWorker(channels, level, dump, database, pool)
  
  let (success, requestId) = sendSinglePromptAsyncWithId(text, model)
  if success:
    debug "Request sent, waiting for response..."
    
    # Wait for response with timeout
    var responseReceived = false
    var responseText = ""
    var attempts = 0
    const maxAttempts = 300  # 30 seconds with 100ms sleep
    
    while not responseReceived and attempts < maxAttempts:
      var response: APIResponse
      if tryReceiveAPIResponse(channels, response):
        # Validate that this response belongs to our current request
        if response.requestId != requestId:
          debug(fmt"Ignoring response from request {response.requestId} (current: {requestId})")
          continue  # Skip processing this response
        
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
          if database != nil and responseText.len > 0:
            try:
              let config = loadConfig()
              let selectedModel = if model.len > 0:
                getModelFromConfig(config, model)
              else:
                config.models[0]
              let dateStr = now().format("yyyy-MM-dd")
              let sessionId = fmt"session_{getUserName()}_{dateStr}"
              logPromptHistory(database, text, responseText, selectedModel.nickname, sessionId)
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
  if database != nil:
    database.close()
  
  # Close log file if active
  if logFileModule.isLoggingActive():
    let logManager = logFileModule.getGlobalLogManager()
    logManager.closeLogFile()
  
  # Linecross cleanup is automatic