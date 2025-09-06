import std/[unittest, strutils, os, options, times, strformat]
import ../src/ui/markdown_cli
import ../src/ui/theme
import ../src/types/config as configTypes

suite "Markdown CLI Rendering Tests":
  
  setup:
    # Initialize theme system with a basic theme for testing
    let testConfig = configTypes.Config(
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

  test "comprehensive markdown elements rendering":
    let comprehensiveMarkdown = """# Main Header
## Sub Header
### Small Header

**Bold text** and *italic text* and ***bold italic***

`inline code` and [link](http://example.com)

- Bullet 1
- Bullet 2

1. Numbered 1
2. Numbered 2

| Col1 | Col2 |
|------|------|
| Cell1| Cell2|

> Blockquote text
"""
    
    let result = renderMarkdownTextCLI(comprehensiveMarkdown)
    check result.len > 0
    check result.contains("Main Header")
    check result.contains("Bold text")
    check result.contains("inline code")

when isMainModule:
  echo "Running Markdown CLI Rendering Tests..."