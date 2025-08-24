## Tool Visualization Module
##
## Provides comprehensive tool execution visualization similar to Claude Code,
## with structured display of tool requests and results including diff visualization.

import std/[strutils, json, tables, strformat, sequtils]
import theme
import diff_visualizer
import diff_types
import markdown_cli

type
  ToolVisualizationConfig* = object
    showToolArgs*: bool
    showToolResults*: bool  
    indentResults*: bool
    useColors*: bool
    maxResultLength*: int
    showDiffs*: bool

  ToolDisplayInfo* = object
    name*: string
    args*: JsonNode
    result*: string
    success*: bool
    executionTime*: float

proc getDefaultToolConfig*(): ToolVisualizationConfig =
  ## Get default tool visualization configuration
  ToolVisualizationConfig(
    showToolArgs: true,
    showToolResults: true,
    indentResults: true,
    useColors: true,
    maxResultLength: 2000,
    showDiffs: true
  )

proc getMinimalToolConfig*(): ToolVisualizationConfig =
  ## Get minimal tool visualization configuration (less verbose)
  ToolVisualizationConfig(
    showToolArgs: false,
    showToolResults: true,
    indentResults: true,
    useColors: false,
    maxResultLength: 500,
    showDiffs: false
  )

proc getVerboseToolConfig*(): ToolVisualizationConfig =
  ## Get verbose tool visualization configuration (full details)
  ToolVisualizationConfig(
    showToolArgs: true,
    showToolResults: true,
    indentResults: true,
    useColors: true,
    maxResultLength: 5000,
    showDiffs: true
  )

proc formatToolHeader*(toolName: string, args: JsonNode, config: ToolVisualizationConfig): string =
  ## Format tool header similar to Claude Code style: Tool(key_args)
  if not config.showToolArgs:
    return toolName
  
  try:
    var argParts: seq[string] = @[]
    
    case toolName:
    of "edit":
      if args.hasKey("path"):
        argParts.add(args["path"].getStr())
      if args.hasKey("operation"):
        let op = args["operation"].getStr()
        if op != "replace":  # Only show non-default operations
          argParts.add(op)
    of "read":
      if args.hasKey("path") or args.hasKey("file_path"):
        let path = if args.hasKey("path"): args["path"].getStr() else: args["file_path"].getStr()
        argParts.add(path)
    of "create":
      if args.hasKey("path") or args.hasKey("file_path"):
        let path = if args.hasKey("path"): args["path"].getStr() else: args["file_path"].getStr()
        argParts.add(path)
    of "list":
      if args.hasKey("path"):
        argParts.add(args["path"].getStr())
    of "bash":
      if args.hasKey("command"):
        let cmd = args["command"].getStr()
        argParts.add(if cmd.len > 30: cmd[0..29] & "..." else: cmd)
    of "fetch":
      if args.hasKey("url"):
        argParts.add(args["url"].getStr())
    
    let argStr = if argParts.len > 0: argParts.join(", ") else: ""
    return fmt"{toolName}({argStr})"
    
  except:
    return fmt"{toolName}(...)"

proc createInlineDiffFromEditResult*(editResult: string, originalContent: string, newContent: string): string =
  ## Create an enhanced diff visualization from edit tool results
  if originalContent == newContent:
    return "  No changes made"
  
  let theme = getCurrentTheme()
  let lineColors = getDiffColors(theme)
  let segmentColors = getDiffSegmentColors(theme)
  let config = getDefaultDiffConfig()
  
  let originalLines = originalContent.splitLines()
  let newLines = newContent.splitLines()
  
  var diffResult = ""
  var i, j = 0
  
  # Simple line-by-line diff with inline highlighting
  while i < originalLines.len or j < newLines.len:
    if i < originalLines.len and j < newLines.len and originalLines[i] == newLines[j]:
      # Lines match - show as context (skip for brevity unless near changes)
      inc i
      inc j
    elif i < originalLines.len and (j >= newLines.len or originalLines[i] != newLines[j]):
      # Line removed or changed
      if j < newLines.len and originalLines[i] != newLines[j]:
        # Line changed - show with inline diff
        let (oldSegments, newSegments) = computeCharDiff(originalLines[i], newLines[j])
        
        let removedLine = InlineDiffLine(
          lineType: Removed,
          segments: oldSegments,
          originalLineNum: i + 1,
          newLineNum: -1
        )
        let addedLine = InlineDiffLine(
          lineType: Added,
          segments: newSegments,
          originalLineNum: -1,
          newLineNum: j + 1
        )
        
        diffResult.add("  " & formatInlineDiffLine(removedLine, lineColors, segmentColors, config) & "\n")
        diffResult.add("  " & formatInlineDiffLine(addedLine, lineColors, segmentColors, config) & "\n")
        
        inc i
        inc j
      else:
        # Line only removed
        let segments = @[DiffSegment(content: originalLines[i], segmentType: Unchanged)]
        let removedLine = InlineDiffLine(
          lineType: Removed,
          segments: segments,
          originalLineNum: i + 1,
          newLineNum: -1
        )
        diffResult.add("  " & formatInlineDiffLine(removedLine, lineColors, segmentColors, config) & "\n")
        inc i
    elif j < newLines.len:
      # Line only added
      let segments = @[DiffSegment(content: newLines[j], segmentType: Unchanged)]
      let addedLine = InlineDiffLine(
        lineType: Added,
        segments: segments,
        originalLineNum: -1,
        newLineNum: j + 1
      )
      diffResult.add("  " & formatInlineDiffLine(addedLine, lineColors, segmentColors, config) & "\n")
      inc j
  
  return diffResult.strip()

proc formatToolResult*(toolInfo: ToolDisplayInfo, config: ToolVisualizationConfig): string =
  ## Format tool result with appropriate styling and truncation
  if not config.showToolResults:
    return ""
  
  let theme = getCurrentTheme()
  var resultText = toolInfo.result
  
  # Truncate if needed
  if config.maxResultLength > 0 and resultText.len > config.maxResultLength:
    resultText = resultText[0..<config.maxResultLength] & "\n... (truncated)"
  
  # Format based on tool type and result
  var formattedResult = ""
  
  case toolInfo.name:
  of "edit":
    # For edit tool, try to extract and format diff information
    if config.showDiffs:
      try:
        let resultJson = parseJson(toolInfo.result)
        if resultJson.hasKey("path") and resultJson.hasKey("changes_made"):
          let path = resultJson["path"].getStr()
          let changesMade = resultJson["changes_made"].getBool()
          
          if changesMade:
            var summary = fmt"Updated {path}"
            
            # Add size change info if available
            if resultJson.hasKey("size_change"):
              let sizeChange = resultJson["size_change"].getInt()
              if sizeChange > 0:
                summary.add(fmt" (+{sizeChange} chars)")
              elif sizeChange < 0:
                summary.add(fmt" ({sizeChange} chars)")
            
            # Add line range info if available
            if resultJson.hasKey("line_range"):
              let lineRange = resultJson["line_range"]
              if lineRange.kind == JArray and lineRange.len == 2:
                let startLine = lineRange[0].getInt()
                let endLine = lineRange[1].getInt()
                summary.add(fmt" (lines {startLine}-{endLine})")
            
            formattedResult = summary
          else:
            formattedResult = fmt"No changes made to {path}"
        else:
          formattedResult = resultText
      except:
        formattedResult = resultText
    else:
      formattedResult = resultText
  
  of "read":
    # For read tool, show file info
    let lines = resultText.splitLines()
    if lines.len > 1:
      formattedResult = fmt"Read {lines.len} lines"
    else:
      formattedResult = "Read file"
  
  of "create":
    # For create tool, show creation confirmation
    try:
      let resultJson = parseJson(toolInfo.result)
      if resultJson.hasKey("path"):
        let path = resultJson["path"].getStr()
        formattedResult = fmt"Created {path}"
      else:
        formattedResult = resultText
    except:
      formattedResult = resultText
  
  of "list":
    # For list tool, show directory content summary
    let lines = resultText.splitLines()
    let fileCount = lines.len - 1  # Subtract header line
    if fileCount > 0:
      formattedResult = fmt"Listed {fileCount} items"
    else:
      formattedResult = "Directory empty"
  
  of "bash":
    # For bash tool, show command execution status
    if toolInfo.success:
      let lines = resultText.splitLines()
      let nonEmptyLines = lines.filterIt(it.strip().len > 0)
      if nonEmptyLines.len > 0:
        formattedResult = fmt"Command executed ({nonEmptyLines.len} lines output)"
      else:
        formattedResult = "Command executed successfully"
    else:
      formattedResult = "Command failed: " & resultText
  
  of "fetch":
    # For fetch tool, show URL fetch status
    let lines = resultText.splitLines()
    if lines.len > 0:
      formattedResult = fmt"Fetched content ({lines.len} lines)"
    else:
      formattedResult = "Fetch completed"
  
  else:
    formattedResult = resultText
  
  # Apply styling if enabled
  if config.useColors and config.indentResults:
    if toolInfo.success:
      return "  " & formatWithStyle(formattedResult, theme.success)
    else:
      return "  " & formatWithStyle(formattedResult, theme.error)
  elif config.indentResults:
    return "  " & formattedResult
  else:
    return formattedResult

proc formatToolVisualization*(toolInfo: ToolDisplayInfo, config: ToolVisualizationConfig = getDefaultToolConfig()): string =
  ## Format complete tool visualization with header and result
  let theme = getCurrentTheme()
  
  # Format header
  let header = formatToolHeader(toolInfo.name, toolInfo.args, config)
  let styledHeader = if config.useColors:
    formatWithStyle(header, theme.toolCall)
  else:
    header
  
  # Format result
  let resultFormatted = formatToolResult(toolInfo, config)
  
  # Combine header and result
  var combinedOutput = styledHeader
  if resultFormatted.len > 0:
    combinedOutput.add("\n" & resultFormatted)
  return combinedOutput

proc displayToolExecution*(toolName: string, args: JsonNode, toolResult: string, success: bool = true, executionTime: float = 0.0, config: ToolVisualizationConfig = getDefaultToolConfig()) =
  ## Display tool execution with visualization
  let toolInfo = ToolDisplayInfo(
    name: toolName,
    args: args,
    result: toolResult,
    success: success,
    executionTime: executionTime
  )
  
  let visualization = formatToolVisualization(toolInfo, config)
  echo visualization

proc createToolDisplayFromResult*(toolName: string, argsJson: string, toolResult: string, success: bool = true): ToolDisplayInfo =
  ## Create tool display info from string arguments
  var args = newJNull()
  try:
    args = parseJson(argsJson)
  except:
    args = %*{"raw": argsJson}
  
  ToolDisplayInfo(
    name: toolName,
    args: args,
    result: toolResult,
    success: success,
    executionTime: 0.0
  )