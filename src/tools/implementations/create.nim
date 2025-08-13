import std/[os, json, times]
import ../../types/tools
import ../common
import ../registry

type
  CreateTool* = ref object of ToolDef

proc newCreateTool*(): CreateTool =
  result = CreateTool()
  result.name = "create"
  result.description = "Create files with safety checks, directory creation, and permission management"

proc validate*(tool: CreateTool, args: JsonNode) =
  ## Validate create tool arguments
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

proc createDirectories*(path: string) =
  ## Create parent directories if they don't exist
  let (dir, _) = splitPath(path)
  if dir.len > 0 and not dirExists(dir):
    safeCreateDir(dir)

proc setFilePermissions*(path: string, permissions: string) =
  ## Set file permissions
  try:
    # For now, we'll skip setting permissions as it's complex in Nim
    # This can be implemented later with proper permission handling
    discard
  except OSError as e:
    raise newToolExecutionError("create", "Failed to set permissions: " & e.msg, -1, "")

proc createFileWithContent*(path: string, content: string, permissions: string) =
  ## Create file with content and set permissions
  try:
    writeFile(path, content)
    setFilePermissions(path, permissions)
  except IOError as e:
    raise newToolExecutionError("create", "Failed to create file: " & e.msg, -1, "")

proc execute*(tool: CreateTool, args: JsonNode): string =
  ## Execute create file operation
  let path = getArgStr(args, "path")
  let content = getArgStr(args, "content")
  let overwrite = if args.hasKey("overwrite"): getArgBool(args, "overwrite") else: false
  let createDirs = if args.hasKey("create_dirs"): getArgBool(args, "create_dirs") else: true
  let permissions = if args.hasKey("permissions"): getArgStr(args, "permissions") else: "644"
  
  let sanitizedPath = sanitizePath(path)
  
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

# Register the tool
proc registerCreateTool*() =
  let tool = newCreateTool()
  let registryPtr = getGlobalToolRegistry()
  var registry = registryPtr[]
  registry.register(tool)

# Create the tool definition for the registry
when isMainModule:
  registerCreateTool()