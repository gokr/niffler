## GPT-4 compatible tokenizer implementation  
## Loads pre-trained BPE vocabularies compatible with tiktoken cl100k_base
## Ported from Karpathy's minbpe: https://github.com/karpathy/minbpe

import std/[tables, json, strutils, re, sequtils]
import base

const
  # GPT-4 regex pattern for text splitting
  GPT4_SPLIT_PATTERN* = r"""'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]++[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+"""
  
  # GPT-4 special tokens
  GPT4_SPECIAL_TOKENS* = {
    "<|endoftext|>": 100257,
    "<|fim_prefix|>": 100258,
    "<|fim_middle|>": 100259, 
    "<|fim_suffix|>": 100260,
    "<|endofprompt|>": 100276
  }.toTable

type
  GPT4Tokenizer* = ref object of Tokenizer
    ## GPT-4 compatible tokenizer that can load tiktoken vocabularies
    byteShuffle*: Table[int, int]        # byte permutation used by GPT-4
    inverseByteShuffle*: Table[int, int] # inverse of byte permutation

proc newGPT4Tokenizer*(): GPT4Tokenizer =
  ## Create a new GPT-4 compatible tokenizer
  result = GPT4Tokenizer()
  result.pattern = GPT4_SPLIT_PATTERN
  result.specialTokens = GPT4_SPECIAL_TOKENS
  result.merges = initTable[tuple[a, b: int], int]()
  result.vocab = initTable[int, string]()
  result.byteShuffle = initTable[int, int]()
  result.inverseByteShuffle = initTable[int, int]()

proc loadFromVocabFile*(tokenizer: GPT4Tokenizer, vocabFile: string) =
  ## Load tokenizer from a vocabulary file
  ## Expected format: JSON with "merges" and optionally "byte_shuffle"
  let jsonStr = readFile(vocabFile)
  let vocabData = parseJson(jsonStr)
  
  # Clear existing data
  tokenizer.merges.clear()
  tokenizer.vocab.clear()
  tokenizer.byteShuffle.clear()
  tokenizer.inverseByteShuffle.clear()
  
  # Load merges if present
  if vocabData.hasKey("merges"):
    let merges = vocabData["merges"]
    var idx = 256
    for mergeItem in merges:
      let pair = mergeItem.getElems()
      let p0 = pair[0].getInt()
      let p1 = pair[1].getInt() 
      tokenizer.merges[(p0, p1)] = idx
      idx += 1
  
  # Load byte shuffle if present (GPT-4 specific)
  if vocabData.hasKey("byte_shuffle"):
    let shuffleData = vocabData["byte_shuffle"]
    for i in 0..255:
      let shuffledValue = shuffleData[i].getInt()
      tokenizer.byteShuffle[i] = shuffledValue
      tokenizer.inverseByteShuffle[shuffledValue] = i
  else:
    # Identity mapping if no shuffle provided
    for i in 0..255:
      tokenizer.byteShuffle[i] = i
      tokenizer.inverseByteShuffle[i] = i
  
  # Rebuild vocabulary
  tokenizer.vocab = tokenizer.buildVocab()

proc splitText*(text: string, pattern: string): seq[string] =
  ## Split text using regex pattern (simplified version)
  ## For production, would need full regex implementation
  # This is a simplified version - for full compatibility,
  # would need to implement the full GPT-4 regex pattern
  result = @[text] # Fallback: treat as single chunk
  
  # Basic word splitting as approximation
  let words = text.split(re(r"\s+"))
  if words.len > 1:
    result = words

method encode*(tokenizer: GPT4Tokenizer, text: string, allowedSpecial: string = "none"): seq[int] {.base.} =
  ## Encode text to token IDs with special token handling
  # Handle special tokens first
  var processedText = text
  var tokens = newSeq[int]()
  
  # Process special tokens if allowed
  if allowedSpecial == "all":
    # Simple approach: check for special tokens at start
    for special, idx in tokenizer.specialTokens:
      if processedText.startsWith(special):
        tokens.add(idx)
        processedText = processedText[special.len..^1]
        break
  
  if processedText.len == 0:
    return tokens
  
  # Split text using pattern (simplified)
  let chunks = splitText(processedText, tokenizer.pattern)
  
  for chunk in chunks:
    if chunk.len == 0:
      continue
      
    # Convert to bytes with shuffle
    var ids = newSeq[int]()
    for b in chunk:
      let byteVal = ord(b)
      ids.add(tokenizer.byteShuffle.getOrDefault(byteVal, byteVal))
    
    # Apply BPE merges  
    while ids.len >= 2:
      let stats = getStats(ids)
      
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
      
      if not foundPair:
        break
        
      ids = merge(ids, bestPair, minMergeIdx)
    
    for id in ids:
      tokens.add(id)
  
  return tokens

method decode*(tokenizer: GPT4Tokenizer, ids: seq[int]): string =
  ## Decode token IDs back to text with byte unshuffle
  var textBytes = ""
  
  for id in ids:
    if id notin tokenizer.vocab:
      # Handle unknown tokens gracefully
      textBytes.add("�") # Unicode replacement character
      continue
      
    textBytes.add(tokenizer.vocab[id])
  
  # Unshuffle bytes
  var unshuffled = ""
  for b in textBytes:
    let byteVal = ord(b)
    let originalByte = tokenizer.inverseByteShuffle.getOrDefault(byteVal, byteVal)
    unshuffled.add(char(originalByte))
  
  return unshuffled

method train*(tokenizer: GPT4Tokenizer, text: string, vocabSize: int, verbose: bool = false) =
  ## GPT-4 tokenizer is pre-trained, cannot be trained
  raise newException(ValueError, "GPT4Tokenizer is pre-trained and cannot be trained")

proc saveVocabToJson*(tokenizer: GPT4Tokenizer, filename: string) =
  ## Save vocabulary to JSON format for later loading
  var vocabData = newJObject()
  
  # Save merges
  var mergesArray = newJArray()
  for pair, idx in tokenizer.merges:
    var pairArray = newJArray()
    pairArray.add(newJInt(pair.a))
    pairArray.add(newJInt(pair.b))
    mergesArray.add(pairArray)
  vocabData["merges"] = mergesArray
  
  # Save byte shuffle
  var shuffleArray = newJArray()
  for i in 0..255:
    shuffleArray.add(newJInt(tokenizer.byteShuffle[i]))
  vocabData["byte_shuffle"] = shuffleArray
  
  # Save special tokens
  var specialObj = newJObject()
  for token, idx in tokenizer.specialTokens:
    specialObj[token] = newJInt(idx)
  vocabData["special_tokens"] = specialObj
  
  writeFile(filename, vocabData.pretty())

# Utility function to create a simple tokenizer for estimation
proc createEstimationTokenizer*(): GPT4Tokenizer =
  ## Create a simple tokenizer for token count estimation
  ## Uses basic BPE merges to provide better estimates than char counting
  result = newGPT4Tokenizer()
  
  # Identity byte shuffle (no permutation)
  for i in 0..255:
    result.byteShuffle[i] = i  
    result.inverseByteShuffle[i] = i
  
  # Add some common English merges for better estimation
  # This is a simplified set - for production would load full vocabulary
  let commonMerges = @[
    (ord('t'), ord('h')),    # "th" -> 256
    (ord('h'), ord('e')),    # "he" -> 257  
    (ord('i'), ord('n')),    # "in" -> 258
    (ord('e'), ord('r')),    # "er" -> 259
    (ord('a'), ord('n')),    # "an" -> 260
  ]
  
  for i, pair in commonMerges:
    result.merges[(pair[0], pair[1])] = 256 + i
  
  result.vocab = result.buildVocab()

when isMainModule:
  # Test the estimation tokenizer
  let tokenizer = createEstimationTokenizer()
  let text = "hello world this is a test"
  let encoded = tokenizer.encode(text)
  echo "Encoded: ", encoded
  echo "Token count: ", encoded.len
  echo "Decoded: ", tokenizer.decode(encoded)