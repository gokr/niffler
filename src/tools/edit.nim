import std/[strutils, json]
import ../types/tools
import common

type
  EditOperation = enum
    Replace, Insert, Delete, Append, Prepend, Rewrite
proc createBackup*(originalPath: string): string {.gcsafe.} =
  ## Create a backup of the original file
  let backupPath = createBackupPath(originalPath)
  let content = attemptUntrackedRead(originalPath)
  
  try:
    writeFile(backupPath, content)
    return backupPath
  except IOError as e:
    raise newToolExecutionError("edit", "Failed to create backup: " & e.msg, -1, "")

proc findTextInFile*(path: string, searchText: string): tuple[found: bool, lineRange: tuple[start: int, `end`: int]] {.gcsafe.} =
  ## Find text in file and return its line range
  let content = attemptUntrackedRead(path)
  let lines = content.splitLines()
  
  var startLine = -1
  var endLine = -1
  let searchLines = searchText.splitLines()
  
  for i in 0..(lines.len - searchLines.len):
    var match = true
    for j in 0..<searchLines.len:
      if lines[i + j] != searchLines[j]:
        match = false
        break
    
    if match:
      startLine = i + 1  # 1-based line numbering
      endLine = i + searchLines.len
      break
  
  return (found: startLine != -1, lineRange: (start: startLine, `end`: endLine))

proc replaceText*(content: string, oldText: string, newText: string): string =
  ## Replace old text with new text in content
  return content.replace(oldText, newText)

proc insertText*(content: string, newText: string, lineRange: tuple[start: int, `end`: int]): string =
  ## Insert new text at specified line range
  let lines = content.splitLines()
  var resultLines: seq[string] = @[]
  
  # Add lines before insertion point
  for i in 0..<(lineRange.start - 1):
    resultLines.add(lines[i])
  
  # Insert new text
  let newLines = newText.splitLines()
  resultLines.add(newLines)
  
  # Add remaining lines
  for i in (lineRange.start - 1)..<(lines.len):
    resultLines.add(lines[i])
  
  return resultLines.join("\n")

proc deleteText*(content: string, oldText: string): string =
  ## Delete old text from content
  return content.replace(oldText, "")

proc appendText*(content: string, newText: string): string =
  ## Append new text to content
  if content.len == 0:
    return newText
  elif not content.endsWith("\n"):
    return content & "\n" & newText
  else:
    return content & newText

proc prependText*(content: string, newText: string): string =
  ## Prepend new text to content
  if content.len == 0:
    return newText
  elif not newText.endsWith("\n"):
    return newText & "\n" & content
  else:
    return newText & content

proc rewriteFile*(path: string, newText: string): string =
  ## Rewrite entire file with new content
  return newText

proc executeEdit*(args: JsonNode): string {.gcsafe.} =
  ## Execute edit file operation
  # Validate arguments
  validateArgs(args, @["path", "operation"])
  
  let path = getArgStr(args, "path")
  let operation = getArgStr(args, "operation")
  let oldText = if args.hasKey("old_text"): getArgStr(args, "old_text") else: ""
  let newText = if args.hasKey("new_text"): getArgStr(args, "new_text") else: ""
  let createBackup = if args.hasKey("create_backup"): getArgBool(args, "create_backup") else: true
  
  # Validate path
  if path.len == 0:
    raise newToolValidationError("edit", "path", "non-empty string", "empty string")
  
  # Validate operation
  let validOperations = ["replace", "insert", "delete", "append", "prepend", "rewrite"]
  if operation.toLowerAscii() notin validOperations:
    raise newToolValidationError("edit", "operation", "one of: " & validOperations.join(", "), operation)
  
  # Validate operation-specific arguments
  case operation.toLowerAscii():
    of "replace":
      if not args.hasKey("old_text") or not args.hasKey("new_text"):
        raise newToolValidationError("edit", "old_text/new_text", "required for replace operation", "missing")
    of "insert":
      if not args.hasKey("new_text"):
        raise newToolValidationError("edit", "new_text", "required for insert operation", "missing")
      if not args.hasKey("line_range"):
        raise newToolValidationError("edit", "line_range", "required for insert operation", "missing")
    of "delete":
      if not args.hasKey("old_text"):
        raise newToolValidationError("edit", "old_text", "required for delete operation", "missing")
    of "append", "prepend":
      if not args.hasKey("new_text"):
        raise newToolValidationError("edit", "new_text", "required for append/prepend operation", "missing")
    of "rewrite":
      if not args.hasKey("new_text"):
        raise newToolValidationError("edit", "new_text", "required for rewrite operation", "missing")
  
  # Validate line_range if present
  if args.hasKey("line_range"):
    let lineRange = args["line_range"]
    if lineRange.kind != JArray or lineRange.len != 2:
      raise newToolValidationError("edit", "line_range", "array of 2 integers", "invalid format")
    
    let startLine = lineRange[0].getInt()
    let endLine = lineRange[1].getInt()
    
    if startLine <= 0 or endLine <= 0:
      raise newToolValidationError("edit", "line_range", "positive integers", "invalid values")
    
    if startLine > endLine:
      raise newToolValidationError("edit", "line_range", "start <= end", "invalid range")
  
  var lineRange: tuple[start: int, `end`: int] = (0, 0)
  if args.hasKey("line_range"):
    let lr = args["line_range"]
    lineRange = (start: lr[0].getInt(), `end`: lr[1].getInt())
  
  let sanitizedPath = sanitizePath(path)
  
  # Check if file exists (except for create operation)
  if operation.toLowerAscii() != "create":
    validateFileExists(sanitizedPath)
    validateFileReadable(sanitizedPath)
    validateFileWritable(sanitizedPath)
  
  try:
    # Read original content
    let originalContent = attemptUntrackedRead(sanitizedPath)
    
    # Create backup if requested
    var backupPath = ""
    if createBackup:
      backupPath = createBackup(sanitizedPath)
    
    # Parse operation
    let op = case operation.toLowerAscii():
      of "replace": Replace
      of "insert": Insert
      of "delete": Delete
      of "append": Append
      of "prepend": Prepend
      of "rewrite": Rewrite
      else: raise newToolExecutionError("edit", "Invalid operation: " & operation, -1, "")
    
    # Apply edit operation
    var newContent: string
    var changesMade = false
    var actualLineRange: tuple[start: int, `end`: int] = (0, 0)
    
    case op:
      of Replace:
        if oldText notin originalContent:
          raise newToolExecutionError("edit", "Text to replace not found in file", -1, "")
        newContent = replaceText(originalContent, oldText, newText)
        changesMade = newContent != originalContent
        let found = findTextInFile(sanitizedPath, oldText)
        if found.found:
          actualLineRange = found.lineRange
      
      of Insert:
        newContent = insertText(originalContent, newText, lineRange)
        changesMade = true
        actualLineRange = lineRange
      
      of Delete:
        if oldText notin originalContent:
          raise newToolExecutionError("edit", "Text to delete not found in file", -1, "")
        newContent = deleteText(originalContent, oldText)
        changesMade = newContent != originalContent
        let found = findTextInFile(sanitizedPath, oldText)
        if found.found:
          actualLineRange = found.lineRange
      
      of Append:
        newContent = appendText(originalContent, newText)
        changesMade = true
        let lines = originalContent.splitLines()
        actualLineRange = (start: lines.len + 1, `end`: lines.len + newText.splitLines().len)
      
      of Prepend:
        newContent = prependText(originalContent, newText)
        changesMade = true
        actualLineRange = (start: 1, `end`: newText.splitLines().len)
      
      of Rewrite:
        newContent = rewriteFile(sanitizedPath, newText)
        changesMade = true
        let lines = newContent.splitLines()
        actualLineRange = (start: 1, `end`: lines.len)
    
    # Write new content if changes were made
    if changesMade:
      try:
        writeFile(sanitizedPath, newContent)
      except IOError as e:
        raise newToolExecutionError("edit", "Failed to write file: " & e.msg, -1, "")
    
    # Create result
    let resultJson = %*{
      "path": sanitizedPath,
      "operation": operation,
      "changes_made": changesMade,
      "backup_path": if backupPath.len > 0: %*backupPath else: newJNull(),
      "line_range": %*[actualLineRange.start, actualLineRange.`end`],
      "original_size": originalContent.len,
      "new_size": newContent.len,
      "size_change": newContent.len - originalContent.len
    }
    
    return $resultJson
  
  except ToolError as e:
    raise e
  except Exception as e:
    raise newToolExecutionError("edit", "Failed to edit file: " & e.msg, -1, "")