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

import std/[os, strutils, strformat, terminal, options, times, algorithm]
import std/logging
when defined(posix):
  import posix
import noise
import ../core/[app, channels, history, config, database]
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
var promptTokens: int = 0
var completionTokens: int = 0
# Global noise instance for enhanced input
var noiseInstance: Option[Noise] = none[Noise]()

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

proc nifflerCompletionHook(noise: var Noise, text: string): int =
  ## Completion hook for nim-noise that handles both / and @ completion
  let cursorPos = text.len  # nim-noise gives us the full current line
  let (contextType, prefix, startPos) = detectCompletionContext(text, cursorPos)
  
  case contextType:
  of "command":
    # Command completion for /
    let completions = getCommandCompletions(prefix)
    for cmd in completions:
      noise.addCompletion(cmd.name)  # nim-noise will replace the typed text
    return completions.len
  of "mention": 
    # User/mention completion for @
    # For now, add some example mentions - this could be extended
    let mentions = @["user", "assistant", "system", "claude", "gpt"]
    var matchCount = 0
    for mention in mentions:
      if mention.startsWith(prefix.toLower()):
        noise.addCompletion(mention)  # nim-noise will replace the typed text
        inc matchCount
    return matchCount
  else:
    return 0

proc initializeNoiseInput(database: DatabaseBackend): bool =
  ## Initialize noise with history and completion support
  try:
    var noise = Noise.init()
    
    # Load history from database if available
    if database != nil:
      try:
        let recentPrompts = getRecentPrompts(database, 100)
        for prompt in recentPrompts:
          noise.historyAdd(prompt)
      except Exception as e:
        debug(fmt"Could not load history from database: {e.msg}")
    
    # Set up completion hook for commands and mentions
    noise.setCompletionHook(nifflerCompletionHook)
    
    noiseInstance = some(noise)
    return true
  except Exception as e:
    debug(fmt"Failed to initialize noise: {e.msg}")
    raise newException(OSError, fmt"Failed to initialize enhanced input (nim-noise): {e.msg}")

proc readInputLine(prompt: string): string =
  ## Read input with enhanced features (noise) - no fallback
  if noiseInstance.isNone():
    raise newException(OSError, "Enhanced input not initialized")
  
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

proc generatePrompt*(modelName: string, isProcessing: bool = false,
                    promptTokens: int = 0, completionTokens: int = 0,
                    contextSize: int = 0, maxContext: int = 128000,
                    modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()): string =
  ## Generate a rich prompt string with token counts, context info, and cost
  let sessionTotal = promptTokens + completionTokens
  
  if sessionTotal > 0:
    # Create context usage bar
    let contextPercent = if maxContext > 0: min(100, (contextSize * 100) div maxContext) else: 0
    let barWidth = 10
    let filledBars = if barWidth > 0: (contextPercent * barWidth) div 100 else: 0
    let contextBar = "█".repeat(filledBars) & "░".repeat(barWidth - filledBars)
    
    # Calculate context cost if available
    let messages = getConversationContext()
    let contextCost = calculateContextCost(messages, modelConfig)
    let costInfo = if contextCost.totalCost > 0: fmt" {formatCost(contextCost.totalCost)}" else: ""
    
    # Use a simpler processing indicator to avoid cursor offset issues
    let statusIndicator = if isProcessing: "⚡" else: ""
    return fmt"{statusIndicator}↑{promptTokens} ↓{completionTokens} [{contextBar}]{contextPercent}%{costInfo} {modelName} > "
  else:
    let statusIndicator = if isProcessing: "⚡ " else: ""
    return fmt"{statusIndicator}{modelName} > "

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

proc updateTokenCounts*(newPromptTokens: int, newCompletionTokens: int) =
  ## Update token counts in central history storage
  updateSessionTokens(newPromptTokens, newCompletionTokens)
  # Also update UI state for prompt display
  promptTokens = newPromptTokens
  completionTokens = newCompletionTokens

proc readInputWithPrompt*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()): string =
  ## Read input with dynamic prompt showing current state
  # Get actual context information
  let contextMessages = getConversationContext()
  let contextTokens = estimateTokenCount(contextMessages)
  let maxContext = if modelConfig.context > 0: modelConfig.context else: 128000
  
  let dynamicPrompt = generatePrompt(currentModelName, isProcessing, 
                                   promptTokens, completionTokens,
                                   contextTokens,  # Use real context size
                                   maxContext, modelConfig)
  
  let input = readInputLine(dynamicPrompt).strip()
  currentInputText = input
  return input


proc startCLIMode*(modelConfig: configTypes.ModelConfig, database: DatabaseBackend, level: Level, dump: bool = false) =
  ## Start the CLI mode with enhanced interface
  
  # Load configuration to get theme settings
  let config = loadConfig()
  loadThemesFromConfig(config)
  let markdownEnabled = isMarkdownEnabled(config)
  
  # Initialize enhanced input with noise - fail if not available
  if not initializeNoiseInput(database):
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
  promptTokens = 0
  completionTokens = 0
  
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
              if response.content.len > 0:
                # For streaming, we need to buffer content to avoid breaking markdown formatting
                responseText.add(response.content)
                # For now, just write the raw content - we'll apply markdown at the end
                stdout.write(response.content)
                stdout.flushFile()
            of arkStreamComplete:
              # Clear the line and apply markdown rendering if enabled to the complete response
              if markdownEnabled and responseText.len > 0:
                # Move to beginning of response and clear it
                stdout.write("\r")
                # Clear the entire response area (rough approach)
                for i in 0..<(responseText.count('\n') + 1):
                  stdout.write("\x1b[2K\x1b[1A")  # Clear line and move up
                stdout.write("\x1b[2K")  # Clear current line
                # Now render with markdown
                let renderedResponse = renderMarkdownTextCLI(responseText)
                stdout.write(renderedResponse)
              writeToConversationArea("")  # Add final newline
              # Update token counts with new response (prompt will show tokens)
              isProcessing = false
              updateTokenCounts(response.usage.promptTokens, response.usage.completionTokens)
              # Add assistant response to history (without tool calls in CLI - tool calls are handled by API worker)
              if responseText.len > 0:
                discard addAssistantMessage(responseText)
                
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
  
  # Cleanup noise instance
  if noiseInstance.isSome():
    noiseInstance = none[Noise]()

proc sendSinglePrompt*(text: string, model: string, level: Level, dump: bool = false) =
  ## Send a single prompt and return response
  if text.len == 0:
    echo "Error: No prompt text provided"
    return
    
  # Initialize the app systems but don't start the full UI loop
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(level)
  initThreadSafeChannels()
  initHistoryManager()
  initDumpFlag()
  setDumpEnabled(dump)
  
  # Initialize database
  let database = initializeGlobalDatabase(level)
  
  # Start a new conversation for cost tracking
  discard startNewConversation()
  
  let channels = getChannels()
  
  # Start API worker
  var apiWorker = startAPIWorker(channels, level, dump)
  
  # Start tool worker
  var toolWorker = startToolWorker(channels, level, dump)
  
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
  
  # Cleanup noise instance
  if noiseInstance.isSome():
    noiseInstance = none[Noise]()