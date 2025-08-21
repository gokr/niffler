## CLI Markdown Renderer
##
## Provides markdown rendering for CLI using ANSI escape codes.

import std/[strutils, re, unicode]
import theme

proc renderInlineMarkdownCLI*(line: string): string =
  ## Render inline markdown formatting (bold, italic, code, links) for CLI
  result = ""
  let theme = getCurrentTheme()
  var i = 0
  
  while i < line.len:
    # Handle triple asterisk ***text*** (bold + italic)
    if i + 2 < line.len and line[i] == '*' and line[i + 1] == '*' and line[i + 2] == '*':
      let endPos = line.find("***", i + 3)
      if endPos != -1:
        let boldItalicText = line[i+3..<endPos]
        result.add(formatWithStyle(boldItalicText, theme.bold))
        i = endPos + 3
        continue
    
    # Handle bold text **text**
    elif i + 1 < line.len and line[i] == '*' and line[i + 1] == '*':
      let endPos = line.find("**", i + 2)
      if endPos != -1:
        let boldText = line[i+2..<endPos]
        result.add(formatWithStyle(boldText, theme.bold))
        i = endPos + 2
        continue
    
    # Handle strikethrough ~~text~~
    elif i + 1 < line.len and line[i] == '~' and line[i + 1] == '~':
      let endPos = line.find("~~", i + 2)
      if endPos != -1:
        let strikeText = line[i+2..<endPos]
        result.add(formatWithStyle(strikeText, theme.italic))  # Use italic style for now
        i = endPos + 2
        continue
    
    # Handle italic text *text* (single asterisk)
    elif i < line.len and line[i] == '*':
      let endPos = line.find("*", i + 1)
      if endPos != -1:
        let italicText = line[i+1..<endPos]
        result.add(formatWithStyle(italicText, theme.italic))
        i = endPos + 1
        continue
    
    # Handle triple underscore ___text___ (bold + italic)
    elif i + 2 < line.len and line[i] == '_' and line[i + 1] == '_' and line[i + 2] == '_':
      let endPos = line.find("___", i + 3)
      if endPos != -1:
        let boldItalicText = line[i+3..<endPos]
        result.add(formatWithStyle(boldItalicText, theme.bold))
        i = endPos + 3
        continue
    
    # Handle bold text __text__
    elif i + 1 < line.len and line[i] == '_' and line[i + 1] == '_':
      let endPos = line.find("__", i + 2)
      if endPos != -1:
        let boldText = line[i+2..<endPos]
        result.add(formatWithStyle(boldText, theme.bold))
        i = endPos + 2
        continue
    
    # Handle italic text _text_ (underscore)
    elif i < line.len and line[i] == '_':
      let endPos = line.find("_", i + 1)
      if endPos != -1:
        let italicText = line[i+1..<endPos]
        result.add(formatWithStyle(italicText, theme.italic))
        i = endPos + 1
        continue
    
    # Handle inline code `text`
    elif i < line.len and line[i] == '`':
      let endPos = line.find("`", i + 1)
      if endPos != -1:
        let codeText = line[i+1..<endPos]
        result.add(formatWithStyle(codeText, theme.code))
        i = endPos + 1
        continue
    
    # Handle links [text](url) - just show the text part
    elif i < line.len and line[i] == '[':
      let closePos = line.find("]", i + 1)
      if closePos != -1 and closePos + 1 < line.len and line[closePos + 1] == '(':
        let urlEnd = line.find(")", closePos + 2)
        if urlEnd != -1:
          let linkText = line[i+1..<closePos]
          result.add(formatWithStyle(linkText, theme.link))
          i = urlEnd + 1
          continue
    
    # Regular character
    result.add(line[i])
    i += 1

proc extractTableCells(line: string): seq[string] =
  ## Extract cells from a table row, cleaning up pipes
  var cells = line.split('|')
  
  # Remove empty first/last cells if they exist (from leading/trailing pipes)
  if cells.len > 0 and cells[0].strip() == "":
    cells.delete(0)
  if cells.len > 0 and cells[^1].strip() == "":
    cells.delete(cells.len - 1)
  
  # Clean and return cells
  result = @[]
  for cell in cells:
    result.add(cell.strip())

proc renderTableRowCLI*(cells: seq[string], columnWidths: seq[int]): string =
  ## Render a table row with proper column alignment
  let theme = getCurrentTheme()
  result = formatWithStyle("│", theme.listBullet)
  
  for i, cell in cells:
    let renderedCell = renderInlineMarkdownCLI(cell)
    # Calculate actual display width (without ANSI codes)
    let displayWidth = cell.len  # Simplified for now
    let width = if i < columnWidths.len: columnWidths[i] else: 10
    let padding = width - displayWidth
    let paddedCell = renderedCell & " ".repeat(max(0, padding))
    result.add(" " & paddedCell & " " & formatWithStyle("│", theme.listBullet))

proc renderTableSeparator*(columnWidths: seq[int]): string =
  ## Render a table separator line with proper column widths
  let theme = getCurrentTheme()
  result = formatWithStyle("├", theme.listBullet)
  for i, width in columnWidths:
    result.add(formatWithStyle("─".repeat(width + 2), theme.listBullet))
    if i < columnWidths.len - 1:
      result.add(formatWithStyle("┼", theme.listBullet))
    else:
      result.add(formatWithStyle("┤", theme.listBullet))

proc renderCompleteTableHelper*(tableLines: seq[string]): string =
  ## Render a complete table with proper column alignment
  result = ""
  var allRows: seq[seq[string]] = @[]
  var columnWidths: seq[int] = @[]
  
  # Extract all cells and calculate column widths
  for line in tableLines:
    if line.contains("-") and line.count("-") > 3:
      continue  # Skip separator lines in calculation
    
    let cells = extractTableCells(line)
    allRows.add(cells)
    
    # Update column widths
    for i, cell in cells:
      let cellWidth = cell.len
      if i >= columnWidths.len:
        columnWidths.add(cellWidth)
      else:
        columnWidths[i] = max(columnWidths[i], cellWidth)
  
  # Ensure minimum column width
  for i in 0..<columnWidths.len:
    columnWidths[i] = max(columnWidths[i], 3)
  
  # Render all rows
  var isFirstRow = true
  var rowCount = 0
  for i, line in tableLines:
    if line.contains("-") and line.count("-") > 3:
      # Skip explicit separator lines - we'll add our own
      continue
    else:
      # Render data row
      let cells = extractTableCells(line)
      result.add(renderTableRowCLI(cells, columnWidths))
      rowCount += 1
      
      # Add separator after header row (first data row)
      if isFirstRow and rowCount == 1:
        result.add('\n')
        result.add(renderTableSeparator(columnWidths))
        isFirstRow = false
    
    if rowCount > 1 or (rowCount == 1 and not isFirstRow):
      result.add('\n')

proc renderMarkdownLineCLI*(line: string): string =
  ## Render a line with markdown formatting for CLI
  let theme = getCurrentTheme()
  
  # Handle different markdown elements
  if line.startsWith("# "):
    # H1 - Large header
    let headerText = line[2..^1]
    result = formatWithStyle("█ " & headerText, theme.header1)
  elif line.startsWith("## "):
    # H2 - Medium header
    let headerText = line[3..^1]
    result = formatWithStyle("▐ " & headerText, theme.header2)
  elif line.startsWith("### "):
    # H3 - Small header
    let headerText = line[4..^1]
    result = formatWithStyle("▌ " & headerText, theme.header3)
  elif line.startsWith("```"):
    # Code block delimiter
    result = formatWithStyle("▓▓▓" & line[3..^1], theme.codeBlock)
  elif line.startsWith("- ") or line.startsWith("* "):
    # Bullet lists
    let listText = line[2..^1]
    result = formatWithStyle("• ", theme.listBullet) & renderInlineMarkdownCLI(listText)
  elif line.match(re"^\\d+\\.\\s"):
    # Numbered lists - just render with normal formatting but apply inline markdown
    result = renderInlineMarkdownCLI(line)
  # Note: Table rendering is now handled in renderMarkdownTextCLI
  elif line.strip().len == 0:
    # Empty line - just keep it empty
    result = ""
  else:
    # Regular text with inline formatting
    result = renderInlineMarkdownCLI(line)

proc renderMarkdownTextCLI*(content: string): string =
  ## Render multi-line markdown content for CLI output with table support
  result = ""
  let lines = content.split('\n')
  var i = 0
  
  while i < lines.len:
    let line = lines[i]
    
    # Check if this line starts a table
    if line.contains("|") and line.count("|") >= 2 and not (line.contains("-") and line.count("-") > 3):
      # Process the entire table as a unit
      var tableLines: seq[string] = @[]
      
      # Collect all table lines
      while i < lines.len and (lines[i].contains("|") or lines[i].strip() == ""):
        if lines[i].strip() != "":
          tableLines.add(lines[i])
        i += 1
      
      # Render the complete table
      if tableLines.len > 0:
        result.add(renderCompleteTableHelper(tableLines))
        if i < lines.len:
          result.add('\n')
      continue
    
    # Regular line processing
    let renderedLine = renderMarkdownLineCLI(line)
    result.add(renderedLine)
    if i < lines.len - 1:
      result.add('\n')
    i += 1

proc renderMarkdownTextCLIStream*(content: string): string =
  ## Simple streaming markdown renderer for real-time output
  ## Applies basic formatting without complex token buffering
  result = ""
  let theme = getCurrentTheme()
  var i = 0
  
  while i < content.len:
    # Handle simple inline formatting on the fly
    # This is a simplified version that works well for streaming
    
    # Handle triple asterisk ***text*** (but only if we can see the complete token)
    if i + 5 < content.len and content[i] == '*' and content[i + 1] == '*' and content[i + 2] == '*':
      let endPos = content.find("***", i + 3)
      if endPos != -1 and endPos < content.len:
        let boldItalicText = content[i+3..<endPos]
        result.add(formatWithStyle(boldItalicText, theme.bold))
        i = endPos + 3
        continue
    
    # Handle bold text **text** (but only if we can see the complete token)
    elif i + 3 < content.len and content[i] == '*' and content[i + 1] == '*':
      let endPos = content.find("**", i + 2)
      if endPos != -1 and endPos < content.len:
        let boldText = content[i+2..<endPos]
        result.add(formatWithStyle(boldText, theme.bold))
        i = endPos + 2
        continue
    
    # Handle strikethrough ~~text~~ (but only if we can see the complete token)
    elif i + 3 < content.len and content[i] == '~' and content[i + 1] == '~':
      let endPos = content.find("~~", i + 2)
      if endPos != -1 and endPos < content.len:
        let strikeText = content[i+2..<endPos]
        result.add(formatWithStyle(strikeText, theme.italic))  # Use italic style for now
        i = endPos + 2
        continue
    
    # Handle italic text *text* (but only if we can see the complete token)
    elif i + 1 < content.len and content[i] == '*':
      let endPos = content.find("*", i + 1)
      if endPos != -1 and endPos < content.len:
        let italicText = content[i+1..<endPos]
        result.add(formatWithStyle(italicText, theme.italic))
        i = endPos + 1
        continue
    
    # Handle triple underscore ___text___ (but only if we can see the complete token)
    elif i + 5 < content.len and content[i] == '_' and content[i + 1] == '_' and content[i + 2] == '_':
      let endPos = content.find("___", i + 3)
      if endPos != -1 and endPos < content.len:
        let boldItalicText = content[i+3..<endPos]
        result.add(formatWithStyle(boldItalicText, theme.bold))
        i = endPos + 3
        continue
    
    # Handle bold text __text__ (but only if we can see the complete token)
    elif i + 3 < content.len and content[i] == '_' and content[i + 1] == '_':
      let endPos = content.find("__", i + 2)
      if endPos != -1 and endPos < content.len:
        let boldText = content[i+2..<endPos]
        result.add(formatWithStyle(boldText, theme.bold))
        i = endPos + 2
        continue
    
    # Handle italic text _text_ (but only if we can see the complete token)
    elif i + 1 < content.len and content[i] == '_':
      let endPos = content.find("_", i + 1)
      if endPos != -1 and endPos < content.len:
        let italicText = content[i+1..<endPos]
        result.add(formatWithStyle(italicText, theme.italic))
        i = endPos + 1
        continue
    
    # Handle inline code `text` (but only if we can see the complete token)
    elif i < content.len and content[i] == '`':
      let endPos = content.find("`", i + 1)
      if endPos != -1 and endPos < content.len:
        let codeText = content[i+1..<endPos]
        result.add(formatWithStyle(codeText, theme.code))
        i = endPos + 1
        continue
    
    # Regular character - just add it
    result.add(content[i])
    i += 1