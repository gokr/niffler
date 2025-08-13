import std/[os, streams, times, strutils, json]
import ../types/tools
import common

type
  ReadTool* = ref object of InternalTool

proc newReadTool*(): ReadTool =
  result = ReadTool()
  result.name = "read"
  result.description = "Read file content with encoding detection and size limits"


proc detectFileEncoding*(path: string): string =
  ## Simple file encoding detection
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

proc execute*(tool: ReadTool, args: JsonNode): string {.gcsafe.} =
  ## Execute read file operation
  # Validate arguments
  validateArgs(args, @["path"])
  
  let path = getArgStr(args, "path")
  let encoding = getOptArgStr(args, "encoding", "auto")
  let maxSize = getOptArgInt(args, "max_size", 10485760)  # 10MB default
  
  # Validate path
  if path.len == 0:
    raise newToolValidationError("read", "path", "non-empty string", "empty string")
  
  # Validate max_size
  if maxSize <= 0:
    raise newToolValidationError("read", "max_size", "positive integer", $maxSize)
  
  if maxSize > 100 * 1024 * 1024:  # 100MB limit
    raise newToolValidationError("read", "max_size", "size under 100MB", $maxSize)
  
  # Validate encoding
  if encoding != "auto" and encoding notin ["utf-8", "utf-16", "utf-32", "ascii", "latin1"]:
    raise newToolValidationError("read", "encoding", "valid encoding", encoding)
  
  let sanitizedPath = sanitizePath(path)
  
  # Check if file exists
  validateFileExists(sanitizedPath)
  
  try:
    # Get file info for metadata
    let fileInfo = attemptUntrackedStat(sanitizedPath)
    
    # Check file size
    validateFileSize(sanitizedPath, maxSize)
    
    # Determine encoding
    let detectedEncoding = if encoding == "auto": detectFileEncoding(sanitizedPath) else: encoding
    
    # Read file content
    var content: string
    case detectedEncoding.toLowerAscii():
      of "utf-8":
        content = attemptUntrackedRead(sanitizedPath)
      of "utf-16":
        let stream = openFileStream(sanitizedPath, fmRead)
        defer: stream.close()
        content = stream.readAll()
      of "utf-32":
        let stream = openFileStream(sanitizedPath, fmRead)
        defer: stream.close()
        content = stream.readAll()
      of "ascii":
        content = attemptUntrackedRead(sanitizedPath)
        # Validate ASCII
        for c in content:
          if ord(c) > 127:
            raise newToolExecutionError("read", "File contains non-ASCII characters", -1, "")
      of "latin1":
        content = attemptUntrackedRead(sanitizedPath)
      else:
        raise newToolExecutionError("read", "Unsupported encoding: " & detectedEncoding, -1, "")
    
    # Get file modification time
    let modTime = fileInfo.lastWriteTime
    
    # Create result JSON
    let resultJson = %*{
      "content": content,
      "path": sanitizedPath,
      "size": fileInfo.size,
      "encoding": detectedEncoding,
      "modified": modTime.toUnix()
    }
    
    return $resultJson
  
  except ToolError as e:
    raise e
  except Exception as e:
    raise newToolExecutionError("read", "Failed to read file: " & e.msg, -1, "")