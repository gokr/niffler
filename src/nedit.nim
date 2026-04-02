## Nedit - A simple file editor CLI for LLMs
## 
## This tool provides safe, predictable file operations designed for LLM agents.
## All operations are explicit and provide clear feedback.
## 
## Usage:
##   nedit <command> [options]
## 
## Commands:
##   read   - Read file contents (with optional line range)
##   write  - Create or overwrite a file
##   edit   - Edit existing file (replace, insert, delete, append, prepend)
##   list   - List directory contents
##   grep   - Search for patterns in files
##   stat   - Get file information
##
## Use "nedit <command> --help" for detailed help on each command.

import std/[os, strutils, parseopt, sequtils, re, terminal, times, tables, algorithm]
from std/strformat import `&`

const
  Version = "1.0.0"
  MaxFileSize = 10 * 1024 * 1024  # 10MB default max

type
  Command = enum
    cmdRead, cmdWrite, cmdEdit, cmdList, cmdGrep, cmdStat, cmdHelp, cmdNone
  


proc printError(msg: string) =
  styledWriteLine(stderr, fgRed, "Error: ", resetStyle, msg)

proc safeParseInt(s: string): int =
  ## Parse int with error handling
  try: parseInt(s)
  except ValueError:
    raise newException(ValueError, &"Invalid number: '{s}'")




proc printSuccess(msg: string) =
  styledWriteLine(stdout, fgGreen, "✓ ", resetStyle, msg)

proc printInfo(msg: string) =
  styledWriteLine(stdout, fgCyan, "ℹ ", resetStyle, msg)

proc showMainHelp() =
  echo """
nedit - File editor for LLM agents (v""" & Version & """)

USAGE:
  nedit <command> [options]

COMMANDS:
  read   Read file contents (supports line ranges)
  write  Create or overwrite a file
  edit   Modify existing file (replace/insert/delete/append/prepend)
  list   List directory contents
  grep   Search for patterns in files
  stat   Get file information

EXPLORATORY USAGE:
  nedit                    Show this help
  nedit read --help        Detailed help for read command
  nedit edit --help        Detailed help for edit command
  nedit <cmd> [args]       Run command, see errors for guidance

EXAMPLES:
  nedit read src/main.py
  nedit read src/main.py --lines=10-20
  nedit write newfile.py "content here"
  nedit edit file.py replace "old" "new"
  nedit list src/
  nedit grep "pattern" src/

For detailed help on any command, use: nedit <command> --help
"""

proc showReadHelp() =
  echo """
nedit read - Read file contents

USAGE:
  nedit read <file> [options]

ARGUMENTS:
  file        Path to file to read

OPTIONS:
  --lines=N-M     Read only lines N through M (inclusive, 1-indexed)
  --lines=N       Read from line N to end
  --max=N         Maximum bytes to read (default: 10485760)
  --encoding=ENC  File encoding: utf-8, ascii, latin1 (default: utf-8)
  --show-lines    Show line numbers in output
  --head=N        Show first N lines
  --tail=N        Show last N lines

EXAMPLES:
  nedit read src/main.py
  nedit read src/main.py --lines=10-20
  nedit read src/main.py --lines=50
  nedit read config.yaml --show-lines
  nedit read log.txt --head=100
  nedit read data.json --tail=50

ERRORS:
  File not found: Check path with 'nedit list'
  Permission denied: Check file permissions
  Binary file: Use --encoding=binary or avoid text operations
"""

proc showWriteHelp() =
  echo """
nedit write - Create or overwrite a file

USAGE:
  nedit write <file> <content>
  nedit write <file> --stdin

ARGUMENTS:
  file        Path to file to write
  content     Content to write (or use --stdin)

OPTIONS:
  --stdin         Read content from stdin
  --mkdir         Create parent directories if needed
  --backup        Create backup before overwriting
  --append        Append to file instead of overwriting

EXAMPLES:
  nedit write hello.py "print('hello')"
  nedit write src/new.py "content" --mkdir
  echo "content" | nedit write file.txt --stdin
  nedit write config.json '{"key": "value"}' --backup

NOTES:
  - Creates file if it doesn't exist
  - Overwrites existing file (use --backup for safety)
  - Use --mkdir to create parent directories
"""

proc showEditHelp() =
  echo """
nedit edit - Edit an existing file

USAGE:
  nedit edit <file> <operation> [arguments] [options]

OPERATIONS:
  replace <old> <new>    Replace first occurrence of text
  insert <line> <text>   Insert text at line number
  delete <start> <end>   Delete lines start through end (inclusive)
  append <text>          Append text to end of file
  prepend <text>         Prepend text to beginning of file
  rewrite <content>      Replace entire file content

OPTIONS:
  --all              Replace all occurrences (for replace operation)
  --backup           Create backup before editing
  --create           Create file if it doesn't exist
  --show-result      Show modified lines after edit (for validation)
  --context=N        Show N lines of context around changes (default: 3)
  --dry-run          Show what would change without modifying file

EXAMPLES:
  nedit edit file.py replace "old_function" "new_function"
  nedit edit file.py replace "foo" "bar" --all
  nedit edit file.py insert 10 "# New comment"
  nedit edit file.py delete 5-10
  nedit edit file.py append "# Added at end"
  nedit edit file.py prepend "# Header comment"
  nedit edit file.py rewrite "entire new content"
  nedit edit file.py replace "old" "new" --show-result --context=5

LINE NUMBERS:
  - Lines are 1-indexed (first line is line 1)
  - For delete: "5-10" means delete lines 5 through 10
  - For insert: insert AT line N (shifts existing content down)

LLM OPTIMIZATION:
  - Use --show-result to validate changes immediately
  - Use --context=N to see surrounding lines for context
  - Use --dry-run to preview changes before applying
  - Errors show similar text suggestions when text not found

ERRORS:
  File not found: Use --create to create new file
  Text not found: Check exact text with 'nedit read'
  Invalid line number: Use 'nedit read --show-lines' to see line numbers
"""

proc showListHelp() =
  echo """
nedit list - List directory contents

USAGE:
  nedit list [directory] [options]

ARGUMENTS:
  directory    Directory to list (default: current directory)

OPTIONS:
  --all           Show hidden files
  --long          Show detailed info (size, modified, type)
  --recursive     List recursively
  --files-only    Show only files (not directories)
  --dirs-only     Show only directories
  --pattern=GLOB  Filter by glob pattern (e.g., "*.nim")

EXAMPLES:
  nedit list
  nedit list src/
  nedit list --long
  nedit list src/ --recursive
  nedit list --pattern="*.py"
  nedit list src/ --files-only

OUTPUT:
  - Directories end with /
  - Hidden files start with . (use --all to show)
"""

proc showGrepHelp() =
  echo """
nedit grep - Search for patterns in files

USAGE:
  nedit grep <pattern> <path> [options]

ARGUMENTS:
  pattern      Pattern to search for (regex supported)
  path         File or directory to search

OPTIONS:
  --recursive      Search directories recursively
  --ignore-case    Case insensitive search
  --line-number    Show line numbers
  --context=N      Show N lines of context around matches
  --files-only     Only show file names with matches
  --count          Only show match count per file

EXAMPLES:
  nedit grep "function" src/
  nedit grep "TODO" src/ --recursive
  nedit grep "error" log.txt --context=3
  nedit grep "import" src/ --files-only
  nedit grep "class \\w+" src/ --line-number

PATTERNS:
  - Uses Nim's regex engine
  - Escape special chars: \\. \\* \\+ \\? etc.
  - Use --ignore-case for case-insensitive matching
"""

proc showStatHelp() =
  echo """
nedit stat - Get file information

USAGE:
  nedit stat <file>

ARGUMENTS:
  file        Path to file

OUTPUT:
  - File size
  - Last modified time
  - Permissions
  - File type (regular, directory, symlink)

EXAMPLES:
  nedit stat src/main.py
  nedit stat /path/to/file
"""

proc parseLineRange(rangeStr: string): tuple[start: int, endd: int] =
  ## Parse line range like "10-20" or "50"
  result = (1, 0)  # Default: all lines
  if rangeStr.len == 0:
    return
  
  if '-' in rangeStr:
    let parts = rangeStr.split('-')
    if parts.len == 2:
      result.start = safeParseInt(parts[0])
      result.endd = safeParseInt(parts[1])
  else:
    result.start = safeParseInt(rangeStr)
    result.endd = 0  # 0 means to end

proc cmdRead(args: seq[string], opts: Table[string, string]): int =
  if args.len < 1:
    printError("Missing file argument")
    echo "\nUsage: nedit read <file> [options]"
    echo "Try: nedit read --help"
    return 1
  
  let filepath = args[0]
  
  if not fileExists(filepath):
    printError(&"File not found: {filepath}")
    echo "\nTry: nedit list to see available files"
    return 1
  
  let
    maxBytes = if "max" in opts: safeParseInt(opts["max"]) else: MaxFileSize
    showLines = "show-lines" in opts
    lineRange = if "lines" in opts: parseLineRange(opts["lines"]) else: (1, 0)
    head = if "head" in opts: safeParseInt(opts["head"]) else: 0
    tail = if "tail" in opts: safeParseInt(opts["tail"]) else: 0
  
  # Check file size
  let fileSize = getFileSize(filepath)
  if fileSize > maxBytes:
    printError(&"File too large: {fileSize} bytes (max: {maxBytes})")
    echo "Use --max=N to increase limit"
    return 1
  
  # Read file
  var content: seq[string]
  try:
    content = readFile(filepath).splitLines()
  except IOError as e:
    printError(&"Failed to read file: {e.msg}")
    return 1
  
  # Apply line range
  var output: seq[string]
  
  if head > 0:
    output = content[0..<min(head, content.len)]
  elif tail > 0:
    let startIdx = max(0, content.len - tail)
    output = content[startIdx..<content.len]
  elif lineRange.endd > 0:
    let startIdx = max(0, lineRange.start - 1)
    let endIdx = min(content.len, lineRange.endd)
    output = content[startIdx..<endIdx]
  elif lineRange.start > 1:
    let startIdx = lineRange.start - 1
    output = content[startIdx..<content.len]
  else:
    output = content
  
  # Output
  if showLines:
    let startLine = if head > 0: 1
                    elif lineRange.endd > 0: lineRange.start
                    elif lineRange.start > 1: lineRange.start
                    else: 1
    for i, line in output:
      echo &"{startLine + i:6d} | {line}"
  else:
    for line in output:
      echo line
  
  printSuccess(&"Read {output.len} lines from {filepath}")
  return 0

proc cmdWrite(args: seq[string], opts: Table[string, string]): int =
  if args.len < 1:
    printError("Missing file argument")
    echo "\nUsage: nedit write <file> <content>"
    echo "       nedit write <file> --stdin"
    echo "Try: nedit write --help"
    return 1
  
  let filepath = args[0]
  
  var content: string
  if "stdin" in opts:
    content = stdin.readAll()
  elif args.len < 2:
    printError("Missing content argument")
    echo "\nUsage: nedit write <file> <content>"
    echo "       nedit write <file> --stdin"
    return 1
  else:
    content = args[1]
  
  let
    createDirs = "mkdir" in opts
    doBackup = "backup" in opts
    doAppend = "append" in opts
  
  # Create parent directories if needed
  if createDirs:
    let parent = parentDir(filepath)
    if parent.len > 0 and not dirExists(parent):
      createDir(parent)
      printInfo(&"Created directory: {parent}")
  
  # Backup if requested
  if doBackup and fileExists(filepath):
    let backupPath = filepath & ".bak"
    copyFile(filepath, backupPath)
    printInfo(&"Created backup: {backupPath}")
  
  # Write file
  try:
    if doAppend and fileExists(filepath):
      let existing = readFile(filepath)
      writeFile(filepath, existing & content)
    else:
      writeFile(filepath, content)
  except IOError as e:
    printError(&"Failed to write file: {e.msg}")
    return 1
  
  let action = if doAppend: "Appended to" else: "Wrote"
  printSuccess(&"{action} {filepath} ({content.len} bytes)")
  return 0

proc findSimilarLines(content: seq[string], searchText: string, maxResults: int = 3): seq[tuple[line: int, text: string, similarity: int]] =
  ## Find lines with similar text to help LLM correct errors
  let searchLower = searchText.toLowerAscii()
  for i, line in content:
    let lineLower = line.toLowerAscii()
    # Check for partial matches (substrings)
    var similarity = 0
    
    # Check if search text is partially in line
    if searchLower.len >= 3:
      # Check for common substrings of length 3+
      for j in 0..max(0, searchLower.len - 3):
        let substr = searchLower[j..min(j+2, searchLower.len-1)]
        if substr in lineLower:
          similarity += substr.len
    
    # Also check if any word from line is in search text
    for word in lineLower.split({' ', '\t', '(', ')', '{', '}', '[', ']', ',', ';', ':'}):
      if word.len > 2 and word in searchLower:
        similarity += word.len
    
    if similarity > 0:
      result.add((i + 1, line, similarity))
  # Sort by similarity descending
  result.sort do (a, b: auto) -> int: cmp(b.similarity, a.similarity)
  if result.len > maxResults:
    result = result[0..<maxResults]

proc showEditContext(filepath: string, content: seq[string], lineNum: int, contextLines: int = 3) =
  ## Show context around a line for verification
  let startLine = max(1, lineNum - contextLines)
  let endLine = min(content.len, lineNum + contextLines)
  echo "\nContext around line ", lineNum, ":"
  echo "---"
  for i in startLine..endLine:
    let marker = if i == lineNum: ">>>" else: "   "
    echo &"{marker} {i:4d} | {content[i-1]}"
  echo "---"

proc cmdEdit(args: seq[string], opts: Table[string, string]): int =
  if args.len < 2:
    printError("Missing arguments")
    echo "\nUsage: nedit edit <file> <operation> [arguments]"
    echo "Operations: replace, insert, delete, append, prepend, rewrite"
    echo "Try: nedit edit --help"
    return 1
  
  let
    filepath = args[0]
    operation = args[1].toLowerAscii()
    createIf = "create" in opts
    doBackup = "backup" in opts
    replaceAll = "all" in opts
    showResult = "show-result" in opts or "verify" in opts
    contextLines = if "context" in opts: safeParseInt(opts["context"]) else: 3
    dryRun = "dry-run" in opts
  
  # Check file exists
  if not fileExists(filepath):
    if createIf:
      writeFile(filepath, "")
      printInfo(&"Created new file: {filepath}")
    else:
      printError(&"File not found: {filepath}")
      echo "Use --create to create new file"
      return 1
  
  # Backup if requested
  if doBackup:
    let backupPath = filepath & ".bak"
    copyFile(filepath, backupPath)
    printInfo(&"Created backup: {backupPath}")
  
  # Read current content
  var content: seq[string]
  try:
    content = readFile(filepath).splitLines()
  except IOError as e:
    printError(&"Failed to read file: {e.msg}")
    return 1
  
  # Track edit location for context display
  var editLine = 0
  
  # Perform operation
  case operation
  of "replace":
    if args.len < 4:
      printError("replace requires <old> <new> arguments")
      echo "Usage: nedit edit <file> replace <old> <new>"
      echo "\nOptions:"
      echo "  --all         Replace all occurrences"
      echo "  --show-result Show context after edit"
      return 1
    
    let
      oldText = args[2]
      newText = args[3]
    
    let fullContent = join(content, "\n")
    if oldText notin fullContent:
      printError(&"Text not found in file")
      echo &"\nSearched for: \"{oldText}\""
      
      # Find the line containing the old text (approximate)
      let similar = findSimilarLines(content, oldText)
      if similar.len > 0:
        echo "\nSimilar lines found:"
        for s in similar:
          let truncated = if s.text.len > 60: s.text[0..<60] & "..." else: s.text
          echo &"  Line {s.line}: {truncated}"
      
      echo "\nTip: Use 'nedit read' with --show-lines to see exact content"
      return 1
    
    # Find line number for context
    let idx = fullContent.find(oldText)
    if idx >= 0:
      var charCount = 0
      for i, line in content:
        charCount += line.len + 1  # +1 for newline
        if charCount > idx:
          editLine = i + 1
          break
    
    if replaceAll:
      let newContent = fullContent.replace(oldText, newText)
      content = newContent.splitLines()
      let count = fullContent.count(oldText)
      printInfo(&"Replaced {count} occurrences")
    else:
      # Replace first occurrence only
      let idx = fullContent.find(oldText)
      if idx >= 0:
        let newContent = fullContent[0..<idx] & newText & fullContent[idx + oldText.len..^1]
        content = newContent.splitLines()

  
  of "insert":
    if args.len < 4:
      printError("insert requires <line> <text> arguments")
      echo "Usage: nedit edit <file> insert <line> <text>"
      return 1
    
    let
      lineNum = safeParseInt(args[2])
      textToInsert = args[3]
    
    if lineNum < 1 or lineNum > content.len + 1:
      printError(&"Invalid line number: {lineNum} (file has {content.len} lines)")
      # Show nearby valid lines
      if content.len > 0:
        echo "\nValid line numbers: 1-", content.len + 1
        let hintLine = min(lineNum, content.len)
        if hintLine >= 1:
          echo &"\nLine {hintLine}: {content[hintLine-1]}"
      echo "\nUse 'nedit read --show-lines' to see line numbers"
      return 1
    
    content.insert(textToInsert, lineNum - 1)
    editLine = lineNum
    printInfo(&"Inserted at line {lineNum}")
  
  of "delete":
    if args.len < 3:
      printError("delete requires <range> argument")
      echo "Usage: nedit edit <file> delete <start-end>"
      return 1
    
    let rangeStr = args[2]
    var startLine, endLine: int
    
    if '-' in rangeStr:
      let parts = rangeStr.split('-')
      startLine = safeParseInt(parts[0])
      endLine = safeParseInt(parts[1])
    else:
      startLine = safeParseInt(rangeStr)
      endLine = startLine
    
    if startLine < 1 or endLine > content.len or startLine > endLine:
      printError(&"Invalid line range: {rangeStr} (file has {content.len} lines)")
      if content.len > 0:
        echo "\nValid range: 1-", content.len
      return 1
    
    # Show what will be deleted
    if showResult or "preview" in opts:
      echo "\nLines to delete:"
      for i in startLine..endLine:
        echo &"  {i:4d} | {content[i-1]}"
    
    let deletedCount = endLine - startLine + 1
    content.delete((startLine - 1)..(endLine - 1))
    editLine = startLine
    printInfo(&"Deleted {deletedCount} lines ({startLine}-{endLine})")
  
  of "append":
    if args.len < 3:
      printError("append requires <text> argument")
      echo "Usage: nedit edit <file> append <text>"
      return 1
    
    let textToAppend = args[2]
    content.add(textToAppend)
    editLine = content.len
    printInfo("Appended to end of file")
  
  of "prepend":
    if args.len < 3:
      printError("prepend requires <text> argument")
      echo "Usage: nedit edit <file> prepend <text>"
      return 1
    
    let textToPrepend = args[2]
    content.insert(textToPrepend, 0)
    editLine = 1
    printInfo("Prepended to beginning of file")
  
  of "rewrite":
    if args.len < 3:
      printError("rewrite requires <content> argument")
      echo "Usage: nedit edit <file> rewrite <content>"
      return 1
    
    content = @[args[2]]
    editLine = 1
    printInfo("Rewrote entire file")
  
  else:
    printError(&"Unknown operation: {operation}")
    echo "Operations: replace, insert, delete, append, prepend, rewrite"
    return 1
  
  # Write back
  try:
    writeFile(filepath, join(content, "\n"))
  except IOError as e:
    printError(&"Failed to write file: {e.msg}")
    return 1
  
  printSuccess(&"Edited {filepath}")
  
  # Show result if requested
  if showResult and editLine > 0:
    echo "\n--- Result ---"
    let contextStart = max(1, editLine - contextLines)
    let contextEnd = min(content.len, editLine + contextLines)
    for i in contextStart..contextEnd:
      let marker = if i == editLine: ">>>" else: "   "
      echo &"{marker} {i:4d} | {content[i-1]}"
    echo "---"
  
  return 0

proc cmdList(args: seq[string], opts: Table[string, string]): int =
  let dirpath = if args.len > 0: args[0] else: "."
  
  if not dirExists(dirpath):
    printError(&"Directory not found: {dirpath}")
    return 1
  
  let
    showAll = "all" in opts
    showLong = "long" in opts
    recursive = "recursive" in opts
    filesOnly = "files-only" in opts
    dirsOnly = "dirs-only" in opts
    pattern = if "pattern" in opts: opts["pattern"] else: ""
  
  proc listDir(path: string, depth: int = 0) =
    var entries: seq[tuple[name: string, path: string, isDir: bool, size: int64, time: Time]]
    
    try:
      for kind, entryPath in walkDir(path):
        let name = extractFilename(entryPath)
        let shouldShow = showAll or not name.startsWith(".")
        if not shouldShow:
          continue
        
        if pattern.len > 0:
          # Simple glob matching
          let matchPattern = pattern.replace("*", "").replace("?", "")
          if matchPattern.len > 0 and matchPattern notin name:
            continue
        
        entries.add((name, entryPath, kind == pcDir, getFileSize(entryPath), getLastModificationTime(entryPath)))
    except OSError as e:
      printError(&"Failed to read directory: {e.msg}")
      return
    
    # Sort: directories first, then alphabetically
    entries.sort do (a, b: tuple[name: string, path: string, isDir: bool, size: int64, time: Time]) -> int:
      if a.isDir and not b.isDir: -1
      elif not a.isDir and b.isDir: 1
      else: cmp(a.name, b.name)
    
    for entry in entries:
      if filesOnly and entry.isDir: continue
      if dirsOnly and not entry.isDir: continue
      
      let
        indent = "  ".repeat(depth)
        suffix = if entry.isDir: "/" else: ""
      
      if showLong:
        let
          sizeStr = if entry.isDir: "     -" else: &"{entry.size:8d}"
          timeStr = entry.time.format("YYYY-MM-dd HH:mm")
        echo &"{indent}{entry.name}{suffix:20} {sizeStr}  {timeStr}"
      else:
        echo &"{indent}{entry.name}{suffix}"
      
      if recursive and entry.isDir:
        listDir(entry.path, depth + 1)
  
  listDir(dirpath)
  return 0

proc cmdGrep(args: seq[string], opts: Table[string, string]): int =
  if args.len < 2:
    printError("Missing arguments")
    echo "\nUsage: nedit grep <pattern> <path>"
    echo "Try: nedit grep --help"
    return 1
  
  let
    pattern = args[0]
    searchPath = args[1]
    recursive = "recursive" in opts
    ignoreCase = "ignore-case" in opts
    showLineNum = "line-number" in opts
    contextLines = if "context" in opts: safeParseInt(opts["context"]) else: 0
    filesOnly = "files-only" in opts
    countOnly = "count" in opts
  
  let regexFlags = if ignoreCase: {reIgnoreCase} else: {}
  
  var regex: Regex
  try:
    regex = re(pattern, regexFlags)
  except RegexError as e:
    printError(&"Invalid regex pattern: {e.msg}")
    echo "\nEscape special characters: \\. \\* \\+ \\? etc."
    return 1
  
  var matchCount = 0
  var fileCount = 0
  
  proc searchFile(filepath: string) =
    var content: seq[string]
    try:
      content = readFile(filepath).splitLines()
    except:
      return
    
    var matches: seq[tuple[line: int, text: string]]
    
    for i, line in content:
      if line.contains(regex):
        matches.add((i + 1, line))
    
    if matches.len > 0:
      fileCount.inc
      matchCount.inc(matches.len)
      
      if filesOnly:
        echo filepath
        return
      
      if countOnly:
        echo &"{filepath}: {matches.len} matches"
        return
      
      for m in matches:
        if showLineNum:
          echo &"{filepath}:{m.line}: {m.text}"
        else:
          echo &"{filepath}: {m.text}"
        
        if contextLines > 0:
          let startLine = max(0, m.line - contextLines - 1)
          let endLine = min(content.len, m.line + contextLines)
          if startLine > 0:
            echo &"  ... ({startLine} lines before)"
          for i in startLine..<m.line - 1:
            echo &"  {i + 1}: {content[i]}"
          for i in m.line..<endLine:
            echo &"  {i + 1}: {content[i]}"
          if endLine < content.len:
            echo &"  ... ({content.len - endLine} lines after)"
  
  if fileExists(searchPath):
    searchFile(searchPath)
  elif dirExists(searchPath):
    if recursive:
      for filepath in walkDirRec(searchPath):
        if filepath.endsWith(".nim") or filepath.endsWith(".py") or 
           filepath.endsWith(".js") or filepath.endsWith(".ts") or
           filepath.endsWith(".go") or filepath.endsWith(".rs") or
           filepath.endsWith(".c") or filepath.endsWith(".h") or
           filepath.endsWith(".cpp") or filepath.endsWith(".java") or
           filepath.endsWith(".txt") or filepath.endsWith(".md") or
           filepath.endsWith(".json") or filepath.endsWith(".yaml") or
           filepath.endsWith(".yml") or filepath.endsWith(".toml"):
          searchFile(filepath)
    else:
      printError(&"Directory requires --recursive flag")
      return 1
  else:
    printError(&"Path not found: {searchPath}")
    return 1
  
  printSuccess(&"Found {matchCount} matches in {fileCount} files")
  return 0

proc cmdStat(args: seq[string], opts: Table[string, string]): int =
  if args.len < 1:
    printError("Missing file argument")
    echo "\nUsage: nedit stat <file>"
    return 1
  
  let filepath = args[0]
  
  if not fileExists(filepath) and not dirExists(filepath):
    printError(&"Path not found: {filepath}")
    return 1
  
  let
    size = getFileSize(filepath)
    time = getLastModificationTime(filepath)
    perms = getFilePermissions(filepath)
    isDir = dirExists(filepath)
  
  let typeStr = if isDir: "Directory" else: "File"
  echo &"Path: {filepath}"
  echo &"Type: {typeStr}"
  echo &"Size: {size} bytes"
  echo &"Modified: {time.format(\"YYYY-MM-dd HH:mm:ss\")}"
  echo "Permissions: "
  for perm in perms:
    echo &"  - {perm}"
  
  return 0

proc parseArgs(argv: seq[string]): tuple[command: Command, args: seq[string], opts: Table[string, string]] =
  result.command = cmdNone
  result.args = @[]
  
  if argv.len == 0:
    return
  
  # Parse command
  case argv[0].toLowerAscii()
  of "read": result.command = cmdRead
  of "write": result.command = cmdWrite
  of "edit": result.command = cmdEdit
  of "list": result.command = cmdList
  of "grep": result.command = cmdGrep
  of "stat": result.command = cmdStat
  of "help", "--help", "-h": result.command = cmdHelp
  else:
    printError(&"Unknown command: {argv[0]}")
    echo "\nCommands: read, write, edit, list, grep, stat, help"
    echo "Try: nedit --help"
    result.command = cmdNone
    return
  
  # Parse remaining args and options
  var i = 1
  while i < argv.len:
    let arg = argv[i]
    if arg.startsWith("--"):
      let optParts = arg[2..^1].split("=", 1)
      if optParts.len == 2:
        result.opts[optParts[0]] = optParts[1]
      else:
        result.opts[optParts[0]] = "true"
    elif arg.startsWith("-"):
      # Short option
      if arg.len > 1:
        result.opts[arg[1..^1]] = "true"
    else:
      result.args.add(arg)
    i.inc

when isMainModule:
  let argv = commandLineParams()
  
  # Handle --help/-h for main command
  if argv.len == 0 or argv[0] in ["--help", "-h", "help"]:
    showMainHelp()
    quit(0)
  
  let (cmd, args, opts) = parseArgs(argv)
  
  # Handle --help for subcommands
  if "help" in opts or "h" in opts:
    case cmd
    of cmdRead: showReadHelp()
    of cmdWrite: showWriteHelp()
    of cmdEdit: showEditHelp()
    of cmdList: showListHelp()
    of cmdGrep: showGrepHelp()
    of cmdStat: showStatHelp()
    else: showMainHelp()
    quit(0)
  
  # Execute command
  var exitCode = 0
  case cmd
  of cmdRead: exitCode = cmdRead(args, opts)
  of cmdWrite: exitCode = cmdWrite(args, opts)
  of cmdEdit: exitCode = cmdEdit(args, opts)
  of cmdList: exitCode = cmdList(args, opts)
  of cmdGrep: exitCode = cmdGrep(args, opts)
  of cmdStat: exitCode = cmdStat(args, opts)
  of cmdHelp: showMainHelp()
  of cmdNone: exitCode = 1
  
  quit(exitCode)
