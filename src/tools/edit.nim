## Edit Tool Implementation
##
## This module implements the file editing functionality for Niffler's tool system.
## It provides comprehensive text manipulation capabilities with safety features
## including automatic backups, path sanitization, and detailed error reporting.
##
## Architecture:
## - EditOperation enum: Defines supported operation types (Replace, Insert, Delete, Append, Prepend, Rewrite)
## - Helper functions: Text manipulation utilities for each operation type
## - executeEdit: Main entry point that validates arguments and applies operations
## - Safety features: Backup creation, path validation, file permission checks
##
## Operation Flow:
## 1. Validate input arguments (path, operation, operation-specific parameters)
## 2. Sanitize file path and validate file existence/permissions
## 3. Create backup file (if requested)
## 4. Apply the specified edit operation to the file content
## 5. Write modified content back to file (if changes were made)
## 6. Return detailed JSON response with operation results
##
## Security Considerations:
## - All file paths are sanitized to prevent directory traversal attacks
## - File permissions are validated before operations
## - Automatic backups prevent data loss
## - Comprehensive error handling with specific error types

import std/[strutils, json, strformat, logging, os, options]
import ../types/tools
import ../types/mode
import ../core/database, ../core/conversation_manager
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
    debug "WARNING: prependText called with empty content - this may indicate a file reading issue"
    return newText
  elif not newText.endsWith("\n"):
    return newText & "\n" & content
  else:
    return newText & content

proc rewriteFile*(path: string, newText: string): string =
  ## Rewrite entire file with new content
  return newText

proc checkPlanModeProtection*(path: string): bool {.gcsafe.} =
  ## Check if a file is protected from editing in plan mode
  ## Returns true if file should be protected (editing should be blocked)
  {.gcsafe.}:
    try:
      # Get current mode from current session
      let currentSession = getCurrentSession()
      if not currentSession.isSome():
        return false  # No active session, no protection
      
      # Get fresh conversation data from database to check current mode
      let database = getGlobalDatabase()
      if database == nil:
        return false  # No database, no protection
      
      let conversationId = currentSession.get().conversation.id
      let conversationOpt = getConversationById(database, conversationId)
      if conversationOpt.isNone():
        return false  # Conversation not found
      
      let conversation = conversationOpt.get()
      if conversation.mode != amPlan:
        return false  # Not in plan mode, no protection needed
      
      # Get plan mode created files state (database and conversationId already retrieved above)
      let createdFiles = getPlanModeCreatedFiles(database, conversationId)
      
      if not createdFiles.enabled:
        return false  # Plan mode not active
      
      # Convert path to relative path for consistent comparison
      let currentDir = getCurrentDir()
      let relativePath = if path.isAbsolute():
        relativePath(path, currentDir)
      else:
        path
      
      # Allow editing if file is in the created files list
      for createdFile in createdFiles.createdFiles:
        if createdFile == relativePath:
          debug(fmt"File {relativePath} was created in plan mode, allowing edit")
          return false
      
      # Allow editing if file doesn't exist (creating new file)
      if not fileExists(path):
        debug(fmt"File {relativePath} doesn't exist, allowing creation")
        return false
      
      # Block editing of existing files not created in plan mode
      debug(fmt"File {relativePath} exists but was not created in plan mode, blocking edit")
      return true
      
    except Exception as e:
      error(fmt"Error checking plan mode protection: {e.msg}")
      return false  # On error, allow the operation (fail open)

proc executeEdit*(args: JsonNode): string {.gcsafe.} =
  ## Execute edit file operation
  # Validate arguments
  validateArgs(args, @["path", "operation"])
  
  let path = getArgStr(args, "path")
  let operation = getArgStr(args, "operation")
  let oldText = if args.hasKey("old_text"): getArgStr(args, "old_text") else: ""
  let newText = if args.hasKey("new_text"): getArgStr(args, "new_text") else: ""
  let createBackup = if args.hasKey("create_backup"): getArgBool(args, "create_backup") else: false
  
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
  
  # File must exist for edit operations
  validateFileExists(sanitizedPath)
  validateFileReadable(sanitizedPath)
  validateFileWritable(sanitizedPath)
  
  # Check plan mode protection (only for existing files)
  if checkPlanModeProtection(sanitizedPath):
    raise newToolValidationError("edit", "file_protection", 
      "Cannot edit existing files in plan mode. You can only edit files created during this plan mode session, or create new files. Switch to code mode to edit existing files.",
      fmt"File '{sanitizedPath}' cannot be edited in plan mode")
  
  try:
    # Read original content
    let originalContent = attemptUntrackedRead(sanitizedPath)
    
    # Debug logging for content reading issues
    debug fmt"Edit operation: path={sanitizedPath}, op={operation}"
    debug fmt"Working directory: {getCurrentDir()}"
    debug fmt"Input path: {path}"
    debug fmt"Sanitized path: {sanitizedPath}"
    debug fmt"Original content length: {originalContent.len}"
    if originalContent.len == 0:
      debug fmt"WARNING: Read empty content from {sanitizedPath} - file exists: {fileExists(sanitizedPath)}"
      debug fmt"File info: size={getFileSize(sanitizedPath)}"
    
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