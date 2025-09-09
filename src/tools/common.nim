## Common Tool Utilities
##
## This module provides shared utilities and helper functions for all tools:
## - File system validation and safety checks
## - Command execution with timeout and error handling
## - Text processing and file type detection
## - Path sanitization and security validation
## - Error handling and consistent exception types
##
## Security Features:
## - Path traversal protection
## - File size limits for safety
## - Timeout enforcement for commands
## - Input validation and sanitization

import std/[strutils, os, times, strformat, osproc, json, streams, logging]
import ../types/tools
import ../core/constants

proc attempt*[T](errMessage: string, callback: proc(): T {.gcsafe.}): T {.gcsafe.} =
  ## Generic error handling wrapper for operations with consistent error messages
  ## Helper to wrap operations with consistent error handling
  try:
    return callback()
  except:
    raise newToolError("unknown", errMessage)

proc attemptUntrackedStat*(path: string): FileInfo {.gcsafe.} =
  ## Safely get file info with proper error handling and path validation
  ## Attempt to stat a file without tracking it
  return attempt(fmt"Could not stat({path}): does the file exist?", proc(): FileInfo =
    getFileInfo(path)
  )

proc attemptUntrackedRead*(path: string): string {.gcsafe.} =
  ## Safely read file contents with error handling and validation
  ## Attempt to read a file without tracking it
  return attempt(fmt"{path} couldn't be read", proc(): string =
    readFile(path)
  )

proc validateFileExists*(path: string) =
  ## Validate that a file exists and is a regular file (not directory)
  ## Validate that a file exists and is readable
  if not fileExists(path):
    raise newToolValidationError("unknown", "filePath", "existing file", path)
  
  let info = attemptUntrackedStat(path)
  if info.kind != pcFile and info.kind != pcLinkToFile:
    raise newToolValidationError("unknown", "filePath", "regular file", path)

proc validateFileNotExists*(path: string) =
  ## Validate that a file does not exist (for create operations)
  ## Validate that a file does not exist
  if fileExists(path):
    raise newToolValidationError("unknown", "filePath", "non-existent path", path)

proc validateDirectoryExists*(path: string) =
  ## Validate that a directory exists and is accessible
  ## Validate that a directory exists
  if not dirExists(path):
    raise newToolValidationError("unknown", "path", "existing directory", path)

proc validateFileReadable*(path: string) =
  ## Validate that a file can be read successfully
  ## Validate that a file is readable
  try:
    discard readFile(path)
  except IOError:
    raise newToolPermissionError("unknown", path)

proc validateFileWritable*(path: string) =
  ## Validate that a file is writable
  try:
    let file = open(path, fmAppend)
    file.close()
  except IOError:
    raise newToolPermissionError("unknown", path)

proc validateFileSize*(path: string, maxSize: int = MAX_FILE_SIZE) =
  ## Validate that a file is within size limits
  let info = attemptUntrackedStat(path)
  if info.size > maxSize:
    raise newToolValidationError("unknown", "filePath", fmt"file under {maxSize} bytes", fmt"{info.size} bytes")

proc validateTimeout*(timeout: int) =
  ## Validate that timeout is reasonable
  if timeout <= 0:
    raise newToolValidationError("unknown", "timeout", "positive integer", $timeout)
  if timeout > MAX_TIMEOUT:
    raise newToolValidationError("unknown", "timeout", fmt"timeout under {MAX_TIMEOUT}ms", $timeout)

proc getCurrentDirectory*(): string =
  ## Get the current working directory
  return getCurrentDir()

proc sanitizePath*(path: string): string =
  ## Sanitize a file path to prevent directory traversal
  let normalized = if isAbsolute(path): normalizedPath(path) else: normalizedPath(getCurrentDir() / path)
  if normalized.startsWith("..") or normalized.contains("/../") or normalized.contains("\\..\\"):
    raise newToolValidationError("unknown", "path", "safe path", path)
  return normalized

proc joinPaths*(base, path: string): string =
  ## Safely join two paths
  let sanitized = sanitizePath(path)
  return joinPath(base, sanitized)

proc getFileExtension*(path: string): string =
  ## Get the file extension from a path
  let parts = splitFile(path)
  return parts.ext

proc isTextFile*(path: string): bool =
  ## Check if a file is likely a text file
  let ext = getFileExtension(path).toLower()
  let textExtensions = [".txt", ".md", ".nim", ".js", ".ts", ".py", ".json", ".yaml", ".yml", 
                       ".xml", ".html", ".css", ".sh", ".bash", ".zsh", ".fish", ".cfg", ".conf",
                       ".ini", ".toml", ".csv", ".log", ".gitignore", ".dockerignore"]
  return ext in textExtensions

proc formatFileSize*(size: int64): string =
  ## Format file size in human readable format
  const units = ["B", "KB", "MB", "GB", "TB"]
  var size = float(size)
  var unitIndex = 0
  
  while size >= 1024.0 and unitIndex < units.len - 1:
    size /= 1024.0
    inc unitIndex
  
  return fmt"{size:.1f} {units[unitIndex]}"

proc formatTimestamp*(time: Time): string =
  ## Format timestamp in a readable format
  return $time

proc createBackupPath*(originalPath: string): string =
  ## Create a backup file path
  let (dir, name, ext) = splitFile(originalPath)
  let timestamp = now().format("yyyyMMddHHmmss")
  return joinPath(dir, fmt"{name}.backup_{timestamp}{ext}")

proc safeCreateDir*(path: string) =
  ## Safely create a directory and its parents
  try:
    createDir(path)
  except OSError:
    raise newToolPermissionError("unknown", path)

proc checkCommandExists*(command: string): bool =
  ## Check if a command exists in PATH
  try:
    when defined(windows):
      let cmdResult = execCmdEx("where " & command)
    else:
      let cmdResult = execCmdEx("which " & command)
    return cmdResult.exitCode == 0
  except:
    return false

proc getCommandOutput*(command: string, args: seq[string] = @[], timeout: int = DEFAULT_TIMEOUT): string =
  ## Execute a command and get its output with timeout
  let fullCmd = if args.len > 0: command & " " & args.join(" ") else: command
  
  try:
    let process = when defined(windows):
      startProcess("cmd", workingDir = getCurrentDir(), args = ["/c", fullCmd], options = {poUsePath, poStdErrToStdOut})
    else:
      startProcess("bash", workingDir = getCurrentDir(), args = ["-c", fullCmd], options = {poUsePath, poStdErrToStdOut})
    
    # waitForExit returns the exit code and takes timeout in milliseconds
    let exitCode = process.waitForExit(timeout)
    
    if exitCode == -1:
      # Timeout occurred (process was still running)
      process.terminate()
      let _ = process.waitForExit(1000)  # Wait up to 1s for termination
      process.close()
      raise newToolTimeoutError("bash", timeout)
    
    # Read the output
    let output = process.outputStream.readAll()
    process.close()
    
    debug "Tool result: " & $(output: output, exitCode: exitCode)
    if exitCode != 0:
      raise newToolExecutionError("bash", "Command failed with exit code " & $exitCode, exitCode, output)
    
    return output
  except ToolError:
    raise  # Re-raise tool errors as-is
  except OSError as e:
    raise newToolExecutionError("bash", "Command execution failed: " & e.msg, -1, "")
  except Exception as e:
    raise newToolExecutionError("bash", "Unexpected error: " & e.msg, -1, "")


proc validateTodolistArgs*(args: JsonNode): void =
  ## Validate todolist tool arguments
  if not args.hasKey("operation") or args["operation"].kind != JString:
    raise newToolValidationError("todolist", "operation", "string operation", "missing or invalid")
  
  let operation = args["operation"].getStr()
  let validOperations = ["add", "update", "delete", "list", "show", "bulk_update"]
  
  if operation notin validOperations:
    raise newToolValidationError("todolist", "operation", "valid operation (" & validOperations.join(", ") & ")", operation)
  
  case operation:
  of "add":
    if not args.hasKey("content") or args["content"].kind != JString:
      raise newToolValidationError("todolist", "content", "string content", "missing or invalid")
    if args["content"].getStr().len == 0:
      raise newToolValidationError("todolist", "content", "non-empty string", "empty string")
    
    # Priority is optional
    if args.hasKey("priority"):
      if args["priority"].kind != JString:
        raise newToolValidationError("todolist", "priority", "string priority", "invalid type")
      let priority = args["priority"].getStr()
      if priority notin ["high", "medium", "low"]:
        raise newToolValidationError("todolist", "priority", "high|medium|low", priority)
  
  of "update":
    if not args.hasKey("itemId") or args["itemId"].kind != JInt:
      raise newToolValidationError("todolist", "itemId", "integer itemId", "missing or invalid")
    
    # At least one of state, content, or priority must be provided
    if not (args.hasKey("state") or args.hasKey("content") or args.hasKey("priority")):
      raise newToolValidationError("todolist", "update", "at least one of state|content|priority", "none provided")
    
    if args.hasKey("state"):
      if args["state"].kind != JString:
        raise newToolValidationError("todolist", "state", "string state", "invalid type")
      let state = args["state"].getStr()
      if state notin ["pending", "in_progress", "completed", "cancelled"]:
        raise newToolValidationError("todolist", "state", "pending|in_progress|completed|cancelled", state)
    
    if args.hasKey("content"):
      if args["content"].kind != JString:
        raise newToolValidationError("todolist", "content", "string content", "invalid type")
      if args["content"].getStr().len == 0:
        raise newToolValidationError("todolist", "content", "non-empty string", "empty string")
    
    if args.hasKey("priority"):
      if args["priority"].kind != JString:
        raise newToolValidationError("todolist", "priority", "string priority", "invalid type")
      let priority = args["priority"].getStr()
      if priority notin ["high", "medium", "low"]:
        raise newToolValidationError("todolist", "priority", "high|medium|low", priority)
  
  of "bulk_update":
    if not args.hasKey("todos") or args["todos"].kind != JString:
      raise newToolValidationError("todolist", "todos", "string markdown content", "missing or invalid")
    if args["todos"].getStr().len == 0:
      raise newToolValidationError("todolist", "todos", "non-empty markdown content", "empty string")
  
  of "list", "show":
    # No additional arguments required for list/show operations
    discard
  
  else:
    # Should not happen due to earlier validation, but be safe
    raise newToolValidationError("todolist", "operation", "supported operation", operation)

proc getToolIcon*(toolName: string): string =
  ## Get appropriate icon for tool type
  case toolName:
  of "read": return "📖"
  of "edit": return "📝"
  of "list": return "📋"
  of "bash": return "💻"
  of "fetch": return "🌐"
  of "create": return "📁"
  of "todolist": return "📝"  # Use same as edit for now
  else: return "🔧"


proc validateToolArgs*(toolName: string, args: JsonNode): void =
  ## Main validation function - tools handle their own validation internally
  ## This is a placeholder for future schema-based validation
  discard