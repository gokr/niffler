## Reusable Popup Framework
##
## This module provides a generic popup system for terminal UI applications.
## It handles rendering, navigation, selection, and common popup behaviors.

import std/[options, strformat]
import illwill

type
  PopupItem*[T] = object
    data*: T
    displayText*: string
    description*: string
    isCurrentItem*: bool

  PopupConfig* = object
    title*: string
    maxItems*: int
    width*: int
    showDescriptions*: bool
    showCurrentIndicator*: bool

  PopupState* = enum
    psHidden,
    psVisible

  Popup*[T] = object
    items*: seq[PopupItem[T]]
    selectedIndex*: int
    config*: PopupConfig
    state*: PopupState

proc newPopup*[T](config: PopupConfig): Popup[T] =
  ## Create a new popup with the given configuration
  Popup[T](
    items: @[],
    selectedIndex: 0,
    config: config,
    state: psHidden
  )

proc addItem*[T](popup: var Popup[T], data: T, displayText: string, 
                description: string = "", isCurrentItem: bool = false) =
  ## Add an item to the popup
  popup.items.add(PopupItem[T](
    data: data,
    displayText: displayText,
    description: description,
    isCurrentItem: isCurrentItem
  ))

proc clearItems*[T](popup: var Popup[T]) =
  ## Clear all items from the popup
  popup.items = @[]
  popup.selectedIndex = 0

proc show*[T](popup: var Popup[T]) =
  ## Show the popup
  popup.state = psVisible
  if popup.items.len > 0 and popup.selectedIndex >= popup.items.len:
    popup.selectedIndex = 0

proc hide*[T](popup: var Popup[T]) =
  ## Hide the popup
  popup.state = psHidden

proc isVisible*[T](popup: Popup[T]): bool =
  ## Check if the popup is visible
  popup.state == psVisible

proc getCurrentItem*[T](popup: Popup[T]): Option[T] =
  ## Get the currently selected item
  if popup.items.len == 0 or popup.selectedIndex < 0 or popup.selectedIndex >= popup.items.len:
    return none(T)
  return some(popup.items[popup.selectedIndex].data)

proc navigateUp*[T](popup: var Popup[T]): bool =
  ## Navigate up in the popup, returns true if navigation occurred
  if popup.items.len == 0:
    return false
  if popup.selectedIndex > 0:
    popup.selectedIndex -= 1
    return true
  return false

proc navigateDown*[T](popup: var Popup[T]): bool =
  ## Navigate down in the popup, returns true if navigation occurred
  if popup.items.len == 0:
    return false
  if popup.selectedIndex < popup.items.len - 1:
    popup.selectedIndex += 1
    return true
  return false

proc calculatePopupPosition*(terminalWidth, terminalHeight, inputBoxHeight, statusHeight: int,
                           popupWidth, popupHeight: int): tuple[x: int, y: int] =
  ## Calculate optimal popup position
  let inputY = terminalHeight - inputBoxHeight - statusHeight
  let desiredPopupY = inputY + inputBoxHeight + 1  # 1 line below input box
  
  let popupY = if desiredPopupY + popupHeight < terminalHeight - 1:
    desiredPopupY
  else:
    max(0, inputY - popupHeight - 1)  # Above input if no room below
  
  let popupX = 2
  return (x: popupX, y: popupY)

proc renderPopup*[T](popup: Popup[T], terminalBuffer: var TerminalBuffer, 
                    terminalWidth, terminalHeight, inputBoxHeight, statusHeight: int) =
  ## Render the popup to the terminal buffer
  if popup.state != psVisible or popup.items.len == 0:
    return
  
  let maxItems = min(popup.config.maxItems, popup.items.len)
  let popupHeight = maxItems + 2  # +2 for borders
  let popupWidth = min(popup.config.width, terminalWidth - 4)
  
  let pos = calculatePopupPosition(terminalWidth, terminalHeight, inputBoxHeight, statusHeight,
                                 popupWidth, popupHeight)
  let popupX = pos.x
  let popupY = pos.y
  
  # Draw popup background
  terminalBuffer.fill(popupX, popupY, popupX + popupWidth - 1, popupY + popupHeight - 1, " ")
  
  # Draw borders
  # Top border
  terminalBuffer.fill(popupX, popupY, popupX + popupWidth - 1, popupY, "─")
  terminalBuffer.write(popupX, popupY, "┌", fgWhite)
  terminalBuffer.write(popupX + popupWidth - 1, popupY, "┐", fgWhite)
  
  # Side borders
  for i in 1..<popupHeight-1:
    terminalBuffer.write(popupX, popupY + i, "│", fgWhite)
    terminalBuffer.write(popupX + popupWidth - 1, popupY + i, "│", fgWhite)
  
  # Bottom border
  terminalBuffer.fill(popupX, popupY + popupHeight - 1, popupX + popupWidth - 1, popupY + popupHeight - 1, "─")
  terminalBuffer.write(popupX, popupY + popupHeight - 1, "└", fgWhite)
  terminalBuffer.write(popupX + popupWidth - 1, popupY + popupHeight - 1, "┘", fgWhite)
  
  # Render items
  for i in 0..<maxItems:
    let item = popup.items[i]
    let y = popupY + 1 + i
    let isSelected = i == popup.selectedIndex
    
    # Build display text
    var displayText = item.displayText
    if popup.config.showCurrentIndicator and item.isCurrentItem:
      displayText = displayText & " (current)"
    
    # Calculate available width for content
    let contentStartX = popupX + 2
    let availableWidth = popupWidth - 4  # Account for borders and padding
    
    if popup.config.showDescriptions and item.description.len > 0:
      # Show both display text and description
      let maxDescWidth = availableWidth - displayText.len - 4  # 4 for spacing
      let description = if item.description.len > maxDescWidth and maxDescWidth > 0:
        item.description[0..<max(0, maxDescWidth-1)] & "…"
      else:
        item.description
      
      let fullText = displayText & "  " & description
      
      if isSelected:
        # Fill with background color and render text
        let paddedText = if fullText.len < availableWidth:
          fullText & " ".repeat(availableWidth - fullText.len)
        else:
          fullText[0..<availableWidth]
        terminalBuffer.write(contentStartX, y, paddedText, fgBlack, styleBright, bgWhite)
      else:
        # Normal rendering
        let displayColor = if item.isCurrentItem: fgGreen else: fgYellow
        terminalBuffer.write(contentStartX, y, displayText, displayColor, styleDim)
        terminalBuffer.write(contentStartX + displayText.len + 2, y, description, fgWhite, styleDim)
    else:
      # Show only display text
      if isSelected:
        # Fill with background color and render text
        let paddedText = if displayText.len < availableWidth:
          displayText & " ".repeat(availableWidth - displayText.len)
        else:
          displayText[0..<availableWidth]
        terminalBuffer.write(contentStartX, y, paddedText, fgBlack, styleBright, bgWhite)
      else:
        # Normal rendering
        let displayColor = if item.isCurrentItem: fgGreen else: fgYellow
        terminalBuffer.write(contentStartX, y, displayText, displayColor, styleDim)