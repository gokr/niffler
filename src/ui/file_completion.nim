## File Completion System for @ References
##
## This module provides file completion functionality for the @ file referencing system,
## including recursive directory scanning and binary file filtering.

import std/[os, strutils, algorithm]
import ../tools/common
import ../core/constants

type
  FileCompletion* = object
    name*: string
    path*: string
    isDir*: bool

proc isBinaryFileByContent*(path: string): bool =
  ## Detect binary files by checking for null bytes in the first few KB
  ## This is a fallback for files without extensions
  try:
    let file = open(path, fmRead)
    defer: file.close()
    
    # Read first 4KB of file
    let bufferSize = BUFFER_SIZE
    var buffer = newString(bufferSize)
    let bytesRead = file.readChars(toOpenArray(buffer, 0, bufferSize-1))
    
    # Check for null bytes which are common in binary files
    for i in 0..<bytesRead:
      if buffer[i] == '\0':
        return true
    
    return false
  except:
    # If we can't read the file, assume it's not binary (safe fallback)
    return false

proc isValidTextFile*(path: string): bool =
  ## Check if a file is a valid text file for @ referencing
  ## Uses extension-based detection first, then content-based detection
  let info = getFileInfo(path)
  
  # Directories are not text files but should be included for navigation
  if info.kind == pcDir:
    return true
  
  # First try extension-based detection
  if isTextFile(path):
    return true
  
  # For files without extensions, check content
  let ext = getFileExtension(path)
  if ext.len == 0:
    # No extension - check content for binary markers
    return not isBinaryFileByContent(path)
  
  # Has extension but not in text list - assume binary
  return false

proc getRelativePath*(fullPath: string, basePath: string): string =
  ## Get relative path from basePath to fullPath
  if fullPath.startsWith(basePath):
    let relative = fullPath[basePath.len..^1]
    # Remove leading slash if present
    if relative.startsWith("/"):
      return relative[1..^1]
    elif relative.startsWith("\\"):
      return relative[1..^1]
    else:
      return relative
  else:
    return fullPath

proc scanFilesRecursively*(basePath: string, prefix: string = ""): seq[FileCompletion] =
  ## Recursively scan directory for files, filtering out binary files
  result = @[]
  
  try:
    for kind, path in walkDir(basePath):
      let name = splitPath(path).tail
      
      # Skip hidden files/directories
      if name.startsWith("."):
        continue
      
      # Check if this matches our prefix filter
      if prefix.len > 0:
        let relativePath = getRelativePath(path, getCurrentDir())
        if not relativePath.toLower().contains(prefix.toLower()):
          continue
      
      # For directories, add them and recurse
      if kind == pcDir:
        let relativePath = getRelativePath(path, getCurrentDir())
        result.add(FileCompletion(
          name: name,
          path: relativePath,
          isDir: true
        ))
        
        # Recursively scan subdirectories
        try:
          let subFiles = scanFilesRecursively(path, prefix)
          for file in subFiles:
            # The subFiles already have correct relative paths
            result.add(FileCompletion(
              name: file.name,
              path: file.path,
              isDir: file.isDir
            ))
        except:
          # Skip directories we can't read
          continue
      else:
        # For files, check if they're text files
        if isValidTextFile(path):
          let relativePath = getRelativePath(path, getCurrentDir())
          result.add(FileCompletion(
            name: name,
            path: relativePath,
            isDir: false
          ))
  except:
    # Return empty list on error
    return @[]
  # Sort results alphabetically by path
  result.sort(proc(a, b: FileCompletion): int =
    return a.path.cmp(b.path)
  )
  # Limit to max completions
  if result.len > MAX_FILE_COMPLETIONS:
    result.setLen(MAX_FILE_COMPLETIONS)

proc getFileCompletions*(prefix: string = ""): seq[FileCompletion] =
  ## Get file completions for @ references, filtering out binary files
  ## Returns only text files and directories
  return scanFilesRecursively(getCurrentDir(), prefix)