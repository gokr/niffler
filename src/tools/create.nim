## File Creation Tool
##
## This tool provides secure file creation functionality with:
## - Parent directory creation
## - Content writing with validation
## - File permission handling
## - Path sanitization and security checks
##
## Features:
## - Creates parent directories automatically
## - Validates paths to prevent security issues
## - Supports content creation with proper encoding
## - Error handling with detailed feedback

import std/[os, json, times, logging, strformat, options]
import ../types/tools, ../types/mode
import ../core/database, ../core/conversation_manager, ../core/mode_state
import common


proc createDirectories*(path: string) =
  ## Create parent directories for the given file path if they don't exist
  let (dir, _) = splitPath(path)
  if dir.len > 0 and not dirExists(dir):
    safeCreateDir(dir)

proc setFilePermissions*(path: string, permissions: string) =
  ## Set file permissions (placeholder implementation for future enhancement)
  try:
    # For now, we'll skip setting permissions as it's complex in Nim
    # This can be implemented later with proper permission handling
    discard
  except OSError as e:
    raise newToolExecutionError("create", "Failed to set permissions: " & e.msg, -1, "")

proc createFileWithContent*(path: string, content: string, permissions: string) =
  ## Create file with specified content and set permissions
  try:
    writeFile(path, content)
    setFilePermissions(path, permissions)
  except IOError as e:
    raise newToolExecutionError("create", "Failed to create file: " & e.msg, -1, "")

proc executeCreate*(args: JsonNode): string =
  ## Execute file creation operation with validation and error handling
  validateArgs(args, @["path", "content"])
  let path = getArgStr(args, "path")
  let content = getArgStr(args, "content")
  let overwrite = if args.hasKey("overwrite"): getArgBool(args, "overwrite") else: false
  let createDirs = if args.hasKey("create_dirs"): getArgBool(args, "create_dirs") else: true
  let permissions = if args.hasKey("permissions"): getArgStr(args, "permissions") else: "644"
  
  # Validate path
  if path.len == 0:
    raise newToolValidationError("create", "path", "non-empty string", "empty string")
  
  let sanitizedPath = sanitizePath(path)
  
  # Check if file exists
  if fileExists(sanitizedPath) and not overwrite:
    raise newToolValidationError("create", "path", "non-existent path", "file already exists")
  
  # Validate permissions format
  if permissions.len != 3:
    raise newToolValidationError("create", "permissions", "3-digit octal (e.g., '644')", permissions)
  
  # Validate permission values
  var validOctal = true
  for c in permissions:
    if c notin "01234567":
      validOctal = false
      break
  
  if not validOctal:
    raise newToolValidationError("create", "permissions", "3-digit octal (e.g., '644')", permissions)

  try:
    # Check if file exists
    let fileExistsBefore = fileExists(sanitizedPath)
    
    if fileExistsBefore and not overwrite:
      raise newToolExecutionError("create", "File already exists and overwrite is false", -1, "")
    
    # Create parent directories if requested
    if createDirs:
      createDirectories(sanitizedPath)
    
    # Create the file
    createFileWithContent(sanitizedPath, content, permissions)
    
    # Track file creation in plan mode
    {.gcsafe.}:
      try:
        let currentSession = getCurrentSession()
        if currentSession.isSome() and getCurrentMode() == amPlan:
          let database = getGlobalDatabase()
          if database != nil:
            let conversationId = currentSession.get().conversation.id
            # Convert to relative path for consistency
            let currentDir = getCurrentDir()
            let relativePath = if sanitizedPath.isAbsolute():
              relativePath(sanitizedPath, currentDir)
            else:
              sanitizedPath
            
            discard addPlanModeCreatedFile(database, conversationId, relativePath)
            debug(fmt"Tracked created file in plan mode: {relativePath}")
      except Exception as e:
        debug(fmt"Failed to track plan mode created file: {e.msg}")
    
    # Get file info for result
    let fileInfo = attemptUntrackedStat(sanitizedPath)
    
    # Create result
    let resultJson = %*{
      "path": sanitizedPath,
      "created": not fileExistsBefore,
      "overwritten": fileExistsBefore and overwrite,
      "size": fileInfo.size,
      "permissions": permissions,
      "modified": fileInfo.lastWriteTime.toUnix(),
      "content_length": content.len
    }
    
    return $resultJson
  
  except ToolError as e:
    raise e
  except Exception as e:
    raise newToolExecutionError("create", "Failed to create file: " & e.msg, -1, "")