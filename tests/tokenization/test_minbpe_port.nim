## Comprehensive tests for minbpe port
## Based on the original minbpe test suite to ensure our port is accurate

import std/[unittest, strformat, os, strutils, tables]
import ../../src/tokenization/[base, basic, gpt4, tokenizer]

# Test data (from minbpe test suite)
let testStrings = @[
  "",  # empty string
  "?", # single character
  "hello world!!!? (안녕하세요!) lol123 😉", # fun small string with unicode
]

# Wikipedia BPE example text
const wikipediaText = "aaabdaaabac"

# Special tokens test string (simplified for our implementation)
const specialsString = """
<|endoftext|>Hello world this is one document
<|endoftext|>And this is another document
<|endoftext|>Last document!!! 👋
""".strip()

proc readTaylorSwiftText(): string =
  ## Read the Taylor Swift test file if it exists
  let testDir = getCurrentDir() / "tests" / "tokenization"
  let taylorFile = testDir / "taylorswift_sample.txt"
  
  # Create a sample if the file doesn't exist
  if not fileExists(taylorFile):
    let sampleText = """
Taylor Swift is an American singer-songwriter. She is known for her narrative songwriting,
which often draws from her personal experiences and has received critical praise and media coverage.
Swift has achieved numerous accolades in her career including multiple Grammy Awards.
    """.strip()
    createDir(testDir)
    writeFile(taylorFile, sampleText)
  
  return readFile(taylorFile)

suite "minbpe Port Verification Tests":
  
  test "Wikipedia BPE example - exact match":
    # This is the canonical BPE test from Wikipedia/minbpe
    # Must produce exactly: [258, 100, 258, 97, 99]
    let tokenizer = newBasicTokenizer()
    tokenizer.train(wikipediaText, 256 + 3)
    
    let encoded = tokenizer.encode(wikipediaText)
    echo fmt"Wikipedia example encoded: {encoded}"
    
    # This is the expected result from minbpe
    check(encoded == @[258, 100, 258, 97, 99])
    
    # Verify round-trip encoding/decoding
    let decoded = tokenizer.decode(encoded)
    check(decoded == wikipediaText)
    
    # Verify we learned exactly 3 merges
    check(tokenizer.merges.len == 3)

  test "Encode/decode identity - empty string":
    let tokenizer = newBasicTokenizer()
    let text = ""
    
    let encoded = tokenizer.encode(text)
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
    check(encoded.len == 0)

  test "Encode/decode identity - single character":
    let tokenizer = newBasicTokenizer()
    let text = "?"
    
    # Don't train on single chars, just test encoding
    let encoded = tokenizer.encode(text)
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
    check(encoded == @[ord('?')])

  test "Encode/decode identity - unicode text":
    let tokenizer = newBasicTokenizer()
    let text = "hello world!!!? (안녕하세요!) lol123 😉"
    
    # Train on this text to learn some patterns
    tokenizer.train(text, 300)
    
    let encoded = tokenizer.encode(text)
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
    
    # Should have some compression
    check(encoded.len <= text.len)

  test "Training with larger vocabulary":
    let text = readTaylorSwiftText()
    let tokenizer = newBasicTokenizer()
    
    # Train with reasonable vocab size
    tokenizer.train(text, 512)
    
    # Verify encoding/decoding works
    let encoded = tokenizer.encode(text)
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
    
    # Should have learned some merges (not necessarily 256 due to early termination)
    check(tokenizer.merges.len > 0)
    check(tokenizer.merges.len <= 256) # At most 256 merges
    
    # Should achieve some compression
    check(encoded.len < text.len)

  test "Save/load functionality":
    let text = "hello world hello world test test"
    let tokenizer = newBasicTokenizer()
    
    # Train tokenizer
    tokenizer.train(text, 280) # 24 merges
    
    # Get encoding before save
    let originalEncoded = tokenizer.encode(text)
    
    # Save tokenizer
    let tempFile = "test_tokenizer_tmp"
    tokenizer.save(tempFile)
    
    # Create new tokenizer and load
    let loadedTokenizer = newBasicTokenizer()
    loadedTokenizer.load(tempFile & ".model")
    
    # Test that loaded tokenizer works the same
    let loadedEncoded = loadedTokenizer.encode(text)
    let loadedDecoded = loadedTokenizer.decode(loadedEncoded)
    
    check(loadedEncoded == originalEncoded)
    check(loadedDecoded == text)
    check(loadedTokenizer.merges.len == tokenizer.merges.len)
    
    # Cleanup temp files
    try:
      removeFile(tempFile & ".model")
      removeFile(tempFile & ".vocab")
    except:
      discard # Files might not exist, that's ok

  test "Consistent merge ordering":
    # Test that the same training produces the same results
    let text = "abcabc defdef ghighi"
    
    let tokenizer1 = newBasicTokenizer()
    let tokenizer2 = newBasicTokenizer()
    
    tokenizer1.train(text, 270)
    tokenizer2.train(text, 270)
    
    let encoded1 = tokenizer1.encode(text)
    let encoded2 = tokenizer2.encode(text)
    
    # Should produce identical results
    check(encoded1 == encoded2)
    check(tokenizer1.merges.len == tokenizer2.merges.len)

suite "Tokenizer API Tests":
  
  test "estimateTokens function":
    let text = "Hello, world! This is a test."
    
    let count = estimateTokens(text)
    echo fmt"Estimate tokens for '{text}': {count}"
    
    # Should be reasonable estimate (not just char/4)
    check(count > 0)
    check(count <= text.len) # Should be at most character count
    check(count >= text.len div 6) # Should be at least reasonable compression

  test "Model-specific token counting":
    let text = "The quick brown fox jumps over the lazy dog."
    
    let openaiCount = countTokensForModel(text, "gpt-4")
    let qwenCount = countTokensForModel(text, "qwen-plus") 
    let glmCount = countTokensForModel(text, "glm-4")
    
    # All should give reasonable estimates
    check(openaiCount > 0)
    check(qwenCount > 0)
    check(glmCount > 0)
    
    # Should be in reasonable range
    for count in [openaiCount, qwenCount, glmCount]:
      check(count >= 5)  # At least a few tokens
      check(count <= 20) # Not more than words

  test "Tokenizer caching":
    let text = "Test caching mechanism"
    
    # First call - should create tokenizer
    let count1 = estimateTokens(text)
    
    # Second call - should use cached tokenizer
    let count2 = estimateTokens(text)
    
    # Should give same result
    check(count1 == count2)
    
    # Test cache cleanup
    clearTokenizerCache()

suite "Helper Function Tests":
  
  test "getStats function":
    let ids = @[1, 2, 3, 1, 2]
    let stats = getStats(ids)
    
    # Expected: (1,2)->2, (2,3)->1, (3,1)->1
    check(stats[(1, 2)] == 2)
    check(stats[(2, 3)] == 1) 
    check(stats[(3, 1)] == 1)
    check(stats.len == 3)

  test "merge function":
    let ids = @[1, 2, 3, 1, 2]
    let pair = (1, 2)
    let newIdx = 4
    
    let merged = merge(ids, pair, newIdx)
    
    # Expected: [4, 3, 4] 
    check(merged == @[4, 3, 4])

  test "replaceControlCharacters function":
    # Test control character replacement
    let textWithControl = "hello\x01world\x7f"
    let cleaned = replaceControlCharacters(textWithControl)
    
    # Should escape control characters
    check("\\u0001" in cleaned)
    check("\\u007f" in cleaned)
    check("hello" in cleaned)
    check("world" in cleaned)

echo "Running comprehensive minbpe port tests..."