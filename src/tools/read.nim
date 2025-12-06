## File Reading Tool
##
## This tool provides secure file reading functionality with:
## - File encoding detection and handling
## - Text file type detection based on extensions
## - Safe file content retrieval with size limits
## - Multiple output format options (content, summary, info)
##
## Features:
## - UTF-8, UTF-16 encoding detection via BOM
## - ASCII validation for text files
## - File type detection based on extensions
## - Size and safety validation before reading
## - Detailed file information retrieval

import std/[os, streams, times, strutils, json, strformat]
import ../types/tools
import ../types/tool_args
import ../core/constants
import common

proc detectFileEncoding*(path: string): string =
  ## Detect file encoding by examining BOM and content characteristics
  let content = attemptUntrackedRead(path)
  if content.len == 0:
    return "utf-8"
  
  # Simple UTF-8 BOM detection
  if content.len >= 3 and content[0] == '\xEF' and content[1] == '\xBB' and content[2] == '\xBF':
    return "utf-8"
  
  # Simple UTF-16 BE BOM detection
  if content.len >= 2 and content[0] == '\xFE' and content[1] == '\xFF':
    return "utf-16"
  
  # Simple UTF-16 LE BOM detection
  if content.len >= 2 and content[0] == '\xFF' and content[1] == '\xFE':
    return "utf-16"
  
  # Check if it's valid ASCII
  var isAscii = true
  for c in content:
    if ord(c) > 127:
      isAscii = false
      break
  
  if isAscii:
    return "ascii"
  
  # Default to utf-8
  return "utf-8"

proc parseLineRange*(rangeStr: string): tuple[startLine: int, endLine: int] =
  ## Parse line range string in various formats:
  ## - "1-100" (dash-separated)
  ## - "1,100" (comma-separated)
  ## - "[1,100]" (bracketed comma-separated)
  ## - "b'[660,690]'" (Python bytes literal format)
  var cleanRange = rangeStr.strip()

  # Remove b' prefix and ' suffix if present (Python bytes literal)
  if cleanRange.startsWith("b'") and cleanRange.endsWith("'"):
    cleanRange = cleanRange[2..^2]

  # Remove brackets if present
  if cleanRange.startsWith("[") and cleanRange.endsWith("]"):
    cleanRange = cleanRange[1..^2]

  # Determine separator (dash or comma)
  var parts: seq[string]
  if '-' in cleanRange and ',' notin cleanRange:
    parts = cleanRange.split('-')
  else:
    parts = cleanRange.split(',')

  if parts.len == 2:
    try:
      result.startLine = parseInt(parts[0].strip())
      result.endLine = parseInt(parts[1].strip())
      # Convert to 1-based indexing (Nim uses 0-based internally)
      if result.startLine > 0:
        result.startLine -= 1
      if result.endLine > 0:
        result.endLine -= 1
    except ValueError:
      # Invalid format, return full range
      result.startLine = 0
      result.endLine = -1
  else:
    # Invalid format, return full range
    result.startLine = 0
    result.endLine = -1

proc extractLinesByRange*(content: string, rangeStr: string): string =
  ## Extract lines from content based on range string
  let (startLine, endLine) = parseLineRange(rangeStr)
  let lines = content.splitLines()
  
  if startLine >= lines.len:
    return ""
  
  let actualEndLine = if endLine < 0 or endLine >= lines.len: lines.len - 1 else: endLine
  let startIndex = max(0, startLine)
  let endIndex = min(actualEndLine, lines.len - 1)
  
  if startIndex <= endIndex:
    var extractedLines: seq[string] = @[]
    for i in startIndex..endIndex:
      # Add line numbers as prefixes for clarity
      extractedLines.add($(i + 1) & " | " & lines[i])
    return extractedLines.join("\n")
  else:
    return ""

proc executeRead*(args: JsonNode): string {.gcsafe.} =
  ## Execute read file operation
  var parsedArgs = parseWithDefaults(ReadArgs, args, "read")

  # Validate path
  if parsedArgs.path.len == 0:
    raise newToolValidationError("read", "path", "non-empty string", "empty string")

  # Validate max_size
  if parsedArgs.maxSize <= 0:
    raise newToolValidationError("read", "max_size", "positive integer", $parsedArgs.maxSize)

  if parsedArgs.maxSize > MAX_FETCH_SIZE_LIMIT:
    raise newToolValidationError("read", "max_size", fmt"size under {MAX_FETCH_SIZE_LIMIT} bytes", $parsedArgs.maxSize)

  # Validate encoding
  if parsedArgs.encoding != "auto" and parsedArgs.encoding notin ["utf-8", "utf-16", "utf-32", "ascii", "latin1"]:
    raise newToolValidationError("read", "encoding", "valid encoding", parsedArgs.encoding)

  let sanitizedPath = sanitizePath(parsedArgs.path)
  
  # Check if file exists
  validateFileExists(sanitizedPath)
  
  try:
    # Get file info for metadata
    let fileInfo = attemptUntrackedStat(sanitizedPath)

    # Check file size - if too large AND no linerange specified, suggest using linerange
    # When linerange is provided, we skip pre-read size check and validate after extraction
    if parsedArgs.linerange.len == 0:
      try:
        validateFileSize(sanitizedPath, parsedArgs.maxSize)
      except CatchableError as e:
        if e.msg.contains("bytes") and parsedArgs.maxSize < attemptUntrackedStat(sanitizedPath).size:
          let fileInfo = attemptUntrackedStat(sanitizedPath)
          raise newToolExecutionError("read",
            fmt"File too large ({fileInfo.size} bytes > {parsedArgs.maxSize}). Use linerange parameter to read specific sections, e.g., linerange: '1-100'",
            -1, "")
        else:
          raise

    # Determine encoding
    let detectedEncoding = if parsedArgs.encoding == "auto": detectFileEncoding(sanitizedPath) else: parsedArgs.encoding

    # Read file content
    var fullContent: string
    case detectedEncoding.toLowerAscii():
      of "utf-8":
        fullContent = attemptUntrackedRead(sanitizedPath)
      of "utf-16":
        let stream = openFileStream(sanitizedPath, fmRead)
        defer: stream.close()
        fullContent = stream.readAll()
      of "utf-32":
        let stream = openFileStream(sanitizedPath, fmRead)
        defer: stream.close()
        fullContent = stream.readAll()
      of "ascii":
        fullContent = attemptUntrackedRead(sanitizedPath)
        # Validate ASCII
        for c in fullContent:
          if ord(c) > 127:
            raise newToolExecutionError("read", "File contains non-ASCII characters", -1, "")
      of "latin1":
        fullContent = attemptUntrackedRead(sanitizedPath)
      else:
        raise newToolExecutionError("read", "Unsupported encoding: " & detectedEncoding, -1, "")

    # Count total lines in file
    let allLines = fullContent.splitLines()
    let totalLines = allLines.len

    # Process line range if specified
    var content = fullContent
    var linesRead = totalLines
    var startLine = 1
    var endLine = totalLines

    if parsedArgs.linerange.len > 0:
      content = extractLinesByRange(fullContent, parsedArgs.linerange)
      # Check extracted content size after line range processing
      if content.len > parsedArgs.maxSize:
        raise newToolExecutionError("read",
          fmt"Extracted content too large ({content.len} bytes > {parsedArgs.maxSize}). Use a smaller line range.",
          -1, "")

      # Calculate actual range returned
      let (parsedStart, parsedEnd) = parseLineRange(parsedArgs.linerange)
      startLine = max(1, parsedStart + 1)  # Convert back to 1-based
      endLine = min(totalLines, if parsedEnd < 0: totalLines else: parsedEnd + 1)
      linesRead = if content.len > 0: content.splitLines().len else: 0

    # Note: Content is returned raw for tool results
    # External rendering (batcat) is applied at UI display layer only

    # Get file modification time
    let modTime = fileInfo.lastWriteTime

    # Create result JSON
    let resultJson = %*{
      "content": content,
      "path": sanitizedPath,
      "size": fileInfo.size,
      "encoding": detectedEncoding,
      "modified": modTime.toUnix(),
      "total_lines": totalLines,
      "lines_read": linesRead,
      "start_line": startLine,
      "end_line": endLine
    }

    return $resultJson
  
  except ToolError as e:
    raise e
  except Exception as e:
    raise newToolExecutionError("read", "Failed to read file: " & e.msg, -1, "")