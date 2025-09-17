## Test and benchmark optimized BPE training implementation
## Validates correctness and measures performance improvements

import std/[times, strformat, os, tables]
import src/tokenization/[core, optimized_core]

proc testBasicOptimizations*() =
  ## Test basic functionality of optimized data structures
  echo "=== Testing Basic Optimizations ==="
  
  # Test chunk deduplication
  let textChunks = @["the", "quick", "brown", "fox", "the", "quick", "dog"]
  let weightedChunks = deduplicateChunks(textChunks)
  
  echo fmt("Original chunks: {textChunks.len}")
  echo fmt("Deduplicated chunks: {weightedChunks.len}")
  
  for chunk in weightedChunks:
    echo fmt("  {chunk}")
  
  # Test fast max tracker
  var tracker: FastMaxTracker
  var pairCounts = initTable[TokenPair, int]()
  pairCounts[(97, 98)] = 5
  pairCounts[(98, 99)] = 3
  pairCounts[(99, 100)] = 7
  initializeFastMaxTracker(tracker, pairCounts)
  
  let (maxPair, maxCount) = getMostCommonPair(tracker)
  echo fmt("Most common pair: {maxPair} with count {maxCount}")
  
  # Test delta application
  var deltas = initTable[TokenPair, int]()
  deltas[(97, 98)] = -2
  deltas[(100, 101)] = 4
  applyDeltas(tracker, deltas)
  
  let (newMaxPair, newMaxCount) = getMostCommonPair(tracker)
  echo fmt("After deltas - Most common pair: {newMaxPair} with count {newMaxCount}")

proc testOptimizedTraining*() =
  ## Test optimized training on a small corpus
  echo "\n=== Testing Optimized Training ==="
  
  let testText = """
  The quick brown fox jumps over the lazy dog.
  The brown fox is quick and agile.
  A lazy dog sleeps in the sun.
  The fox jumps quickly over obstacles.
  """
  
  var optimizedTokenizer = newOptimizedTokenizer()
  
  echo "Training with optimized algorithm..."
  let startTime = epochTime()
  
  let result = trainOptimizedUntilConvergence(
    optimizedTokenizer,
    testText,
    maxVocabSize = 300,
    minImprovement = 0.01,
    minFrequency = 2,
    verbose = true
  )
  
  let elapsed = epochTime() - startTime
  
  echo fmt("Training completed in {elapsed:.3f}s")
  echo fmt("Final vocabulary size: {result.finalVocabSize}")
  echo fmt("Convergence reason: {result.reason}")
  echo fmt("Number of merge rules: {optimizedTokenizer.merges.len}")

proc benchmarkComparison*() =
  ## Compare performance with current implementation on Taylor Swift corpus
  echo "\n=== Benchmarking Comparison ==="
  
  let corpusPath = "/home/gokr/tankfeud/minbpe/tests/taylorswift.txt"
  if not fileExists(corpusPath):
    echo "Taylor Swift corpus not found, skipping benchmark"
    return
  
  let trainingText = readFile(corpusPath)
  echo fmt("Corpus size: {trainingText.len} characters")
  
  # Test optimized training
  echo "\nTesting optimized training..."
  var optimizedTokenizer = newOptimizedTokenizer()
  
  let optimizedStart = epochTime()
  let optimizedResult = trainOptimizedUntilConvergence(
    optimizedTokenizer,
    trainingText,
    maxVocabSize = 2000,
    minImprovement = 0.001,
    minFrequency = 2,
    verbose = false
  )
  let optimizedElapsed = epochTime() - optimizedStart
  
  echo fmt("Optimized training: {optimizedElapsed:.3f}s")
  echo fmt("Final vocab size: {optimizedResult.finalVocabSize}")
  echo fmt("Convergence reason: {optimizedResult.reason}")
  echo fmt("Merge rules: {optimizedTokenizer.merges.len}")
  
  # Test current implementation for comparison
  echo "\nTesting current implementation..."
  var currentTokenizer = newRegexTokenizer()
  
  let currentStart = epochTime()
  let currentResult = trainUntilConvergence(
    currentTokenizer,
    trainingText,
    maxVocabSize = 2000,
    minImprovement = 0.001,
    minFrequency = 2,
    verbose = false
  )
  let currentElapsed = epochTime() - currentStart
  
  echo fmt("Current training: {currentElapsed:.3f}s")
  echo fmt("Final vocab size: {currentResult.finalVocabSize}")
  echo fmt("Convergence reason: {currentResult.reason}")
  echo fmt("Merge rules: {currentTokenizer.merges.len}")
  
  # Compare results
  if currentElapsed > 0.001: # Avoid division by zero
    let speedup = currentElapsed / optimizedElapsed
    echo fmt("\nSpeedup: {speedup:.1f}x faster")
  
  # Check if results are similar (they should be identical)
  echo fmt("Vocab size difference: {optimizedResult.finalVocabSize - currentResult.finalVocabSize}")
  
proc main*() =
  echo "Testing Optimized BPE Training Implementation"
  echo "============================================"
  
  testBasicOptimizations()
  testOptimizedTraining()
  benchmarkComparison()
  
  echo "\nAll tests completed!"

when isMainModule:
  main()