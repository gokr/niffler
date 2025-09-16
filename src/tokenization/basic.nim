## Basic (byte-level) Byte Pair Encoding tokenizer
## Minimal BPE implementation that follows the GPT tokenizer algorithm
## Ported from Karpathy's minbpe: https://github.com/karpathy/minbpe

import std/[tables, strutils, algorithm, strformat]
import base

type
  BasicTokenizer* = ref object of Tokenizer
    ## Minimal BPE tokenizer that runs directly on text
    ## Does not handle regex splitting or special tokens

proc newBasicTokenizer*(): BasicTokenizer =
  ## Create a new basic BPE tokenizer
  result = BasicTokenizer()
  result.merges = initTable[tuple[a, b: int], int]()
  result.pattern = ""
  result.specialTokens = initTable[string, int]()
  result.vocab = result.buildVocab()

method train*(tokenizer: BasicTokenizer, text: string, vocabSize: int, verbose: bool = false) =
  ## Train the tokenizer on text using BPE algorithm
  if vocabSize < 256:
    raise newException(ValueError, "Vocabulary size must be at least 256")
  
  let numMerges = vocabSize - 256
  
  # Convert text to UTF-8 bytes and then to list of integers
  let textBytes = text
  var ids = newSeq[int]()
  for b in textBytes:
    ids.add(ord(b))
  
  # Initialize structures
  var merges = initTable[tuple[a, b: int], int]()
  var vocab = initTable[int, string]()
  
  # Initialize base vocabulary (0-255 bytes)
  for idx in 0..255:
    vocab[idx] = $char(idx)
  
  # Iteratively merge the most common pairs to create new tokens
  for i in 0..<numMerges:
    # Count consecutive pair frequencies
    let stats = getStats(ids)
    
    if stats.len == 0:
      break # No more pairs to merge
    
    # Find the pair with the highest count
    var maxCount = 0
    var bestPair: tuple[a, b: int]
    for pair, count in stats:
      if count > maxCount:
        maxCount = count
        bestPair = pair
    
    if maxCount == 0:
      break # No pairs found
    
    # Create new token with next available ID
    let newIdx = 256 + i
    
    # Replace all occurrences of the best pair with new token
    ids = merge(ids, bestPair, newIdx)
    
    # Save the merge and update vocabulary
    merges[bestPair] = newIdx
    vocab[newIdx] = vocab[bestPair.a] & vocab[bestPair.b]
    
    if verbose:
      echo fmt"merge {i+1}/{numMerges}: {bestPair} -> {newIdx} ({vocab[newIdx]}) had {maxCount} occurrences"
  
  # Save to tokenizer instance
  tokenizer.merges = merges
  tokenizer.vocab = vocab

method encode*(tokenizer: BasicTokenizer, text: string): seq[int] =
  ## Encode text string to sequence of token IDs using learned merges
  # Convert text to UTF-8 bytes
  var ids = newSeq[int]()
  for b in text:
    ids.add(ord(b))
  
  # Apply merges greedily - always merge the pair that was learned earliest
  while ids.len >= 2:
    # Find all possible pairs and their merge indices
    let stats = getStats(ids)
    
    # Find the pair with the lowest merge index (earliest learned)
    var minMergeIdx = int.high
    var bestPair: tuple[a, b: int]
    var foundPair = false
    
    for pair in stats.keys:
      if pair in tokenizer.merges:
        let mergeIdx = tokenizer.merges[pair]
        if mergeIdx < minMergeIdx:
          minMergeIdx = mergeIdx  
          bestPair = pair
          foundPair = true
    
    # If no mergeable pairs found, we're done
    if not foundPair:
      break
      
    # Apply the best merge
    ids = merge(ids, bestPair, minMergeIdx)
  
  return ids

method decode*(tokenizer: BasicTokenizer, ids: seq[int]): string =
  ## Decode sequence of token IDs back to text string
  var textBytes = ""
  
  for id in ids:
    if id notin tokenizer.vocab:
      raise newException(ValueError, fmt"Token ID {id} not found in vocabulary")
    textBytes.add(tokenizer.vocab[id])
  
  return textBytes

# Test function for basic usage
when isMainModule:
  # Example from Wikipedia BPE article
  let tokenizer = newBasicTokenizer()
  let text = "aaabdaaabac"
  tokenizer.train(text, 256 + 3, verbose = true) # 256 byte tokens + 3 merges
  
  let encoded = tokenizer.encode(text)
  echo "Encoded: ", encoded
  
  let decoded = tokenizer.decode(encoded)  
  echo "Decoded: ", decoded
  
  # Should output: [258, 100, 258, 97, 99] and "aaabdaaabac"