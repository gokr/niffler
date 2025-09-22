## Diff Visualization Module
##
## Provides terminal-based colored diff visualization with unified diff format
## and line numbers, similar to git diff --color.

import std/[strutils, tables]
import hldiffpkg/edits
import theme
import diff_types
import external_renderer

proc getDiffColors*(theme: Theme): Table[DiffLineType, ThemeStyle] =
  ## Get diff-specific colors from theme
  result = initTable[DiffLineType, ThemeStyle]()
  result[Added] = theme.diffAdded
  result[Removed] = theme.diffRemoved
  result[Context] = theme.diffContext
  result[Header] = theme.normal

proc getDiffSegmentColors*(theme: Theme): Table[DiffSegmentType, ThemeStyle] =
  ## Get segment-specific colors from theme
  result = initTable[DiffSegmentType, ThemeStyle]()
  result[Unchanged] = theme.normal
  result[AddedSegment] = theme.diffAddedBg
  result[RemovedSegment] = theme.diffRemovedBg

proc alignLeft*(s: string, width: int): string =
  ## Left-align string in field of specified width
  if s.len >= width:
    return s
  else:
    return s & " ".repeat(width - s.len)

type
  DiffLine* = object
    lineType*: DiffLineType
    content*: string
    originalLineNum*: int  # -1 if not applicable
    newLineNum*: int       # -1 if not applicable
    
  DiffHunk* = object
    originalStart*: int
    originalLines*: int
    newStart*: int
    newLines*: int
    lines*: seq[DiffLine]
    
  DiffResult* = ref object
    filePath*: string
    hunks*: seq[DiffHunk]
    originalContent*: string
    modifiedContent*: string

  DiffConfig* = object
    contextLines*: int
    showLineNumbers*: bool
    useColor*: bool

proc getDefaultDiffConfig*(): DiffConfig =
  ## Get default diff configuration
  DiffConfig(
    contextLines: 3,
    showLineNumbers: true,
    useColor: true
  )


proc computeCharDiff*(oldLine, newLine: string): tuple[oldSegments, newSegments: seq[DiffSegment]] =
  ## Compute character-level diff between two lines for more precise highlighting
  # This is a simplified implementation - can be enhanced with more sophisticated algorithms
  var oldSegments: seq[DiffSegment] = @[]
  var newSegments: seq[DiffSegment] = @[]
  
  if oldLine == newLine:
    oldSegments.add(DiffSegment(content: oldLine, segmentType: Unchanged))
    newSegments.add(DiffSegment(content: newLine, segmentType: Unchanged))
    return (oldSegments, newSegments)
  
  # Find common prefix
  var commonPrefix = 0
  let minLen = min(oldLine.len, newLine.len)
  while commonPrefix < minLen and oldLine[commonPrefix] == newLine[commonPrefix]:
    inc commonPrefix
  
  # Find common suffix
  var commonSuffix = 0
  var oldEnd = oldLine.len - 1
  var newEnd = newLine.len - 1
  while commonSuffix < minLen - commonPrefix and oldLine[oldEnd - commonSuffix] == newLine[newEnd - commonSuffix]:
    inc commonSuffix
  
  # Add prefix (unchanged)
  if commonPrefix > 0:
    let prefixStr = oldLine[0..<commonPrefix]
    oldSegments.add(DiffSegment(content: prefixStr, segmentType: Unchanged))
    newSegments.add(DiffSegment(content: prefixStr, segmentType: Unchanged))
  
  # Add changed middle part
  let oldMiddleStart = commonPrefix
  let oldMiddleEnd = oldLine.len - commonSuffix
  let newMiddleStart = commonPrefix
  let newMiddleEnd = newLine.len - commonSuffix
  
  if oldMiddleStart < oldMiddleEnd:
    let oldMiddle = oldLine[oldMiddleStart..<oldMiddleEnd]
    oldSegments.add(DiffSegment(content: oldMiddle, segmentType: RemovedSegment))
  
  if newMiddleStart < newMiddleEnd:
    let newMiddle = newLine[newMiddleStart..<newMiddleEnd]
    newSegments.add(DiffSegment(content: newMiddle, segmentType: AddedSegment))
  
  # Add suffix (unchanged)
  if commonSuffix > 0:
    let suffixStr = oldLine[(oldLine.len - commonSuffix)..^1]
    oldSegments.add(DiffSegment(content: suffixStr, segmentType: Unchanged))
    newSegments.add(DiffSegment(content: suffixStr, segmentType: Unchanged))
  
  return (oldSegments, newSegments)


proc computeDiff*(original, modified: string, config: DiffConfig = getDefaultDiffConfig()): DiffResult =
  ## Compute diff between original and modified content using hldiff algorithm
  new(result)
  result.originalContent = original
  result.modifiedContent = modified
  
  let originalLines = original.splitLines()
  let modifiedLines = modified.splitLines()
  
  # Use hldiff's grouped edits for unified diff with context
  let sames = sames(originalLines, modifiedLines)
  let editGroups = grouped(sames, config.contextLines)
  
  for editGroup in editGroups:
    var hunk = DiffHunk()
    var lines: seq[DiffLine] = @[]
    
    # Calculate hunk header info from first and last edits
    if editGroup.len > 0:
      let firstEdit = editGroup[0]
      let lastEdit = editGroup[^1]
      
      hunk.originalStart = firstEdit.s.a + 1  # Convert to 1-based
      hunk.newStart = firstEdit.t.a + 1
      hunk.originalLines = lastEdit.s.b - firstEdit.s.a
      hunk.newLines = lastEdit.t.b - firstEdit.t.a
    
    # Convert hldiff edits to DiffLine format
    for edit in editGroup:
      case edit.ek:
      of ekEql:
        # Equal lines - show as context  
        for i in edit.s:
          if i < originalLines.len:
            lines.add(DiffLine(
              lineType: Context,
              content: originalLines[i],
              originalLineNum: i + 1,
              newLineNum: edit.t.a + (i - edit.s.a) + 1
            ))
      of ekDel:
        # Deleted lines
        for i in edit.s:
          if i < originalLines.len:
            lines.add(DiffLine(
              lineType: Removed,
              content: originalLines[i],
              originalLineNum: i + 1,
              newLineNum: -1
            ))
      of ekIns:
        # Inserted lines
        for i in edit.t:
          if i < modifiedLines.len:
            lines.add(DiffLine(
              lineType: Added,
              content: modifiedLines[i],
              originalLineNum: -1,
              newLineNum: i + 1
            ))
      of ekSub:
        # Substituted lines (deleted then added)
        for i in edit.s:
          if i < originalLines.len:
            lines.add(DiffLine(
              lineType: Removed,
              content: originalLines[i],
              originalLineNum: i + 1,
              newLineNum: -1
            ))
        for i in edit.t:
          if i < modifiedLines.len:
            lines.add(DiffLine(
              lineType: Added,
              content: modifiedLines[i],
              originalLineNum: -1,
              newLineNum: i + 1
            ))
    
    hunk.lines = lines
    result.hunks.add(hunk)

proc formatDiffLine*(line: DiffLine, colors: Table[DiffLineType, ThemeStyle], config: DiffConfig): string =
  ## Format a single diff line with colors and line numbers
  var prefix = ""
  var lineNumStr = ""
  
  case line.lineType:
    of Added:
      prefix = "+"
      if config.showLineNumbers:
        lineNumStr = alignLeft($(line.newLineNum), 4) & " "
    of Removed:
      prefix = "-"
      if config.showLineNumbers:
        lineNumStr = alignLeft($(line.originalLineNum), 4) & " "
    of Context:
      prefix = " "
      if config.showLineNumbers:
        let lineNum = if line.originalLineNum != -1: line.originalLineNum else: line.newLineNum
        lineNumStr = alignLeft($lineNum, 4) & " "
    of Header:
      prefix = ""
  
  let content = prefix & lineNumStr & line.content
  
  if config.useColor and line.lineType in colors:
    result = formatWithStyle(content, colors[line.lineType])
  else:
    result = content

proc formatInlineDiffLine*(line: InlineDiffLine, lineColors: Table[DiffLineType, ThemeStyle], segmentColors: Table[DiffSegmentType, ThemeStyle], config: DiffConfig): string =
  ## Format a diff line with inline segment highlighting (Claude Code style)
  var prefix = ""
  var lineNumStr = ""
  
  # Format line number first, then prefix (Claude Code format: "82 + content")
  case line.lineType:
    of Added:
      if config.showLineNumbers:
        lineNumStr = alignLeft($(line.newLineNum), 4) & " "
      prefix = "+"
    of Removed:
      if config.showLineNumbers:
        lineNumStr = alignLeft($(line.originalLineNum), 4) & " "
      prefix = "-"
    of Context:
      if config.showLineNumbers:
        let lineNum = if line.originalLineNum != -1: line.originalLineNum else: line.newLineNum
        lineNumStr = alignLeft($lineNum, 4) & " "
      prefix = " "
    of Header:
      prefix = ""
  
  # Build line content with inline highlighting for changed portions
  var segments = ""
  for segment in line.segments:
    if config.useColor and segment.segmentType in segmentColors and segment.segmentType != Unchanged:
      # Apply darker highlighting to changed portions
      segments.add(formatWithStyle(segment.content, segmentColors[segment.segmentType]))
    else:
      segments.add(segment.content)
  
  # Claude Code format: line number, prefix, two spaces, content
  # Apply full-line background color to the entire line
  let content = lineNumStr & prefix & "  " & segments
  
  if config.useColor and line.lineType in lineColors:
    # Apply light background to entire line
    result = formatWithStyle(content, lineColors[line.lineType])
  else:
    result = content

proc formatDiffHeader*(filePath: string, colors: Table[DiffLineType, ThemeStyle], config: DiffConfig): string =
  ## Format diff header with file information
  let headerColor = if config.useColor: colors[Header] else: currentTheme.normal
  
  result = ""
  if config.useColor:
    result = formatWithStyle("--- " & filePath, headerColor) & "\n"
    result.add(formatWithStyle("+++ " & filePath, headerColor) & "\n")
  else:
    result = "--- " & filePath & "\n"
    result.add("+++ " & filePath & "\n")

proc formatDiffHunk*(hunk: DiffHunk, colors: Table[DiffLineType, ThemeStyle], config: DiffConfig): string =
  ## Format a diff hunk with range information
  let headerColor = if config.useColor: colors[Header] else: currentTheme.normal
  
  let hunkHeader = "@@ -" & $hunk.originalStart & "," & $hunk.originalLines & 
                   " +" & $hunk.newStart & "," & $hunk.newLines & " @@"
  
  if config.useColor:
    result = formatWithStyle(hunkHeader, headerColor) & "\n"
  else:
    result = hunkHeader & "\n"
  
  for line in hunk.lines:
    result.add(formatDiffLine(line, colors, config) & "\n")
  
  return result

proc renderDiff*(diffResult: DiffResult, config: DiffConfig = getDefaultDiffConfig()): string =
  ## Render the complete diff result as a formatted string
  if diffResult.hunks.len == 0:
    return ""
  
  let colors = getDiffColors(currentTheme)
  
  result = formatDiffHeader(diffResult.filePath, colors, config)
  
  for hunk in diffResult.hunks:
    result.add(formatDiffHunk(hunk, colors, config))

proc renderDiffWithExternal*(original, modified: string, filePath: string = "", config: DiffConfig = getDefaultDiffConfig()): string =
  ## Render diff using external tool if configured, with fallback to built-in rendering
  # First create built-in rendering as fallback
  let diffResult = computeDiff(original, modified, config)
  let builtinRendered = renderDiff(diffResult, config)
  
  # Try external rendering if available (this may access global config, but function isn't marked gcsafe)
  try:
    let renderConfig = getCurrentExternalRenderingConfig()
    if renderConfig.enabled:
      let externalResult = renderDiff(builtinRendered, renderConfig, builtinRendered)
      if externalResult.success:
        return externalResult.content
  except:
    discard  # Fall back to built-in rendering
  
  # Fallback to built-in rendering
  return builtinRendered

proc displayDiff*(diffResult: DiffResult, config: DiffConfig = getDefaultDiffConfig()) =
  ## Display the diff result directly to terminal
  let rendered = renderDiff(diffResult, config)
  if rendered.len > 0:
    echo rendered

proc displayDiffWithExternal*(original, modified: string, filePath: string = "", config: DiffConfig = getDefaultDiffConfig()) =
  ## Display diff using external tool if configured, with fallback to built-in rendering
  let rendered = renderDiffWithExternal(original, modified, filePath, config)
  if rendered.len > 0:
    echo rendered