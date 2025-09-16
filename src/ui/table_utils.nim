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
  ## Render a Nancy TerminalTable to string with optional Unicode box drawing characters
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

proc formatCostBreakdownTable*(rows: seq[ConversationCostRow], 
                              totalInput: int, totalOutput: int, totalReasoning: int,
                              totalInputCost: float, totalOutputCost: float, totalReasoningCost: float, totalCost: float): string =
  ## Format conversation cost breakdown as a table with reasoning token analysis
  if rows.len == 0:
    return "No cost data available"
  
  var table: TerminalTable
  
  # Add header
  if totalReasoning > 0:
    table.add bold("Model"), bold("Input"), bold("Output"), bold("Reasoning"), bold("Input Cost"), bold("Output Cost"), bold("Reasoning Cost"), bold("Total Cost")
  else:
    table.add bold("Model"), bold("Input"), bold("Output"), bold("Input Cost"), bold("Output Cost"), bold("Total Cost")
  
  # Add model rows
  for row in rows:
    # Format token counts with thousands separator (manual formatting)
    let inputStr = if row.inputTokens > 999: 
      insertSep($row.inputTokens, ',') 
    else: 
      $row.inputTokens
    let outputStr = if row.outputTokens > 999: 
      insertSep($row.outputTokens, ',') 
    else: 
      $row.outputTokens
    
    # Short model name (extract last part after /)
    let modelName = if "/" in row.model: row.model.split("/")[^1] else: row.model
    
    if totalReasoning > 0:
      let reasoningStr = if row.reasoningTokens > 0:
        if row.reasoningTokens > 999: 
          insertSep($row.reasoningTokens, ',')
        else: 
          $row.reasoningTokens
      else: dim("0")
      
      let reasoningCostStr = if row.reasoningCost > 0.0: fmt"${row.reasoningCost:.4f}" else: dim("$0.0000")
      
      table.add modelName, inputStr, outputStr, reasoningStr, 
                fmt"${row.inputCost:.4f}", fmt"${row.outputCost:.4f}", reasoningCostStr,
                fmt"${row.totalCost:.4f}"
    else:
      table.add modelName, inputStr, outputStr,
                fmt"${row.inputCost:.4f}", fmt"${row.outputCost:.4f}",
                fmt"${row.totalCost:.4f}"
  
  # Add total row
  let totalInputStr = if totalInput > 999: 
    insertSep($totalInput, ',') 
  else: 
    $totalInput
  let totalOutputStr = if totalOutput > 999: 
    insertSep($totalOutput, ',') 
  else: 
    $totalOutput
  
  if totalReasoning > 0:
    let totalReasoningStr = if totalReasoning > 0:
      if totalReasoning > 999: 
        insertSep($totalReasoning, ',')
      else: 
        $totalReasoning
    else: dim("0")
    
    let totalReasoningCostStr = if totalReasoningCost > 0.0: fmt"${totalReasoningCost:.4f}" else: dim("$0.0000")
    
    # Calculate reasoning percentage
    let reasoningPercent = if totalOutput > 0: 
      fmt"({(totalReasoning.float / totalOutput.float * 100):.1f}%)"
    else: ""
    
    table.add green(bold("TOTAL")), green(bold(totalInputStr)), green(bold(totalOutputStr)), 
              green(bold(totalReasoningStr & " " & dim(reasoningPercent))), 
              green(bold(fmt"${totalInputCost:.4f}")), green(bold(fmt"${totalOutputCost:.4f}")), green(bold(totalReasoningCostStr)),
              green(bold(fmt"${totalCost:.4f}"))
  else:
    table.add green(bold("TOTAL")), green(bold(totalInputStr)), green(bold(totalOutputStr)),
              green(bold(fmt"${totalInputCost:.4f}")), green(bold(fmt"${totalOutputCost:.4f}")),
              green(bold(fmt"${totalCost:.4f}"))
  
  return renderTableToString(table, maxWidth = 140, useBoxChars = true)

proc formatContextBreakdownTable*(userCount: int, assistantCount: int, toolCount: int,
                                  userTokens: int, assistantTokens: int, toolTokens: int): string =
  ## Format conversation context breakdown as a table
  let totalCount = userCount + assistantCount + toolCount
  let totalTokens = userTokens + assistantTokens + toolTokens
  
  if totalCount == 0:
    return "No messages in context"
  
  var table: TerminalTable
  
  # Add header
  table.add bold("Message Type"), bold("Count"), bold("Total Tokens"), bold("Avg per Message")
  
  # Helper function to calculate average
  proc avgTokens(tokens: int, count: int): string =
    if count > 0: $((tokens.float / count.float).int) else: dim("-")
  
  # Add rows for each message type (always show all types)
  let userTokensStr = if userTokens > 999: insertSep($userTokens, ',') else: $userTokens
  table.add "User", $userCount, userTokensStr, avgTokens(userTokens, userCount)
  
  let assistantTokensStr = if assistantTokens > 999: insertSep($assistantTokens, ',') else: $assistantTokens
  table.add "Assistant", $assistantCount, assistantTokensStr, avgTokens(assistantTokens, assistantCount)
  
  let toolTokensStr = if toolTokens > 999: insertSep($toolTokens, ',') else: $toolTokens
  table.add "Tool", $toolCount, toolTokensStr, avgTokens(toolTokens, toolCount)
  
  # Add total row
  let totalTokensStr = if totalTokens > 999: insertSep($totalTokens, ',') else: $totalTokens
  table.add green(bold("TOTAL")), green(bold($totalCount)), green(bold(totalTokensStr)), 
            green(bold(avgTokens(totalTokens, totalCount)))
  
  return renderTableToString(table, maxWidth = 120, useBoxChars = true)