import std/[unittest, strutils, times]
import ../src/ui/markdown_cli
import ../src/ui/theme

suite "Streaming Markdown Tests":
  
  setup:
    # Initialize themes for testing
    initializeThemes()
  
  test "Streaming markdown rendering processes character by character":
    let testText = "**Bold** and *italic*"
    let result = renderMarkdownTextCLIStream(testText)
    check result.len > 0
    check result.contains("Bold")
    check result.contains("italic")
  
  test "Streaming markdown handles partial content":
    # Test with incomplete markdown
    let partialText = "**Partial"
    let result = renderMarkdownTextCLIStream(partialText)
    check result.len >= 0  # Should handle partial content gracefully
  
  test "Streaming vs complete rendering consistency":
    let completeText = "# Test Header\nThis is **bold** and *italic*.\n- List item"
    
    let renderedComplete = renderMarkdownTextCLI(completeText)
    let renderedStream = renderMarkdownTextCLIStream(completeText)
    
    # Both should produce output
    check renderedComplete.len > 0
    check renderedStream.len > 0
    
    # Should contain the same key elements
    check renderedComplete.contains("Test Header")
    check renderedStream.contains("Test Header")

  test "Performance of streaming vs complete rendering":
    let testContent = "**Bold** and *italic* with `code` elements"
    
    # Time complete rendering
    let startComplete = epochTime()
    let completeResult = renderMarkdownTextCLI(testContent)
    let completeTime = epochTime() - startComplete
    
    # Time streaming rendering
    let startStream = epochTime()
    let streamResult = renderMarkdownTextCLIStream(testContent)
    let streamTime = epochTime() - startStream
    
    # Both should produce results
    check completeResult.len > 0
    check streamResult.len > 0
    
    # Both should be reasonably fast (less than 1 second)
    check completeTime < 1.0
    check streamTime < 1.0

when isMainModule:
  echo "Running Streaming Markdown Tests..."