## Tabular output utilities using Nancy for clean formatting
##
## This module provides utilities for creating nicely formatted tables
## for various types of data in Niffler.

import std/[strformat, strutils, times, options, json]
import nancy
import ../core/database
import ../types/[config, mode]

# ANSI color helpers
proc green*(s: string): string = "\e[32m" & s & "\e[0m"
proc red*(s: string): string = "\e[31m" & s & "\e[0m"  
proc blue*(s: string): string = "\e[34m" & s & "\e[0m"
proc yellow*(s: string): string = "\e[33m" & s & "\e[0m"
proc cyan*(s: string): string = "\e[36m" & s & "\e[0m"
proc magenta*(s: string): string = "\e[35m" & s & "\e[0m"
proc bold*(s: string): string = "\e[1m" & s & "\e[0m"
proc dim*(s: string): string = "\e[2m" & s & "\e[0m"

# Unicode box drawing characters for professional tables
const boxSeps = (
  topLeft: "┌", topRight: "┐", topMiddle: "┬",
  bottomLeft: "└", bottomMiddle: "┴", bottomRight: "┘",
  centerLeft: "├", centerMiddle: "┼", centerRight: "┤",
  vertical: "│", horizontal: "─"
)

proc renderTableToString*(table: TerminalTable, maxWidth: int = 120, useBoxChars: bool = true): string =
  ## Render a Nancy TerminalTable to string instead of stdout
  let sizes = table.getColumnSizes(maxWidth, padding = 1)
  var output = ""
  
  # Choose separator style
  let seps = if useBoxChars: boxSeps else: (
    topLeft: "+", topRight: "+", topMiddle: "+",
    bottomLeft: "+", bottomMiddle: "+", bottomRight: "+",
    centerLeft: "+", centerMiddle: "+", centerRight: "+",
    vertical: "|", horizontal: "-"
  )
  
  # Top border
  output.add seps.topLeft
  for i, size in sizes:
    output.add repeat(seps.horizontal, size + 2)
    if i < sizes.len - 1:
      output.add seps.topMiddle
  output.add seps.topRight & "\n"
  
  # Table content
  var isFirstRow = true
  for rowIdx, entry in table.entries(sizes):
    for lineIdx, line in entry():
      output.add seps.vertical
      var cellIdx = 0
      for colIdx, cell in line():
        output.add " " & cell.alignLeft(sizes[colIdx]) & " "
        if cellIdx < sizes.len - 1:
          output.add seps.vertical
        cellIdx.inc
      output.add seps.vertical & "\n"
    
    # Separator after header
    if isFirstRow and table.rows() > 1:
      output.add seps.centerLeft
      for i, size in sizes:
        output.add repeat(seps.horizontal, size + 2)
        if i < sizes.len - 1:
          output.add seps.centerMiddle
      output.add seps.centerRight & "\n"
      isFirstRow = false
  
  # Bottom border
  output.add seps.bottomLeft
  for i, size in sizes:
    output.add repeat(seps.horizontal, size + 2)
    if i < sizes.len - 1:
      output.add seps.bottomMiddle
  output.add seps.bottomRight
  
  return output

proc formatConversationTable*(conversations: seq[Conversation], currentId: int = -1, 
                             showArchived: bool = false, showEmpty: bool = true): string =
  ## Format a sequence of conversations as a nicely formatted table
  if conversations.len == 0:
    if showEmpty:
      return if showArchived: 
        "No archived conversations found. Use '/archive <id>' to archive conversations."
      else:
        "No conversations found. Create one with '/new [title]'"
    else:
      return ""
  
  var table: TerminalTable
  
  # Add header row with bold formatting
  table.add bold("ID"), bold("Title"), bold("Mode/Model"), bold("Messages"), bold("Status"), bold("Activity")
  
  for conv in conversations:
    let statusStr = if not conv.isActive:
      red("Archived")
    elif conv.id == currentId:
      green("Current")
    else:
      "Active"
    
    let modeModel = case conv.mode:
      of amCode: cyan("Code") & dim("/" & conv.modelNickname)
      of amPlan: blue("Plan") & dim("/" & conv.modelNickname)
    
    let msgCount = fmt"{conv.messageCount} msgs"
    let activity = conv.lastActivity.format("MMM dd HH:mm")
    
    table.add $conv.id, conv.title, modeModel, msgCount, statusStr, activity
  
  return renderTableToString(table, maxWidth = 120, useBoxChars = true)


proc formatModelsTable*(models: seq[ModelConfig]): string =
  ## Format model configurations as a table
  if models.len == 0:
    return "No models configured."
  
  var table: TerminalTable
  
  # Add header
  table.add bold("Nickname"), bold("Base URL"), bold("Max Tokens"), bold("Temperature")
  
  for model in models:
    let maxTokens = if model.maxTokens.isSome: $model.maxTokens.get() else: dim("Default")
    let temp = if model.temperature.isSome: fmt"{model.temperature.get():.1f}" else: dim("Default")
    
    table.add model.nickname, model.baseUrl, maxTokens, temp
  
  return renderTableToString(table, maxWidth = 120, useBoxChars = true)

proc formatApiModelsTable*(jsonResponse: JsonNode): string =
  ## Format API models response as a table (expects JSON with models array)
  try:
    if not jsonResponse.hasKey("data") or jsonResponse["data"].kind != JArray:
      return "API response format not supported for table display.\nRaw response:\n" & jsonResponse.pretty(indent = 2)
    
    let models = jsonResponse["data"]
    if models.len == 0:
      return "No models found in API response."
    
    var table: TerminalTable
    
    # Add header
    table.add bold("ID"), bold("Object"), bold("Created"), bold("Owned By")
    
    for model in models:
      let id = if model.hasKey("id"): model["id"].getStr() else: dim("N/A")
      let obj = if model.hasKey("object"): model["object"].getStr() else: dim("N/A") 
      let created = if model.hasKey("created"):
        let timestamp = model["created"].getInt()
        if timestamp > 0:
          let time = fromUnix(timestamp.int64)
          time.format("yyyy-MM-dd")
        else: dim("N/A")
      else: dim("N/A")
      let ownedBy = if model.hasKey("owned_by"): model["owned_by"].getStr() else: dim("N/A")
      
      table.add id, obj, created, ownedBy
    
    return renderTableToString(table, maxWidth = 120, useBoxChars = true)
  except Exception as e:
    return fmt"Error formatting API models table: {e.msg}\nRaw response:\n" & jsonResponse.pretty(indent = 2)