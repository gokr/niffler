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

import std/[os, strutils, strformat, terminal, options, times, math, tables]
import std/logging
when defined(posix):
  import posix
import ../../../linecross/linecross
import ../core/[app, channels, conversation_manager, config, database, mode_state, session]
import ../core/log_file as logFileModule
import ../types/[messages, config as configTypes, tools, agents]
import ../api/api
import ../api/curlyStreaming
import ../tools/[worker, common]
import ../mcp/[mcp, tools as mcpTools]
import commands
import theme
import table_utils
import markdown_cli
import tool_visualizer
import file_completion

# Forward declarations for helper functions called early in the file
proc generatePrompt*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()): string
proc updatePromptState*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig())

# State for input box rendering
var currentInputText: string = ""
var currentModelName: string = ""
var isProcessing: bool = false
var inputTokens: int = 0
var outputTokens: int = 0

# State for tool call display with progressive rendering
var pendingToolCalls: Table[string, CompactToolRequestInfo] = initTable[string, CompactToolRequestInfo]()
var outputAfterToolCall: bool = false  # Track if any output occurred after showing tool call

# State for thinking token display
var isInThinkingBlock: bool = false  # Track if we're currently displaying thinking content

# Streaming buffer for batching output
var streamingBuffer: string = ""
const STREAMING_FLUSH_THRESHOLD = 200  # Increased threshold to reduce fragmentation
const STREAMING_MAX_BUFFER = 500  # Force flush at this size regardless of word boundaries

proc getUserName*(): string =
  ## Get the current user's name
  result = getEnv("USER", getEnv("USERNAME", "User"))

proc logToPromptHistory*(database: DatabaseBackend, input: string, output: string = "", modelNickname: string, sessionId: string = "") =
  ## Log prompt exchange to database with consistent error handling
  if database != nil:
    try:
      let finalSessionId = if sessionId.len > 0: 
        sessionId 
      else: 
        let dateStr = now().utc().format("yyyy-MM-dd")
        fmt"session_{getUserName()}_{dateStr}"
      logPromptHistory(database, input, output, modelNickname, finalSessionId)
      debug(fmt"Stored prompt in history: {input[0..min(50, input.len-1)]}")
    except Exception as e:
      debug(fmt"Failed to log prompt to database: {e.msg}")

proc initializeSystemComponents*(): (configTypes.Config, bool) =
  ## Initialize system components and return config and markdown flag
  let config = loadConfig()
  loadThemesFromConfig(config)
  let markdownEnabled = isMarkdownEnabled(config)
  return (config, markdownEnabled)

proc cleanupSystem*(channels: ptr ThreadChannels, apiWorker: var APIWorker, toolWorker: var ToolWorker, mcpWorker: var McpWorker, database: DatabaseBackend) =
  ## Perform system cleanup: shutdown workers, close database and log files
  signalShutdown(channels)
  stopAPIWorker(apiWorker)
  stopToolWorker(toolWorker)
  stopMcpWorker(mcpWorker)
  closeChannels(channels[])

  if database != nil:
    database.close()

  if logFileModule.isLoggingActive():
    let logManager = logFileModule.getGlobalLogManager()
    logManager.closeLogFile()


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
    # File completion - remove the leading @
    let prefix = if text.len > 1: text[1..^1] else: ""
    return ("file", prefix, 0)
  
  # Fallback: look backward from cursor to find completion triggers
  var searchPos = min(cursorPos - 1, text.len - 1)
  
  # Find the start of the current word/token
  while searchPos >= 0:
    let ch = text[searchPos]
    if ch in {' ', '\t', '\n'}:
      break
    if ch == '/':
      # Check if we're in a file context (after @)
      # Look backward to see if there's an @ before this /
      var atPos = -1
      for i in countdown(searchPos - 1, 0):
        if text[i] == '@':
          atPos = i
          break
        elif text[i] in {' ', '\t', '\n'}:
          break
      
      if atPos >= 0:
        # We're in file context, continue with file completion
        let prefix = if searchPos + 1 < text.len: text[searchPos + 1..min(cursorPos - 1, text.len - 1)] else: ""
        return ("file", prefix, searchPos)
      else:
        # Command completion context
        let prefix = if searchPos + 1 < text.len: text[searchPos + 1..min(cursorPos - 1, text.len - 1)] else: ""
        return ("command", prefix, searchPos)
    elif ch == '@':
      # File completion context
      let prefix = if searchPos + 1 < text.len: text[searchPos + 1..min(cursorPos - 1, text.len - 1)] else: ""
      return ("file", prefix, searchPos)
    searchPos -= 1
  
  return ("none", "", -1)


proc nifflerCompletionCallback(buffer: string, cursorPos: int, isSecondTab: bool): string =
  ## New completion callback for linecross that handles / and @ completion
  debug(fmt"=== COMPLETION CALLBACK DEBUG ===")
  debug(fmt"Buffer: '{buffer}', cursorPos: {cursorPos}, isSecondTab: {isSecondTab}")
  
  let (contextType, prefix, startPos) = detectCompletionContext(buffer, cursorPos)
  
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
      
      if commandCompletions.len == 1:
        # Single match - complete it with space
        let completion = commandCompletions[0].name
        let suffix = completion[parts[0].len..^1] & " "
        debug(fmt"Single command match: returning '{suffix}'")
        clearInfo()  # Clear any existing completion info
        return suffix
      elif commandCompletions.len > 1:
        if isSecondTab:
          # Show command options in info area
          var infoLines: seq[string] = @["Available commands:"]
          for cmd in commandCompletions:
            infoLines.add(fmt"  /{cmd.name} - {cmd.description}")
          setInfo(infoLines)
          redraw()
          debug(fmt"Showing {commandCompletions.len} command options in info area")
        return ""  # Multiple matches - first tab silent, second tab shows options
      else:
        return ""  # No matches
    else:
      # Completing command arguments
      let command = parts[0]
      let argPrefix = parts[1]
      debug(fmt"Completing arguments for command '{command}' with prefix '{argPrefix}'")
      
      case command:
      of "model":
        # Model completion with Nancy table
        let config = loadConfig()
        debug(fmt"Found {config.models.len} models in config")
        var matchedModels: seq[configTypes.ModelConfig] = @[]
        
        for model in config.models:
          let matchesNickname = model.nickname.toLower().startsWith(argPrefix.toLower())
          let matchesModel = model.model.toLower().contains(argPrefix.toLower()) or argPrefix.len == 0
          
          if matchesNickname or matchesModel:
            matchedModels.add(model)
        
        if matchedModels.len == 1:
          # Single match - complete it with space
          let model = matchedModels[0]
          let suffix = model.nickname[argPrefix.len..^1] & " "
          debug(fmt"Single model match: returning '{suffix}'")
          clearInfo()  # Clear any existing completion info
          return suffix
        elif matchedModels.len > 1:
          if isSecondTab:
            # Show Nancy table in info area
            let tableOutput = formatModelsTable(matchedModels)
            let tableLines = tableOutput.split('\n')
            setInfo(tableLines)
            redraw()
            debug(fmt"Showing model table with {matchedModels.len} models in info area")
          return ""
        else:
          return ""
      of "theme":
        # Theme completion
        let availableThemes = getAvailableThemes()
        var matchedThemes: seq[string] = @[]
        
        for themeName in availableThemes:
          if themeName.toLower().startsWith(argPrefix.toLower()):
            matchedThemes.add(themeName)
        
        if matchedThemes.len == 1:
          # Single match - complete it with space
          let suffix = matchedThemes[0][argPrefix.len..^1] & " "
          debug(fmt"Single theme match: returning '{suffix}'")
          clearInfo()  # Clear any existing completion info
          return suffix
        elif matchedThemes.len > 1:
          if isSecondTab:
            # Show theme options in info area
            var infoLines: seq[string] = @["Available themes:"]
            for theme in matchedThemes:
              infoLines.add(fmt"  {theme}")
            setInfo(infoLines)
            redraw()
            debug(fmt"Showing {matchedThemes.len} theme options in info area")
          return ""
        else:
          return ""
      of "agent":
        # Agent completion
        let agentsDir = session.getAgentsDir()
        let agents = loadAgentDefinitions(agentsDir)
        var matchedAgents: seq[AgentDefinition] = @[]

        for agent in agents:
          if agent.name.toLower().startsWith(argPrefix.toLower()):
            matchedAgents.add(agent)

        if matchedAgents.len == 1:
          # Single match - complete it with space
          let suffix = matchedAgents[0].name[argPrefix.len..^1] & " "
          debug(fmt"Single agent match: returning '{suffix}'")
          clearInfo()
          return suffix
        elif matchedAgents.len > 1:
          if isSecondTab:
            # Show agent options in info area
            var infoLines: seq[string] = @["Available agents:"]
            for agent in matchedAgents:
              infoLines.add(fmt"  {agent.name}")
            setInfo(infoLines)
            redraw()
            debug(fmt"Showing {matchedAgents.len} agent options in info area")
          return ""
        else:
          return ""
      of "conv", "archive":
        # Conversation completion with Nancy table
        try:
          let database = getGlobalDatabase()
          if database != nil:
            let allConversations = listActiveConversations(database)
            let currentSession = getCurrentSession()
            let activeId = if currentSession.isSome(): currentSession.get().conversation.id else: -1

            # Filter conversations based on argPrefix
            var filteredConversations: seq[Conversation] = @[]
            for conv in allConversations:
              let idStr = $conv.id
              let matchesId = idStr.startsWith(argPrefix)
              let matchesTitle = conv.title.toLower().startsWith(argPrefix.toLower())

              if matchesId or (matchesTitle and argPrefix.len > 0):
                filteredConversations.add(conv)
            
            if filteredConversations.len == 1:
              # Single match - complete it with space
              let conv = filteredConversations[0]
              let idStr = $conv.id

              # Determine what we matched on and complete accordingly
              let matchedById = idStr.startsWith(argPrefix)
              let matchedByTitle = conv.title.toLower().startsWith(argPrefix.toLower())

              debug(fmt"CONV COMPLETION: conv.id={conv.id}, title='{conv.title}', argPrefix='{argPrefix}'")
              debug(fmt"CONV COMPLETION: matchedById={matchedById}, matchedByTitle={matchedByTitle}")

              # For title matching, we need to return the full title with proper casing
              # since we matched case-insensitively but want to replace with correct case
              let suffix = if matchedById and not matchedByTitle:
                # Only matched by ID - complete the ID
                idStr[argPrefix.len..^1] & " "
              elif matchedByTitle:
                # Matched by title - return rest of title with correct case
                # First, calculate how many chars of argPrefix matched (case-insensitive)
                let matchLen = argPrefix.len
                # Return the correctly-cased prefix + rest of title
                # But we only want to add the suffix, so we need to figure out what to add
                # The user typed "pi", the title is "Pizza" - we need to add "zza "
                # But the case might be different, so we return: title[matchLen..^1]
                conv.title[matchLen..^1] & " "
              else:
                # Shouldn't happen, but fallback to ID
                idStr[argPrefix.len..^1] & " "

              debug(fmt"CONV COMPLETION: calculated suffix='{suffix}'")
              clearInfo()  # Clear any existing completion info
              return suffix
            elif filteredConversations.len > 1:
              if isSecondTab:
                # Show Nancy table in info area
                let tableOutput = formatConversationTable(filteredConversations, activeId, showArchived = false)
                let tableLines = tableOutput.split('\n')
                setInfo(tableLines)
                redraw()
                debug(fmt"Showing conversation table with {filteredConversations.len} conversations in info area")
              return ""
            else:
              return ""
        except Exception as e:
          debug(fmt"Error getting conversation completions: {e.msg}")
          return ""
      of "unarchive":
        # Archived conversation completion with Nancy table
        try:
          let database = getGlobalDatabase()
          if database != nil:
            let allConversations = listArchivedConversations(database)

            # Filter conversations based on argPrefix
            var filteredConversations: seq[Conversation] = @[]
            for conv in allConversations:
              let idStr = $conv.id
              let matchesId = idStr.startsWith(argPrefix)
              let matchesTitle = conv.title.toLower().startsWith(argPrefix.toLower())

              if matchesId or (matchesTitle and argPrefix.len > 0):
                filteredConversations.add(conv)
            
            if filteredConversations.len == 1:
              # Single match - complete with conversation ID and space
              let conv = filteredConversations[0]
              let idStr = $conv.id

              # Determine what we matched on and complete accordingly
              let matchedById = idStr.startsWith(argPrefix)
              let matchedByTitle = conv.title.toLower().startsWith(argPrefix.toLower())

              let suffix = if matchedById and not matchedByTitle:
                # Only matched by ID - complete the ID
                idStr[argPrefix.len..^1] & " "
              elif matchedByTitle:
                # Matched by title - return rest of title with correct case
                conv.title[argPrefix.len..^1] & " "
              else:
                # Shouldn't happen, but fallback to ID
                idStr[argPrefix.len..^1] & " "

              debug(fmt"Single archived conversation match: returning '{suffix}'")
              clearInfo()  # Clear any existing completion info
              return suffix
            elif filteredConversations.len > 1:
              if isSecondTab:
                # Show Nancy table in info area
                let tableOutput = formatConversationTable(filteredConversations, currentId = -1, showArchived = true)
                let tableLines = tableOutput.split('\n')
                setInfo(tableLines)
                redraw()
                debug(fmt"Showing archived conversation table with {filteredConversations.len} conversations in info area")
              return ""
            else:
              return ""
        except Exception as e:
          debug(fmt"Error getting archived conversation completions: {e.msg}")
          return ""
      else:
        # No argument completion for this command
        debug(fmt"No argument completion available for command '{command}'")
        return ""
  of "mention":
    # User/mention completion for @
    let mentions = @["user", "assistant", "system", "claude", "gpt"]
    var matchedMentions: seq[string] = @[]
    
    for mention in mentions:
      if mention.startsWith(prefix.toLower()):
        matchedMentions.add(mention)
    
    if matchedMentions.len == 1:
      # Single match - complete it with space
      let suffix = matchedMentions[0][prefix.len..^1] & " "
      debug(fmt"Single mention match: returning '{suffix}'")
      clearInfo()  # Clear any existing completion info
      return suffix
    elif matchedMentions.len > 1:
      if isSecondTab:
        # Show mention options in info area
        var infoLines: seq[string] = @["Available mentions:"]
        for mention in matchedMentions:
          infoLines.add(fmt"  @{mention}")
        setInfo(infoLines)
        redraw()
        debug(fmt"Showing {matchedMentions.len} mention options in info area")
      return ""
    else:
      return ""
  of "file":
    # File completion for @
    try:
      let fileCompletions = getFileCompletions(prefix)
      debug(fmt"Found {fileCompletions.len} file completions for prefix '{prefix}'")
      
      if fileCompletions.len == 1:
        # Single match - complete it
        let file = fileCompletions[0]
        let completePath = if file.isDir: file.path & "/" else: file.path
        let suffix = completePath[prefix.len..^1]
        debug(fmt"Single file match: returning '{suffix}'")
        clearInfo()  # Clear any existing completion info
        return suffix
      elif fileCompletions.len > 1:
        if isSecondTab:
          # Show file options in info area
          var infoLines: seq[string] = @["Available files:"]
          for file in fileCompletions:
            let displayPath = if file.isDir: file.path & "/" else: file.path
            infoLines.add(fmt"  @{displayPath}")
          setInfo(infoLines)
          redraw()
          debug(fmt"Showing {fileCompletions.len} file options in info area")
        return ""
      else:
        return ""
    except Exception as e:
      debug(fmt"Error getting file completions: {e.msg}")
      return ""
  else:
    debug("No completion context found")
    return ""

proc initializeLinecrossInput(database: DatabaseBackend): bool =
  ## Initialize linecross with history and completion support
  try:
    # Initialize linecross with full features for good editing experience
    initLinecross(enableHistory = true, enableHistorySearch = false, moveCursorOnEnter = true)
    
    # Set up completion callback for commands and mentions
    registerCompletionCallback(nifflerCompletionCallback)
    
    # Configure prompt colors to match current blue style
    updatePromptState()
    
    # Load history from database if available
    if database != nil:
      try:
        let recentPrompts = getRecentPrompts(database, 100)
        debug(fmt"Retrieved {recentPrompts.len} prompts from database")
        for i in countdown(recentPrompts.len - 1, 0):
          let prompt = recentPrompts[i]
          addToHistory(prompt)
          debug(fmt"Added prompt {recentPrompts.len - i}: {prompt[0..min(50, prompt.len-1)]}")
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

proc flushStreamingBuffer*(redraw: bool = true) =
  ## Flush any buffered streaming content to output
  ## Use redraw=false when the caller will handle redrawing (e.g., writeCompleteLine)
  if streamingBuffer.len > 0:
    writeOutputRaw(streamingBuffer, addNewline = false, redraw = redraw)
    streamingBuffer = ""

proc shouldFlushBuffer(): bool =
  ## Determine if buffer should be flushed based on size and word boundaries
  ## Flush on whitespace to avoid breaking words mid-stream
  if streamingBuffer.len >= STREAMING_MAX_BUFFER:
    return true

  if streamingBuffer.len >= STREAMING_FLUSH_THRESHOLD:
    # Check if last character is whitespace (safe flush point)
    if streamingBuffer.len > 0:
      let lastChar = streamingBuffer[^1]
      if lastChar in {' ', '\n', '\t', '.', ',', '!', '?', ':', ';'}:
        return true

  return false

proc writeStreamingChunk*(text: string) =
  ## Write streaming content chunk - buffers and flushes on word boundaries
  streamingBuffer.add(text)
  if shouldFlushBuffer():
    flushStreamingBuffer(redraw = true)

proc writeStreamingChunkStyled*(text: string, style: ThemeStyle) =
  ## Write styled streaming content chunk - buffers and flushes on word boundaries
  let styledText = formatWithStyle(text, style)
  streamingBuffer.add(styledText)
  if shouldFlushBuffer():
    flushStreamingBuffer(redraw = true)

proc writeCompleteLine*(text: string) =
  ## Write complete line - flushes buffer first, then writes with newline
  flushStreamingBuffer(redraw = false)  # Don't redraw yet - writeOutput will do it
  writeOutput(text)

proc finishStreaming*() =
  ## Call after streaming chunks are done to flush remaining content
  flushStreamingBuffer()

proc writeUserInput*(text: string) =
  ## Write user input to scrollback with "> " prefix and theme styling
  ## Adds blank line before for separation, then writes user input
  let formattedInput = formatWithStyle(fmt"> {text}", currentTheme.userInput)
  writeOutput("\n" & formattedInput)

proc formatTokenAmount*(tokens: int): string =
  ## Format token amounts with appropriate units (0-1000, 1.0k-20.0k, 20k-999k, 1.0M+)
  if tokens < 1000:
    return $tokens
  elif tokens < 20000:
    let k = tokens.float / 1000.0
    return fmt"{k:.1f}k"
  elif tokens < 1000000:
    let k = tokens div 1000
    return fmt"{k}k"
  else:
    let m = tokens.float / 1000000.0
    return fmt"{m:.1f}M"

proc formatCostRounded*(cost: float): string =
  ## Format cost rounded to 3 decimals with no trailing zeros
  let rounded = round(cost, 3)
  if rounded == 0.0:
    return "$0"
  
  let formatted = fmt"${rounded:.3f}"
  # Remove trailing zeros after decimal point
  var finalResult = formatted
  if '.' in finalResult:
    while finalResult.endsWith("0"):
      finalResult = finalResult[0..^2]
    if finalResult.endsWith("."):
      finalResult = finalResult[0..^2]
  return finalResult

proc updateStatusLine*() =
  ## Update status line with token counts, context info, and cost
  let sessionTotal = inputTokens + outputTokens

  if sessionTotal > 0:
    # Get model config from current session or load from config
    let config = loadConfig()
    let modelConfig = if currentModelName.len > 0:
      getModelFromConfig(config, currentModelName)
    else:
      config.models[0]

    let contextMessages = conversation_manager.getConversationContext()
    let contextSize = estimateTokenCount(contextMessages)
    let maxContext = if modelConfig.context > 0: modelConfig.context else: 128000
    let statusIndicator = if isProcessing: "⚡" else: ""

    # Calculate context percentage and format max context
    let contextPercent = if maxContext > 0: min(100, (contextSize * 100) div maxContext) else: 0
    let contextInfo = fmt"{contextPercent}% of {formatTokenAmount(maxContext)}"

    # Format token amounts with new formatting
    let formattedInputTokens = formatTokenAmount(inputTokens)
    let formattedOutputTokens = formatTokenAmount(outputTokens)

    # Calculate session cost if available using real token data
    let sessionTokens = getSessionTokens()
    var sessionCost = 0.0

    if modelConfig.inputCostPerMToken.isSome() and sessionTokens.inputTokens > 0:
      let inputCostPerToken = modelConfig.inputCostPerMToken.get() / 1_000_000.0
      sessionCost += sessionTokens.inputTokens.float * inputCostPerToken

    if modelConfig.outputCostPerMToken.isSome() and sessionTokens.outputTokens > 0:
      let outputCostPerToken = modelConfig.outputCostPerMToken.get() / 1_000_000.0
      sessionCost += sessionTokens.outputTokens.float * outputCostPerToken

    let costInfo = if sessionCost > 0: fmt" {formatCostRounded(sessionCost)}" else: ""
    let statusLine = fmt"{statusIndicator}↑{formattedInputTokens} ↓{formattedOutputTokens} {contextInfo}{costInfo}"
    setStatus(@[statusLine])
    # Don't call redraw() here - let readline() handle it
  else:
    # Clear status line when no tokens yet
    clearStatus()
    # Don't call redraw() here - let readline() handle it

proc generatePrompt*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()): string =
  ## Generate a simplified prompt with model name, mode, and conversation ID
  # Get conversation info and build model name with conversation context
  let currentSession = getCurrentSession()
  let modelNameWithContext = if currentSession.isSome():
    let conv = currentSession.get().conversation
    let runtimeMode = getCurrentMode()
    fmt"{currentModelName}({runtimeMode}, {conv.id})"
  else:
    debug("generatePrompt: currentSession is None, using plain model name")
    currentModelName

  return fmt"{modelNameWithContext} > "

proc updatePromptState*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()) =
  ## Update prompt color and text based on current mode and model  
  setPromptColor(getModePromptColor(), {styleBright})
  # Note: linecross doesn't have setPrompt - prompt is set dynamically in readline() calls

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
  
  # Track that output occurred after tool call for progressive rendering
  outputAfterToolCall = true

proc resetUIState*() =
  ## Reset UI-specific state (tokens, pending tool calls) - used when switching conversations
  inputTokens = 0
  outputTokens = 0
  pendingToolCalls.clear()
  
  # Sync currentModelName with the current session's model
  let currentSession = getCurrentSession()
  if currentSession.isSome():
    let conv = currentSession.get().conversation
    currentModelName = conv.modelNickname
    debug(fmt"UI state reset: tokens/tool calls cleared, model synced to {currentModelName}")
  else:
    debug("UI state reset: tokens and pending tool calls cleared")
  
  # Update prompt color to reflect current mode (fixes conversation switching color bug)
  updatePromptState()
    
proc resetUIState*(modelName: string) =
  ## Reset UI-specific state and set specific model name (for cases with known model)
  inputTokens = 0
  outputTokens = 0
  pendingToolCalls.clear()
  
  # Update prompt color to reflect current mode (fixes conversation switching color bug)
  updatePromptState()
  currentModelName = modelName
  debug(fmt"UI state reset: tokens/tool calls cleared, model set to {modelName}")

proc updateTokenCounts*(newInputTokens: int, newOutputTokens: int) =
  ## Update token counts in central history storage
  updateSessionTokens(newInputTokens, newOutputTokens)
  # Also update UI state for prompt display
  inputTokens = newInputTokens
  outputTokens = newOutputTokens
  # Note: Status line will be updated on next prompt display

proc nifflerCustomKeyHook(keyCode: int, buffer: string): bool =
  ## Custom key hook for handling special key combinations like Shift+Tab
  if keyCode == ord(ShiftTab):
    # Toggle mode and immediately update prompt, it is refreshed by linecross
    discard toggleModeWithProtection()
    updatePromptState()
    # Update status line and generate new prompt with updated mode
    updateStatusLine()
    let newPrompt = generatePrompt()
    setPrompt(newPrompt)
    redraw()
    return true  # Key was handled
  return false  # Key not handled, continue with default processing

proc readInputWithPrompt*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()): string =
  ## Read input with prompt showing current state
  updateStatusLine()  # Just sets the status, readline() will refresh
  let prompt = generatePrompt(modelConfig)
  currentInputText = readInputLine(prompt).strip()
  return currentInputText

proc executeBashCommand(command: string, database: DatabaseBackend, currentModel: configTypes.ModelConfig, markdownEnabled: bool) =
  ## Execute a bash command directly and display the output
  try:
    let output = getCommandOutput(command, timeout = 30000)
    writeCompleteLine(formatWithStyle(fmt"$ {command}", currentTheme.toolCall))
    if output.len > 0:
      writeCompleteLine(output)

    # Store command in prompt history (bash-style history) but NOT in LLM conversation
    let fullCommand = "!" & command
    logToPromptHistory(database, fullCommand, "", currentModel.nickname)

  except ToolExecutionError as e:
    # Non-zero exit code - show command, output, and exit code
    writeCompleteLine(formatWithStyle(fmt"$ {command}", currentTheme.toolCall))
    if e.output.len > 0:
      writeCompleteLine(e.output)
    writeCompleteLine(formatWithStyle(fmt"Exit code: {e.exitCode}", currentTheme.error))

    # Store failed command in history too
    let fullCommand = "!" & command
    logToPromptHistory(database, fullCommand, "", currentModel.nickname)

  except ToolTimeoutError:
    writeCompleteLine(formatWithStyle(fmt"$ {command}", currentTheme.toolCall))
    writeCompleteLine(formatWithStyle("Command timed out after 30 seconds", currentTheme.error))
  except ToolError as e:
    writeCompleteLine(formatWithStyle(fmt"$ {command}", currentTheme.toolCall))
    writeCompleteLine(formatWithStyle(fmt"Error: {e.msg}", currentTheme.error))
  except Exception as e:
    writeCompleteLine(formatWithStyle(fmt"$ {command}", currentTheme.toolCall))
    writeCompleteLine(formatWithStyle(fmt"Unexpected error: {e.msg}", currentTheme.error))

proc startCLIMode*(session: var Session, modelConfig: configTypes.ModelConfig, database: DatabaseBackend, level: Level, dump: bool = false) =
  ## Start the CLI mode with enhanced interface

  # Load configuration to get theme settings
  let (config, markdownEnabled) = initializeSystemComponents()
  
  # Initialize enhanced input with linecross - fail if not available
  if not initializeLinecrossInput(database):
    raise newException(OSError, "Failed to initialize enhanced input")
  
  # Initialize command system
  initializeCommands()
  
  # Initialize default conversation if needed
  initializeDefaultConversation(database)
  
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
  writeCompleteLine(formatWithStyle("Welcome to Niffler!", currentTheme.success))
  writeCompleteLine("Type '/help' for help, '!command' for bash, and '/exit' or '/quit' to leave.")
  writeCompleteLine("Press Ctrl+C to stop stream display or exit.")
  
  # Initialize global state for enhanced CLI
  currentModelName = currentModel.nickname
  currentInputText = ""
  isProcessing = false
  inputTokens = 0
  outputTokens = 0
  
  initializeModeState()
  
  # Get database pool for cross-thread history sharing
  let pool = if database != nil: database.pool else: nil
  
  # Initialize default conversation and session manager
  if database != nil:
    initializeDefaultConversation(database)
    let currentSession = getCurrentSession()
    if currentSession.isSome():
      let conversationId = currentSession.get().conversation.id
      initSessionManager(pool, conversationId)
      
      # Restore model and mode from loaded conversation
      let conversation = currentSession.get().conversation
      
      # Restore mode from conversation with protection
      restoreModeWithProtection(conversation.mode)
      
      # Restore model from loaded conversation (if no model specified on command line)
      if conversation.modelNickname.len > 0 and modelConfig.nickname == config.models[0].nickname:
        # Only restore model if user didn't specify one and we're using the default
        for model in config.models:
          if model.nickname == conversation.modelNickname:
            currentModel = model
            currentModelName = model.nickname
            debug(fmt"Restored model from conversation: {model.nickname}")
            break
    else:
      # Fallback: use timestamp-based ID if no conversation system available
      initSessionManager(pool, epochTime().int)
  else:
    # No database: use timestamp-based ID for in-memory session
    initSessionManager(pool, epochTime().int)
  
  # Display final model after all conversation loading and restoration
  writeCompleteLine(formatWithStyle(fmt"Using model: {currentModel.nickname} ({currentModel.model})", currentTheme.success))

  # Update prompt color to reflect the restored mode
  updatePromptState()
  
  # Start API worker with pool
  var apiWorker = startAPIWorker(channels, level, dump, database, pool)

  # Start MCP worker with pool
  var mcpWorker = startMcpWorker(channels, level, dump, database, pool)

  # Wait for MCP ready signal
  var mcpReady = false
  while not mcpReady:
    let maybeResponse = tryReceiveMcpResponse(channels)
    if maybeResponse.isSome():
      let response = maybeResponse.get()
      if response.kind == mcrrkReady:
        mcpReady = true
        debug("MCP worker ready")
    if not mcpReady:
      sleep(10)

  # Give MCP servers time to fully initialize
  sleep(100)

  # Discover and integrate MCP tools
  mcpTools.discoverMcpTools()
  let mcpToolCount = mcpTools.getMcpToolsCount()
  if mcpToolCount > 0:
    debug(fmt("Discovered {mcpToolCount} MCP tools"))

  # Start tool worker with pool
  var toolWorker = startToolWorker(channels, level, dump, database, pool)

  # Configure API worker with initial model
  if not configureAPIWorker(currentModel):
    echo fmt"Warning: Failed to configure API worker with model {currentModel.nickname}. Check API key."
  
  # Set up custom key callback for shift-tab etc
  registerCustomKeyCallback(nifflerCustomKeyHook)  # TODO: Fix this - function may not exist

  # Interactive loop
  var running = true
  while running:
    try:
      # Read user input with dynamic prompt
      let input = readInputWithPrompt(currentModel)
      
      # Clear any completion info from previous tab operations
      clearInfo()
      
      if input.len == 0:
        continue
      
      # Handle commands using the command system
      if input.startsWith("/"):
        let (command, args) = parseCommand(input)
        if command.len > 0:
          # Show user input in scrollback
          writeUserInput(input)

          let res = executeCommand(command, args, session, currentModel)

          # Display command result with markdown if enabled
          if markdownEnabled:
            let renderedText = renderMarkdownTextCLI(res.message)
            writeCompleteLine(renderedText)
          else:
            writeCompleteLine(res.message)

          # Store command in prompt history (input only, like bash history)
          logToPromptHistory(database, input, "", currentModel.nickname)

          # Handle special commands that need additional actions
          if res.success:
            if command == "model":
              # Reconfigure API worker with new model
              currentModelName = currentModel.nickname
              if not configureAPIWorker(currentModel):
                writeCompleteLine(formatWithStyle(fmt"Warning: Failed to configure API worker with model {currentModel.nickname}. Check API key.", currentTheme.error))

          if res.shouldExit:
            running = false

          # Reset UI state if requested by command (e.g., after conversation switching)
          when compiles(res.shouldResetUI):
            if res.shouldResetUI:
              resetUIState()

          continue
        else:
          # Show user input even for invalid commands
          writeUserInput(input)
          writeCompleteLine(formatWithStyle("Invalid command format", currentTheme.error))
          continue

      # Handle bash commands with ! prefix
      if input.startsWith("!"):
        let command = input[1..^1].strip()  # Remove ! prefix and strip whitespace
        if command.len > 0:
          executeBashCommand(command, database, currentModel, markdownEnabled)
        else:
          writeCompleteLine(formatWithStyle("Empty command after '!'", currentTheme.error))
        continue
      
      # Regular message - send to API
      # Show user input in scrollback
      writeUserInput(input)

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

        # Show processing status
        isProcessing = true
        
        # Write model name in conversation area (nim-noise already showed user input)
        # Not needed since we now have it in the prompt: writeToConversationArea(fmt"{currentModel.nickname}: ", fgGreen)
        
        while not responseReceived:
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
              
              # Handle thinking content display
              if response.thinkingContent.isSome():
                let thinkingContent = response.thinkingContent.get()
                let isEncrypted = response.isEncrypted.isSome() and response.isEncrypted.get()

                if not isInThinkingBlock:
                  # Start of thinking block - show emoji prefix and set flag
                  let emojiPrefix = if isEncrypted: "🔒 " else: "🤔 "
                  let styledContent = formatWithStyle(thinkingContent, currentTheme.thinking)
                  writeStreamingChunk(emojiPrefix & styledContent)
                  isInThinkingBlock = true
                else:
                  # Continuing thinking block - just show content without emoji
                  writeStreamingChunkStyled(thinkingContent, currentTheme.thinking)

              if response.content.len > 0:
                # Add separator when transitioning from thinking to regular content
                if isInThinkingBlock:
                  finishStreaming()  # Flush thinking content first
                  writeCompleteLine("")  # Add blank line separator
                  isInThinkingBlock = false

                responseText.add(response.content)
                # Only show streaming content if markdown is disabled to prevent double rendering
                if not markdownEnabled:
                  writeStreamingChunk(response.content)
                # Track that output occurred after tool call for progressive rendering
                outputAfterToolCall = true
            of arkToolCallRequest:
              # Flush any pending thinking content before displaying tool call
              finishStreaming()

              # Display tool request immediately without hourglass
              let toolRequest = response.toolRequestInfo
              pendingToolCalls[toolRequest.toolCallId] = toolRequest

              # Reset output tracking and display tool call
              outputAfterToolCall = false
              let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
              writeCompleteLine(formattedRequest)
            of arkToolCallResult:
              # Handle tool result display - only show result line (request already displayed)
              let toolResult = response.toolResultInfo
              if pendingToolCalls.hasKey(toolResult.toolCallId):
                let formattedResult = formatCompactToolResultWithIndent(toolResult)

                # Write only the result line (request was already written)
                writeCompleteLine(formattedResult)

                # Remove from pending
                pendingToolCalls.del(toolResult.toolCallId)
              else:
                # Fallback if request wasn't tracked
                let formattedResult = formatCompactToolResult(toolResult)
                writeCompleteLine(formattedResult)
            of arkStreamComplete:
              # Apply markdown formatting to the complete response if enabled
              if markdownEnabled and responseText.len > 0:
                # For markdown mode, render the complete response since we didn't stream it
                let renderedText = renderMarkdownTextCLI(responseText)
                writeCompleteLine(renderedText)
              elif responseText.len > 0:
                # Just add final newline if no markdown was used (content was already streamed)
                writeCompleteLine("")
              else:
                # No content but we may have had streaming - redraw UI
                finishStreaming()

              # Update token counts with new response (prompt will show tokens)
              isProcessing = false
              isInThinkingBlock = false  # Reset thinking block flag when stream completes
              updateTokenCounts(response.usage.inputTokens, response.usage.outputTokens)
              # Add assistant response to history only if no tool calls were involved
              # (API worker already handles history for tool call conversations)
              if responseText.len > 0 and not hadToolCalls:
                debug("DEBUG: Adding assistant message to history (no tool calls detected)")
                discard addAssistantMessage(responseText, none(seq[LLMToolCall]), response.usage.outputTokens, currentModel.model)
              elif hadToolCalls:
                debug("DEBUG: Skipping assistant message addition - tool calls already handled by API worker")
              
              # Log user input to prompt history (bash-style history)
              logToPromptHistory(database, input, "", currentModel.nickname)
              responseReceived = true
              when defined(posix):
                currentActiveRequestId = ""
            of arkStreamError:
              writeCompleteLine(formatWithStyle(fmt"Error: {response.error}", currentTheme.error))
              isProcessing = false
              isInThinkingBlock = false  # Reset thinking block flag on error
              responseReceived = true
              when defined(posix):
                currentActiveRequestId = ""
            of arkReady:
              discard  # Just ignore ready responses

          if not responseReceived:
            sleep(5)

        if not responseReceived:
          writeCompleteLine(formatWithStyle("Timeout waiting for response", currentTheme.error))
          isProcessing = false
          when defined(posix):
            currentActiveRequestId = ""
      else:
        writeCompleteLine(formatWithStyle("Failed to send message", currentTheme.error))
    except EOFError:
      # Handle Ctrl+C, Ctrl+D gracefully
      running = false

  # Cleanup
  cleanupSystem(channels, apiWorker, toolWorker, mcpWorker, database)

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
    let consoleLogger = newConsoleLogger(useStderr = true)
    addHandler(consoleLogger)
  
  setLogFilter(level)
  initThreadSafeChannels()
  initDumpFlag()
  setDumpEnabled(dump)
  
  # Initialize database
  let database = initializeGlobalDatabase(level)
  
  # Load config and check if markdown rendering is enabled
  let (_, markdownEnabled) = initializeSystemComponents()
  
  # Get database pool for cross-thread history sharing
  let pool = if database != nil: database.pool else: nil
  
  # Initialize session manager with pool (no database for single prompts)
  initSessionManager(pool, epochTime().int)
  
  let channels = getChannels()

  # Start API worker with pool
  var apiWorker = startAPIWorker(channels, level, dump, database, pool)

  # Start MCP worker with pool
  var mcpWorker = startMcpWorker(channels, level, dump, database, pool)

  # Wait for MCP ready signal
  var mcpReady = false
  while not mcpReady:
    let maybeResponse = tryReceiveMcpResponse(channels)
    if maybeResponse.isSome():
      let response = maybeResponse.get()
      if response.kind == mcrrkReady:
        mcpReady = true
    if not mcpReady:
      sleep(10)

  # Discover MCP tools
  mcpTools.discoverMcpTools()

  # Start tool worker with pool
  var toolWorker = startToolWorker(channels, level, dump, database, pool)

  let (success, requestId) = sendSinglePromptAsyncWithId(text, model)
  if success:
    debug "Request sent, waiting for response..."
    
    # Wait for response with timeout
    var responseReceived = false
    var responseText = ""
    
    while not responseReceived:
      var response: APIResponse
      if tryReceiveAPIResponse(channels, response):
        # Validate that this response belongs to our current request
        if response.requestId != requestId:
          debug(fmt"Ignoring response from request {response.requestId} (current: {requestId})")
          continue  # Skip processing this response
        
        case response.kind:
        of arkStreamChunk:
          # Handle thinking content display
          if response.thinkingContent.isSome():
            let thinkingContent = response.thinkingContent.get()
            let isEncrypted = response.isEncrypted.isSome() and response.isEncrypted.get()

            if not isInThinkingBlock:
              # Start of thinking block - show emoji prefix and set flag
              let emojiPrefix = if isEncrypted: "🔒 " else: "🤔 "
              let styledContent = formatWithStyle(thinkingContent, currentTheme.thinking)
              writeStreamingChunk(emojiPrefix & styledContent)
              isInThinkingBlock = true
            else:
              # Continuing thinking block - just show content without emoji
              writeStreamingChunkStyled(thinkingContent, currentTheme.thinking)

          if response.content.len > 0:
            # Add separator when transitioning from thinking to regular content
            if isInThinkingBlock:
              writeCompleteLine("\n")
              isInThinkingBlock = false

            responseText.add(response.content)
            # Only show streaming content if markdown is disabled to prevent double rendering
            if not markdownEnabled:
              writeStreamingChunk(response.content)
            # Track that output occurred after tool call for progressive rendering
            outputAfterToolCall = true
        of arkStreamComplete:
          # Apply markdown formatting to the complete response if enabled
          if markdownEnabled and responseText.len > 0:
            # For markdown mode, render the complete response since we didn't stream it
            let renderedText = renderMarkdownTextCLI(responseText)
            writeCompleteLine(renderedText)
          elif responseText.len > 0:
            # Just add final newline if no markdown was used (content was already streamed)
            writeCompleteLine("")
          else:
            # No content but we may have had streaming - redraw UI
            finishStreaming()
          info fmt"Tokens used: {response.usage.totalTokens}"
          
          # Log the prompt exchange to database
          if responseText.len > 0:
            let config = loadConfig()
            let selectedModel = if model.len > 0:
              getModelFromConfig(config, model)
            else:
              config.models[0]
            logToPromptHistory(database, text, responseText, selectedModel.nickname)
          
          isInThinkingBlock = false  # Reset thinking block flag when stream completes
          responseReceived = true
        of arkStreamError:
          writeCompleteLine(formatWithStyle(fmt"Error: {response.error}", currentTheme.error))
          isInThinkingBlock = false  # Reset thinking block flag on error
          responseReceived = true
        of arkToolCallRequest:
          # Display tool request immediately with hourglass indicator
          let toolRequest = response.toolRequestInfo
          pendingToolCalls[toolRequest.toolCallId] = toolRequest

          # Reset output tracking and display tool call with hourglass
          outputAfterToolCall = false
          let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
          writeCompleteLine(formattedRequest & " ⏳")
        of arkToolCallResult:
          # Handle tool result display - always show complete request + result
          let toolResult = response.toolResultInfo
          if pendingToolCalls.hasKey(toolResult.toolCallId):
            let toolRequest = pendingToolCalls[toolResult.toolCallId]
            let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
            let formattedResult = formatCompactToolResultWithIndent(toolResult)

            # Write complete tool call and result
            writeCompleteLine(formattedRequest)
            writeCompleteLine(formattedResult)

            # Remove from pending
            pendingToolCalls.del(toolResult.toolCallId)
          else:
            # Fallback if request wasn't tracked
            let formattedResult = formatCompactToolResult(toolResult)
            writeCompleteLine(formattedResult)
        of arkReady:
          discard  # Just ignore ready responses
      
      if not responseReceived:
        sleep(5)
  else:
    echo "Failed to send request"

  # Cleanup
  cleanupSystem(channels, apiWorker, toolWorker, mcpWorker, database)

  # Linecross cleanup is automatic