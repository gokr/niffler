## Core tokenization implementation for Niffler
## Idiomatic Nim design using object variants instead of inheritance
## Ported from Karpathy's minbpe: https://github.com/karpathy/minbpe

import std/[tables, strutils, strformat, algorithm, re]

type
  TokenizerKind* = enum
    tkBasic,      ## Basic BPE tokenizer
    tkRegex,      ## Regex-based BPE tokenizer (trainable)
    tkGPT4,       ## GPT-4 compatible tokenizer (pre-trained)
    tkEstimation  ## Simple estimation tokenizer

  Tokenizer* = object
    ## Unified tokenizer using object variants instead of inheritance
    case kind*: TokenizerKind
    of tkGPT4:
      byteShuffle*: Table[int, int]        # byte permutation used by GPT-4
      inverseByteShuffle*: Table[int, int] # inverse of byte permutation
    else:
      discard
    
    # Common fields for all tokenizer types
    merges*: Table[tuple[a, b: int], int]  # (int, int) -> int
    pattern*: string                       # regex pattern for text splitting  
    specialTokens*: Table[string, int]     # str -> int, e.g. {'<|endoftext|>': 100257}
    vocab*: Table[int, string]             # int -> bytes as string

# === Helper Functions ===

proc getStats*(ids: seq[int]): Table[tuple[a, b: int], int] =
  ## Given a sequence of integers, return a table of counts of consecutive pairs
  ## Example: @[1, 2, 3, 1, 2] -> {(1, 2): 2, (2, 3): 1, (3, 1): 1}
  result = initTable[tuple[a, b: int], int]()
  for i in 0..<(ids.len - 1):
    let pair = (ids[i], ids[i + 1])
    result[pair] = result.getOrDefault(pair, 0) + 1

proc merge*(ids: seq[int], pair: tuple[a, b: int], idx: int): seq[int] =
  ## In the sequence of integers (ids), replace all consecutive occurrences
  ## of pair with the new integer token idx
  ## Example: ids=@[1, 2, 3, 1, 2], pair=(1, 2), idx=4 -> @[4, 3, 4]
  result = newSeq[int]()
  var i = 0
  while i < ids.len:
    # if not at the very last position AND the pair matches, replace it
    if i < ids.len - 1 and ids[i] == pair.a and ids[i + 1] == pair.b:
      result.add(idx)
      i += 2
    else:
      result.add(ids[i])
      i += 1

proc replaceControlCharacters*(s: string): string =
  ## Replace control characters with Unicode escape sequences
  ## to prevent output distortion
  result = ""
  for ch in s:
    # Simple check for control characters (ASCII 0-31 and 127)
    if ord(ch) >= 32 and ord(ch) != 127:
      result.add(ch)
    else:
      result.add(fmt("\\u{ord(ch):04x}"))

proc renderToken*(token: string): string =
  ## Pretty print a token, escaping control characters
  replaceControlCharacters(token)

# === Tokenizer Construction ===

proc newBasicTokenizer*(): Tokenizer =
  ## Create a new basic BPE tokenizer
  result = Tokenizer(kind: tkBasic)
  result.merges = initTable[tuple[a, b: int], int]()
  result.pattern = ""
  result.specialTokens = initTable[string, int]()
  result.vocab = initTable[int, string]()
  # Initialize base vocabulary
  for idx in 0..255:
    result.vocab[idx] = $char(idx)

proc newGPT4Tokenizer*(): Tokenizer =
  ## Create a new GPT-4 compatible tokenizer
  const gpt4SpecialTokens = {
    "<|endoftext|>": 100257,
    "<|fim_prefix|>": 100258,
    "<|fim_middle|>": 100259, 
    "<|fim_suffix|>": 100260,
    "<|endofprompt|>": 100276
  }.toTable
  
  const gpt4Pattern = r"""'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]++[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+"""
  
  result = Tokenizer(kind: tkGPT4)
  result.pattern = gpt4Pattern
  result.specialTokens = gpt4SpecialTokens
  result.merges = initTable[tuple[a, b: int], int]()
  result.vocab = initTable[int, string]()
  result.byteShuffle = initTable[int, int]()
  result.inverseByteShuffle = initTable[int, int]()
  
  # Initialize identity byte shuffle
  for i in 0..255:
    result.byteShuffle[i] = i
    result.inverseByteShuffle[i] = i
    result.vocab[i] = $char(i)

proc newEstimationTokenizer*(): Tokenizer =
  ## Create a simple tokenizer for token count estimation
  ## Uses basic BPE merges to provide better estimates than char counting
  result = Tokenizer(kind: tkEstimation)
  result.merges = initTable[tuple[a, b: int], int]()
  result.pattern = ""
  result.specialTokens = initTable[string, int]()
  result.vocab = initTable[int, string]()
  
  # Initialize base vocabulary
  for idx in 0..255:
    result.vocab[idx] = $char(idx)
  
  # Add some common English merges for better estimation
  let commonMerges = @[
    (ord('t'), ord('h')),    # "th" -> 256
    (ord('h'), ord('e')),    # "he" -> 257  
    (ord('i'), ord('n')),    # "in" -> 258
    (ord('e'), ord('r')),    # "er" -> 259
    (ord('a'), ord('n')),    # "an" -> 260
  ]
  
  for i, pair in commonMerges:
    result.merges[(pair[0], pair[1])] = 256 + i
    # Build vocabulary entry for this merge
    let leftStr = $char(pair[0])
    let rightStr = $char(pair[1])
    result.vocab[256 + i] = leftStr & rightStr

proc splitText*(text: string, pattern: string): seq[string] =
  ## Split text using GPT-4 regex pattern to find matches (not split on delimiters)
  ## This preserves all characters by finding all regex matches in sequence
  if pattern.len == 0 or text.len == 0:
    return @[text]
  
  try:
    # Use findAll to get all matches of the GPT-4 pattern
    # This finds all the tokens the pattern recognizes
    let regex = re(pattern)
    let matches = findAll(text, regex)
    
    # If we got matches that cover the entire string, use them
    var totalMatchLength = 0
    for match in matches:
      totalMatchLength += match.len
    
    if totalMatchLength == text.len:
      return matches
    else:
      # Fallback: if regex doesn't match entire string, split into characters
      # This ensures losslessness even if the regex is imperfect
      result = newSeq[string]()
      for ch in text:
        result.add($ch)
      return result
  except:
    # If regex compilation fails, fallback to character splitting
    result = newSeq[string]()
    for ch in text:
      result.add($ch)
    return result

proc newRegexTokenizer*(): Tokenizer =
  ## Create a new regex-based BPE tokenizer (like minbpe's RegexTokenizer)
  ## Uses GPT-4's regex pattern for text preprocessing but can be trained
  const regexPattern = r"""'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]++[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+"""
  
  result = Tokenizer(kind: tkRegex)
  result.pattern = regexPattern
  result.specialTokens = initTable[string, int]()
  result.merges = initTable[tuple[a, b: int], int]()
  result.vocab = initTable[int, string]()
  
  # Initialize base vocabulary
  for idx in 0..255:
    result.vocab[idx] = $char(idx)

# === Core Operations ===

proc buildVocab*(tokenizer: Tokenizer): Table[int, string] =
  ## Build vocabulary from merges and special tokens
  ## vocab is deterministically derived from merges
  result = initTable[int, string]()
  
  # Add base byte tokens (0-255)
  for idx in 0..255:
    result[idx] = $char(idx)
  
  # Add merged tokens - sort by index to resolve dependencies in order
  var sortedMerges = newSeq[(tuple[a, b: int], int)]()
  for pair, idx in tokenizer.merges:
    sortedMerges.add((pair, idx))
  
  sortedMerges.sort(proc(a, b: (tuple[a, b: int], int)): int = cmp(a[1], b[1]))
  
  for (pair, idx) in sortedMerges:
    # Safely get strings for the pair components
    var leftStr, rightStr: string
    
    if pair.a < 256:
      leftStr = $char(pair.a)
    elif pair.a in result:
      leftStr = result[pair.a]
    else:
      leftStr = "�" # Fallback for missing tokens
    
    if pair.b < 256:
      rightStr = $char(pair.b)  
    elif pair.b in result:
      rightStr = result[pair.b]
    else:
      rightStr = "�" # Fallback for missing tokens
      
    result[idx] = leftStr & rightStr
  
  # Add special tokens
  for special, idx in tokenizer.specialTokens:
    result[idx] = special

proc train*(tokenizer: var Tokenizer, text: string, vocabSize: int, verbose: bool = false) =
  ## Train the tokenizer on text to build vocabulary of vocabSize
  case tokenizer.kind:
  of tkBasic, tkEstimation:
    if vocabSize < 256:
      raise newException(ValueError, "Vocabulary size must be at least 256")
    
    let numMerges = vocabSize - 256
    
    # Convert text to UTF-8 bytes and then to list of integers
    var ids = newSeq[int]()
    for b in text:
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
        echo fmt("merge {i+1}/{numMerges}: {bestPair} -> {newIdx} ({vocab[newIdx]}) had {maxCount} occurrences")
    
    # Save to tokenizer instance
    tokenizer.merges = merges
    tokenizer.vocab = vocab
    
  of tkRegex:
    if vocabSize < 256:
      raise newException(ValueError, "Vocabulary size must be at least 256")
    
    let numMerges = vocabSize - 256
    
    # Split text using regex pattern, then process all chunks together for BPE training
    let chunks = splitText(text, tokenizer.pattern)
    
    # Convert all chunks to UTF-8 bytes and collect into single sequence for training
    var allIds = newSeq[int]()
    for chunk in chunks:
      if chunk.len == 0:
        continue
      for b in chunk:
        allIds.add(ord(b))
    
    # Initialize structures
    var merges = initTable[tuple[a, b: int], int]()
    var vocab = initTable[int, string]()
    
    # Initialize base vocabulary (0-255 bytes)
    for idx in 0..255:
      vocab[idx] = $char(idx)
    
    # Iteratively merge the most common pairs to create new tokens
    for i in 0..<numMerges:
      # Count consecutive pair frequencies
      let stats = getStats(allIds)
      
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
      allIds = merge(allIds, bestPair, newIdx)
      
      # Save the merge and update vocabulary
      merges[bestPair] = newIdx
      vocab[newIdx] = vocab[bestPair.a] & vocab[bestPair.b]
      
      if verbose:
        echo fmt("merge {i+1}/{numMerges}: {bestPair} -> {newIdx} ({vocab[newIdx]}) had {maxCount} occurrences")
    
    # Save to tokenizer instance
    tokenizer.merges = merges
    tokenizer.vocab = vocab
    
  of tkGPT4:
    raise newException(ValueError, "GPT4Tokenizer is pre-trained and cannot be trained")

proc trainUntilConvergence*(tokenizer: var Tokenizer, text: string, 
                            maxVocabSize: int = 50000,
                            minImprovement: float = 0.001,
                            minFrequency: int = 2,
                            verbose: bool = false): tuple[finalVocabSize: int, reason: string] =
  ## Train tokenizer until convergence using adaptive stopping criteria
  ## Returns the final vocabulary size achieved and the reason for stopping
  case tokenizer.kind:
  of tkBasic, tkEstimation:
    if maxVocabSize < 256:
      raise newException(ValueError, "Maximum vocabulary size must be at least 256")
    
    # Convert text to UTF-8 bytes and then to list of integers
    var ids = newSeq[int]()
    for b in text:
      ids.add(ord(b))
    
    # Initialize structures
    var merges = initTable[tuple[a, b: int], int]()
    var vocab = initTable[int, string]()
    
    # Initialize base vocabulary (0-255 bytes)
    for idx in 0..255:
      vocab[idx] = $char(idx)
    
    var previousTokenCount = ids.len
    var mergeCount = 0
    let maxMerges = maxVocabSize - 256
    
    if verbose:
      echo fmt("Starting convergence training: {ids.len} initial tokens, max vocab: {maxVocabSize}")
    
    # Iteratively merge until convergence
    while mergeCount < maxMerges:
      # Count consecutive pair frequencies
      let stats = getStats(ids)
      
      if stats.len == 0:
        let reason = "No more pairs available to merge"
        if verbose: echo fmt("Stopping: {reason}")
        result = (finalVocabSize: 256 + mergeCount, reason: reason)
        break
      
      # Find the pair with the highest count
      var maxCount = 0
      var bestPair: tuple[a, b: int]
      for pair, count in stats:
        if count > maxCount:
          maxCount = count
          bestPair = pair
      
      # Check frequency convergence
      if maxCount < minFrequency:
        let reason = fmt("Best pair frequency ({maxCount}) below threshold ({minFrequency})")
        if verbose: echo fmt("Stopping: {reason}")
        result = (finalVocabSize: 256 + mergeCount, reason: reason)
        break
      
      # Create new token with next available ID
      let newIdx = 256 + mergeCount
      
      # Replace all occurrences of the best pair with new token
      ids = merge(ids, bestPair, newIdx)
      
      # Check compression improvement
      let currentTokenCount = ids.len
      let improvement = (previousTokenCount - currentTokenCount).float / previousTokenCount.float
      
      if improvement < minImprovement:
        let reason = fmt("Compression improvement ({improvement:.4f}) below threshold ({minImprovement})")
        if verbose: echo fmt("Stopping: {reason}")
        result = (finalVocabSize: 256 + mergeCount, reason: reason)
        break
      
      # Save the merge and update vocabulary
      merges[bestPair] = newIdx
      vocab[newIdx] = vocab[bestPair.a] & vocab[bestPair.b]
      
      if verbose and (mergeCount mod 100 == 0 or mergeCount < 10):
        echo fmt("Merge {mergeCount + 1}: {bestPair} -> {newIdx} ({vocab[newIdx]}) had {maxCount} occurrences, improvement: {improvement:.4f}")
      
      previousTokenCount = currentTokenCount
      inc mergeCount
    
    # Check if we hit the maximum
    if mergeCount >= maxMerges:
      let reason = fmt("Reached maximum vocabulary size ({maxVocabSize})")
      if verbose: echo fmt("Stopping: {reason}")
      result = (finalVocabSize: maxVocabSize, reason: reason)
    
    # Save to tokenizer instance
    tokenizer.merges = merges
    tokenizer.vocab = vocab
    
    if verbose:
      echo fmt("Training completed: {result.finalVocabSize} final vocabulary size")
      echo fmt("Performed {mergeCount} merges, final token count: {ids.len}")
    
  of tkRegex:
    if maxVocabSize < 256:
      raise newException(ValueError, "Maximum vocabulary size must be at least 256")
    
    # Split text using regex pattern, then process all chunks together for BPE training
    let chunks = splitText(text, tokenizer.pattern)
    
    # Convert all chunks to UTF-8 bytes and collect into single sequence for training
    var allIds = newSeq[int]()
    for chunk in chunks:
      if chunk.len == 0:
        continue
      for b in chunk:
        allIds.add(ord(b))
    
    # Initialize structures
    var merges = initTable[tuple[a, b: int], int]()
    var vocab = initTable[int, string]()
    
    # Initialize base vocabulary (0-255 bytes)
    for idx in 0..255:
      vocab[idx] = $char(idx)
    
    var previousTokenCount = allIds.len
    var mergeCount = 0
    let maxMerges = maxVocabSize - 256
    
    if verbose:
      echo fmt("Starting regex convergence training: {allIds.len} initial tokens, max vocab: {maxVocabSize}")
    
    # Iteratively merge until convergence
    while mergeCount < maxMerges:
      # Count consecutive pair frequencies
      let stats = getStats(allIds)
      
      if stats.len == 0:
        let reason = "No more pairs available to merge"
        if verbose: echo fmt("Stopping: {reason}")
        result = (finalVocabSize: 256 + mergeCount, reason: reason)
        break
      
      # Find the pair with the highest count
      var maxCount = 0
      var bestPair: tuple[a, b: int]
      for pair, count in stats:
        if count > maxCount:
          maxCount = count
          bestPair = pair
      
      # Check frequency convergence
      if maxCount < minFrequency:
        let reason = fmt("Best pair frequency ({maxCount}) below threshold ({minFrequency})")
        if verbose: echo fmt("Stopping: {reason}")
        result = (finalVocabSize: 256 + mergeCount, reason: reason)
        break
      
      # Create new token with next available ID
      let newIdx = 256 + mergeCount
      
      # Replace all occurrences of the best pair with new token
      allIds = merge(allIds, bestPair, newIdx)
      
      # Check compression improvement
      let currentTokenCount = allIds.len
      let improvement = (previousTokenCount - currentTokenCount).float / previousTokenCount.float
      
      if improvement < minImprovement:
        let reason = fmt("Compression improvement ({improvement:.4f}) below threshold ({minImprovement})")
        if verbose: echo fmt("Stopping: {reason}")
        result = (finalVocabSize: 256 + mergeCount, reason: reason)
        break
      
      # Save the merge and update vocabulary
      merges[bestPair] = newIdx
      vocab[newIdx] = vocab[bestPair.a] & vocab[bestPair.b]
      
      if verbose and (mergeCount mod 100 == 0 or mergeCount < 10):
        echo fmt("Merge {mergeCount + 1}: {bestPair} -> {newIdx} ({vocab[newIdx]}) had {maxCount} occurrences, improvement: {improvement:.4f}")
      
      previousTokenCount = currentTokenCount
      inc mergeCount
    
    # Check if we hit the maximum
    if mergeCount >= maxMerges:
      let reason = fmt("Reached maximum vocabulary size ({maxVocabSize})")
      if verbose: echo fmt("Stopping: {reason}")
      result = (finalVocabSize: maxVocabSize, reason: reason)
    
    # Save to tokenizer instance
    tokenizer.merges = merges
    tokenizer.vocab = vocab
    
    if verbose:
      echo fmt("Training completed: {result.finalVocabSize} final vocabulary size")
      echo fmt("Performed {mergeCount} merges, final token count: {allIds.len}")
    
  of tkGPT4:
    raise newException(ValueError, "GPT4Tokenizer is pre-trained and cannot be trained")

proc encode*(tokenizer: Tokenizer, text: string): seq[int] =
  ## Encode text string to sequence of token IDs
  case tokenizer.kind:
  of tkBasic, tkEstimation:
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
    
  of tkRegex:
    # Handle special tokens first
    var processedText = text
    var tokens = newSeq[int]()
    
    # Process special tokens at start
    for special, idx in tokenizer.specialTokens:
      if processedText.startsWith(special):
        tokens.add(idx)
        processedText = processedText[special.len..^1]
        break
    
    if processedText.len == 0:
      return tokens
    
    # Split text using regex pattern
    let chunks = splitText(processedText, tokenizer.pattern)
    
    for chunk in chunks:
      if chunk.len == 0:
        continue
        
      # Convert to bytes
      var ids = newSeq[int]()
      for b in chunk:
        ids.add(ord(b))
      
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
    
  of tkGPT4:
    # Handle special tokens first (simplified)
    var processedText = text
    var tokens = newSeq[int]()
    
    # Process special tokens at start
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

proc decode*(tokenizer: Tokenizer, ids: seq[int]): string =
  ## Decode sequence of token IDs back to text string
  case tokenizer.kind:
  of tkBasic, tkEstimation:
    var textBytes = ""
    
    for id in ids:
      if id notin tokenizer.vocab:
        raise newException(ValueError, fmt("Token ID {id} not found in vocabulary"))
      textBytes.add(tokenizer.vocab[id])
    
    return textBytes
    
  of tkRegex:
    var textBytes = ""
    
    for id in ids:
      if id notin tokenizer.vocab:
        # Handle unknown tokens gracefully
        textBytes.add("�") # Unicode replacement character
        continue
        
      textBytes.add(tokenizer.vocab[id])
    
    return textBytes
    
  of tkGPT4:
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