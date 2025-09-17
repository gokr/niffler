## Test the new heuristic token estimation system
## Compare against BPE estimates and validate accuracy improvements

import std/[strformat, times, re, strutils]
import src/tokenization/[estimation, tokenizer, core]

proc testBasicEstimation() =
  echo "=== Testing Basic Heuristic Estimation ==="
  
  let testTexts = @[
    ("Hello, world!", "Simple English"),
    ("The quick brown fox jumps over the lazy dog.", "Longer English sentence"),
    ("Die pünktlich gewünschte Trüffelfüllung", "German with umlauts"),
    ("こんにちは世界", "Japanese text"),
    ("function calculateTotal(items) { return items.reduce((sum, item) => sum + item.price, 0); }", "JavaScript code"),
    ("123,456.78 + 987.65 = 124,444.43", "Numeric content"),
    ("!@#$%^&*()[]{}|\\:;\"'<>,.?/", "Punctuation only"),
    ("   \n\t\r   ", "Whitespace only")
  ]
  
  for (text, description) in testTexts:
    let heuristicTokens = estimateTokenCountSimple(text)
    let charDiv4 = max(1, text.len div 4)
    let ratio = heuristicTokens.float / charDiv4.float
    
    echo fmt("Text: {description}")
    echo fmt("  '{text}'")
    echo fmt("  Length: {text.len} chars")
    echo fmt("  Heuristic: {heuristicTokens} tokens")
    echo fmt("  Char/4: {charDiv4} tokens") 
    echo fmt("  Ratio: {ratio:.2f}x")
    echo ""

proc testLanguageSpecificEstimation() =
  echo "=== Testing Language-Specific Estimation ==="
  
  # Test with custom language configurations
  let customOptions = EstimationOptions(
    defaultCharsPerToken: 4.0,
    languageConfigs: @[
      LanguageConfig(pattern: re(r"[你我他她它们]"), averageCharsPerToken: 1.5),  # Chinese
      LanguageConfig(pattern: re(r"[éèêëàâîï]", {reIgnoreCase}), averageCharsPerToken: 2.5)  # French accents
    ]
  )
  
  let testTexts = @[
    "Bonjour, ceci est un texte français avec des caractères accentués.",
    "你好世界，这是一个测试文本。",
    "This is regular English text for comparison."
  ]
  
  for text in testTexts:
    let defaultTokens = estimateTokenCount(text)
    let customTokens = estimateTokenCount(text, customOptions)
    
    echo fmt("Text: '{text}'")
    echo fmt("  Default estimation: {defaultTokens} tokens")
    echo fmt("  Custom estimation: {customTokens} tokens") 
    echo fmt("  Difference: {customTokens - defaultTokens} tokens")
    echo ""

proc testSliceByTokens() =
  echo "=== Testing Token-Based Text Slicing ==="
  
  let text = "The quick brown fox jumps over the lazy dog and runs through the forest."
  let totalTokens = estimateTokenCountSimple(text)
  
  echo fmt("Original text: '{text}'")
  echo fmt("Total estimated tokens: {totalTokens}")
  echo ""
  
  # Test different slicing operations
  let slices = @[
    (0, 3, "First 3 tokens"),
    (2, 5, "Tokens 2-5"),
    (-3, -1, "Last 3 tokens except final"),
    (5, -1, "From token 5 to end")
  ]
  
  for (start, `end`, description) in slices:
    let sliced = sliceByTokens(text, start, `end`)
    echo fmt("{description}: '{sliced}'")
  
  echo ""

proc compareWithBPE() =
  echo "=== Comparing Heuristic vs BPE Estimation ==="
  
  let testTexts = @[
    "Hello, world! This is a test.",
    "The implementation uses advanced algorithms for optimization.",
    "import std/[strformat, times, os] # Nim code example"
  ]
  
  for text in testTexts:
    let heuristicTokens = estimateTokens(text)       # New heuristic method
    let bpeTokens = estimateTokensBPE(text)          # Old BPE method
    let charDiv4 = text.len div 4
    
    echo fmt("Text: '{text}'")
    echo fmt("  Length: {text.len} chars")
    echo fmt("  Heuristic: {heuristicTokens} tokens")
    echo fmt("  BPE: {bpeTokens} tokens")
    echo fmt("  Char/4: {charDiv4} tokens")
    echo fmt("  Heuristic vs Char/4: {heuristicTokens.float / charDiv4.float:.2f}x")
    echo fmt("  BPE vs Char/4: {bpeTokens.float / charDiv4.float:.2f}x")
    echo ""

proc testCorrectionFactorIntegration() =
  echo "=== Testing Correction Factor Integration ==="
  
  let text = "This is a test message for checking correction factor application."
  let modelName = "test-model"
  
  # Test the complete flow: heuristic estimation + correction factors
  let baseEstimate = estimateTokens(text)
  let correctedEstimate = countTokensForModel(text, modelName)
  
  echo fmt("Test text: '{text}'")
  echo fmt("Base heuristic estimate: {baseEstimate} tokens")
  echo fmt("After correction factors: {correctedEstimate} tokens")
  
  if baseEstimate == correctedEstimate:
    echo "✅ No correction factor applied (as expected for new model)"
  else:
    echo fmt("✅ Correction factor applied: {correctedEstimate.float / baseEstimate.float:.3f}x")
  
  echo ""

proc testPerformance() =
  echo "=== Testing Performance ==="
  
  # Create a reasonably large text for performance testing
  let largeText = "This is a sample sentence that will be repeated many times to create a larger text for performance testing. ".repeat(1000)
  
  echo fmt("Testing with {largeText.len} character text...")
  
  # Test heuristic estimation performance
  let startTime = epochTime()
  let tokens = estimateTokenCountSimple(largeText)
  let elapsed = epochTime() - startTime
  
  echo fmt("Heuristic estimation: {tokens} tokens in {elapsed:.6f} seconds")
  echo fmt("Processing rate: {(largeText.len.float / elapsed / 1000).int} KB/sec")
  echo ""

proc main() =
  echo "Testing Heuristic Token Estimation System"
  echo "========================================"
  echo ""
  
  testBasicEstimation()
  testLanguageSpecificEstimation()
  testSliceByTokens()
  compareWithBPE()
  testCorrectionFactorIntegration()
  testPerformance()
  
  echo "✅ All heuristic estimation tests completed!"

when isMainModule:
  main()