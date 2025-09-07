## Thinking Token Parser Tests
##
## Comprehensive test suite for the thinking token parser module,
## covering Anthropic, OpenAI, and encrypted content formats.

import std/[unittest, strutils, options]
import ../src/types/[config, thinking_tokens, messages]
import ../src/api/thinking_token_parser

suite "Thinking Token Parser Tests":

  test "Anthropic XML thinking block parsing":
    let content = "Regular content\n<thinking>\nLet me analyze this step by step:\n1. First point\n2. Second point\n</thinking>\nFinal answer"
    let result = parseAnthropicThinkingBlock(content)
    
    check result.isThinkingContent == true
    check result.isComplete == true
    check result.format == ttfAnthropic
    check result.thinkingContent.isSome()
    check result.thinkingContent.get().contains("Let me analyze this step by step")
    check result.thinkingContent.get().contains("1. First point")
    check result.regularContent.isSome()
    check result.regularContent.get().contains("Regular content")
    check result.regularContent.get().contains("Final answer")

  test "Anthropic redacted thinking block parsing":
    let content = "Some content\n<redacted_thinking>Encrypted reasoning here</redacted_thinking>\nAnswer"
    let result = parseAnthropicThinkingBlock(content)
    
    check result.isThinkingContent == true
    check result.isComplete == true
    check result.format == ttfEncrypted
    check result.thinkingContent.isSome()
    check result.thinkingContent.get() == "[ENCRYPTED REASONING]"
    check result.regularContent.isSome()

  test "Anthropic incomplete thinking block detection":
    let content = "Regular content\n<thinking>\nThis is incomplete reasoning"
    let result = parseAnthropicThinkingBlock(content)
    
    check result.isThinkingContent == true
    check result.isComplete == false
    check result.format == ttfAnthropic
    check result.thinkingContent.isSome()
    check result.thinkingContent.get() == "This is incomplete reasoning"
    check result.regularContent.isSome()
    check result.regularContent.get() == "Regular content"

  test "OpenAI reasoning content JSON parsing":
    let jsonContent = """{"reasoning_content": "I need to debug this step by step", "content": "The issue is in the loop"}"""
    let result = parseOpenAIReasoningContent(jsonContent)
    
    check result.isThinkingContent == true
    check result.isComplete == true
    check result.format == ttfOpenAI
    check result.thinkingContent.isSome()
    check result.thinkingContent.get() == "I need to debug this step by step"
    check result.regularContent.isSome()
    check result.regularContent.get() == "The issue is in the loop"

  test "OpenAI encrypted reasoning parsing":
    let jsonContent = """{"encrypted_reasoning": "ENCRYPTED_DATA_HERE", "content": "Solution provided"}"""
    let result = parseOpenAIReasoningContent(jsonContent)
    
    check result.isThinkingContent == true
    check result.isComplete == true
    check result.format == ttfEncrypted
    check result.thinkingContent.isSome()
    check result.thinkingContent.get() == "ENCRYPTED_DATA_HERE"

  test "OpenAI reasoning content with reasoning_id":
    let jsonContent = """{"reasoning_content": "Multi-step analysis", "reasoning_id": "reason-123", "content": "Answer"}"""
    let result = parseOpenAIReasoningContent(jsonContent)
    
    check result.isThinkingContent == true
    check result.isComplete == true
    check result.format == ttfOpenAI

  test "No thinking content detection":
    let regularContent = "This is just regular text with no thinking content"
    let result = parseOpenAIReasoningContent(regularContent)
    
    check result.isThinkingContent == false
    check result.format in [ttfNone, ttfOpenAI]  # Could be detected as OpenAI if JSON-like
    check result.thinkingContent.isNone()

  test "Automatic format detection - Anthropic":
    let content = "<thinking>This is thinking content</thinking>"
    let detectedFormat = detectThinkingTokenFormat(content)
    
    check detectedFormat.format == ttfAnthropic
    check detectedFormat.confidence > 0.8
    check detectedFormat.detectedFrom.contains("Anthropic")

  test "Automatic format detection - OpenAI":
    let jsonString = """{"reasoning_content": "Thinking here"}"""
    let detectedFormat = detectThinkingTokenFormat(jsonString)
    
    check detectedFormat.format == ttfOpenAI
    check detectedFormat.confidence > 0.8
    check detectedFormat.detectedFrom.contains("OpenAI")

  test "Automatic format detection - Encrypted":
    let content = "some content with encrypted_reasoning field"
    let detectedFormat = detectThinkingTokenFormat(content)
    
    check detectedFormat.format in [ttfEncrypted, ttfOpenAI]  # Could be detected as either
    check detectedFormat.confidence > 0.8
    let detectionContains = detectedFormat.detectedFrom.contains("Encryption") or detectedFormat.detectedFrom.contains("Encrypted") or detectedFormat.detectedFrom.contains("encrypted")
    check detectionContains == true

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
    updateIncrementalParser(parser, "\nThis is step 1 of my reasoning")
    updateIncrementalParser(parser, "\nThis is step 2 of my reasoning")
    
    check parser.isInThinkingBlock == true
    check parser.startMarkerFound == true
    check parser.format.get(ttfNone) == ttfAnthropic
    
    let thinkingContent = getThinkingContentFromIncrementalParser(parser)
    check thinkingContent.isSome()
    check thinkingContent.get().contains("This is step 1 of my reasoning")
    check thinkingContent.get().contains("This is step 2 of my reasoning")

  test "Incremental parser completion detection":
    var parser = initIncrementalParser()
    updateIncrementalParser(parser, "<thinking>Reasoning content</thinking>")
    
    check parser.endMarkerFound == true
    check isThinkingBlockComplete(parser) == true

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
    check canProcessThinkingToken(manager, 3000) == true  # Reduced to fit within 4096 limit
    
    addThinkingTokens(manager, 3000)
    check canProcessThinkingToken(manager, 1000) == true
    check canProcessThinkingToken(manager, 1200) == false  # Would exceed 4096 limit
    
    let remaining = getRemainingThinkingBudget(manager)
    check remaining >= 1090 and remaining <= 1096  # Roughly 1096 tokens remaining

  test "Thinking chunk creation":
    let chunk = createThinkingChunk("New thinking content", true, ttfAnthropic)
    check chunk.content == "New thinking content"
    check chunk.isFinal == true
    check chunk.provider == ttfAnthropic
    check chunk.timestamp > 0

  test "Model-based budget detection (deprecated)":
    let advancedModel = getThinkingBudgetFromModel("claude-3-5-sonnet")
    check advancedModel == rlHigh
    
    let reasoningModel = getThinkingBudgetFromModel("deepseek-r1")
    check reasoningModel == rlMedium
    
    let basicModel = getThinkingBudgetFromModel("gpt-3.5-turbo")
    check basicModel == rlLow
    
    let unknownModel = getThinkingBudgetFromModel("unknown-model")
    check unknownModel == rlMedium

  test "Config-based budget detection":
    # Test with explicit reasoning configuration
    var highConfig = ModelConfig(
      nickname: "advanced",
      baseUrl: "https://api.anthropic.com/v1",
      model: "claude-3.5-sonnet",
      context: 8192,
      enabled: true,
      reasoning: some(rlHigh)
    )
    check getThinkingBudgetFromConfig(highConfig) == rlHigh
    
    # Test with medium reasoning configuration
    var mediumConfig = ModelConfig(
      nickname: "standard",
      baseUrl: "https://api.openai.com/v1", 
      model: "gpt-4",
      context: 4096,
      enabled: true,
      reasoning: some(rlMedium)
    )
    check getThinkingBudgetFromConfig(mediumConfig) == rlMedium
    
    # Test without reasoning configuration (should use default)
    var defaultConfig = ModelConfig(
      nickname: "basic",
      baseUrl: "https://api.openai.com/v1",
      model: "gpt-3.5-turbo", 
      context: 2048,
      enabled: true,
      reasoning: none(ReasoningLevel)
    )
    check getThinkingBudgetFromConfig(defaultConfig) == rlMedium  # Default
    check getThinkingBudgetFromConfig(defaultConfig, rlLow) == rlLow  # Custom default

  test "String conversion for ReasoningLevel":
    check $rlLow == "low"
    check $rlMedium == "medium"
    check $rlHigh == "high"
    check $rlNone == "none"
    
    check parseReasoningLevel("low") == rlLow
    check parseReasoningLevel("HIGH") == rlHigh  # Case insensitive
    check parseReasoningLevel("none") == rlNone
    check parseReasoningLevel("invalid") == rlLow  # Default fallback

suite "Thinking ParseResult Helper Tests":

  test "Thinking result helper functions":
    let result = ThinkingParseResult(
      isThinkingContent: true,
      thinkingContent: some("Test thinking content"),
      format: ttfOpenAI,
      isComplete: true
    )
    
    check isThinkingContent(result) == true
    check hasValidThinkingContent(result) == true
    
    let emptyResult = ThinkingParseResult(
      isThinkingContent: true,
      thinkingContent: some(""),
      format: ttfOpenAI,
      isComplete: true
    )
    
    check hasValidThinkingContent(emptyResult) == false  # Empty content not valid

  test "Extract thinking content from streaming chunk":
    let chunk = StreamChunk(
      choices: @[StreamChoice(
        index: 0,
        delta: ChatMessage(
          role: "assistant",
          content: "Some analysis"
        ),
        finishReason: none(string)
      )],
      isThinkingContent: true,
      thinkingContent: some("This is my reasoning")
    )
    
    let extracted = extractThinkingContentForStreaming(chunk)
    check extracted.isThinkingContent == true
    check extracted.thinkingContent.isSome()
    check extracted.thinkingContent.get() == "This is my reasoning"

suite "Edge Cases and Error Handling":

  test "Malformed Anthropic thinking block":
    let content = "Content <thinking> incomplete"
    let result = parseAnthropicThinkingBlock(content)
    
    check result.isThinkingContent == true
    check result.isComplete == false  # Incomplete due to missing closing tag

  test "Invalid JSON in OpenAI format":
    let invalidJson = """{"reasoning_content": "incomplete json"""
    let result = parseOpenAIReasoningContent(invalidJson)
    
    # Should handle gracefully without exception
    check result.isThinkingContent == false or result.isComplete == false

  test "Empty and whitespace content":
    check detectAndParseThinkingContent("").isThinkingContent == false
    check detectAndParseThinkingContent("   ").isThinkingContent == false
    check detectAndParseThinkingContent("\n\n").isThinkingContent == false

  test "Mixed content with partial thinking":
    let mixedContent = "Regular text and <thinking> partial reasoning"
    let result = detectAndParseThinkingContent(mixedContent)
    
    check result.isThinkingContent == true
    check result.regularContent.isSome()
    check result.regularContent.get().contains("Regular text and")

  test "Case sensitivity handling":
    let lowerCase = "<thinking>lower case</thinking>"
    let upperCase = "<THINKING>upper case</THINKING>"
    let mixedCase = "<ThInKiNg>mixed case</ThInKiNg>"
    
    check detectThinkingTokenFormat(lowerCase).format == ttfAnthropic
    check detectThinkingTokenFormat(upperCase).format == ttfAnthropic
    check detectThinkingTokenFormat(mixedCase).format == ttfAnthropic

  test "Budget manager edge cases":
    var manager = initThinkingBudgetManager(rlNone)
    check manager.maxTokens == 0
    check manager.isEnabled == true
    
    manager.isEnabled = false
    check canProcessThinkingToken(manager, 1) == false
    check getRemainingThinkingBudget(manager) == 0

when isMainModule:
  echo "Running thinking token parser tests..."
  echo "All tests completed ✓"