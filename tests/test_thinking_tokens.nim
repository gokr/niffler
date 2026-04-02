import std/[unittest, strutils, options]
import ../src/types/[thinking_tokens, config]
import ../src/api/thinking_token_parser

suite "Thinking Token Parser Tests":
  test "Anthropic XML thinking block parsing":
    let content = "Regular content\n<thinking>\nLet me analyze this step by step:\n1. First point\n2. Second point\n</thinking>\nFinal answer"
    let result = parseAnthropicThinkingBlock(content)
    
    check result.isThinkingContent == true
    check result.isComplete == true
    check result.format == ttfAnthropic
    check result.thinkingContent.isSome()
    check result.thinkingContent.get().contains("step by step")
    check result.regularContent.isSome()

  test "Anthropic redacted thinking block":
    let content = "Some content\n<redacted_thinking>Encrypted reasoning here</redacted_thinking>\nAnswer"
    let result = parseAnthropicThinkingBlock(content)
    
    check result.isThinkingContent == true
    check result.format == ttfEncrypted
    check result.thinkingContent.isSome()
    check result.thinkingContent.get() == "[ENCRYPTED REASONING]"

  test "Anthropic incomplete thinking block":
    let content = "Regular content\n<thinking>\nThis is incomplete reasoning"
    let result = parseAnthropicThinkingBlock(content)
    
    check result.isThinkingContent == true
    check result.isComplete == false
    check result.format == ttfAnthropic

  test "OpenAI reasoning content JSON parsing":
    let jsonContent = """{"reasoning_content": "I need to debug this step by step", "content": "The issue is in the loop"}"""
    let result = parseOpenAIReasoningContent(jsonContent)
    
    check result.isThinkingContent == true
    check result.isComplete == true
    check result.format == ttfOpenAI
    check result.thinkingContent.isSome()
    check result.thinkingContent.get() == "I need to debug this step by step"
    check result.regularContent.isSome()

  test "OpenAI encrypted reasoning parsing":
    let jsonContent = """{"encrypted_reasoning": "ENCRYPTED_DATA_HERE", "content": "Solution provided"}"""
    let result = parseOpenAIReasoningContent(jsonContent)
    
    check result.isThinkingContent == true
    check result.format == ttfEncrypted
    check result.thinkingContent.isSome()
    check result.thinkingContent.get() == "ENCRYPTED_DATA_HERE"

  test "No thinking content detection":
    let regularContent = "This is just regular text"
    let result = parseOpenAIReasoningContent(regularContent)
    check result.isThinkingContent == false

  test "Automatic format detection - Anthropic":
    let content = "<thinking>This is thinking content</thinking>"
    let detectedFormat = detectThinkingTokenFormat(content)
    
    check detectedFormat.format == ttfAnthropic
    check detectedFormat.confidence > 0.8

  test "Automatic format detection - OpenAI":
    let jsonString = """{"reasoning_content": "Thinking here"}"""
    let detectedFormat = detectThinkingTokenFormat(jsonString)
    
    check detectedFormat.format == ttfOpenAI
    check detectedFormat.confidence > 0.8

  test "No format detection":
    let regularContent = "Just regular text without any thinking fields"
    let detectedFormat = detectThinkingTokenFormat(regularContent)
    
    check detectedFormat.format == ttfNone
    check detectedFormat.confidence == 1.0

  test "Incremental parser initialization":
    let parser = initIncrementalParser()
    check not parser.isInThinkingBlock
    check parser.accumulatedThinking.len == 0
    check parser.format.isNone()

  test "Incremental parser with Anthropic content":
    var parser = initIncrementalParser()
    
    updateIncrementalParser(parser, "<thinking>")
    updateIncrementalParser(parser, "\nThis is step 1")
    updateIncrementalParser(parser, "\nThis is step 2")
    
    check parser.isInThinkingBlock == true
    check parser.format.get(ttfNone) == ttfAnthropic
    
    let thinkingContent = getThinkingContentFromIncrementalParser(parser)
    check thinkingContent.isSome()
    check thinkingContent.get().contains("step 1")

  test "Incremental parser completion detection":
    var parser = initIncrementalParser()
    updateIncrementalParser(parser, "<thinking>Reasoning content</thinking>")
    
    check parser.endMarkerFound == true
    check isThinkingBlockComplete(parser) == true

  test "Case sensitivity handling":
    check detectThinkingTokenFormat("<thinking>lower</thinking>").format == ttfAnthropic
    check detectThinkingTokenFormat("<THINKING>upper</THINKING>").format == ttfAnthropic
    check detectThinkingTokenFormat("<ThInKiNg>mixed</ThInKiNg>").format == ttfAnthropic

  test "Empty and whitespace content":
    check detectAndParseThinkingContent("").isThinkingContent == false
    check detectAndParseThinkingContent("   ").isThinkingContent == false
    check detectAndParseThinkingContent("\n\n").isThinkingContent == false

suite "Thinking Token Budget Tests":
  test "Budget manager initialization":
    let lowBudgetManager = initThinkingBudgetManager(rlLow)
    check lowBudgetManager.maxTokens == 2048
    check lowBudgetManager.isEnabled == true
    
    let highBudgetManager = initThinkingBudgetManager(rlHigh)
    check highBudgetManager.maxTokens == 8192
    
    let disabledManager = initThinkingBudgetManager(rlMedium, false)
    check disabledManager.isEnabled == false

  test "Budget manager token counting":
    var manager = initThinkingBudgetManager(rlMedium)
    check canProcessThinkingToken(manager, 1000) == true
    check canProcessThinkingToken(manager, 3000) == true
    
    addThinkingTokens(manager, 3000)
    check canProcessThinkingToken(manager, 1000) == true
    check canProcessThinkingToken(manager, 1200) == false
    
    let remaining = getRemainingThinkingBudget(manager)
    check remaining >= 1090 and remaining <= 1096

  test "Budget manager edge cases":
    var manager = initThinkingBudgetManager(rlNone)
    check manager.maxTokens == 0
    check manager.isEnabled == true
    
    manager.isEnabled = false
    check canProcessThinkingToken(manager, 1) == false
    check getRemainingThinkingBudget(manager) == 0

  test "Config-based budget detection":
    var highConfig = ModelConfig(
      nickname: "advanced",
      baseUrl: "https://api.anthropic.com/v1",
      model: "claude-3.5-sonnet",
      context: 8192,
      enabled: true,
      reasoning: some(rlHigh)
    )
    check getThinkingBudgetFromConfig(highConfig) == rlHigh
    
    var defaultConfig = ModelConfig(
      nickname: "basic",
      baseUrl: "https://api.openai.com/v1",
      model: "gpt-3.5-turbo",
      context: 2048,
      enabled: true,
      reasoning: none(ReasoningLevel)
    )
    check getThinkingBudgetFromConfig(defaultConfig) == rlMedium
    check getThinkingBudgetFromConfig(defaultConfig, rlLow) == rlLow

  test "String conversion for ReasoningLevel":
    check $rlLow == "low"
    check $rlMedium == "medium"
    check $rlHigh == "high"
    check $rlNone == "none"
    
    check parseReasoningLevel("low") == rlLow
    check parseReasoningLevel("HIGH") == rlHigh
    check parseReasoningLevel("none") == rlNone
    check parseReasoningLevel("invalid") == rlLow

suite "Thinking Token Windowing Tests":
  test "Window manager initialization":
    let window = initThinkingWindowManager(1000)
    check window.maxSize == 1000
    check window.currentSize == 0
    check window.tokens.len == 0

  test "Token creation and estimation":
    let content = "This is a test thinking content"
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
    var window = initThinkingWindowManager(50)
    
    let smallToken = createThinkingToken("Small")
    check addTokenToWindow(window, smallToken) == true
    
    let mediumToken = createThinkingToken("This is a medium sized token")
    check addTokenToWindow(window, mediumToken) == true
    
    check window.tokens.len == 2

  test "Importance-based token retrieval":
    var window = initThinkingWindowManager(1000)
    
    discard addTokenToWindow(window, createThinkingToken("Low", tiLow))
    discard addTokenToWindow(window, createThinkingToken("Medium", tiMedium))
    discard addTokenToWindow(window, createThinkingToken("High", tiHigh))
    discard addTokenToWindow(window, createThinkingToken("Essential", tiEssential))
    
    let highAndAbove = getImportantTokens(window, tiHigh)
    check highAndAbove.len == 2
    
    let mediumAndAbove = getImportantTokens(window, tiMedium)
    check mediumAndAbove.len == 3

  test "Window clearing":
    var window = initThinkingWindowManager(1000)
    discard addTokenToWindow(window, createThinkingToken("Test content"))
    
    check window.tokens.len == 1
    clearWindow(window)
    check window.tokens.len == 0
    check window.currentSize == 0

  test "Importance classification":
    check classifyThinkingImportance("This is a critical and essential insight") == tiEssential
    check classifyThinkingImportance("This is an important key insight") == tiHigh
    check classifyThinkingImportance("This is obvious and straightforward") == tiLow
    check classifyThinkingImportance("This is standard reasoning content") == tiMedium

  test "Keyword extraction":
    let content = "The quick brown fox jumps over the lazy dog and finds important information"
    let keywords = extractKeywords(content, 3)
    check keywords.len <= 3
    check "the" notin keywords

  test "Empty content handling":
    let emptyToken = createThinkingToken("")
    check emptyToken.tokenCount == 1
    
    var window = initThinkingWindowManager(1000)
    check addTokenToWindow(window, emptyToken) == true

  test "Zero size window":
    var zeroWindow = initThinkingWindowManager(0)
    let token = createThinkingToken("Test")
    check addTokenToWindow(zeroWindow, token) == false

suite "Thinking Token Integration Tests":
  test "Thinking token format detection and parsing":
    let anthropicContent = "<thinking>Let me analyze this problem step by step...</thinking>"
    let anthropicResult = parseAnthropicThinkingBlock(anthropicContent)
    check anthropicResult.isThinkingContent
    check anthropicResult.format == ttfAnthropic
    check anthropicResult.thinkingContent.isSome()
    check anthropicResult.thinkingContent.get().contains("step by step")
    
    let openaiContent = """{"reasoning_content": "I should break this down methodically", "content": "Here's my response"}"""
    let openaiResult = parseOpenAIReasoningContent(openaiContent)
    check openaiResult.isThinkingContent
    check openaiResult.format == ttfOpenAI
    
    let autoDetectResult = detectAndParseThinkingContent(anthropicContent)
    check autoDetectResult.isThinkingContent
    check autoDetectResult.format == ttfAnthropic

  test "Thinking token cost configuration":
    let modelConfig = ModelConfig(
      nickname: "test-reasoning-model",
      baseUrl: "https://api.test.com",
      model: "reasoning-test-1",
      context: 8192,
      reasoning: some(rlMedium),
      enabled: true,
      inputCostPerMToken: some(1.0),
      outputCostPerMToken: some(2.0),
      reasoningCostPerMToken: some(5.0)
    )
    
    check modelConfig.reasoningCostPerMToken.isSome()
    check modelConfig.reasoningCostPerMToken.get() == 5.0
    check modelConfig.reasoning.isSome()
    check modelConfig.reasoning.get() == rlMedium

  test "Thinking chunk creation":
    let chunk = createThinkingChunk("New thinking content", true, ttfAnthropic)
    check chunk.content == "New thinking content"
    check chunk.isFinal == true
    check chunk.provider == ttfAnthropic
    check chunk.timestamp > 0

echo "All thinking token tests completed"
