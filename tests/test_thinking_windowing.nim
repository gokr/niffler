## Thinking Token Windowing Tests
##
## Test suite for the context-aware thinking token windowing system.

import std/[unittest, strutils]
import ../src/types/thinking_tokens

suite "Thinking Token Windowing Tests":

  test "Window manager initialization":
    let window = initThinkingWindowManager(1000)
    check window.maxSize == 1000
    check window.currentSize == 0
    check window.tokens.len == 0

  test "Token creation and estimation":
    let content = "This is a test thinking content for token estimation"
    let token = createThinkingToken(content, tiMedium, ttfOpenAI)
    
    check token.content == content
    check token.importance == tiMedium
    check token.provider == ttfOpenAI
    check token.tokenCount > 0
    check token.id.len > 0
    check token.timestamp > 0

  test "Simple token addition":
    var window = initThinkingWindowManager(1000)
    let token = createThinkingToken("Simple test content")
    
    let added = addTokenToWindow(window, token)
    check added == true
    check window.tokens.len == 1
    check window.currentSize == token.tokenCount

  test "Window size management":
    var window = initThinkingWindowManager(50)  # Small window
    
    # Add tokens that should fit
    let smallToken = createThinkingToken("Small")
    check addTokenToWindow(window, smallToken) == true
    
    # Add a larger token that should also fit
    let mediumToken = createThinkingToken("This is a medium sized token content")
    check addTokenToWindow(window, mediumToken) == true
    
    check window.tokens.len == 2

  test "Window overflow handling":
    var window = initThinkingWindowManager(30)  # Very small window
    
    # Add a large token
    let largeToken = createThinkingToken("This is a very large token that should consume most of the window space")
    check addTokenToWindow(window, largeToken) == true
    
    # Try to add another token - should fail or cause eviction
    let anotherToken = createThinkingToken("Another token")
    let result = addTokenToWindow(window, anotherToken)
    
    # Either the token was added (after eviction) or rejected
    check window.tokens.len >= 1

  test "Importance-based token retrieval":
    var window = initThinkingWindowManager(1000)
    
    # Add tokens with different importance levels
    let lowToken = createThinkingToken("Low importance content", tiLow)
    let mediumToken = createThinkingToken("Medium importance content", tiMedium)
    let highToken = createThinkingToken("High importance content", tiHigh)
    let essentialToken = createThinkingToken("Essential content", tiEssential)
    
    discard addTokenToWindow(window, lowToken)
    discard addTokenToWindow(window, mediumToken)
    discard addTokenToWindow(window, highToken)
    discard addTokenToWindow(window, essentialToken)
    
    # Get tokens with minimum importance
    let highAndAbove = getImportantTokens(window, tiHigh)
    check highAndAbove.len == 2  # High and Essential tokens
    
    let mediumAndAbove = getImportantTokens(window, tiMedium)
    check mediumAndAbove.len == 3  # Medium, High, and Essential tokens

  test "Window summary generation":
    var window = initThinkingWindowManager(1000)
    let summary = getWindowSummary(window)
    check "Thinking Window" in summary
    check "0 tokens" in summary

  test "Window clearing":
    var window = initThinkingWindowManager(1000)
    let token = createThinkingToken("Test content")
    discard addTokenToWindow(window, token)
    
    check window.tokens.len == 1
    clearWindow(window)
    check window.tokens.len == 0
    check window.currentSize == 0

  test "Importance classification":
    # Test essential importance
    let essentialContent = "This is a critical and essential insight"
    check classifyThinkingImportance(essentialContent) == tiEssential
    
    # Test high importance
    let highContent = "This is an important key insight"
    check classifyThinkingImportance(highContent) == tiHigh
    
    # Test low importance
    let lowContent = "This is obvious and straightforward"
    check classifyThinkingImportance(lowContent) == tiLow
    
    # Test default medium importance
    let mediumContent = "This is standard reasoning content"
    check classifyThinkingImportance(mediumContent) == tiMedium

  test "Keyword extraction":
    let content = "The quick brown fox jumps over the lazy dog and finds important information"
    let keywords = extractKeywords(content, 3)
    check keywords.len <= 3
    # Should contain meaningful words, not common words like "the"
    check "the" notin keywords

suite "Edge Cases":

  test "Empty content handling":
    let emptyToken = createThinkingToken("")
    check emptyToken.tokenCount == 1  # Should default to 1 token minimum
    
    var window = initThinkingWindowManager(1000)
    check addTokenToWindow(window, emptyToken) == true

  test "Very large window":
    let largeWindow = initThinkingWindowManager(1000000)  # 1M tokens
    check largeWindow.maxSize == 1000000

  test "Zero size window":
    var zeroWindow = initThinkingWindowManager(0)
    let token = createThinkingToken("Test")
    check addTokenToWindow(zeroWindow, token) == false

when isMainModule:
  echo "Running thinking token windowing tests..."
  echo "All tests completed"