## Enhanced Terminal UI with Illwill
##
## This module provides an enhanced terminal user interface using the illwill library,
## featuring a prompt box at the bottom, status indicators, and improved visual layout.
##
## Key Features:
## - Prompt box at bottom of screen with cursor and input handling
## - Fixed status indicators below prompt (model, token counts, connection status)
## - Arrow key history navigation (up/down through previous prompts)
## - Real-time streaming response display with proper text wrapping
## - Colored output and syntax highlighting
## - @ referencing system for context inclusion (future)
##
## Design Decisions:
## - Uses illwill for cross-platform terminal control
## - Maintains compatibility with existing message types and API
## - Separates input handling from response display
## - Thread-safe UI updates for streaming responses

import std/[strutils, strformat, os, logging, deques, re]
when defined(posix):
  import posix
import illwill
import ../core/[app, channels, history, config]
import ../types/[config as configTypes]
import ../api/api

type
  EnhancedUI* = object
    terminalBuffer: TerminalBuffer
    width: int
    height: int
    currentPrompt: string
    promptLines: seq[string]  # Multi-line prompt support
    cursorX: int  # Cursor X position within current line
    cursorY: int  # Cursor Y position (line number)
    promptHistory: Deque[string]
    historyIndex: int
    currentModel: configTypes.ModelConfig
    connectionStatus: string
    tokenCount: int
    responseLines: seq[string]
    scrollOffset: int
    editBoxHeight: int  # Height of the edit box
    autoAcceptEdits: bool  # Toggle for auto-accept mode

var ui: EnhancedUI
var globalChannels: ptr ThreadChannels = nil
var globalModel: configTypes.ModelConfig

proc initializeAppSystems(level: Level, dump: bool) =
  ## Initialize common app systems
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(level)
  initThreadSafeChannels()
  initHistoryManager()

proc initEnhancedUI*() =
  ## Initialize the enhanced terminal UI
  # Check if we have a proper terminal
  when defined(posix):
    if isatty(stdin.getFileHandle()) == 0:
      raise newException(OSError, "Enhanced UI requires an interactive terminal")
  
  illwillInit(fullscreen = false)
  ui.terminalBuffer = newTerminalBuffer(terminalWidth(), terminalHeight())
  ui.width = terminalWidth()
  ui.height = terminalHeight()
  ui.currentPrompt = ""
  ui.promptLines = @[""]  # Start with one empty line
  ui.cursorX = 0
  ui.cursorY = 0
  ui.promptHistory = initDeque[string]()
  ui.historyIndex = -1
  ui.connectionStatus = "Disconnected"
  ui.tokenCount = 0
  ui.responseLines = @[]
  ui.scrollOffset = 0
  ui.editBoxHeight = 4  # Default height for edit box (similar to Claude Code)
  ui.autoAcceptEdits = false

  # Set up signal handlers for clean exit
  proc exitProc() {.noconv.} =
    illwillDeinit()
    showCursor()
    quit(0)
  setControlCHook(exitProc)

proc cleanupEnhancedUI*() =
  ## Clean up the enhanced terminal UI
  illwillDeinit()
  showCursor()

proc updateStatusBar() =
  ## Update the status bar below the edit box
  let statusY = ui.height - 1
  
  # Clear status line
  ui.terminalBuffer.fill(0, statusY, ui.width-1, statusY, " ")
  
  # Left side: auto-accept toggle indicator
  let autoAcceptText = if ui.autoAcceptEdits: ">> auto-accept edits on" else: ">> auto-accept edits off"
  let toggleHint = " (tab to cycle)"
  ui.terminalBuffer.write(0, statusY, autoAcceptText, 
    if ui.autoAcceptEdits: fgGreen else: fgYellow)
  ui.terminalBuffer.write(autoAcceptText.len, statusY, toggleHint, fgWhite, styleDim)
  
  # Right side: usage information and model
  let usageInfo = fmt"Tokens: {ui.tokenCount}"
  let modelInfo = fmt"Model: {ui.currentModel.nickname}"
  let rightText = fmt"{usageInfo} | {modelInfo}"
  let rightStartX = ui.width - rightText.len - 2
  if rightStartX > autoAcceptText.len + toggleHint.len + 5:
    ui.terminalBuffer.write(rightStartX, statusY, rightText, fgCyan)

proc updateEditBox() =
  ## Update the multi-line edit box
  let editBoxStartY = ui.height - ui.editBoxHeight - 2  # Leave space for status bar
  
  # Clear edit box area
  ui.terminalBuffer.fill(0, editBoxStartY, ui.width-1, ui.height - 2, " ")
  
  # Draw top border
  ui.terminalBuffer.fill(0, editBoxStartY, ui.width-1, editBoxStartY, "─")
  ui.terminalBuffer.write(0, editBoxStartY, "┌", fgWhite)
  ui.terminalBuffer.write(ui.width-1, editBoxStartY, "┐", fgWhite)
  
  # Draw side borders and content
  for i in 0..<ui.editBoxHeight:
    let y = editBoxStartY + 1 + i
    ui.terminalBuffer.write(0, y, "│", fgWhite)
    ui.terminalBuffer.write(ui.width-1, y, "│", fgWhite)
    
    # Display prompt line if it exists
    if i < ui.promptLines.len:
      let line = ui.promptLines[i]
      let prefix = if i == 0: "> " else: "  "
      let prefixColor = if i == 0: fgGreen else: fgWhite
      let maxLineWidth = ui.width - 6  # Account for borders, prefix, and padding
      let displayLine = if line.len > maxLineWidth: 
        line[0..<maxLineWidth] & "…"
      else: 
        line
      
      ui.terminalBuffer.write(2, y, prefix, prefixColor, styleBright)
      ui.terminalBuffer.write(2 + prefix.len, y, displayLine, fgWhite)
      
      # Show line continuation indicator for long lines
      if line.len > maxLineWidth:
        ui.terminalBuffer.write(ui.width - 3, y, "…", fgYellow, styleDim)
  
  # Draw bottom border
  let bottomY = editBoxStartY + ui.editBoxHeight + 1
  ui.terminalBuffer.fill(0, bottomY, ui.width-1, bottomY, "─")
  ui.terminalBuffer.write(0, bottomY, "└", fgWhite)
  ui.terminalBuffer.write(ui.width-1, bottomY, "┘", fgWhite)
  
  # Position cursor
  let cursorYPos = editBoxStartY + 1 + ui.cursorY
  let prefix = if ui.cursorY == 0: "> " else: "  "
  let cursorXPos = 2 + prefix.len + ui.cursorX
  ui.terminalBuffer.setCursorPos(min(cursorXPos, ui.width-2), cursorYPos)

proc addResponseLine(line: string) =
  ## Add a line to the response display
  ui.responseLines.add(line)
  
  # Auto-scroll to show latest content
  let maxDisplayLines = ui.height - ui.editBoxHeight - 4  # Leave space for edit box and status
  if ui.responseLines.len > maxDisplayLines:
    ui.scrollOffset = ui.responseLines.len - maxDisplayLines

proc renderInlineMarkdown(line: string, x: int, y: int) =
  ## Render inline markdown formatting (bold, italic, code, links)
  var currentX = x
  let maxX = ui.width - 1
  var i = 0
  
  while i < line.len and currentX < maxX:
    if i + 1 < line.len and line[i..i+1] == "**":
      # Bold text
      let endPos = line.find("**", i + 2)
      if endPos != -1:
        let boldText = line[i+2..<endPos]
        ui.terminalBuffer.write(currentX, y, boldText, fgWhite, styleBright)
        currentX += boldText.len
        i = endPos + 2
        continue
    elif i + 0 < line.len and line[i] == '*':
      # Italic text
      let endPos = line.find("*", i + 1)
      if endPos != -1:
        let italicText = line[i+1..<endPos]
        ui.terminalBuffer.write(currentX, y, italicText, fgCyan)
        currentX += italicText.len  
        i = endPos + 1
        continue
    elif i + 0 < line.len and line[i] == '`':
      # Inline code
      let endPos = line.find("`", i + 1)
      if endPos != -1:
        let codeText = line[i+1..<endPos]
        ui.terminalBuffer.write(currentX, y, codeText, fgGreen, styleDim)
        currentX += codeText.len
        i = endPos + 1
        continue
    elif i + 0 < line.len and line[i] == '[':
      # Links [text](url) - just show the text part
      let closePos = line.find("]", i + 1)
      if closePos != -1 and closePos + 1 < line.len and line[closePos + 1] == '(':
        let urlEnd = line.find(")", closePos + 2)
        if urlEnd != -1:
          let linkText = line[i+1..<closePos]
          ui.terminalBuffer.write(currentX, y, linkText, fgBlue)
          currentX += linkText.len
          i = urlEnd + 1
          continue
    
    # Regular character
    if currentX < maxX:
      ui.terminalBuffer.write(currentX, y, $line[i], fgWhite)
      currentX += 1
    i += 1

proc renderMarkdownLine(line: string, x: int, y: int) =
  ## Render a line with markdown formatting
  var currentX = x
  let maxX = ui.width - 1
  
  if currentX >= maxX:
    return
  
  # Handle different markdown elements
  if line.startsWith("# "):
    # H1 - Large yellow header
    ui.terminalBuffer.write(currentX, y, "█ " & line[2..^1], fgYellow, styleBright)
  elif line.startsWith("## "):
    # H2 - Medium yellow header  
    ui.terminalBuffer.write(currentX, y, "▐ " & line[3..^1], fgYellow)
  elif line.startsWith("### "):
    # H3 - Small yellow header
    ui.terminalBuffer.write(currentX, y, "▌ " & line[4..^1], fgYellow, styleDim)
  elif line.startsWith("```"):
    # Code block delimiter
    ui.terminalBuffer.write(currentX, y, line, fgCyan, styleDim)
  elif line.startsWith("- ") or line.startsWith("* "):
    # Bullet lists
    ui.terminalBuffer.write(currentX, y, "• " & line[2..^1], fgWhite)
  elif line.contains(re"^\d+\. "):
    # Numbered lists  
    ui.terminalBuffer.write(currentX, y, line, fgWhite)
  else:
    # Regular text with inline formatting
    renderInlineMarkdown(line, currentX, y)

proc updateResponseArea() =
  ## Update the response display area
  let maxY = ui.height - ui.editBoxHeight - 3  # Leave space for edit box and status
  let startY = 1
  let maxDisplayLines = maxY - startY
  
  # Clear response area
  ui.terminalBuffer.fill(0, startY, ui.width-1, maxY, " ")
  
  # Display response lines with scrolling
  let startIdx = ui.scrollOffset
  let endIdx = min(ui.responseLines.len, startIdx + maxDisplayLines)
  
  for i in startIdx..<endIdx:
    let y = startY + (i - startIdx)
    let line = ui.responseLines[i]
    
    # Enhanced markdown rendering
    renderMarkdownLine(line, 0, y)

proc redrawScreen() =
  ## Redraw the entire screen
  ui.terminalBuffer.clear()
  
  # Draw title bar
  ui.terminalBuffer.fill(0, 0, ui.width-1, 0, "─")
  let title = fmt" Niffler - AI Assistant "
  let titleX = (ui.width - title.len) div 2
  ui.terminalBuffer.write(titleX, 0, title, fgWhite, styleBright)
  
  # Add helpful hints on the right side of title bar
  let hint = " Ctrl+C=exit "
  if ui.width > title.len + hint.len + 10:
    ui.terminalBuffer.write(ui.width - hint.len - 1, 0, hint, fgYellow, styleDim)
  
  updateResponseArea()
  updateEditBox()
  updateStatusBar()
  
  ui.terminalBuffer.display()

proc joinPromptLines(): string =
  ## Join all prompt lines into a single string
  return ui.promptLines.join("\n")

proc clearPrompt() =
  ## Clear the current prompt
  ui.promptLines = @[""]
  ui.cursorX = 0
  ui.cursorY = 0
  ui.currentPrompt = ""

proc ensureCursorValid() =
  ## Ensure cursor position is valid
  if ui.cursorY >= ui.promptLines.len:
    ui.cursorY = ui.promptLines.len - 1
  if ui.cursorY < 0:
    ui.cursorY = 0
  if ui.cursorX > ui.promptLines[ui.cursorY].len:
    ui.cursorX = ui.promptLines[ui.cursorY].len
  if ui.cursorX < 0:
    ui.cursorX = 0

proc sendPromptToAPI(promptText: string) =
  ## Send a prompt to the API worker and handle streaming response
  if globalChannels == nil:
    addResponseLine("Error: API not initialized")
    return
  
  ui.connectionStatus = "Sending..."
  
  # Send the prompt using the same logic as in app.nim
  if sendSinglePromptInteractive(promptText, globalModel):
    addResponseLine("Assistant: (Processing...)")
    ui.connectionStatus = "Receiving..."
    
    # Check for streaming responses
    # This is a simplified version - in a real implementation we'd need
    # proper threading to handle streaming responses
    ui.connectionStatus = "Connected"
  else:
    addResponseLine("Error: Failed to send prompt")
    ui.connectionStatus = "Error"

proc handleKeypress(key: illwill.Key): bool =
  ## Handle keypress events, return false to exit
  case key:
  of illwill.Key.None:
    return true

  of illwill.Key.Escape, illwill.Key.CtrlC:
    return false
    
  of illwill.Key.Enter:
    # For multi-line input: Enter creates new line, Ctrl+Enter sends
    # But if only one line with content, Enter sends
    let promptText = joinPromptLines().strip()
    let hasContent = promptText.len > 0
    let isSingleLine = ui.promptLines.len == 1
    
    # Send if it's a single line with content or if we're in auto-accept mode
    if (hasContent and isSingleLine) or ui.autoAcceptEdits:
      if hasContent:
        # Add to history
        ui.promptHistory.addLast(promptText)
        if ui.promptHistory.len > 100:  # Limit history size
          ui.promptHistory.popFirst()
        
        # Process the prompt
        addResponseLine(fmt"You: {promptText}")
        
        # Clear prompt first for better UX
        clearPrompt()
        ui.historyIndex = -1
        
        # Send to API worker
        sendPromptToAPI(promptText)
    else:
      # Insert new line
      let currentLine = ui.promptLines[ui.cursorY]
      let leftPart = if ui.cursorX > 0: currentLine[0..<ui.cursorX] else: ""
      let rightPart = if ui.cursorX < currentLine.len: currentLine[ui.cursorX..^1] else: ""
      
      ui.promptLines[ui.cursorY] = leftPart
      ui.promptLines.insert(rightPart, ui.cursorY + 1)
      ui.cursorY += 1
      ui.cursorX = 0
      
      # Ensure we don't exceed edit box height
      if ui.promptLines.len > ui.editBoxHeight:
        ui.promptLines.delete(0)
        ui.cursorY -= 1
    
  of illwill.Key.Backspace:
    if ui.cursorX > 0:
      # Delete character to the left
      ui.promptLines[ui.cursorY].delete(ui.cursorX - 1..ui.cursorX - 1)
      ui.cursorX -= 1
    elif ui.cursorY > 0:
      # Join with previous line
      ui.cursorX = ui.promptLines[ui.cursorY - 1].len
      ui.promptLines[ui.cursorY - 1].add(ui.promptLines[ui.cursorY])
      ui.promptLines.delete(ui.cursorY)
      ui.cursorY -= 1
      
  of illwill.Key.Delete:
    if ui.cursorX < ui.promptLines[ui.cursorY].len:
      ui.promptLines[ui.cursorY].delete(ui.cursorX..ui.cursorX)
    elif ui.cursorY < ui.promptLines.len - 1:
      # Join with next line
      ui.promptLines[ui.cursorY].add(ui.promptLines[ui.cursorY + 1])
      ui.promptLines.delete(ui.cursorY + 1)
      
  of illwill.Key.Left:
    if ui.cursorX > 0:
      ui.cursorX -= 1
    elif ui.cursorY > 0:
      ui.cursorY -= 1
      ui.cursorX = ui.promptLines[ui.cursorY].len
      
  of illwill.Key.Right:
    if ui.cursorX < ui.promptLines[ui.cursorY].len:
      ui.cursorX += 1
    elif ui.cursorY < ui.promptLines.len - 1:
      ui.cursorY += 1
      ui.cursorX = 0
      
  of illwill.Key.Up:
    if ui.cursorY > 0:
      ui.cursorY -= 1
      ensureCursorValid()
    elif ui.promptHistory.len > 0:
      # Navigate up in history
      if ui.historyIndex == -1:
        ui.historyIndex = ui.promptHistory.len - 1
      elif ui.historyIndex > 0:
        ui.historyIndex -= 1
      
      let historyText = ui.promptHistory[ui.historyIndex]
      ui.promptLines = historyText.split("\n")
      ui.cursorY = ui.promptLines.len - 1
      ui.cursorX = ui.promptLines[ui.cursorY].len
      
  of illwill.Key.Down:
    if ui.cursorY < ui.promptLines.len - 1:
      ui.cursorY += 1
      ensureCursorValid()
    elif ui.historyIndex >= 0:
      # Navigate down in history
      if ui.historyIndex < ui.promptHistory.len - 1:
        ui.historyIndex += 1
        let historyText = ui.promptHistory[ui.historyIndex]
        ui.promptLines = historyText.split("\n")
      else:
        ui.historyIndex = -1
        clearPrompt()
      ui.cursorY = ui.promptLines.len - 1
      ui.cursorX = ui.promptLines[ui.cursorY].len
      
  of illwill.Key.Home:
    ui.cursorX = 0
    
  of illwill.Key.End:
    ui.cursorX = ui.promptLines[ui.cursorY].len
    
  of illwill.Key.Tab:
    # Toggle auto-accept edits (tab to cycle)
    ui.autoAcceptEdits = not ui.autoAcceptEdits
    
  else:
    # Handle regular character input
    let ch = char(ord(key))
    if ch >= ' ' and ch <= '~':
      ui.promptLines[ui.cursorY].insert($ch, ui.cursorX)
      ui.cursorX += 1
      
  ensureCursorValid()
  return true

proc updateConnectionStatus*(status: string) =
  ## Update the connection status
  ui.connectionStatus = status

proc updateTokenCount*(count: int) =
  ## Update the token count
  ui.tokenCount = count

proc updateCurrentModel*(model: configTypes.ModelConfig) =
  ## Update the current model information
  ui.currentModel = model
  globalModel = model

proc startEnhancedInteractiveUI*(model: string = "", level: Level, dump: bool = false) =
  ## Start the enhanced interactive terminal UI
  try:
    initEnhancedUI()
    debug("Enhanced UI initialized successfully")
  except Exception as e:
    error(fmt"Failed to initialize enhanced UI: {e.msg}")
    raise e
  
  try:
    # Initialize app systems
    initializeAppSystems(level, dump)
    let channels = getChannels()
    globalChannels = channels
    let config = loadConfig()
    
    # Select initial model
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
          addResponseLine(fmt"Warning: Model '{model}' not found, using default: {config.models[0].nickname}")
        selectedModel
    else:
      if config.models.len > 0: config.models[0] else: 
        addResponseLine("Error: No models configured. Please run 'niffler init' first.")
        return
    
    updateCurrentModel(currentModel)
    updateConnectionStatus("Connecting...")
    
    # Start API worker
    var apiWorker = startAPIWorker(channels, level, dump)
    
    # Configure API worker with initial model
    if configureAPIWorker(currentModel):
      updateConnectionStatus("Connected")
      addResponseLine(fmt"Connected to {currentModel.nickname} ({currentModel.model})")
    else:
      updateConnectionStatus("Error")
      addResponseLine("Warning: Failed to configure API worker. Check API key.")
    
    addResponseLine("Welcome to Niffler! Type your messages below.")
    addResponseLine("Press Ctrl+C or ESC to exit. Use arrow keys to navigate history.")
    addResponseLine("")
    
    # Main UI loop
    var running = true
    while running:
      try:
        redrawScreen()
        
        let key = getKey()
        running = handleKeypress(key)
        
        # Small delay to prevent excessive CPU usage
        sleep(16)  # ~60 FPS
      except Exception as e:
        debug(fmt"Error in main UI loop: {e.msg}")
        running = false
        raise e
      
  finally:
    cleanupEnhancedUI()