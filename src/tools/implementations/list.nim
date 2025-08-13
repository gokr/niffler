import std/[os, strutils, times, json, algorithm]
import ../../types/tools
import ../common
import ../registry

type
  ListTool* = ref object of ToolDef

  ListEntry = object
    name: string
    path: string
    `type`: string
    size: int64
    modified: int64
    permissions: string
    isDir: bool
    isFile: bool
    isLink: bool

proc newListTool*(): ListTool =
  result = ListTool()
  result.name = "list"
  result.description = "List directory contents with filtering, sorting, and metadata"

proc validate*(tool: ListTool, args: JsonNode) =
  ## Validate list tool arguments
  validateArgs(args, @["path"])
  
  let path = getArgStr(args, "path")
  let recursive = if args.hasKey("recursive"): getArgBool(args, "recursive") else: false
  let maxDepth = if args.hasKey("max_depth"): getArgInt(args, "max_depth") else: 10
  let includeHidden = if args.hasKey("include_hidden"): getArgBool(args, "include_hidden") else: false
  let sortBy = if args.hasKey("sort_by"): getArgStr(args, "sort_by") else: "name"
  let sortOrder = if args.hasKey("sort_order"): getArgStr(args, "sort_order") else: "asc"
  
  # Validate path
  if path.len == 0:
    raise newToolValidationError("list", "path", "non-empty string", "empty string")
  
  let sanitizedPath = sanitizePath(path)
  
  # Check if directory exists
  validateDirectoryExists(sanitizedPath)
  
  # Validate max_depth
  if maxDepth <= 0:
    raise newToolValidationError("list", "max_depth", "positive integer", $maxDepth)
  
  if maxDepth > 100:
    raise newToolValidationError("list", "max_depth", "depth under 100", $maxDepth)
  
  # Validate sort_by
  let validSortBy = ["name", "size", "modified", "type"]
  if sortBy notin validSortBy:
    raise newToolValidationError("list", "sort_by", "one of: " & validSortBy.join(", "), sortBy)
  
  # Validate sort_order
  let validSortOrder = ["asc", "desc"]
  if sortOrder notin validSortOrder:
    raise newToolValidationError("list", "sort_order", "one of: " & validSortOrder.join(", "), sortOrder)

proc getPermissions*(path: string): string =
  ## Get file permissions as a string (rwx format)
  try:
    let info = getFileInfo(path)
    result = ""
    
    # Owner permissions
    result.add(if fpUserRead in info.permissions: "r" else: "-")
    result.add(if fpUserWrite in info.permissions: "w" else: "-")
    result.add(if fpUserExec in info.permissions: "x" else: "-")
    
    # Group permissions
    result.add(if fpGroupRead in info.permissions: "r" else: "-")
    result.add(if fpGroupWrite in info.permissions: "w" else: "-")
    result.add(if fpGroupExec in info.permissions: "x" else: "-")
    
    # Other permissions
    result.add(if fpOthersRead in info.permissions: "r" else: "-")
    result.add(if fpOthersWrite in info.permissions: "w" else: "-")
    result.add(if fpOthersExec in info.permissions: "x" else: "-")
  except OSError:
    return "---------"

proc createListEntry*(path: string, name: string = ""): ListEntry =
  ## Create a list entry from a file path
  let actualName = if name.len > 0: name else: splitPath(path).tail
  let info = attemptUntrackedStat(path)
  
  result = ListEntry(
    name: actualName,
    path: path,
    `type`: 
      if info.kind == pcDir: "directory"
      elif info.kind == pcFile: "file"
      elif info.kind == pcLinkToFile or info.kind == pcLinkToDir: "link"
      else: "other",
    size: info.size,
    modified: info.lastWriteTime.toUnix(),
    permissions: getPermissions(path),
    isDir: info.kind == pcDir,
    isFile: info.kind == pcFile,
    isLink: info.kind == pcLinkToFile or info.kind == pcLinkToDir
  )

proc listDirectory*(path: string, includeHidden: bool = false): seq[ListEntry] =
  ## List contents of a single directory
  result = @[]
  
  for kind, path in walkDir(path):
    let name = splitPath(path).tail
    
    # Skip hidden files if not included
    if not includeHidden and name.startsWith("."):
      continue
    
    result.add(createListEntry(path, name))

proc listDirectoryRecursive*(path: string, maxDepth: int, includeHidden: bool = false, currentDepth: int = 0): seq[ListEntry] =
  ## List directory contents recursively
  result = @[]
  
  if currentDepth >= maxDepth:
    return
  
  # Add current directory contents
  let entries = listDirectory(path, includeHidden)
  result.add(entries)
  
  # Recursively list subdirectories
  for entry in entries:
    if entry.isDir:
      let subEntries = listDirectoryRecursive(entry.path, maxDepth, includeHidden, currentDepth + 1)
      result.add(subEntries)

proc sortEntries*(entries: var seq[ListEntry], sortBy: string, sortOrder: string) =
  ## Sort entries by specified criteria
  proc compare(a, b: ListEntry): int =
    case sortBy.toLowerAscii():
      of "name":
        result = cmp(a.name.toLowerAscii(), b.name.toLowerAscii())
      of "size":
        result = cmp(a.size, b.size)
      of "modified":
        result = cmp(a.modified, b.modified)
      of "type":
        result = cmp(a.`type`, b.`type`)
      else:
        result = cmp(a.name.toLowerAscii(), b.name.toLowerAscii())
    
    if sortOrder.toLowerAscii() == "desc":
      result = -result
  
  entries.sort(compare)

proc execute*(tool: ListTool, args: JsonNode): string =
  ## Execute list directory operation
  let path = getArgStr(args, "path")
  let recursive = if args.hasKey("recursive"): getArgBool(args, "recursive") else: false
  let maxDepth = if args.hasKey("max_depth"): getArgInt(args, "max_depth") else: 10
  let includeHidden = if args.hasKey("include_hidden"): getArgBool(args, "include_hidden") else: false
  let sortBy = if args.hasKey("sort_by"): getArgStr(args, "sort_by") else: "name"
  let sortOrder = if args.hasKey("sort_order"): getArgStr(args, "sort_order") else: "asc"
  let filterType = if args.hasKey("filter_type"): getArgStr(args, "filter_type") else: ""
  
  let sanitizedPath = sanitizePath(path)
  
  try:
    # Get directory entries
    var entries: seq[ListEntry]
    if recursive:
      entries = listDirectoryRecursive(sanitizedPath, maxDepth, includeHidden)
    else:
      entries = listDirectory(sanitizedPath, includeHidden)
    
    # Apply type filter if specified
    if filterType.len > 0:
      var filteredEntries: seq[ListEntry] = @[]
      for entry in entries:
        if entry.`type` == filterType:
          filteredEntries.add(entry)
      entries = filteredEntries
    
    # Sort entries
    sortEntries(entries, sortBy, sortOrder)
    
    # Convert to JSON
    var jsonEntries = newJArray()
    for entry in entries:
      let jsonEntry = %*{
        "name": entry.name,
        "path": entry.path,
        "type": entry.`type`,
        "size": entry.size,
        "modified": entry.modified,
        "permissions": entry.permissions,
        "is_dir": entry.isDir,
        "is_file": entry.isFile,
        "is_link": entry.isLink
      }
      jsonEntries.add(jsonEntry)
    
    # Create result
    let resultJson = %*{
      "path": sanitizedPath,
      "entries": jsonEntries,
      "total_count": entries.len,
      "recursive": recursive,
      "max_depth": maxDepth,
      "include_hidden": includeHidden,
      "sort_by": sortBy,
      "sort_order": sortOrder,
      "filter_type": if filterType.len > 0: %*filterType else: newJNull()
    }
    
    return $resultJson
  
  except ToolError as e:
    raise e
  except Exception as e:
    raise newToolExecutionError("list", "Failed to list directory: " & e.msg, -1, "")

# Register the tool
proc registerListTool*() =
  let tool = newListTool()
  let registryPtr = getGlobalToolRegistry()
  var registry = registryPtr[]
  registry.register(tool)

# Create the tool definition for the registry
when isMainModule:
  registerListTool()