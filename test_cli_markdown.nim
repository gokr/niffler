import src/core/config
import src/ui/theme
import src/ui/markdown_cli

# Test if markdown rendering works
proc testMarkdownRendering() =
  # Load config
  let config = loadConfig()
  echo "Config loaded successfully"
  
  # Check if markdown is enabled
  let markdownEnabled = isMarkdownEnabled(config)
  echo "Markdown enabled: ", markdownEnabled
  
  # Initialize themes
  loadThemesFromConfig(config)
  echo "Themes loaded successfully"
  
  # Test markdown rendering
  let testText = "**bold text** and *italic text*"
  let rendered = renderMarkdownTextCLI(testText)
  echo "Rendered markdown: ", rendered

when isMainModule:
  testMarkdownRendering()