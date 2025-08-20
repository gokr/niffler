## Terminal UI with TUI-style widgets
##
## This module provides an terminal user interface inspired by tui_widget,
## featuring a cleaner widget-like approach with improved layout and event handling.
##
## Key Features:
## - Clean widget-style interface using illwill
## - Streaming response support
## - Improved input handling
## - Better visual layout
## - Event-driven architecture

import std/[strformat, os, logging, strutils, deques, times, re, unicode, options]
when defined(posix):
  import posix
import illwill
import ../core/[app, channels, history, config, database]
import ../types/[config as configTypes, messages]
import ../api/api
import ../tools/worker
import commands
import popup

type
  TUIApp* = object
    terminalBuffer: TerminalBuffer
    width: int
    height: int
    inputLines: seq[string]  # Multi-line input support
    cursorX: int
    cursorY: int  # Current line in input
    promptHistory: Deque[string]
    historyIndex: int
    savedCurrentInput: string  # Save current input when navigating history
    currentModel: configTypes.ModelConfig
    responseLines: seq[string]  # Conversation history buffer
    scrollOffset: int  # Manual scroll position
    isFollowingBottom: bool  # Whether to auto-scroll to new content
    inputBoxHeight: int
    statusHeight: int
    waitingForResponse: bool
    currentResponseText: string
    # Request tracking for cancellation
    currentRequestId: string  # Track active request for cancellation
    # Popup framework state
    commandCompletionPopup: Popup[CommandInfo]
    modelSelectionPopup: Popup[configTypes.ModelConfig]
    originalInputBoxHeight: int
    # Help shortcuts state
    showingHelp: bool
    helpShortcuts: seq[tuple[key: string, description: string]]
    # Activity indicator state
    requestStartTime: DateTime
    currentTokenCount: int
    # Session token tracking
    sessionPromptTokens: int
    sessionCompletionTokens: int
    currentContextSize: int  # Estimated context size in tokens

var tuiApp: TUIApp
var globalChannels: ptr ThreadChannels = nil
var globalAPIWorker: APIWorker
var globalToolWorker: ToolWorker

# Clean illwill-only TUI functions

proc getUserName(): string =
  ## Get the current user's name
  result = getEnv("USER", getEnv("USERNAME", "User"))


proc initTUIApp(database: DatabaseBackend = nil) =
  ## Initialize the TUI application
  try:
    illwillInit(fullscreen = false)
  except Exception as e:
    raise newException(OSError, fmt"Failed to initialize TUI (illwill required): {e.msg}")
  tuiApp.terminalBuffer = newTerminalBuffer(terminalWidth(), terminalHeight())
  tuiApp.width = terminalWidth()
  tuiApp.height = terminalHeight()
  
  # Initialize input state
  tuiApp.inputLines = @[""]  # Start with one empty line
  tuiApp.cursorX = 0
  tuiApp.cursorY = 0
  tuiApp.promptHistory = initDeque[string]()
  tuiApp.historyIndex = -1
  tuiApp.savedCurrentInput = ""
  
  # Load history from database
  if database != nil:
    try:
      let recentPrompts = getRecentPrompts(database, 50)
      for prompt in recentPrompts:
        tuiApp.promptHistory.addLast(prompt)
      debug(fmt"Loaded {recentPrompts.len} prompts from database into TUI history")
    except Exception as e:
      debug(fmt"Could not load history from database into TUI: {e.msg}")
  
  # Load history from database
  if database != nil:
    try:
      let recentPrompts = getRecentPrompts(database, 50)
      for prompt in recentPrompts:
        tuiApp.promptHistory.addLast(prompt)
      debug(fmt"Loaded {recentPrompts.len} prompts from database into TUI history")
    except Exception as e:
      debug(fmt"Could not load history from database into TUI: {e.msg}")
  
  tuiApp.responseLines = @[]
  tuiApp.scrollOffset = 0
  tuiApp.isFollowingBottom = true  # Start following new content
  tuiApp.inputBoxHeight = 3
  tuiApp.statusHeight = 1
  tuiApp.waitingForResponse = false
  tuiApp.currentResponseText = ""
  tuiApp.currentRequestId = ""
  # Initialize new popup framework
  tuiApp.commandCompletionPopup = newPopup[CommandInfo](PopupConfig(
    title: "Commands",
    maxItems: 8,
    width: 60,
    showDescriptions: true,
    showCurrentIndicator: false
  ))
  tuiApp.modelSelectionPopup = newPopup[configTypes.ModelConfig](PopupConfig(
    title: "Models",
    maxItems: 8,
    width: 60,
    showDescriptions: true,
    showCurrentIndicator: true
  ))
  tuiApp.originalInputBoxHeight = 3
  tuiApp.showingHelp = false
  tuiApp.helpShortcuts = @[
    ("Enter", "Send message"),
    ("Ctrl+J", "Insert newline"),
    ("/command", "Show and filter commands"),
    ("?", "Show keyboard shortcuts"),
    ("Tab", "Complete command"),
    ("↑↓", "Navigate history/completions"),
    ("←→", "Move cursor"),
    ("Home/End", "Jump to line start/end"),
    ("Esc", "Close popups/stop stream display"),
    ("Ctrl+C", "Exit Niffler")
  ]
  tuiApp.requestStartTime = now()
  tuiApp.currentTokenCount = 0
  tuiApp.sessionPromptTokens = 0
  tuiApp.sessionCompletionTokens = 0
  tuiApp.currentContextSize = 0

proc resetSessionCounts*() =
  ## Reset session token counts
  tuiApp.sessionPromptTokens = 0
  tuiApp.sessionCompletionTokens = 0
  tuiApp.currentContextSize = 0

proc cleanupTUIApp() =
  ## Clean up the TUI application
  illwillDeinit()
  showCursor()

proc getCurrentInputText(): string =
  ## Get the current input as a single string
  result = tuiApp.inputLines.join("\n")

proc setCurrentInputText(text: string) =
  ## Set the current input from a string
  tuiApp.inputLines = text.split('\n')
  if tuiApp.inputLines.len == 0:
    tuiApp.inputLines = @[""]
  tuiApp.cursorY = tuiApp.inputLines.len - 1
  tuiApp.cursorX = tuiApp.inputLines[tuiApp.cursorY].len

proc clearCurrentInput() =
  ## Clear the current input
  tuiApp.inputLines = @[""]
  tuiApp.cursorX = 0
  tuiApp.cursorY = 0

proc ensureCursorValid() =
  ## Ensure cursor position is valid
  if tuiApp.cursorY >= tuiApp.inputLines.len:
    tuiApp.cursorY = tuiApp.inputLines.len - 1
  if tuiApp.cursorY < 0:
    tuiApp.cursorY = 0
  if tuiApp.cursorX > tuiApp.inputLines[tuiApp.cursorY].len:
    tuiApp.cursorX = tuiApp.inputLines[tuiApp.cursorY].len
  if tuiApp.cursorX < 0:
    tuiApp.cursorX = 0

proc adjustInputBoxHeight() =
  ## Adjust input box height based on content
  let minHeight = 3
  let maxHeight = tuiApp.height div 3  # Max 1/3 of screen
  let contentHeight = tuiApp.inputLines.len + 2  # +2 for borders
  tuiApp.inputBoxHeight = max(minHeight, min(maxHeight, contentHeight))

proc isCommandInput(): bool =
  ## Check if current input is a command (starts with /)
  result = tuiApp.inputLines.len > 0 and tuiApp.inputLines[0].len > 0 and tuiApp.inputLines[0][0] == '/'

proc isHelpInput(): bool =
  ## Check if current input is help request (starts with ?)
  result = tuiApp.inputLines.len > 0 and tuiApp.inputLines[0].len > 0 and tuiApp.inputLines[0][0] == '?'

proc updateCommandCompletions() =
  ## Update command completions based on current input
  if isHelpInput():
    # Show keyboard shortcuts help
    tuiApp.showingHelp = true
    tuiApp.commandCompletionPopup.hide()
    return
  elif not isCommandInput():
    tuiApp.showingHelp = false
    tuiApp.commandCompletionPopup.hide()
    return
  
  tuiApp.showingHelp = false
  let currentText = getCurrentInputText()
  
  # Clear existing items
  tuiApp.commandCompletionPopup.clearItems()
  
  var commandsToShow: seq[CommandInfo] = @[]
  
  if currentText.len == 1 and currentText == "/":
    # Show all commands
    commandsToShow = getAvailableCommands()
  elif currentText.len > 1:
    # Show filtered completions
    let commandPart = currentText[1..^1]  # Remove the '/'
    commandsToShow = getCommandCompletions(commandPart)
  
  if commandsToShow.len > 0:
    # Add items to popup
    for command in commandsToShow:
      tuiApp.commandCompletionPopup.addItem(
        data = command,
        displayText = fmt"/{command.name}",
        description = command.description,
        isCurrentItem = false
      )
    tuiApp.commandCompletionPopup.show()
  else:
    tuiApp.commandCompletionPopup.hide()

proc showModelSelection() =
  ## Show model selection popup
  let config = loadConfig()
  
  # Clear existing items and add models to popup
  tuiApp.modelSelectionPopup.clearItems()
  
  var currentModelIndex = 0
  for i, model in config.models:
    let isCurrent = model.nickname == tuiApp.currentModel.nickname
    if isCurrent:
      currentModelIndex = i
    
    tuiApp.modelSelectionPopup.addItem(
      data = model,
      displayText = model.nickname,
      description = model.model,
      isCurrentItem = isCurrent
    )
  
  # Set selection to current model and show popup
  tuiApp.modelSelectionPopup.selectedIndex = currentModelIndex
  tuiApp.modelSelectionPopup.show()
  
  # Hide other popups
  tuiApp.commandCompletionPopup.hide()
  tuiApp.showingHelp = false

proc selectCompletion() =
  ## Select the current completion
  if not tuiApp.commandCompletionPopup.isVisible():
    return
  
  let maybeSelected = tuiApp.commandCompletionPopup.getCurrentItem()
  if maybeSelected.isNone():
    return
  
  let selected = maybeSelected.get()
  
  # Special handling for commands that should open popups immediately
  case selected.name:
  of "model":
    showModelSelection()  # Open model popup immediately
    tuiApp.commandCompletionPopup.hide()
  of "help":
    tuiApp.showingHelp = true
    tuiApp.commandCompletionPopup.hide()
  else:
    setCurrentInputText("/" & selected.name)  # Normal behavior
    tuiApp.commandCompletionPopup.hide()

proc wrapText(text: string, maxWidth: int): seq[string] =
  ## Wrap text to fit within maxWidth characters
  result = @[]
  if text.len == 0:
    result.add("")
    return
  
  var currentLine = ""
  var currentWidth = 0
  let words = text.split(' ')
  
  for word in words:
    let wordWidth = word.len
    
    # If adding this word would exceed the width, start a new line
    if currentWidth + wordWidth + (if currentLine.len > 0: 1 else: 0) > maxWidth and currentLine.len > 0:
      result.add(currentLine)
      currentLine = word
      currentWidth = wordWidth
    else:
      # Add word to current line
      if currentLine.len > 0:
        currentLine.add(" ")
        currentWidth += 1
      currentLine.add(word)
      currentWidth += wordWidth
  
  # Add the last line if it has content
  if currentLine.len > 0:
    result.add(currentLine)
  elif result.len == 0:
    result.add("")

proc addResponseLine(line: string) =
  ## Add a line to the response display with proper text wrapping
  let maxWidth = tuiApp.width - 2  # Leave some margin
  let wrappedLines = wrapText(line, maxWidth)
  
  for wrappedLine in wrappedLines:
    tuiApp.responseLines.add(wrappedLine)
  
  # Smart auto-scroll: only scroll if user is following the bottom
  if tuiApp.isFollowingBottom:
    let maxDisplayLines = tuiApp.height - tuiApp.inputBoxHeight - tuiApp.statusHeight - 1
    if tuiApp.responseLines.len > maxDisplayLines:
      tuiApp.scrollOffset = tuiApp.responseLines.len - maxDisplayLines

proc selectModel() =
  ## Select the current model from the popup
  if not tuiApp.modelSelectionPopup.isVisible():
    return
  
  let maybeSelectedModel = tuiApp.modelSelectionPopup.getCurrentItem()
  if maybeSelectedModel.isNone():
    return
  
  let selectedModel = maybeSelectedModel.get()
  tuiApp.currentModel = selectedModel
  
  # Configure API worker with new model
  if configureAPIWorker(tuiApp.currentModel):
    addResponseLine(fmt"Switched to model: {tuiApp.currentModel.nickname} ({tuiApp.currentModel.model})")
  else:
    addResponseLine(fmt"Error: Failed to configure model {tuiApp.currentModel.nickname}. Check API key.")
  addResponseLine("")
  
  # Close model selection
  tuiApp.modelSelectionPopup.hide()
  clearCurrentInput()  # Clear the /model command

proc renderInlineMarkdown(line: string, x: int, y: int) =
  ## Render inline markdown formatting (bold, italic, code, links)
  var currentX = x
  let maxX = tuiApp.width - 1
  var i = 0
  
  while i < line.len and currentX < maxX:
    # Handle bold text **text**
    if i + 1 < line.len and line[i] == '*' and line[i + 1] == '*':
      let endPos = line.find("**", i + 2)
      if endPos != -1:
        let boldText = line[i+2..<endPos]
        # Fix character encoding by ensuring proper UTF-8 handling
        for ch in boldText.runes:
          if currentX < maxX:
            tuiApp.terminalBuffer.write(currentX, y, $ch, fgWhite, styleBright)
            currentX += 1
        i = endPos + 2
        continue
    
    # Handle italic text *text*
    elif i < line.len and line[i] == '*':
      let endPos = line.find("*", i + 1)
      if endPos != -1:
        let italicText = line[i+1..<endPos]
        for ch in italicText.runes:
          if currentX < maxX:
            tuiApp.terminalBuffer.write(currentX, y, $ch, fgCyan)
            currentX += 1
        i = endPos + 1
        continue
    
    # Handle inline code `text`
    elif i < line.len and line[i] == '`':
      let endPos = line.find("`", i + 1)
      if endPos != -1:
        let codeText = line[i+1..<endPos]
        for ch in codeText.runes:
          if currentX < maxX:
            tuiApp.terminalBuffer.write(currentX, y, $ch, fgGreen, styleDim)
            currentX += 1
        i = endPos + 1
        continue
    
    # Handle links [text](url) - just show the text part
    elif i < line.len and line[i] == '[':
      let closePos = line.find("]", i + 1)
      if closePos != -1 and closePos + 1 < line.len and line[closePos + 1] == '(':
        let urlEnd = line.find(")", closePos + 2)
        if urlEnd != -1:
          let linkText = line[i+1..<closePos]
          for ch in linkText.runes:
            if currentX < maxX:
              tuiApp.terminalBuffer.write(currentX, y, $ch, fgBlue)
              currentX += 1
          i = urlEnd + 1
          continue
    
    # Regular character - handle UTF-8 properly
    if currentX < maxX:
      let rune = line.runeAt(i)
      tuiApp.terminalBuffer.write(currentX, y, $rune, fgWhite)
      currentX += 1
      i += rune.size
    else:
      i += 1

proc renderMarkdownLine(line: string, x: int, y: int) =
  ## Render a line with markdown formatting
  var currentX = x
  let maxX = tuiApp.width - 1
  
  if currentX >= maxX:
    return
  
  # Handle different markdown elements
  if line.startsWith("# "):
    # H1 - Large yellow header
    let headerText = line[2..^1]
    tuiApp.terminalBuffer.write(currentX, y, "█ ", fgYellow, styleBright)
    currentX += 2
    for ch in headerText.runes:
      if currentX < maxX:
        tuiApp.terminalBuffer.write(currentX, y, $ch, fgYellow, styleBright)
        currentX += 1
  elif line.startsWith("## "):
    # H2 - Medium yellow header
    let headerText = line[3..^1]
    tuiApp.terminalBuffer.write(currentX, y, "▐ ", fgYellow)
    currentX += 2
    for ch in headerText.runes:
      if currentX < maxX:
        tuiApp.terminalBuffer.write(currentX, y, $ch, fgYellow)
        currentX += 1
  elif line.startsWith("### "):
    # H3 - Small yellow header
    let headerText = line[4..^1]
    tuiApp.terminalBuffer.write(currentX, y, "▌ ", fgYellow, styleDim)
    currentX += 2
    for ch in headerText.runes:
      if currentX < maxX:
        tuiApp.terminalBuffer.write(currentX, y, $ch, fgYellow, styleDim)
        currentX += 1
  elif line.startsWith("```"):
    # Code block delimiter
    tuiApp.terminalBuffer.write(currentX, y, "▓▓▓", fgCyan, styleBright)
    currentX += 3
    for ch in line[3..^1].runes:
      if currentX < maxX:
        tuiApp.terminalBuffer.write(currentX, y, $ch, fgCyan, styleDim)
        currentX += 1
  elif line.startsWith("- ") or line.startsWith("* "):
    # Bullet lists
    tuiApp.terminalBuffer.write(currentX, y, "• ", fgWhite)
    currentX += 2
    let listText = line[2..^1]
    for ch in listText.runes:
      if currentX < maxX:
        tuiApp.terminalBuffer.write(currentX, y, $ch, fgWhite)
        currentX += 1
  elif line.match(re"^\\d+\\.\\s"):
    # Numbered lists
    for ch in line.runes:
      if currentX < maxX:
        tuiApp.terminalBuffer.write(currentX, y, $ch, fgWhite)
        currentX += 1
  elif line.strip().len == 0:
    # Empty line - just skip
    discard
  else:
    # Regular text with inline formatting
    renderInlineMarkdown(line, currentX, y)

proc renderHelpPopup() =
  ## Render keyboard shortcuts help popup in bottom area
  if not tuiApp.showingHelp:
    return
  
  let maxItems = min(6, tuiApp.helpShortcuts.len)  # Reduce to fit in bottom area
  let popupHeight = maxItems + 2  # +2 for borders
  let popupWidth = min(60, tuiApp.width - 4)  # Leave some margin
  
  # Position within bottom reserved area
  let popupY = 1  # Start below separator line
  let popupX = 2
  
  # Only render if it fits in the bottom area
  let maxPopupY = tuiApp.height - tuiApp.inputBoxHeight - tuiApp.statusHeight
  if popupY + popupHeight <= maxPopupY:
    # Draw popup background and border
    tuiApp.terminalBuffer.fill(popupX, popupY, popupX + popupWidth - 1, popupY + popupHeight - 1, " ")
  
  # Top border
  tuiApp.terminalBuffer.fill(popupX, popupY, popupX + popupWidth - 1, popupY, "─")
  tuiApp.terminalBuffer.write(popupX, popupY, "┌", fgWhite)
  tuiApp.terminalBuffer.write(popupX + popupWidth - 1, popupY, "┐", fgWhite)
  
  # Side borders
  for i in 1..<popupHeight-1:
    tuiApp.terminalBuffer.write(popupX, popupY + i, "│", fgWhite)
    tuiApp.terminalBuffer.write(popupX + popupWidth - 1, popupY + i, "│", fgWhite)
  
  # Bottom border
  tuiApp.terminalBuffer.fill(popupX, popupY + popupHeight - 1, popupX + popupWidth - 1, popupY + popupHeight - 1, "─")
  tuiApp.terminalBuffer.write(popupX, popupY + popupHeight - 1, "└", fgWhite)
  tuiApp.terminalBuffer.write(popupX + popupWidth - 1, popupY + popupHeight - 1, "┘", fgWhite)
  
  # Render shortcut items
  for i in 0..<maxItems:
    let shortcut = tuiApp.helpShortcuts[i]
    let y = popupY + 1 + i
    
    # Key combination
    tuiApp.terminalBuffer.write(popupX + 2, y, shortcut.key, fgCyan, styleBright)
    
    # Description
    let maxDescWidth = popupWidth - shortcut.key.len - 6
    let description = if shortcut.description.len > maxDescWidth:
      shortcut.description[0..<maxDescWidth-1] & "…"
    else:
      shortcut.description
    
    tuiApp.terminalBuffer.write(popupX + 2 + shortcut.key.len + 2, y, description, fgWhite, styleDim)

proc renderInputBox() =
  ## Render the input box at the bottom
  # Adjust height first
  adjustInputBoxHeight()
  
  # Input box stays at bottom
  let inputY = tuiApp.height - tuiApp.inputBoxHeight - tuiApp.statusHeight
  
  # Clear input area
  tuiApp.terminalBuffer.fill(0, inputY, tuiApp.width-1, inputY + tuiApp.inputBoxHeight - 1, " ")
  
  # Draw border
  tuiApp.terminalBuffer.fill(0, inputY, tuiApp.width-1, inputY, "─")
  tuiApp.terminalBuffer.write(0, inputY, "┌", fgWhite)
  tuiApp.terminalBuffer.write(tuiApp.width-1, inputY, "┐", fgWhite)
  
  for i in 1..<tuiApp.inputBoxHeight-1:
    tuiApp.terminalBuffer.write(0, inputY + i, "│", fgWhite)
    tuiApp.terminalBuffer.write(tuiApp.width-1, inputY + i, "│", fgWhite)
  
  tuiApp.terminalBuffer.fill(0, inputY + tuiApp.inputBoxHeight - 1, tuiApp.width-1, inputY + tuiApp.inputBoxHeight - 1, "─")
  tuiApp.terminalBuffer.write(0, inputY + tuiApp.inputBoxHeight - 1, "└", fgWhite)
  tuiApp.terminalBuffer.write(tuiApp.width-1, inputY + tuiApp.inputBoxHeight - 1, "┘", fgWhite)
  
  # Render multi-line input
  let maxInputWidth = tuiApp.width - 4
  let maxContentLines = tuiApp.inputBoxHeight - 2
  
  for i in 0..<min(tuiApp.inputLines.len, maxContentLines):
    let lineY = inputY + 1 + i
    let line = tuiApp.inputLines[i]
    let promptPrefix = if i == 0: "> " else: "  "
    let prefixColor = if i == 0: fgGreen else: fgWhite
    
    # Display line with prefix
    tuiApp.terminalBuffer.write(2, lineY, promptPrefix, prefixColor, if i == 0: styleBright else: styleDim)
    
    # Display line content with wrapping
    let availableWidth = maxInputWidth - promptPrefix.len
    let displayLine = if line.len > availableWidth: 
      line[0..<availableWidth] & "…"
    else: 
      line
    
    tuiApp.terminalBuffer.write(2 + promptPrefix.len, lineY, displayLine, fgWhite)
  
  # Position cursor in input area
  if tuiApp.cursorY < maxContentLines:
    let lineY = inputY + 1 + tuiApp.cursorY
    let promptPrefix = if tuiApp.cursorY == 0: "> " else: "  "
    let line = tuiApp.inputLines[tuiApp.cursorY]
    let availableWidth = maxInputWidth - promptPrefix.len
    
    # Ensure cursor position is valid and within bounds
    let validCursorX = max(0, min(tuiApp.cursorX, line.len))
    
    # Account for text truncation when positioning cursor
    let effectiveCursorX = if line.len > availableWidth:
      min(validCursorX, availableWidth - 1)  # -1 for the ellipsis
    else:
      validCursorX
    
    let cursorXPos = 2 + promptPrefix.len + effectiveCursorX
    tuiApp.terminalBuffer.setCursorPos(min(cursorXPos, tuiApp.width-2), lineY)

proc renderResponseArea() =
  ## Render the response display area with scrolling support
  let maxY = tuiApp.height - tuiApp.inputBoxHeight - tuiApp.statusHeight - 1
  let startY = 0
  let maxDisplayLines = maxY - startY
  
  # Clear response area
  tuiApp.terminalBuffer.fill(0, startY, tuiApp.width-1, maxY, " ")
  
  # Display response lines with manual scrolling
  let startIdx = tuiApp.scrollOffset
  let endIdx = min(tuiApp.responseLines.len, startIdx + maxDisplayLines)
  
  for i in startIdx..<endIdx:
    let y = startY + (i - startIdx)
    let line = tuiApp.responseLines[i]
    renderMarkdownLine(line, 0, y)
  
  # Show scroll indicators if there's more content
  if tuiApp.scrollOffset > 0:
    tuiApp.terminalBuffer.write(tuiApp.width-1, startY, "▲", fgYellow, styleBright)
  if tuiApp.scrollOffset + maxDisplayLines < tuiApp.responseLines.len:
    tuiApp.terminalBuffer.write(tuiApp.width-1, maxY-1, "▼", fgYellow, styleBright)

proc renderActivityIndicator() =
  ## Render activity indicator in bottom area when processing
  if not tuiApp.waitingForResponse:
    return
  
  let elapsed = now() - tuiApp.requestStartTime
  let elapsedSeconds = elapsed.inSeconds()
  let activityText = fmt"⚡ Thinking... ({elapsedSeconds}s · esc to stop display)"
  
  # Position above input box
  let activityY = tuiApp.height - tuiApp.inputBoxHeight - tuiApp.statusHeight - 1
  
  # Clear and draw activity indicator
  if activityY > 0:  # Make sure we have space
    tuiApp.terminalBuffer.fill(0, activityY, tuiApp.width-1, activityY, " ")
    let centeredX = max(0, (tuiApp.width - activityText.len) div 2)
    tuiApp.terminalBuffer.write(centeredX, activityY, activityText, fgYellow, styleBright)

proc renderStatusBar() =
  ## Render the status bar at the bottom
  let statusY = tuiApp.height - 1
  
  # Clear status line
  tuiApp.terminalBuffer.fill(0, statusY, tuiApp.width-1, statusY, " ")
  
  # Left side: connection status
  let statusText = if tuiApp.waitingForResponse: "Processing..." else: "Ready"
  tuiApp.terminalBuffer.write(0, statusY, statusText, if tuiApp.waitingForResponse: fgYellow else: fgGreen)
  
  # Right side: token info and model info with visual indicators
  let sessionTotal = tuiApp.sessionPromptTokens + tuiApp.sessionCompletionTokens
  
  # Create context usage bar (assume max context of model, fallback to 128k)
  let maxContext = if tuiApp.currentModel.context > 0: tuiApp.currentModel.context else: 128000
  let contextPercent = min(100, (tuiApp.currentContextSize * 100) div maxContext)
  let barWidth = 10
  let filledBars = (contextPercent * barWidth) div 100
  let contextBar = "█".repeat(filledBars) & "░".repeat(barWidth - filledBars)
  
  # Add context warning indicator
  let contextWarning = if contextPercent > 80: " 🚨" elif contextPercent > 60: " ⚠️" else: ""
  
  let tokenInfo = if sessionTotal > 0:
    fmt"↑{tuiApp.sessionPromptTokens} ↓{tuiApp.sessionCompletionTokens} [{contextBar}]{contextPercent}%{contextWarning} | {tuiApp.currentModel.nickname}"
  else:
    fmt"{tuiApp.currentModel.nickname}"
  
  let rightStartX = tuiApp.width - tokenInfo.len - 1
  if rightStartX > statusText.len + 5:
    let tokenColor = if contextPercent > 80: fgRed elif contextPercent > 60: fgYellow else: fgCyan
    tuiApp.terminalBuffer.write(rightStartX, statusY, tokenInfo, tokenColor)

proc redrawScreen() =
  ## Redraw the entire screen
  tuiApp.terminalBuffer.clear()
  renderResponseArea()
  renderInputBox()
  # Render popups using framework
  tuiApp.commandCompletionPopup.renderPopup(tuiApp.terminalBuffer, tuiApp.width, tuiApp.height, 
                                           tuiApp.inputBoxHeight, tuiApp.statusHeight)
  tuiApp.modelSelectionPopup.renderPopup(tuiApp.terminalBuffer, tuiApp.width, tuiApp.height,
                                        tuiApp.inputBoxHeight, tuiApp.statusHeight)
  renderHelpPopup()
  renderActivityIndicator()
  renderStatusBar()
  tuiApp.terminalBuffer.display()

# Removed hybrid rendering functions

proc handleAPIResponses() =
  ## Check for and handle streaming API responses
  if globalChannels == nil:
    return
  
  var response: APIResponse
  if tryReceiveAPIResponse(globalChannels, response):
    # Validate that this response belongs to our current request
    if tuiApp.waitingForResponse and response.requestId == tuiApp.currentRequestId:
      case response.kind:
      of arkStreamChunk:
        if response.content.len > 0:
          # Split content into lines and handle streaming properly
          let lines = response.content.split('\n')
          if lines.len > 0:
            # Update the last line (append to current line)
            if tuiApp.responseLines.len > 0:
              let combinedLine = tuiApp.responseLines[^1] & lines[0]
              tuiApp.responseLines[^1] = combinedLine
            else:
              tuiApp.responseLines.add(lines[0])
            
            # Add any additional lines
            for i in 1..<lines.len:
              tuiApp.responseLines.add(lines[i])
          
          tuiApp.currentResponseText.add(response.content)
          
          # Auto-scroll if following bottom
          if tuiApp.isFollowingBottom:
            let maxDisplayLines = tuiApp.height - tuiApp.inputBoxHeight - tuiApp.statusHeight - 1
            if tuiApp.responseLines.len > maxDisplayLines:
              tuiApp.scrollOffset = tuiApp.responseLines.len - maxDisplayLines
      of arkStreamComplete:
        # Send completed response to scrollback buffer
        if tuiApp.currentResponseText.len > 0:
          # Print to stdout so it goes to terminal scrollback
          echo ""
          echo tuiApp.currentResponseText
          echo ""
        
        tuiApp.waitingForResponse = false
        tuiApp.currentRequestId = ""  # Clear request ID when completed
        
        # Update session token counts
        tuiApp.sessionPromptTokens += response.usage.promptTokens
        tuiApp.sessionCompletionTokens += response.usage.completionTokens
        
        # Calculate actual context size using real conversation context
        let contextMessages = app.getConversationContext()
        tuiApp.currentContextSize = app.estimateTokenCount(contextMessages)
        
        # Add assistant response to history (without tool calls in TUI - tool calls are handled by API worker)
        if tuiApp.currentResponseText.len > 0:
          discard addAssistantMessage(tuiApp.currentResponseText)
        
        # Just add a blank line, token info moved to status bar
        addResponseLine("")
      of arkStreamError:
        addResponseLine(fmt"Error: {response.error}")
        addResponseLine("")
        tuiApp.waitingForResponse = false
        tuiApp.currentRequestId = ""  # Clear request ID on error
      of arkReady:
        discard
    else:
      # Response from cancelled or old request - ignore and drain
      debug(fmt"Ignoring response from request {response.requestId} (current: {tuiApp.currentRequestId}, waiting: {tuiApp.waitingForResponse})")

proc sendPromptToAPI(promptText: string) =
  ## Send a prompt to the API worker
  if globalChannels == nil:
    addResponseLine("Error: API not initialized")
    return
  
  debug(fmt"Sending prompt: {promptText}")
  
  # Add user message to display
  let userName = getUserName()
  addResponseLine(fmt"{userName}: {promptText}")
  # Start the assistant response line
  tuiApp.responseLines.add(fmt"{tuiApp.currentModel.nickname}: ")
  
  let (success, requestId) = sendSinglePromptInteractiveWithId(promptText, tuiApp.currentModel)
  if success:
    tuiApp.waitingForResponse = true
    tuiApp.currentResponseText = ""
    tuiApp.currentRequestId = requestId
    tuiApp.requestStartTime = now()
    tuiApp.currentTokenCount = 0
  else:
    addResponseLine("Failed to send request")

proc handleKeypress(key: illwill.Key): bool =
  ## Handle keypress events, return false to exit
  case key:
  of illwill.Key.None:
    return true
  of illwill.Key.Escape:
    if tuiApp.commandCompletionPopup.isVisible():
      # Close completions and clear input if it's just a command character
      tuiApp.commandCompletionPopup.hide()
      let currentText = getCurrentInputText().strip()
      if currentText == "/" or currentText == "/?":
        clearCurrentInput()
    elif tuiApp.showingHelp:
      # Close help (no need to clear input since ? doesn't get typed)
      tuiApp.showingHelp = false
    elif tuiApp.modelSelectionPopup.isVisible():
      # Close model selection and clear input
      tuiApp.modelSelectionPopup.hide()
      clearCurrentInput()
    elif tuiApp.waitingForResponse and tuiApp.currentRequestId.len > 0:
      # Cancel active stream if waiting for response
      if globalChannels != nil:
        let requestIdToCancel = tuiApp.currentRequestId  # Capture to avoid race conditions
        let cancelRequest = APIRequest(
          kind: arkStreamCancel,
          cancelRequestId: requestIdToCancel
        )
        if trySendAPIRequest(globalChannels, cancelRequest):
          addResponseLine("")
          addResponseLine("\x1b[31m⚠️ Response stopped by user, token generation may continue briefly\x1b[0m")
          addResponseLine("")
          tuiApp.waitingForResponse = false
          tuiApp.currentRequestId = ""
          
          # Note: Request ID validation in handleAPIResponses will ignore 
          # any remaining responses from the cancelled request
        else:
          addResponseLine("")
          addResponseLine("⚠️ Failed to cancel stream")
          addResponseLine("")
    # ESC no longer exits - only closes popups or cancels streams
  of illwill.Key.CtrlC:
    return false
  of illwill.Key.Enter:
    # Handle popup selections or execute command/message
    if tuiApp.modelSelectionPopup.isVisible():
      selectModel()
    elif tuiApp.commandCompletionPopup.isVisible():
      selectCompletion()
    else:
      let promptText = getCurrentInputText().strip()
      if promptText.len > 0:
        # Check if it's a command
        if promptText.startsWith("/"):
          let (command, args) = parseCommand(promptText)
          if command.len > 0:
            # Special case: /model command without args shows interactive popup
            if command == "model" and args.len == 0:
              showModelSelection()
              return true  # Don't clear input yet, user will select from popup
            else:
              let res = executeCommand(command, args, tuiApp.currentModel)
              
              # Add command and result to response display
              addResponseLine(fmt"> {promptText}")
              addResponseLine(res.message)
              addResponseLine("")
              
              # Handle special commands that need additional actions
              if res.success and command == "clear":
                # Reset session token counts when clearing history
                resetSessionCounts()
              elif res.success and command == "model":
                # Reconfigure API worker with new model
                if not configureAPIWorker(tuiApp.currentModel):
                  addResponseLine(fmt"Warning: Failed to configure API worker with model {tuiApp.currentModel.nickname}. Check API key.")
                  addResponseLine("")
              
              if res.shouldExit:
                return false
          else:
            addResponseLine("Invalid command format")
            addResponseLine("")
        else:
          # Regular message - add to history
          tuiApp.promptHistory.addLast(promptText)
          if tuiApp.promptHistory.len > 100:
            tuiApp.promptHistory.popFirst()
          
          # Send prompt to API
          sendPromptToAPI(promptText)
        
        # Clear input
        clearCurrentInput()
        tuiApp.historyIndex = -1
        tuiApp.savedCurrentInput = ""
  of illwill.Key.CtrlJ:
    # Use Ctrl+J as newline insertion (alternative to Shift+Enter)
    let remainingText = tuiApp.inputLines[tuiApp.cursorY][tuiApp.cursorX..^1]
    tuiApp.inputLines[tuiApp.cursorY] = tuiApp.inputLines[tuiApp.cursorY][0..<tuiApp.cursorX]
    tuiApp.inputLines.insert(remainingText, tuiApp.cursorY + 1)
    tuiApp.cursorY += 1
    tuiApp.cursorX = 0
    adjustInputBoxHeight()
    ensureCursorValid()
  of illwill.Key.Backspace:
    if tuiApp.cursorX > 0:
      # Delete character before cursor
      tuiApp.inputLines[tuiApp.cursorY].delete(tuiApp.cursorX - 1..tuiApp.cursorX - 1)
      tuiApp.cursorX -= 1
    elif tuiApp.cursorY > 0:
      # At beginning of line, merge with previous line
      let currentLine = tuiApp.inputLines[tuiApp.cursorY]
      tuiApp.cursorX = tuiApp.inputLines[tuiApp.cursorY - 1].len
      tuiApp.inputLines[tuiApp.cursorY - 1].add(currentLine)
      tuiApp.inputLines.delete(tuiApp.cursorY)
      tuiApp.cursorY -= 1
      adjustInputBoxHeight()
    ensureCursorValid()
  of illwill.Key.Delete:
    if tuiApp.cursorX < tuiApp.inputLines[tuiApp.cursorY].len:
      # Delete character at cursor
      tuiApp.inputLines[tuiApp.cursorY].delete(tuiApp.cursorX..tuiApp.cursorX)
    elif tuiApp.cursorY < tuiApp.inputLines.len - 1:
      # At end of line, merge with next line
      let nextLine = tuiApp.inputLines[tuiApp.cursorY + 1]
      tuiApp.inputLines[tuiApp.cursorY].add(nextLine)
      tuiApp.inputLines.delete(tuiApp.cursorY + 1)
      adjustInputBoxHeight()
    ensureCursorValid()
  of illwill.Key.Left:
    # Handle popup navigation first
    if tuiApp.modelSelectionPopup.isVisible() or tuiApp.commandCompletionPopup.isVisible():
      # Don't handle cursor movement in input when popups are visible
      discard
    else:
      # Normal cursor movement
      if tuiApp.cursorX > 0:
        tuiApp.cursorX -= 1
      elif tuiApp.cursorY > 0:
        tuiApp.cursorY -= 1
        tuiApp.cursorX = tuiApp.inputLines[tuiApp.cursorY].len
      ensureCursorValid()
  of illwill.Key.Right:
    # Handle popup navigation first
    if tuiApp.modelSelectionPopup.isVisible() or tuiApp.commandCompletionPopup.isVisible():
      # Don't handle cursor movement in input when popups are visible
      discard
    else:
      # Normal cursor movement
      if tuiApp.cursorX < tuiApp.inputLines[tuiApp.cursorY].len:
        tuiApp.cursorX += 1
      elif tuiApp.cursorY < tuiApp.inputLines.len - 1:
        tuiApp.cursorY += 1
        tuiApp.cursorX = 0
      ensureCursorValid()
  of illwill.Key.Up:
    if tuiApp.modelSelectionPopup.isVisible():
      # Navigate model selection using popup framework
      discard tuiApp.modelSelectionPopup.navigateUp()
    elif tuiApp.commandCompletionPopup.isVisible():
      # Navigate command completions using popup framework
      discard tuiApp.commandCompletionPopup.navigateUp()
    elif tuiApp.cursorY > 0:
      # Move cursor up one line
      tuiApp.cursorY -= 1
      tuiApp.cursorX = min(tuiApp.cursorX, tuiApp.inputLines[tuiApp.cursorY].len)
    else:
      # Navigate history
      if tuiApp.promptHistory.len > 0:
        if tuiApp.historyIndex == -1:
          # Save current input when starting history navigation
          tuiApp.savedCurrentInput = getCurrentInputText()
          tuiApp.historyIndex = tuiApp.promptHistory.len - 1
        elif tuiApp.historyIndex > 0:
          tuiApp.historyIndex -= 1
        
        setCurrentInputText(tuiApp.promptHistory[tuiApp.historyIndex])
    ensureCursorValid()
  of illwill.Key.Down:
    if tuiApp.modelSelectionPopup.isVisible():
      # Navigate model selection using popup framework
      discard tuiApp.modelSelectionPopup.navigateDown()
    elif tuiApp.commandCompletionPopup.isVisible():
      # Navigate command completions using popup framework
      discard tuiApp.commandCompletionPopup.navigateDown()
    elif tuiApp.cursorY < tuiApp.inputLines.len - 1:
      # Move cursor down one line
      tuiApp.cursorY += 1
      tuiApp.cursorX = min(tuiApp.cursorX, tuiApp.inputLines[tuiApp.cursorY].len)
    else:
      # Navigate history
      if tuiApp.historyIndex >= 0:
        if tuiApp.historyIndex < tuiApp.promptHistory.len - 1:
          tuiApp.historyIndex += 1
          setCurrentInputText(tuiApp.promptHistory[tuiApp.historyIndex])
        else:
          # Restore saved current input
          tuiApp.historyIndex = -1
          setCurrentInputText(tuiApp.savedCurrentInput)
          tuiApp.savedCurrentInput = ""
    ensureCursorValid()
  of illwill.Key.Tab:
    # Tab completion
    if isCommandInput() or isHelpInput():
      updateCommandCompletions()
    elif tuiApp.commandCompletionPopup.isVisible():
      selectCompletion()
  of illwill.Key.Home:
    tuiApp.cursorX = 0
  of illwill.Key.End:
    tuiApp.cursorX = tuiApp.inputLines[tuiApp.cursorY].len
  of illwill.Key.PageUp:
    # Scroll conversation up (manual scrolling)
    let maxDisplayLines = tuiApp.height - tuiApp.inputBoxHeight - tuiApp.statusHeight - 1
    let scrollAmount = maxDisplayLines div 2  # Scroll half a screen
    tuiApp.scrollOffset = max(0, tuiApp.scrollOffset - scrollAmount)
    tuiApp.isFollowingBottom = false  # User manually scrolled, stop auto-following
  of illwill.Key.PageDown:
    # Scroll conversation down (manual scrolling)
    let maxDisplayLines = tuiApp.height - tuiApp.inputBoxHeight - tuiApp.statusHeight - 1
    let scrollAmount = maxDisplayLines div 2  # Scroll half a screen
    let maxScroll = max(0, tuiApp.responseLines.len - maxDisplayLines)
    tuiApp.scrollOffset = min(maxScroll, tuiApp.scrollOffset + scrollAmount)
    
    # If we've scrolled to the bottom, resume auto-following
    if tuiApp.scrollOffset >= maxScroll:
      tuiApp.isFollowingBottom = true
  else:
    # Handle regular character input
    let ch = char(ord(key))
    if ch >= ' ' and ch <= '~':
      # Special case: '?' at start of empty line shows help without typing
      if ch == '?' and tuiApp.cursorX == 0 and tuiApp.cursorY == 0 and getCurrentInputText().strip().len == 0:
        tuiApp.showingHelp = true
        tuiApp.commandCompletionPopup.hide()
        return true  # Don't insert the character
      
      # Insert character at cursor position
      tuiApp.inputLines[tuiApp.cursorY].insert($ch, tuiApp.cursorX)
      tuiApp.cursorX += 1
      
      # Update command completions if this is a command or help
      if isCommandInput() or isHelpInput():
        updateCommandCompletions()
      else:
        tuiApp.commandCompletionPopup.hide()
        tuiApp.showingHelp = false
      
      # Check if we need to wrap to next line
      let maxLineWidth = tuiApp.width - 8  # Account for borders and prompt
      if tuiApp.inputLines[tuiApp.cursorY].len > maxLineWidth:
        # Create new line with overflow text
        let overflowStart = maxLineWidth
        let overflowText = tuiApp.inputLines[tuiApp.cursorY][overflowStart..^1]
        tuiApp.inputLines[tuiApp.cursorY] = tuiApp.inputLines[tuiApp.cursorY][0..<overflowStart]
        tuiApp.inputLines.insert(overflowText, tuiApp.cursorY + 1)
        tuiApp.cursorY += 1
        tuiApp.cursorX = tuiApp.cursorX - overflowStart
        adjustInputBoxHeight()
    ensureCursorValid()
  
  return true

proc startTUIMode*(modelConfig: configTypes.ModelConfig, database: DatabaseBackend, level: Level, dump: bool = false) =
  ## Start the TUI interface - fail fast if not available
  when defined(posix):
    if isatty(stdin.getFileHandle()) == 0:
      raise newException(OSError, "TUI requires an interactive terminal")
  
  try:
    let channels = getChannels()
    globalChannels = channels
    
    # Use the provided model configuration
    tuiApp.currentModel = modelConfig
    
    # Start workers
    globalAPIWorker = startAPIWorker(channels, level, dump, database)
    globalToolWorker = startToolWorker(channels, level, dump)
    
    # Configure API worker with initial model
    if not configureAPIWorker(tuiApp.currentModel):
      echo fmt"Warning: Failed to configure API worker with model {tuiApp.currentModel.nickname}. Check API key."
    
    # Initialize command system
    initializeCommands()
    
    # Initialize TUI
    initTUIApp(database)
    
    # Add welcome message
    addResponseLine(fmt"Welcome to Niffler!")
    addResponseLine("")
    addResponseLine(fmt"Connected to: {tuiApp.currentModel.nickname} ({tuiApp.currentModel.model})")
    addResponseLine("")
    addResponseLine("Type your messages below and press Enter to send.")
    addResponseLine("Use Ctrl+J for newlines, Tab for command completion, Page Up/Down for scrolling.")
    addResponseLine("Type '/' to see available commands, '?' for keyboard shortcuts. Press Ctrl+C to exit.")
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
    error(fmt"Failed to start TUI mode: {e.msg}")
    raise e
  finally:
    # Cleanup workers
    if globalChannels != nil:
      signalShutdown(globalChannels)
      stopAPIWorker(globalAPIWorker)
      stopToolWorker(globalToolWorker)
      closeChannels(globalChannels[])
    cleanupTUIApp()