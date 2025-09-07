import std/[unittest, options, strutils]
import ../src/core/config
import ../src/types/config
import ../src/ui/theme
import ../src/ui/markdown_cli

suite "Markdown Debug Tests":
  
  test "Markdown rendering with configuration":
    # Create a minimal test config
    let testConfig = Config(
      yourName: "Test",
      models: @[],
      markdownEnabled: some(true),
      currentTheme: some("default")
    )
    
    # Test config loading functions
    let markdownEnabled = isMarkdownEnabled(testConfig)
    check markdownEnabled == true
  
  test "Theme loading and markdown rendering":
    # Create test config with theme
    let testConfig = Config(
      yourName: "Test",
      models: @[],
      markdownEnabled: some(true),
      currentTheme: some("default")
    )
    
    # Test that we can load themes from config
    loadThemesFromConfig(testConfig)
    
    # Test basic markdown rendering after theme loading
    let testText = "**bold text** and *italic text*"
    let rendered = renderMarkdownTextCLI(testText)
    check rendered.len > 0
    check "bold text" in rendered
    check "italic text" in rendered
  
  test "Empty markdown handling":
    let emptyResult = renderMarkdownTextCLI("")
    check emptyResult.len == 0 or emptyResult == ""
  
  test "Simple markdown elements":
    let simpleMarkdown = "# Header\n**Bold**\n*Italic*"
    let result = renderMarkdownTextCLI(simpleMarkdown)
    check result.len > 0
    check "Header" in result
    check "Bold" in result
    check "Italic" in result

when isMainModule:
  echo "Running Markdown Debug Tests..."