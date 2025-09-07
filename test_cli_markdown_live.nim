import src/core/[config, database]
import src/ui/[theme, cli, markdown_cli]
import src/types/config as configTypes
import logging

# Test actual CLI markdown functionality
proc testCLIMarkdown() =
  # Initialize basic systems
  let consoleLogger = newConsoleLogger()
  addHandler(consoleLogger)
  setLogFilter(lvlInfo)
  
  # Load config
  let config = loadConfig()
  echo "Config loaded successfully"
  
  # Check if markdown is enabled
  let markdownEnabled = isMarkdownEnabled(config)
  echo "Markdown enabled: ", markdownEnabled
  
  # Initialize themes
  loadThemesFromConfig(config)
  echo "Themes loaded successfully"
  
  # Test writeToConversationArea with markdown
  echo "\n=== Testing writeToConversationArea with markdown enabled ==="
  let testMarkdown = "**Bold text** and *italic text*"
  writeToConversationArea(testMarkdown, fgWhite, styleBright, useMarkdown = true)
  
  echo "\n=== Testing writeToConversationArea with markdown disabled ==="
  writeToConversationArea(testMarkdown, fgWhite, styleBright, useMarkdown = false)
  
  echo "\n=== Testing different markdown elements ==="
  let complexMarkdown = """
# Header 1
## Header 2

This is **bold text**, *italic text*, and `inline code`.

- Bullet point 1
- Bullet point 2

| Column 1 | Column 2 |
|----------|----------|
| Cell 1   | Cell 2   |
"""
  writeToConversationArea(complexMarkdown, fgWhite, styleBright, useMarkdown = true)

when isMainModule:
  testCLIMarkdown()