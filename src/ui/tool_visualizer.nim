## Tool Visualization Module
##
## Provides comprehensive tool execution visualization similar to Claude Code,
## with structured display of tool requests and results including diff visualization.

import std/[strutils, json, strformat, sequtils, os]
import hldiffpkg/edits
import theme
import diff_visualizer
import diff_types
import external_renderer
import ../types/messages
import ../core/constants

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
    maxResultLength: TOOL_RESULT_MAX_LENGTH_SHORT,
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
    maxResultLength: TOOL_RESULT_MAX_LENGTH_LONG,
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
        argParts.add(if cmd.len > TOOL_ARGS_COMPACT_LENGTH: cmd[0..<TOOL_ARGS_COMPACT_LENGTH] & "..." else: cmd)
    of "fetch":
      if args.hasKey("url"):
        argParts.add(args["url"].getStr())
    of "todolist":
      if args.hasKey("operation"):
        let op = args["operation"].getStr()
        case op:
        of "bulk_update":
          if args.hasKey("todos"):
            let todos = args["todos"].getStr()
            let lineCount = todos.splitLines().filterIt(it.strip().startsWith("- [")).len
            argParts.add(fmt"bulk_update({lineCount} items)")
          else:
            argParts.add("bulk_update")
        of "add":
          if args.hasKey("content"):
            let content = args["content"].getStr()
            let shortContent = if content.len > 150: content[0..149] & "..." else: content
            argParts.add("add(\"" & shortContent & "\")")
          else:
            argParts.add("add")
        of "update":
          if args.hasKey("itemId"):
            let itemId = args["itemId"].getInt()
            var updateInfo = fmt"item {itemId}"
            if args.hasKey("state"):
              let state = args["state"].getStr()
              updateInfo.add(fmt" → {state}")
            argParts.add(fmt"update({updateInfo})")
          else:
            argParts.add("update")
        else:
          argParts.add(op)
    
    # Fallback to "raw" key if no specific args were found and raw exists
    if argParts.len == 0 and args.hasKey("raw"):
      let rawArgs = args["raw"].getStr()
      argParts.add(if rawArgs.len > 150: rawArgs[0..149] & "..." else: rawArgs)
    
    let argStr = if argParts.len > 0: argParts.join(", ") else: ""
    return fmt"{toolName}({argStr})"
    
  except:
    return fmt"{toolName}(...)"

proc createInlineDiffFromEditResult*(editResult: string, originalContent: string, newContent: string): string =
  ## Create an enhanced diff visualization from edit tool results using hldiff
  if originalContent == newContent:
    return "  No changes made"

  let lineColors = getDiffColors(currentTheme)
  let segmentColors = getDiffSegmentColors(currentTheme)
  let config = getDefaultDiffConfig()
  
  let originalLines = originalContent.splitLines()
  let newLines = newContent.splitLines()
  
  var diffResult = ""
  
  # Use hldiff for accurate diff calculation
  for edit in edits(originalLines, newLines):
    case edit.ek:
    of ekEql:
      # Skip context lines for brevity in inline display
      continue
    of ekDel:
      # Deleted lines
      for i in edit.s:
        if i < originalLines.len:
          let segments = @[DiffSegment(content: originalLines[i], segmentType: Unchanged)]
          let removedLine = InlineDiffLine(
            lineType: Removed,
            segments: segments,
            originalLineNum: i + 1,
            newLineNum: -1
          )
          diffResult.add("  " & formatInlineDiffLine(removedLine, lineColors, segmentColors, config) & "\r\n")
    of ekIns:
      # Inserted lines
      for i in edit.t:
        if i < newLines.len:
          let segments = @[DiffSegment(content: newLines[i], segmentType: Unchanged)]
          let addedLine = InlineDiffLine(
            lineType: Added,
            segments: segments,
            originalLineNum: -1,
            newLineNum: i + 1
          )
          diffResult.add("  " & formatInlineDiffLine(addedLine, lineColors, segmentColors, config) & "\r\n")
    of ekSub:
      # Substituted lines - show with character-level inline diff
      var newIdx = edit.t.a
      
      # Process substituted lines with character-level highlighting
      for i in edit.s:
        if i < originalLines.len:
          var newLineContent = ""
          if newIdx < newLines.len and newIdx < edit.t.b:
            newLineContent = newLines[newIdx]
            inc newIdx
          
          if newLineContent.len > 0:
            # Line changed - show with inline character diff
            let (oldSegments, newSegments) = computeCharDiff(originalLines[i], newLineContent)
            
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
              newLineNum: newIdx
            )
            
            diffResult.add("  " & formatInlineDiffLine(removedLine, lineColors, segmentColors, config) & "\r\n")
            diffResult.add("  " & formatInlineDiffLine(addedLine, lineColors, segmentColors, config) & "\r\n")
          else:
            # Line only removed
            let segments = @[DiffSegment(content: originalLines[i], segmentType: Unchanged)]
            let removedLine = InlineDiffLine(
              lineType: Removed,
              segments: segments,
              originalLineNum: i + 1,
              newLineNum: -1
            )
            diffResult.add("  " & formatInlineDiffLine(removedLine, lineColors, segmentColors, config) & "\r\n")
      
      # Handle any remaining new lines in the substitution
      while newIdx < edit.t.b and newIdx < newLines.len:
        let segments = @[DiffSegment(content: newLines[newIdx], segmentType: Unchanged)]
        let addedLine = InlineDiffLine(
          lineType: Added,
          segments: segments,
          originalLineNum: -1,
          newLineNum: newIdx + 1
        )
        diffResult.add("  " & formatInlineDiffLine(addedLine, lineColors, segmentColors, config) & "\r\n")
        inc newIdx
  
  return diffResult.strip()

proc formatToolResult*(toolInfo: ToolDisplayInfo, config: ToolVisualizationConfig): string =
  ## Format tool result with appropriate styling and truncation
  if not config.showToolResults:
    return ""
  
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
            
            # Try to show external diff if diff content is available
            if resultJson.hasKey("diff") and config.showDiffs:
              let diffContent = resultJson["diff"].getStr()
              if diffContent.len > 0:
                try:
                  let renderConfig = getCurrentExternalRenderingConfig()
                  let diffResult = renderDiff(diffContent, renderConfig, diffContent)
                  if diffResult.success and diffResult.usedExternal:
                    formattedResult = summary & "\n\n" & diffResult.content
                  else:
                    formattedResult = summary & "\n\n" & diffContent
                except:
                  formattedResult = summary & "\n\n" & diffContent
              else:
                formattedResult = summary
            else:
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
    # For read tool, show file content with potential external rendering
    try:
      let resultJson = parseJson(toolInfo.result)
      if resultJson.hasKey("content"):
        let content = resultJson["content"].getStr()
        let lines = content.splitLines()
        let nonEmptyLines = lines.filterIt(it.strip().len > 0)
        
        # If content appears to be already externally rendered (contains ANSI codes), use as-is
        if content.contains("\e[") or content.contains("\x1b["):
          formattedResult = content
        elif lines.len <= 10 and content.len <= 500:
          # For small files, try external rendering if we have a file path
          if resultJson.hasKey("path"):
            let filePath = resultJson["path"].getStr()
            try:
              let renderConfig = getCurrentExternalRenderingConfig()
              let renderResult = renderContentWithTempFile(content, splitFile(filePath).ext, renderConfig, content)
              if renderResult.success and renderResult.usedExternal:
                formattedResult = renderResult.content
              else:
                formattedResult = content
            except:
              formattedResult = content
          else:
            formattedResult = content
        else:
          formattedResult = fmt"Read {lines.len} lines ({nonEmptyLines.len} non-empty)"
      else:
        formattedResult = "Read file"
    except:
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
    # For list tool, show directory content or summary
    try:
      let resultJson = parseJson(resultText)
      if resultJson.hasKey("entries"):
        let entries = resultJson["entries"].getElems()
        
        if entries.len == 0:
          formattedResult = "Directory empty"
        elif entries.len <= 10:
          # Show actual directory contents if small
          var contentLines: seq[string] = @[]
          for entry in entries:
            let name = entry["name"].getStr()
            let entryType = entry["type"].getStr()
            let typeChar = if entryType == "directory": "📁" else: "📄"
            contentLines.add(fmt"{typeChar} {name}")
          formattedResult = contentLines.join("\r\n")
        else:
          formattedResult = fmt"Listed {entries.len} items"
      else:
        formattedResult = "Listed directory"
    except:
      formattedResult = "Error parsing list result"
  
  of "bash":
    # For bash tool, show command output when relevant
    try:
      let resultJson = parseJson(resultText)
      if resultJson.hasKey("exit_code"):
        let exitCode = resultJson["exit_code"].getInt()
        let output = resultJson{"output"}.getStr("")
        let outputLines = if output.len > 0: output.splitLines() else: @[]
        let nonEmptyLines = outputLines.filterIt(it.strip().len > 0)
        
        if exitCode == 0:
          if output.len > 0:
            # Show actual output if it's small and useful
            if output.len <= 500 and nonEmptyLines.len <= 10:
              formattedResult = output.strip()
            else:
              formattedResult = fmt"Command executed ({nonEmptyLines.len} lines output)"
          else:
            formattedResult = "Command executed"
        else:
          # Always show error output if available
          if output.len > 0:
            if output.len <= 300:
              formattedResult = fmt("Command failed (exit code {exitCode}):\n{output.strip()}")
            else:
              formattedResult = fmt"Command failed (exit code {exitCode}) with {nonEmptyLines.len} lines of output"
          else:
            formattedResult = fmt"Command failed (exit code {exitCode})"
      else:
        # Fallback for other JSON formats
        formattedResult = "Command executed"
    except:
      # Not JSON, treat as raw output (legacy format for exit code 0)
      if toolInfo.success:
        let lines = resultText.splitLines()
        let nonEmptyLines = lines.filterIt(it.strip().len > 0)
        if nonEmptyLines.len > 0 and resultText.len <= 500:
          formattedResult = resultText.strip()
        elif nonEmptyLines.len > 0:
          formattedResult = fmt"Command executed ({nonEmptyLines.len} lines output)"
        else:
          formattedResult = "Command executed"
      else:
        formattedResult = "Command failed: " & resultText
  
  of "fetch":
    # For fetch tool, show URL fetch status
    let lines = resultText.splitLines()
    if lines.len > 0:
      formattedResult = fmt"Fetched content ({lines.len} lines)"
    else:
      formattedResult = "Fetch completed"
  
  of "todolist":
    # For todolist tool, show the actual todo list content like Claude Code
    try:
      let resultJson = parseJson(toolInfo.result)
      if resultJson.hasKey("success") and resultJson["success"].getBool():
        if resultJson.hasKey("todoList"):
          let todoList = resultJson["todoList"].getStr()
          if todoList.strip().len > 0:
            # Show only the formatted todo list content
            formattedResult = todoList
          else:
            formattedResult = "Todo list is empty"
        else:
          formattedResult = if resultJson.hasKey("message"): resultJson["message"].getStr() else: "Todo list updated"
      else:
        formattedResult = "Todo list operation failed"
    except:
      formattedResult = "Todo list updated"
  
  else:
    formattedResult = resultText
  
  # Apply styling if enabled
  if config.useColors and config.indentResults:
    let indentedResult = formattedResult.splitLines().mapIt("  " & it).join("\r\n")
    if toolInfo.success:
      return formatWithStyle(indentedResult, currentTheme.success)
    else:
      return formatWithStyle(indentedResult, currentTheme.error)
  elif config.indentResults:
    return formattedResult.splitLines().mapIt("  " & it).join("\r\n")
  else:
    return formattedResult

proc formatToolVisualization*(toolInfo: ToolDisplayInfo, config: ToolVisualizationConfig = getDefaultToolConfig()): string =
  ## Format complete tool visualization with header and result
  
  # Format header
  let header = formatToolHeader(toolInfo.name, toolInfo.args, config)
  let styledHeader = if config.useColors:
    formatWithStyle(header, currentTheme.toolCall)
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


proc formatToolArgs*(toolName: string, args: JsonNode): string =
  ## Format tool arguments for compact display
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
        argParts.add(if cmd.len > TOOL_ARGS_COMPACT_LENGTH: cmd[0..<TOOL_ARGS_COMPACT_LENGTH] & "..." else: cmd)
    of "fetch":
      if args.hasKey("url"):
        argParts.add(args["url"].getStr())
    of "todolist":
      if args.hasKey("operation"):
        let op = args["operation"].getStr()
        case op:
        of "bulk_update":
          if args.hasKey("todos"):
            let todos = args["todos"].getStr()
            let lineCount = todos.splitLines().filterIt(it.strip().startsWith("- [")).len
            argParts.add(fmt"bulk_update({lineCount} items)")
          else:
            argParts.add("bulk_update")
        of "add":
          if args.hasKey("content"):
            let content = args["content"].getStr()
            let shortContent = if content.len > 150: content[0..149] & "..." else: content
            argParts.add("add(\"" & shortContent & "\")")
          else:
            argParts.add("add")
        of "update":
          if args.hasKey("itemId"):
            let itemId = args["itemId"].getInt()
            var updateInfo = fmt"item {itemId}"
            if args.hasKey("state"):
              let state = args["state"].getStr()
              updateInfo.add(fmt" → {state}")
            argParts.add(fmt"update({updateInfo})")
          else:
            argParts.add("update")
        else:
          argParts.add(op)
    
    # Fallback to "raw" key if no specific args were found and raw exists
    if argParts.len == 0 and args.hasKey("raw"):
      let rawArgs = args["raw"].getStr()
      argParts.add(if rawArgs.len > 150: rawArgs[0..149] & "..." else: rawArgs)
    
    let argStr = if argParts.len > 0: argParts.join(", ") else: ""
    return argStr
    
  except:
    return "..."

proc formatCompactToolRequest*(toolInfo: CompactToolRequestInfo): string =
  ## Format compact one-line tool request display
  let argsStr = formatToolArgs(toolInfo.toolName, toolInfo.args)
  return fmt"{toolInfo.icon} {toolInfo.toolName}({argsStr}) {toolInfo.status}"

proc formatCompactToolResult*(toolInfo: CompactToolResultInfo): string =
  ## Format compact one-line tool result display
  let statusIcon = if toolInfo.success: "✅" else: "❌"
  return fmt"{toolInfo.icon} {toolInfo.toolName} {statusIcon} {toolInfo.resultSummary}"

proc formatCompactToolRequestWithIndent*(toolInfo: CompactToolRequestInfo): string =
  ## Format tool request with 4-space indentation (no hourglass)
  let argsStr = formatToolArgs(toolInfo.toolName, toolInfo.args)
  return fmt"    {toolInfo.icon} {toolInfo.toolName}({argsStr})"

proc formatCompactToolResultWithIndent*(toolInfo: CompactToolResultInfo): string =
  ## Format tool result with 8-space indentation
  let statusIcon = if toolInfo.success: "✅" else: "❌"
  return fmt"        {statusIcon} {toolInfo.resultSummary}"

proc createToolResultSummary*(toolName: string, toolResult: string, success: bool): string =
  ## Create a concise summary of tool execution result
  if not success:
    return "Failed"
  
  case toolName:
  of "read":
    try:
      let resultJson = parseJson(toolResult)
      if resultJson.hasKey("content"):
        let content = resultJson["content"].getStr()
        let lines = content.splitLines()
        return fmt"{lines.len} lines read"
      else:
        return "File read"
    except:
      return "File read"
  
  of "edit":
    try:
      let resultJson = parseJson(toolResult)
      if resultJson.hasKey("path") and resultJson.hasKey("changes_made"):
        let changesMade = resultJson["changes_made"].getBool()
        
        if changesMade:
          var summary = "Updated"
          
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
          
          return summary
        else:
          return fmt"No changes made"
      else:
        return "Edit completed"
    except:
      return "Edit completed"
  
  of "create":
    try:
      let resultJson = parseJson(toolResult)
      if resultJson.hasKey("path"):
        let path = resultJson["path"].getStr()
        return fmt"Created {path.extractFilename()}"
      else:
        return "File created"
    except:
      return "File created"
  
  of "list":
    try:
      let resultJson = parseJson(toolResult)
      if resultJson.hasKey("entries"):
        let entries = resultJson["entries"].getElems()
        if entries.len > 0:
          return fmt"Listed {entries.len} items"
        else:
          return "Directory empty"
      else:
        return "Listed directory"
    except:
      return "Error parsing list result"
  
  of "bash":
    # Check if result is JSON with exit code info
    try:
      let resultJson = parseJson(toolResult)
      if resultJson.kind == JObject and resultJson.hasKey("exit_code"):
        let exitCode = resultJson["exit_code"].getInt()
        let output = resultJson{"output"}.getStr("")
        let outputLines = if output.len > 0: output.splitLines().filterIt(it.strip().len > 0) else: @[]
        
        if exitCode == 0:
          if outputLines.len > 0:
            return fmt"Command executed ({outputLines.len} lines output)"
          else:
            return "Command executed"
        else:
          if outputLines.len > 0:
            return fmt"Command executed, exit code {exitCode} ({outputLines.len} lines output)"
          else:
            return fmt"Command executed, exit code {exitCode}"
      else:
        return "Command executed"
    except:
      # Not JSON, treat as raw output (legacy format for exit code 0)
      let lines = toolResult.splitLines()
      let nonEmptyLines = lines.filterIt(it.strip().len > 0)
      if nonEmptyLines.len > 0:
        return fmt"Command executed ({nonEmptyLines.len} lines output)"
      else:
        return "Command executed"
  
  of "fetch":
    let lines = toolResult.splitLines()
    if lines.len > 0:
      return fmt"Fetched content ({lines.len} lines)"
    else:
      return "Fetch completed"
  
  of "todolist":
    # For todolist tool, show the actual todo list content like Claude Code
    try:
      let resultJson = parseJson(toolResult)
      if resultJson.hasKey("success") and resultJson["success"].getBool():
        if resultJson.hasKey("todoList"):
          let todoList = resultJson["todoList"].getStr()
          if todoList.strip().len > 0:
            # Show only the formatted todo list content
            return todoList
          else:
            return "Todo list is empty"
        elif resultJson.hasKey("message"):
          return resultJson["message"].getStr()
        else:
          return "Todo list updated"
      else:
        return "Todo list operation failed"
    except:
      return "Todo list updated"

  of "task":
    # Format task execution results
    try:
      let resultJson = parseJson(toolResult)
      if resultJson.hasKey("success") and resultJson["success"].getBool():
        var output = "\nTask completed successfully\n"

        # Add summary if available
        if resultJson.hasKey("summary"):
          let summary = resultJson["summary"].getStr().strip()
          if summary.len > 0:
            output.add("\nSummary:\n" & summary & "\n")

        # Add artifacts if any
        if resultJson.hasKey("artifacts"):
          let artifacts = resultJson["artifacts"].getElems()
          if artifacts.len > 0:
            output.add("\nArtifacts:\n")
            for artifact in artifacts:
              output.add("  • " & artifact.getStr() & "\n")

        # Add metrics
        if resultJson.hasKey("tool_calls") or resultJson.hasKey("tokens_used"):
          output.add("\nMetrics:\n")
          if resultJson.hasKey("tool_calls"):
            let toolCalls = resultJson["tool_calls"].getInt()
            output.add(fmt"  • Tool calls: {toolCalls}\n")
          if resultJson.hasKey("tokens_used"):
            let tokensUsed = resultJson["tokens_used"].getInt()
            output.add(fmt"  • Tokens used: {tokensUsed}\n")

        return output.strip()
      else:
        # Task failed
        var output = "\nTask failed\n"
        if resultJson.hasKey("error"):
          let error = resultJson["error"].getStr()
          if error.len > 0:
            output.add("\nError:\n" & error & "\n")
        return output.strip()
    except:
      return "Task execution error"

  else:
    return "Completed"

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