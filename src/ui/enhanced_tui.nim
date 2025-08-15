## Enhanced Terminal UI with TUI-style widgets
##
## This module provides an enhanced terminal user interface inspired by tui_widget,
## featuring a cleaner widget-like approach with improved layout and event handling.
##
## Key Features:
## - Clean widget-style interface using illwill
## - Streaming response support
## - Improved input handling
## - Better visual layout
## - Event-driven architecture

import std/[strformat, os, logging, strutils, deques]
when defined(posix):
  import posix
import illwill
import ../core/[app, channels, history, config]
import ../types/[config as configTypes, messages]
import ../api/api
import ../tools/worker

type
  TUIApp* = object
    terminalBuffer: TerminalBuffer
    width: int
    height: int
    currentPrompt: string
    cursorX: int
    promptHistory: Deque[string]
    historyIndex: int
    currentModel: configTypes.ModelConfig
    responseLines: seq[string]
    scrollOffset: int
    inputBoxHeight: int
    statusHeight: int
    waitingForResponse: bool
    currentResponseText: string

var app: TUIApp
var globalChannels: ptr ThreadChannels = nil
var globalAPIWorker: APIWorker
var globalToolWorker: ToolWorker

proc getUserName(): string =
  ## Get the current user's name
  result = getEnv("USER", getEnv("USERNAME", "User"))

proc initializeAppSystems(level: Level, dump: bool) =
  ## Initialize common app systems
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(level)
  initThreadSafeChannels()
  initHistoryManager()

proc initTUIApp() =
  ## Initialize the TUI application
  when defined(posix):
    if isatty(stdin.getFileHandle()) == 0:
      raise newException(OSError, "TUI requires an interactive terminal")
  
  illwillInit(fullscreen = false)
  app.terminalBuffer = newTerminalBuffer(terminalWidth(), terminalHeight())
  app.width = terminalWidth()
  app.height = terminalHeight()
  app.currentPrompt = ""
  app.cursorX = 0
  app.promptHistory = initDeque[string]()
  app.historyIndex = -1
  app.responseLines = @[]
  app.scrollOffset = 0
  app.inputBoxHeight = 3
  app.statusHeight = 1
  app.waitingForResponse = false
  app.currentResponseText = ""

proc cleanupTUIApp() =
  ## Clean up the TUI application
  illwillDeinit()
  showCursor()

proc addResponseLine(line: string) =
  ## Add a line to the response display
  app.responseLines.add(line)
  
  # Auto-scroll to show latest content
  let maxDisplayLines = app.height - app.inputBoxHeight - app.statusHeight - 3
  if app.responseLines.len > maxDisplayLines:
    app.scrollOffset = app.responseLines.len - maxDisplayLines

proc renderInputBox() =
  ## Render the input box at the bottom
  let inputY = app.height - app.inputBoxHeight - app.statusHeight
  
  # Clear input area
  app.terminalBuffer.fill(0, inputY, app.width-1, inputY + app.inputBoxHeight - 1, " ")
  
  # Draw border
  app.terminalBuffer.fill(0, inputY, app.width-1, inputY, "─")
  app.terminalBuffer.write(0, inputY, "┌", fgWhite)
  app.terminalBuffer.write(app.width-1, inputY, "┐", fgWhite)
  
  for i in 1..<app.inputBoxHeight-1:
    app.terminalBuffer.write(0, inputY + i, "│", fgWhite)
    app.terminalBuffer.write(app.width-1, inputY + i, "│", fgWhite)
  
  app.terminalBuffer.fill(0, inputY + app.inputBoxHeight - 1, app.width-1, inputY + app.inputBoxHeight - 1, "─")
  app.terminalBuffer.write(0, inputY + app.inputBoxHeight - 1, "└", fgWhite)
  app.terminalBuffer.write(app.width-1, inputY + app.inputBoxHeight - 1, "┘", fgWhite)
  
  # Render prompt and input
  let promptPrefix = "> "
  let maxInputWidth = app.width - 4 - promptPrefix.len
  let displayPrompt = if app.currentPrompt.len > maxInputWidth: 
    app.currentPrompt[0..<maxInputWidth] & "…"
  else: 
    app.currentPrompt
  
  app.terminalBuffer.write(2, inputY + 1, promptPrefix, fgGreen, styleBright)
  app.terminalBuffer.write(2 + promptPrefix.len, inputY + 1, displayPrompt, fgWhite)
  
  # Position cursor
  let cursorXPos = 2 + promptPrefix.len + app.cursorX
  app.terminalBuffer.setCursorPos(min(cursorXPos, app.width-2), inputY + 1)

proc renderResponseArea() =
  ## Render the response display area
  let maxY = app.height - app.inputBoxHeight - app.statusHeight - 2
  let startY = 1
  let maxDisplayLines = maxY - startY
  
  # Clear response area
  app.terminalBuffer.fill(0, startY, app.width-1, maxY, " ")
  
  # Display response lines with scrolling
  let startIdx = app.scrollOffset
  let endIdx = min(app.responseLines.len, startIdx + maxDisplayLines)
  
  for i in startIdx..<endIdx:
    let y = startY + (i - startIdx)
    let line = app.responseLines[i]
    app.terminalBuffer.write(0, y, line, fgWhite)

proc renderStatusBar() =
  ## Render the status bar at the bottom
  let statusY = app.height - 1
  
  # Clear status line
  app.terminalBuffer.fill(0, statusY, app.width-1, statusY, " ")
  
  # Left side: connection status
  let statusText = if app.waitingForResponse: "Processing..." else: "Ready"
  app.terminalBuffer.write(0, statusY, statusText, if app.waitingForResponse: fgYellow else: fgGreen)
  
  # Right side: model info
  let modelInfo = fmt"Model: {app.currentModel.nickname}"
  let rightStartX = app.width - modelInfo.len - 1
  if rightStartX > statusText.len + 5:
    app.terminalBuffer.write(rightStartX, statusY, modelInfo, fgCyan)

proc renderTitleBar() =
  ## Render the title bar at the top
  app.terminalBuffer.fill(0, 0, app.width-1, 0, "─")
  let title = " Niffler AI Assistant "
  let titleX = (app.width - title.len) div 2
  app.terminalBuffer.write(titleX, 0, title, fgWhite, styleBright)
  
  # Add helpful hints
  let hint = " Ctrl+C=exit "
  if app.width > title.len + hint.len + 10:
    app.terminalBuffer.write(app.width - hint.len - 1, 0, hint, fgYellow, styleDim)

proc redrawScreen() =
  ## Redraw the entire screen
  app.terminalBuffer.clear()
  renderTitleBar()
  renderResponseArea()
  renderInputBox()
  renderStatusBar()
  app.terminalBuffer.display()

proc handleAPIResponses() =
  ## Check for and handle streaming API responses
  if not app.waitingForResponse or globalChannels == nil:
    return
  
  var response: APIResponse
  if tryReceiveAPIResponse(globalChannels, response):
    case response.kind:
    of arkStreamChunk:
      if response.content.len > 0:
        # Split content into lines and add to response display
        let lines = response.content.split('\n')
        if lines.len > 0:
          # Update the last line (append to current line)
          if app.responseLines.len > 0:
            app.responseLines[^1].add(lines[0])
          else:
            app.responseLines.add(lines[0])
          
          # Add any additional lines
          for i in 1..<lines.len:
            app.responseLines.add(lines[i])
        
        app.currentResponseText.add(response.content)
    of arkStreamComplete:
      app.waitingForResponse = false
      
      # Add assistant response to history
      if app.currentResponseText.len > 0:
        discard addAssistantMessage(app.currentResponseText)
      
      # Add token usage info
      addResponseLine("")
      addResponseLine(fmt"[{response.usage.totalTokens} tokens]")
      addResponseLine("")
    of arkStreamError:
      addResponseLine(fmt"Error: {response.error}")
      addResponseLine("")
      app.waitingForResponse = false
    of arkReady:
      discard

proc sendPromptToAPI(promptText: string) =
  ## Send a prompt to the API worker
  if globalChannels == nil:
    addResponseLine("Error: API not initialized")
    return
  
  debug(fmt"Sending prompt: {promptText}")
  
  # Add user message to display
  let userName = getUserName()
  addResponseLine(fmt"{userName}: {promptText}")
  addResponseLine(fmt"{app.currentModel.nickname}: ")
  
  if sendSinglePromptInteractive(promptText, app.currentModel):
    app.waitingForResponse = true
    app.currentResponseText = ""
  else:
    addResponseLine("Failed to send request")

proc handleKeypress(key: Key): bool =
  ## Handle keypress events, return false to exit
  case key:
  of Key.None:
    return true
  of Key.Escape, Key.CtrlC:
    return false
  of Key.Enter:
    # Send prompt if there's content
    let promptText = app.currentPrompt.strip()
    if promptText.len > 0:
      # Add to history
      app.promptHistory.addLast(promptText)
      if app.promptHistory.len > 100:
        app.promptHistory.popFirst()
      
      # Send prompt and clear input
      sendPromptToAPI(promptText)
      app.currentPrompt = ""
      app.cursorX = 0
      app.historyIndex = -1
  of Key.Backspace:
    if app.cursorX > 0:
      app.currentPrompt.delete(app.cursorX - 1..app.cursorX - 1)
      app.cursorX -= 1
  of Key.Delete:
    if app.cursorX < app.currentPrompt.len:
      app.currentPrompt.delete(app.cursorX..app.cursorX)
  of Key.Left:
    if app.cursorX > 0:
      app.cursorX -= 1
  of Key.Right:
    if app.cursorX < app.currentPrompt.len:
      app.cursorX += 1
  of Key.Up:
    if app.promptHistory.len > 0:
      if app.historyIndex == -1:
        app.historyIndex = app.promptHistory.len - 1
      elif app.historyIndex > 0:
        app.historyIndex -= 1
      
      app.currentPrompt = app.promptHistory[app.historyIndex]
      app.cursorX = app.currentPrompt.len
  of Key.Down:
    if app.historyIndex >= 0:
      if app.historyIndex < app.promptHistory.len - 1:
        app.historyIndex += 1
        app.currentPrompt = app.promptHistory[app.historyIndex]
      else:
        app.historyIndex = -1
        app.currentPrompt = ""
      app.cursorX = app.currentPrompt.len
  of Key.Home:
    app.cursorX = 0
  of Key.End:
    app.cursorX = app.currentPrompt.len
  else:
    # Handle regular character input
    let ch = char(ord(key))
    if ch >= ' ' and ch <= '~':
      app.currentPrompt.insert($ch, app.cursorX)
      app.cursorX += 1
  
  return true

proc startEnhancedTUIMode*(model: string = "", level: Level, dump: bool = false) =
  ## Start the enhanced TUI interface
  try:
    # Initialize app systems
    initializeAppSystems(level, dump)
    let channels = getChannels()
    globalChannels = channels
    let config = loadConfig()
    
    # Select initial model
    app.currentModel = if model.len > 0:
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
        echo "Error: No models configured. Please run 'niffler init' first."
        return
    
    # Start workers
    globalAPIWorker = startAPIWorker(channels, level, dump)
    globalToolWorker = startToolWorker(channels, level, dump)
    
    # Configure API worker with initial model
    if not configureAPIWorker(app.currentModel):
      echo fmt"Warning: Failed to configure API worker with model {app.currentModel.nickname}. Check API key."
    
    # Initialize TUI
    initTUIApp()
    
    # Add welcome message
    addResponseLine(fmt"Welcome to Niffler!")
    addResponseLine("")
    addResponseLine(fmt"Connected to: {app.currentModel.nickname} ({app.currentModel.model})")
    addResponseLine("")
    addResponseLine("Type your messages below and press Enter to send.")
    addResponseLine("Press Ctrl+C or ESC to exit. Use arrow keys for history.")
    addResponseLine("")
    
    # Set up signal handlers for clean exit
    proc exitProc() {.noconv.} =
      cleanupTUIApp()
      quit(0)
    setControlCHook(exitProc)
    
    # Main UI loop
    var running = true
    while running:
      try:
        # Handle any pending API responses first
        handleAPIResponses()
        
        # Redraw screen
        redrawScreen()
        
        # Handle keyboard input
        let key = getKey()
        running = handleKeypress(key)
        
        # Small delay to prevent excessive CPU usage
        sleep(16)  # ~60 FPS
      except Exception as e:
        debug(fmt"Error in main UI loop: {e.msg}")
        running = false
        raise e
    
  except Exception as e:
    error(fmt"Failed to start enhanced TUI mode: {e.msg}")
    raise e
  finally:
    # Cleanup workers
    if globalChannels != nil:
      signalShutdown(globalChannels)
      stopAPIWorker(globalAPIWorker)
      stopToolWorker(globalToolWorker)
      closeChannels(globalChannels[])
    cleanupTUIApp()