## CLI Markdown Renderer
##
## Provides markdown rendering for CLI mode using ANSI escape codes.
## Provides markdown rendering for CLI output using ANSI escape codes.

import std/[strutils, re, unicode]
import theme

proc renderInlineMarkdownCLI*(line: string): string =
  ## Render inline markdown formatting (bold, italic, code, links) for CLI
  result = ""
  let theme = getCurrentTheme()
  var i = 0
  
  while i < line.len:
    # Handle bold text **text**
    if i + 1 < line.len and line[i] == '*' and line[i + 1] == '*':
      let endPos = line.find("**", i + 2)
      if endPos != -1:
        let boldText = line[i+2..<endPos]
        result.add(formatWithStyle(boldText, theme.bold))
        i = endPos + 2
        continue
    
    # Handle italic text *text*
    elif i < line.len and line[i] == '*':
      let endPos = line.find("*", i + 1)
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
  elif line.strip().len == 0:
    # Empty line - just keep it empty
    result = ""
  else:
    # Regular text with inline formatting
    result = renderInlineMarkdownCLI(line)

proc renderMarkdownTextCLI*(content: string): string =
  ## Render multi-line markdown content for CLI output
  result = ""
  let lines = content.split('\n')
  
  for i, line in lines:
    let renderedLine = renderMarkdownLineCLI(line)
    result.add(renderedLine)
    # Add newline except for the last line
    if i < lines.len - 1:
      result.add('\n')

proc renderMarkdownTextCLIStream*(content: string): string =
  ## Simple streaming markdown renderer for real-time output
  ## Applies basic formatting without complex token buffering
  result = ""
  let theme = getCurrentTheme()
  var i = 0
  
  while i < content.len:
    # Handle simple inline formatting on the fly
    # This is a simplified version that works well for streaming
    
    # Handle bold text **text** (but only if we can see the complete token)
    if i + 3 < content.len and content[i] == '*' and content[i + 1] == '*':
      let endPos = content.find("**", i + 2)
      if endPos != -1 and endPos < content.len:
        let boldText = content[i+2..<endPos]
        result.add(formatWithStyle(boldText, theme.bold))
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