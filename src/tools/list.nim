## List Tool Implementation
##
## This module implements the 'list' tool which provides directory listing functionality
## with various options for sorting, filtering, and recursion.
##
## ## Features:
## - Basic directory listing with file details (name, size, permissions, etc.)
## - Recursive listing with configurable depth
## - Sorting by name, size, modification time, or type
## - Filtering by file type (file, directory, link)
## - Hidden file inclusion option
##
## ## Usage:
## The tool is invoked through the executeList() proc which takes a JSON object
## with the following parameters:
## - path (required): Directory path to list
## - recursive (optional): Whether to list recursively (default: false)
## - max_depth (optional): Maximum recursion depth (default: 10, max: 100)
## - include_hidden (optional): Include hidden files (default: false)
## - sort_by (optional): Sort criteria - "name", "size", "modified", "type" (default: "name")
## - sort_order (optional): Sort order - "asc" or "desc" (default: "asc")
## - filter_type (optional): Filter by type - "file", "directory", "link"
##
## ## Response Format:
## Returns a JSON object with the directory path, entries array, and metadata about
## the operation (total count, options used, etc.)
##
## Each entry contains:
## - name: File/directory name
## - path: Full path
## - type: "file", "directory", or "link"
## - size: File size in bytes
## - modified: Last modified timestamp (Unix time)
## - permissions: File permissions in rwx format
## - is_dir, is_file, is_link: Boolean flags for type
import std/[os, strutils, times, json, algorithm]
import ../types/tools
import ../types/tool_args
import common

type
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

proc executeList*(args: JsonNode): string {.gcsafe.} =
  ## Execute list directory operation
  var parsedArgs = parseWithDefaults(ListArgs, args, "list")

  # Validate path
  if parsedArgs.path.len == 0:
    raise newToolValidationError("list", "path", "non-empty string", "empty string")

  # Validate max_depth
  if parsedArgs.maxDepth <= 0:
    raise newToolValidationError("list", "max_depth", "positive integer", $parsedArgs.maxDepth)

  if parsedArgs.maxDepth > 100:
    raise newToolValidationError("list", "max_depth", "depth under 100", $parsedArgs.maxDepth)

  # Validate sort_by
  let validSortBy = ["name", "size", "modified", "type"]
  if parsedArgs.sortBy notin validSortBy:
    raise newToolValidationError("list", "sort_by", "one of: " & validSortBy.join(", "), parsedArgs.sortBy)

  # Validate sort_order
  let validSortOrder = ["asc", "desc"]
  if parsedArgs.sortOrder notin validSortOrder:
    raise newToolValidationError("list", "sort_order", "one of: " & validSortOrder.join(", "), parsedArgs.sortOrder)

  let sanitizedPath = sanitizePath(parsedArgs.path)
  
  # Check if directory exists
  validateDirectoryExists(sanitizedPath)
  
  try:
    # Get directory entries
    var entries: seq[ListEntry]
    if parsedArgs.recursive:
      entries = listDirectoryRecursive(sanitizedPath, parsedArgs.maxDepth, parsedArgs.includeHidden)
    else:
      entries = listDirectory(sanitizedPath, parsedArgs.includeHidden)

    # Apply type filter if specified
    if parsedArgs.filterType.len > 0:
      var filteredEntries: seq[ListEntry] = @[]
      for entry in entries:
        if entry.`type` == parsedArgs.filterType:
          filteredEntries.add(entry)
      entries = filteredEntries

    # Sort entries
    sortEntries(entries, parsedArgs.sortBy, parsedArgs.sortOrder)
    
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
      "recursive": parsedArgs.recursive,
      "max_depth": parsedArgs.maxDepth,
      "include_hidden": parsedArgs.includeHidden,
      "sort_by": parsedArgs.sortBy,
      "sort_order": parsedArgs.sortOrder,
      "filter_type": if parsedArgs.filterType.len > 0: %*parsedArgs.filterType else: newJNull()
    }
    
    return $resultJson
  
  except ToolError as e:
    raise e
  except Exception as e:
    raise newToolExecutionError("list", "Failed to list directory: " & e.msg, -1, "")