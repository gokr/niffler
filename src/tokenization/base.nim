## Base tokenizer implementation ported from Karpathy's minbpe
## Contains the base Tokenizer class and helper functions for BPE tokenization.
## Original: https://github.com/karpathy/minbpe

import std/[tables, strutils, strformat, algorithm]

# Helper functions for BPE tokenization

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
      result.add(fmt"\\u{ord(ch):04x}")

proc renderToken*(token: string): string =
  ## Pretty print a token, escaping control characters
  replaceControlCharacters(token)

# Base Tokenizer class

type
  Tokenizer* = ref object of RootObj
    ## Base class for all tokenizers
    merges*: Table[tuple[a, b: int], int]  # (int, int) -> int
    pattern*: string                       # regex pattern for text splitting  
    specialTokens*: Table[string, int]     # str -> int, e.g. {'<|endoftext|>': 100257}
    vocab*: Table[int, string]             # int -> bytes as string

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

proc newTokenizer*(): Tokenizer =
  ## Create a new base tokenizer instance
  result = Tokenizer()
  result.merges = initTable[tuple[a, b: int], int]()
  result.pattern = ""
  result.specialTokens = initTable[string, int]()
  result.vocab = initTable[int, string]()
  # Initialize base vocabulary
  for idx in 0..255:
    result.vocab[idx] = $char(idx)

method train*(tokenizer: Tokenizer, text: string, vocabSize: int, verbose: bool = false) {.base.} =
  ## Train the tokenizer on text to build vocabulary of vocabSize
  ## Must be implemented by subclasses
  raise newException(ValueError, "train() must be implemented by subclass")

method encode*(tokenizer: Tokenizer, text: string): seq[int] {.base.} =
  ## Encode a string into a sequence of token integers
  ## Must be implemented by subclasses  
  raise newException(ValueError, "encode() must be implemented by subclass")

method decode*(tokenizer: Tokenizer, ids: seq[int]): string {.base.} =
  ## Decode a sequence of token integers into a string
  ## Must be implemented by subclasses
  raise newException(ValueError, "decode() must be implemented by subclass")

proc save*(tokenizer: Tokenizer, filePrefix: string) =
  ## Save tokenizer to files: filePrefix.model and filePrefix.vocab
  ## Model file is for loading, vocab file is for human inspection
  
  # Save model file (critical for load())
  let modelFile = filePrefix & ".model"
  var f = open(modelFile, fmWrite)
  defer: f.close()
  
  # Write version, pattern and special tokens
  f.writeLine("minbpe v1")
  f.writeLine(tokenizer.pattern)
  f.writeLine($tokenizer.specialTokens.len)
  
  for special, idx in tokenizer.specialTokens:
    f.writeLine(fmt"{special} {idx}")
  
  # Write merges with their actual indices
  for pair, idx in tokenizer.merges:
    f.writeLine(fmt"{pair.a} {pair.b} {idx}")
  
  # Save vocab file (for human inspection)  
  let vocabFile = filePrefix & ".vocab"
  var vf = open(vocabFile, fmWrite)
  defer: vf.close()
  
  var invertedMerges = initTable[int, tuple[a, b: int]]()
  for pair, idx in tokenizer.merges:
    invertedMerges[idx] = pair
  
  for idx in 0..<tokenizer.vocab.len:
    if idx in tokenizer.vocab:
      let token = tokenizer.vocab[idx]
      let renderedToken = renderToken(token)
      
      if idx in invertedMerges:
        # This is a merged token, show its components
        let pair = invertedMerges[idx]
        let idx0 = pair.a
        let idx1 = pair.b
        let token0 = renderToken(tokenizer.vocab[idx0])
        let token1 = renderToken(tokenizer.vocab[idx1])
        vf.writeLine(fmt"[{token0}][{token1}] -> [{renderedToken}] {idx}")
      else:
        # Leaf token (should be first 256 byte tokens)
        vf.writeLine(fmt"[{renderedToken}] {idx}")

proc load*(tokenizer: Tokenizer, modelFile: string) =
  ## Load tokenizer from model file (inverse of save)
  if not modelFile.endsWith(".model"):
    raise newException(ValueError, "Model file must end with .model")
  
  var merges = initTable[tuple[a, b: int], int]()
  var specialTokens = initTable[string, int]()
  
  var f = open(modelFile, fmRead)
  defer: f.close()
  
  # Read version
  let version = f.readLine().strip()
  if version != "minbpe v1":
    raise newException(ValueError, fmt"Expected minbpe v1, got {version}")
  
  # Read pattern
  tokenizer.pattern = f.readLine().strip()
  
  # Read special tokens
  let numSpecial = parseInt(f.readLine().strip())
  for _ in 0..<numSpecial:
    let parts = f.readLine().strip().split(' ', 1)
    let special = parts[0]
    let specialIdx = parseInt(parts[1])
    specialTokens[special] = specialIdx
  
  # Read merges with their actual indices
  while not f.endOfFile():
    let line = f.readLine().strip()
    if line.len > 0:
      let parts = line.split()
      let idx1 = parseInt(parts[0])
      let idx2 = parseInt(parts[1])
      let mergeIdx = parseInt(parts[2])
      merges[(idx1, idx2)] = mergeIdx
  
  # Update tokenizer
  tokenizer.merges = merges
  tokenizer.specialTokens = specialTokens  
  tokenizer.vocab = tokenizer.buildVocab()