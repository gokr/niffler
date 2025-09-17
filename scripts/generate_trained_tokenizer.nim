## Train regex tokenizer and generate Nim code for compile-time inclusion
import std/[strformat, os, strutils, tables]
import src/tokenization/[core, tokenizer]

proc escapeNimString(s: string): string =
  ## Escape a string for safe inclusion in Nim code
  result = "\""
  for ch in s:
    case ch:
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\0': result.add("\\0")
    else:
      # Handle other control characters
      if ord(ch) < 32 or ord(ch) >= 127:
        result.add("\\x" & ord(ch).toHex(2))
      else:
        result.add(ch)
  result.add("\"")

proc generateTrainedTokenizerCode(tokenizer: Tokenizer, moduleName: string): string =
  ## Generate Nim code that recreates the trained tokenizer at compile time
  let header = fmt"""## Auto-generated trained tokenizer: {moduleName}
## Generated from training corpus
## DO NOT EDIT - regenerate using generate_trained_tokenizer.nim

import std/tables
import ./core

proc new{moduleName}*(): Tokenizer =
  ## Create pre-trained regex tokenizer with compiled merge rules
  result = Tokenizer(kind: tkRegex)
  result.pattern = {escapeNimString(tokenizer.pattern)}
  result.specialTokens = initTable[string, int]()
  
  # Pre-trained merge rules (compiled at build time)
"""
  result = header

  # Add merge rules as compile-time table literal
  result.add("  result.merges = {\n")
  var mergeEntries: seq[string] = @[]
  for pair, idx in tokenizer.merges:
    mergeEntries.add(fmt"    ({pair.a}, {pair.b}): {idx}")
  
  result.add(mergeEntries.join(",\n"))
  result.add("\n  }.toTable\n\n")
  
  # Add vocabulary as compile-time table literal
  result.add("  # Pre-built vocabulary (compiled at build time)\n")
  result.add("  result.vocab = {\n")
  
  var vocabEntries: seq[string] = @[]
  for idx, token in tokenizer.vocab:
    vocabEntries.add(fmt"    {idx}: {escapeNimString(token)}")
  
  result.add(vocabEntries.join(",\n"))
  result.add("\n  }.toTable\n\n")
  
  # Add usage example in comments
  result.add(fmt"""
# Usage example:
# let tokenizer = new{moduleName}()
# let tokens = tokenizer.encode("Hello, world!")
# let text = tokenizer.decode(tokens)
""")

proc main() =
  echo "=== Generating Trained Tokenizer Nim Code ==="
  
  # Check for command line arguments for corpus file
  var corpusPath = ""
  if paramCount() > 0:
    corpusPath = paramStr(1)
  else:
    # Default to programming-focused corpus if no argument provided
    corpusPath = "training_corpus.txt"
  
  if not fileExists(corpusPath):
    echo "Error: Training corpus file not found at: ", corpusPath
    echo "Usage: nim r generate_trained_tokenizer.nim [corpus_file.txt]"
    echo "       nim r generate_trained_tokenizer.nim  # (uses default training_corpus.txt)"
    return
    
  let trainingText = readFile(corpusPath)
  echo fmt"Training corpus: {corpusPath}"
  echo fmt"Corpus size: {trainingText.len} characters"
  
  # Create and train regex tokenizer using convergence-based approach
  echo "Training regex tokenizer with convergence detection..."
  var regexTokenizer = newRegexTokenizer()
  
  # Use convergence-based training instead of fixed vocabulary size
  let maxVocabSize = if trainingText.len > 500000: 50000
                     elif trainingText.len > 100000: 20000
                     else: 10000
  echo fmt"Training with convergence detection (max vocab: {maxVocabSize})"
  echo "Convergence thresholds: min improvement 0.1%, min frequency 2"
  
  var trainingResult: tuple[finalVocabSize: int, reason: string]
  try:
    trainingResult = regexTokenizer.trainUntilConvergence(
      trainingText, 
      maxVocabSize = maxVocabSize,
      minImprovement = 0.001,  # 0.1% improvement threshold
      minFrequency = 2,        # Pairs must appear at least 2 times
      verbose = true
    )
    echo fmt"Training completed successfully!"
    echo fmt"Final vocabulary size: {trainingResult.finalVocabSize}"
    echo fmt"Convergence reason: {trainingResult.reason}"
  except Exception as e:
    echo "Training failed: ", e.msg
    return
  
  # Test the trained tokenizer
  echo "\nTesting trained tokenizer..."
  let testTexts = @[
    "Hello, world!",
    "The quick brown fox jumps over the lazy dog.",
    "I'll be there in 5 minutes.",
    "This is a test of the BPE tokenization system."
  ]
  
  var totalImprovement = 0.0
  var testCount = 0
  for testText in testTexts:
    let oldEstimate = testText.len  # Compare against character count
    let newTokens = regexTokenizer.encode(testText)
    
    if oldEstimate > 0:
      let improvement = 100.0 * (oldEstimate - newTokens.len).float / oldEstimate.float
      totalImprovement += improvement
      inc testCount
    
    let decoded = regexTokenizer.decode(newTokens)
    let lossless = if testText == decoded: "✅" else: "❌"
    echo fmt"  {lossless} '{testText}' ({testText.len} chars -> {newTokens.len} tokens)"
  
  if testCount > 0:
    echo fmt"\nAverage compression: {totalImprovement / testCount.float:.1f}%"
  
  # Generate Nim code
  echo "\nGenerating Nim code..."
  let generatedCode = generateTrainedTokenizerCode(regexTokenizer, "TrainedRegexTokenizer")
  
  # Write to file
  let outputPath = "src/tokenization/trained_tokenizer.nim"
  writeFile(outputPath, generatedCode)
  echo fmt"Generated trained tokenizer code: {outputPath}"
  
  # Count generated elements and show final statistics
  var mergeCount = 0
  for pair in regexTokenizer.merges.keys:
    inc mergeCount
  var vocabCount = 0  
  for idx in regexTokenizer.vocab.keys:
    inc vocabCount
    
  echo fmt"  - {mergeCount} merge rules"
  echo fmt"  - {vocabCount} vocabulary entries (achieved: {trainingResult.finalVocabSize})"
  echo fmt"  - Convergence: {trainingResult.reason}"
  echo fmt"  - Ready for compile-time inclusion!"
  
  # Test compilation
  echo "\nTesting generated code compilation..."
  let compileResult = execShellCmd("nim c --threads:on -d:ssl src/tokenization/trained_tokenizer.nim")
  if compileResult == 0:
    echo "✅ Generated tokenizer compiles successfully!"
  else:
    echo "❌ Generated tokenizer failed to compile"

when isMainModule:
  main()