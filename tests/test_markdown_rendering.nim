import std/[unittest, strutils, os, options, times, strformat]
import ../src/ui/markdown_cli
import ../src/ui/theme
import ../src/types/config as configTypes

# Test markdown rendering using sample-markdown.md

suite "Markdown Rendering Tests":
  
  setup:
    # Initialize theme system with a basic theme for testing
    let testConfig = Config(
      yourName: "Test",
      models: @[],
      markdownEnabled: some(true),
      currentTheme: some("default")
    )
    loadThemesFromConfig(testConfig)
  
  test "renderInlineMarkdownCLI handles basic formatting":
    # Test bold text
    let boldResult = renderInlineMarkdownCLI("This is **bold text** here")
    check boldResult.contains("bold text")
    
    # Test italic text
    let italicResult = renderInlineMarkdownCLI("This is *italic text* here")
    check italicResult.contains("italic text")
    
    # Test inline code
    let codeResult = renderInlineMarkdownCLI("Use `console.log()` for output")
    check codeResult.contains("console.log()")
    
    # Test links
    let linkResult = renderInlineMarkdownCLI("Visit [OpenAI](https://openai.com) today")
    check linkResult.contains("OpenAI")

  test "renderMarkdownLineCLI handles headers":
    let h1Result = renderMarkdownLineCLI("# Header 1")
    check h1Result.contains("Header 1")
    
    let h2Result = renderMarkdownLineCLI("## Header 2")
    check h2Result.contains("Header 2")
    
    let h3Result = renderMarkdownLineCLI("### Header 3")
    check h3Result.contains("Header 3")

  test "renderMarkdownLineCLI handles lists":
    let bulletResult = renderMarkdownLineCLI("- First item")
    check bulletResult.contains("First item")
    
    let numberedResult = renderMarkdownLineCLI("1. First step")
    check numberedResult.contains("First step")

  test "renderMarkdownTextCLI handles multi-line content":
    let testContent = """# Test Header
This is regular text with **bold** and *italic* formatting.

## Another Header
- List item 1
- List item 2

Some `inline code` here."""
    
    let result = renderMarkdownTextCLI(testContent)
    check result.contains("Test Header")
    check result.contains("Another Header")
    check result.contains("List item 1")
    check result.contains("inline code")

  test "renderMarkdownTextCLIStream handles streaming content":
    let streamContent = "This is **bold** and this is *italic* text with `code`."
    let result = renderMarkdownTextCLIStream(streamContent)
    check result.contains("bold")
    check result.contains("italic")
    check result.contains("code")

  test "sample-markdown.md processing":
    let samplePath = "sample-markdown.md"
    if fileExists(samplePath):
      let content = readFile(samplePath)
      
      # Test full rendering
      let fullResult = renderMarkdownTextCLI(content)
      check fullResult.len > 0
      
      # Test streaming rendering
      let streamResult = renderMarkdownTextCLIStream(content)
      check streamResult.len > 0
      
      # Verify specific elements are processed
      check fullResult.contains("Sample Markdown Rendering Test")  # H1
      check fullResult.contains("Text Formatting")  # H2
      check fullResult.contains("Bold text")  # Bold formatting
      check fullResult.contains("Italic text")  # Italic formatting
      check fullResult.contains("console.log")  # Inline code
      check fullResult.contains("First item")  # List items
      check fullResult.contains("OpenAI")  # Links
      
      echo "\n=== Full Rendered Output ==="
      echo fullResult
      echo "\n=== End Sample ==="
    else:
      skip()

  test "performance comparison":
    let testContent = """# Performance Test
This is a **performance** test with *many* formatting `elements`.
- Item 1 with **bold**
- Item 2 with *italic*
- Item 3 with `code`

[Link text](https://example.com) here."""
    
    # Time full rendering
    let startFull = epochTime()
    let fullResult = renderMarkdownTextCLI(testContent)
    let fullTime = epochTime() - startFull
    
    # Time streaming rendering  
    let startStream = epochTime()
    let streamResult = renderMarkdownTextCLIStream(testContent)
    let streamTime = epochTime() - startStream
    
    check fullResult.len > 0
    check streamResult.len > 0
    
    echo fmt"\nRendering times - Full: {fullTime:.4f}s, Stream: {streamTime:.4f}s"

when isMainModule:
  echo "Running Markdown Rendering Tests..."
  echo "Testing markdown rendering with sample-markdown.md content"