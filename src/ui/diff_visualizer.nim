## Diff Visualization Module
##
## Provides terminal-based colored diff visualization with unified diff format
## and line numbers, similar to git diff --color.

import std/[strutils, tables]
import theme
import diff_types

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

proc computeWordDiff*(oldLine, newLine: string): tuple[oldSegments, newSegments: seq[DiffSegment]] =
  ## Compute word-level diff between two lines
  let oldWords = oldLine.split(' ')
  let newWords = newLine.split(' ')
  
  var oldSegments: seq[DiffSegment] = @[]
  var newSegments: seq[DiffSegment] = @[]
  
  # Simple word-level diff algorithm
  # This can be enhanced with more sophisticated algorithms like Myers' diff
  var i, j = 0
  
  while i < oldWords.len or j < newWords.len:
    if i < oldWords.len and j < newWords.len and oldWords[i] == newWords[j]:
      # Words match - add as unchanged
      oldSegments.add(DiffSegment(content: oldWords[i] & " ", segmentType: Unchanged))
      newSegments.add(DiffSegment(content: newWords[j] & " ", segmentType: Unchanged))
      inc i
      inc j
    elif i < oldWords.len and (j >= newWords.len or oldWords[i] != newWords[j]):
      # Word removed
      oldSegments.add(DiffSegment(content: oldWords[i] & " ", segmentType: RemovedSegment))
      inc i
    elif j < newWords.len:
      # Word added
      newSegments.add(DiffSegment(content: newWords[j] & " ", segmentType: AddedSegment))
      inc j
  
  return (oldSegments, newSegments)

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
  ## Compute diff between original and modified content
  new(result)
  result.originalContent = original
  result.modifiedContent = modified
  
  let originalLines = original.splitLines()
  let modifiedLines = modified.splitLines()
  
  # Simple diff algorithm for now - can be enhanced later
  var i, j = 0
  var currentHunk: DiffHunk
  var inHunk = false
  
  while i < originalLines.len or j < modifiedLines.len:
    if i < originalLines.len and j < modifiedLines.len and originalLines[i] == modifiedLines[j]:
      # Lines match
      if inHunk:
        # Check if we should end the current hunk
        let contextAhead = min(config.contextLines, originalLines.len - i - 1)
        if contextAhead >= config.contextLines:
          # Add remaining context and end hunk
          for k in 0..<config.contextLines:
            if i + k < originalLines.len:
              currentHunk.lines.add(DiffLine(
                lineType: Context,
                content: originalLines[i + k],
                originalLineNum: i + k + 1,
                newLineNum: j + k + 1
              ))
          result.hunks.add(currentHunk)
          currentHunk = DiffHunk()
          inHunk = false
          i += config.contextLines
          j += config.contextLines
          continue
      
      # Add context line if in hunk or before first hunk
      if inHunk or result.hunks.len == 0:
        currentHunk.lines.add(DiffLine(
          lineType: Context,
          content: originalLines[i],
          originalLineNum: i + 1,
          newLineNum: j + 1
        ))
      inc(i)
      inc(j)
    else:
      # Lines don't match - start or continue hunk
      if not inHunk:
        # Start new hunk
        inHunk = true
        currentHunk.originalStart = max(1, i - config.contextLines + 1)
        currentHunk.newStart = max(1, j - config.contextLines + 1)
        
        # Add context lines before the change
        let contextBefore = min(config.contextLines, i)
        for k in countdown(contextBefore - 1, 0):
          currentHunk.lines.add(DiffLine(
            lineType: Context,
            content: originalLines[i - contextBefore + k],
            originalLineNum: i - contextBefore + k + 1,
            newLineNum: j - contextBefore + k + 1
          ))
      
      # Handle deletions
      while i < originalLines.len and (j >= modifiedLines.len or originalLines[i] != modifiedLines[j]):
        currentHunk.lines.add(DiffLine(
          lineType: Removed,
          content: originalLines[i],
          originalLineNum: i + 1,
          newLineNum: -1
        ))
        inc(i)
        inc(currentHunk.originalLines)
      
      # Handle additions
      while j < modifiedLines.len and (i >= originalLines.len or originalLines[i] != modifiedLines[j]):
        currentHunk.lines.add(DiffLine(
          lineType: Added,
          content: modifiedLines[j],
          originalLineNum: -1,
          newLineNum: j + 1
        ))
        inc(j)
        inc(currentHunk.newLines)
  
  # Close final hunk if open
  if inHunk:
    # Add context lines after the change
    let contextAfter = min(config.contextLines, originalLines.len - currentHunk.originalStart - currentHunk.originalLines + 1)
    for k in 0..<contextAfter:
      let lineIdx = currentHunk.originalStart + currentHunk.originalLines + k - 1
      if lineIdx < originalLines.len:
        currentHunk.lines.add(DiffLine(
          lineType: Context,
          content: originalLines[lineIdx],
          originalLineNum: lineIdx + 1,
          newLineNum: currentHunk.newStart + currentHunk.newLines + k
        ))
    result.hunks.add(currentHunk)

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
  var theme = getCurrentTheme()
  let headerColor = if config.useColor: colors[Header] else: theme.normal
  
  result = ""
  if config.useColor:
    result = formatWithStyle("--- " & filePath, headerColor) & "\n"
    result.add(formatWithStyle("+++ " & filePath, headerColor) & "\n")
  else:
    result = "--- " & filePath & "\n"
    result.add("+++ " & filePath & "\n")

proc formatDiffHunk*(hunk: DiffHunk, colors: Table[DiffLineType, ThemeStyle], config: DiffConfig): string =
  ## Format a diff hunk with range information
  var theme = getCurrentTheme()
  let headerColor = if config.useColor: colors[Header] else: theme.normal
  
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
  
  let theme = getCurrentTheme()
  let colors = getDiffColors(theme)
  
  result = formatDiffHeader(diffResult.filePath, colors, config)
  
  for hunk in diffResult.hunks:
    result.add(formatDiffHunk(hunk, colors, config))

proc displayDiff*(diffResult: DiffResult, config: DiffConfig = getDefaultDiffConfig()) =
  ## Display the diff result directly to terminal
  let rendered = renderDiff(diffResult, config)
  if rendered.len > 0:
    echo rendered