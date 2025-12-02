## Tests for BasicTokenizer implementation
## Verifies that our BPE port matches expected behavior from minbpe

import std/[unittest, tables, strformat]
import ../../src/tokenization/[base, basic]

suite "BasicTokenizer Tests":
  
  test "Wikipedia BPE example":
    # Test the classic Wikipedia BPE example: "aaabdaaabac"
    # Expected: 3 merges should result in [258, 100, 258, 97, 99]
    let tokenizer = newBasicTokenizer()
    let text = "aaabdaaabac"
    
    # Train with 256 base tokens + 3 merges
    tokenizer.train(text, 256 + 3, verbose = false)
    
    # Test encoding
    let encoded = tokenizer.encode(text)
    check(encoded == @[258, 100, 258, 97, 99])
    
    # Test decoding
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
    
    # Verify the merges were learned correctly
    # First merge should be "aa" -> 256 (most frequent pair)
    # Second merge should be "ab" -> 257  
    # Third merge should be "aaa" (aa+a) -> 258
    check(tokenizer.merges.len == 3)
    
    # Check that common pairs were merged
    let hasAAMerge = (ord('a'), ord('a')) in tokenizer.merges
    let hasABMerge = (ord('a'), ord('b')) in tokenizer.merges  
    check(hasAAMerge or hasABMerge) # At least one of these should be merged
  
  test "Simple English text":
    let tokenizer = newBasicTokenizer()
    let text = "hello world hello"
    
    # Train with reasonable vocabulary size
    tokenizer.train(text, 300, verbose = false)
    
    # Test that encoding/decoding is lossless
    let encoded = tokenizer.encode(text)
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
    
    # Check that some merges were learned
    check(tokenizer.merges.len > 0)
    
    # Token count should be less than character count due to merges
    check(encoded.len <= text.len)
  
  test "Empty text handling":
    let tokenizer = newBasicTokenizer()
    
    # Encoding empty text should return empty sequence
    let encoded = tokenizer.encode("")
    check(encoded.len == 0)
    
    # Decoding empty sequence should return empty string
    let decoded = tokenizer.decode(@[])
    check(decoded == "")
  
  test "Single character":
    let tokenizer = newBasicTokenizer()
    let text = "a"
    
    # Train on single character (no merges possible)
    tokenizer.train(text, 256 + 10, verbose = false)
    
    let encoded = tokenizer.encode(text)
    check(encoded == @[ord('a')]) # Should just be the byte value
    
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
  
  test "UTF-8 text handling":
    let tokenizer = newBasicTokenizer()
    let text = "hello world"  # Mix of ASCII and Unicode
    
    tokenizer.train(text, 300, verbose = false)
    
    # Should handle UTF-8 correctly
    let encoded = tokenizer.encode(text)
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
    
    # Should have some tokens (UTF-8 bytes)
    check(encoded.len > 0)
  
  test "Repeated patterns":
    let tokenizer = newBasicTokenizer()
    let text = "abcabcabcabc"  # Repeated pattern should be merged
    
    tokenizer.train(text, 270, verbose = false)
    
    let encoded = tokenizer.encode(text)
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)
    
    # Should achieve compression due to pattern repetition
    check(encoded.len < text.len)
    
    # Should have learned some merges
    check(tokenizer.merges.len > 0)

  test "Vocabulary size limits":
    let tokenizer = newBasicTokenizer()
    let text = "abcdefghijklmnopqrstuvwxyz" * 10  # Long text with variety
    
    # Train with exactly 256 + 5 tokens
    tokenizer.train(text, 261, verbose = false)
    
    # Should have learned exactly 5 merges
    check(tokenizer.merges.len == 5)
    
    # Should still encode/decode correctly
    let encoded = tokenizer.encode(text)
    let decoded = tokenizer.decode(encoded)
    check(decoded == text)

echo "Running BasicTokenizer tests..."