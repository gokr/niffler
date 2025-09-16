## Test for dynamic correction factor system
## Demonstrates how the system learns and improves token estimates

import std/[unittest, strformat, os, tables, options]
import ../../src/tokenization/tokenizer
import ../../src/core/database
import ../../src/types/config as configTypes

suite "Dynamic Correction Factor Tests":
  
  setup:
    # Create in-memory database for testing
    let testDbConfig = DatabaseConfig(
      `type`: dtSQLite,
      enabled: true,
      path: some(":memory:"),  # In-memory database for testing
      walMode: false,
      busyTimeout: 1000,
      poolSize: 1
    )
    let testDb = createDatabaseBackend(testDbConfig)
    setGlobalDatabase(testDb)
    clearCorrectionData()  # Start fresh for each test
  
  teardown:
    # Cleanup correction data
    clearCorrectionData()

  test "Basic correction recording and application":
    let text = "Hello world, this is a test message"
    let modelName = "test-model"
    
    # Get initial estimate
    let initialEstimate = estimateTokens(text)
    echo fmt"Initial estimate: {initialEstimate} tokens"
    
    # Simulate getting actual token counts from API (e.g., actual was higher)
    let actualTokens1 = initialEstimate + 3  # Model uses 3 more tokens than estimated
    let actualTokens2 = initialEstimate + 2  # Second request, still 2 more
    let actualTokens3 = initialEstimate + 4  # Third request, 4 more
    
    # Record correction samples
    recordTokenCountCorrection(modelName, initialEstimate, actualTokens1)
    recordTokenCountCorrection(modelName, initialEstimate, actualTokens2) 
    recordTokenCountCorrection(modelName, initialEstimate, actualTokens3)
    
    # Now apply correction - should be close to average actual count
    let correctedEstimate = countTokensForModel(text, modelName)
    echo fmt"Corrected estimate: {correctedEstimate} tokens"
    
    # Correction should improve the estimate
    let expectedAvg = (actualTokens1 + actualTokens2 + actualTokens3) / 3
    let tolerance = 1.0  # Allow 1 token tolerance
    check correctedEstimate >= (expectedAvg - tolerance).int
    check correctedEstimate <= (expectedAvg + tolerance).int
    
    # Should be different from initial estimate
    check correctedEstimate != initialEstimate

  test "Model-specific corrections":
    let text = "Test message for model-specific corrections"
    let gptModel = "gpt-4"
    let qwenModel = "qwen-plus"
    
    let baseEstimate = estimateTokens(text)
    
    # Simulate GPT-4 typically using fewer tokens (more efficient tokenizer)
    recordTokenCountCorrection(gptModel, baseEstimate, baseEstimate - 2)
    recordTokenCountCorrection(gptModel, baseEstimate, baseEstimate - 1)
    recordTokenCountCorrection(gptModel, baseEstimate, baseEstimate - 2)
    
    # Simulate Qwen using more tokens  
    recordTokenCountCorrection(qwenModel, baseEstimate, baseEstimate + 3)
    recordTokenCountCorrection(qwenModel, baseEstimate, baseEstimate + 4)
    recordTokenCountCorrection(qwenModel, baseEstimate, baseEstimate + 2)
    
    # Apply corrections
    let gptCorrected = countTokensForModel(text, gptModel)
    let qwenCorrected = countTokensForModel(text, qwenModel)
    
    echo fmt"Base estimate: {baseEstimate}"
    echo fmt"GPT-4 corrected: {gptCorrected}"  
    echo fmt"Qwen corrected: {qwenCorrected}"
    
    # GPT correction should be lower, Qwen should be higher
    check gptCorrected < baseEstimate
    check qwenCorrected > baseEstimate
    check gptCorrected != qwenCorrected  # Different models have different corrections

  test "Correction stats and persistence":
    let modelName = "stats-test-model"
    let estimate = 10
    
    # Record some corrections
    recordTokenCountCorrection(modelName, estimate, 12)
    recordTokenCountCorrection(modelName, estimate, 13) 
    recordTokenCountCorrection(modelName, estimate, 11)
    
    # Check stats
    let stats = getCorrectionStats()
    var found = false
    for factor in stats:
      if factor.modelName == modelName:
        found = true
        check factor.totalSamples == 3
        check factor.avgCorrection > 1.0  # Should be > 1 since actuals were higher
        break
    check found

  test "Too few samples doesn't apply correction":
    let modelName = "insufficient-samples"
    let estimate = 8
    
    # Record only 1 sample (need 3+ for correction to apply)
    recordTokenCountCorrection(modelName, estimate, 10)
    
    # Should not apply correction yet (need 3+ samples)
    let result = countTokensForModel("test text for insufficient samples", modelName) 
    let baseEstimate = estimateTokens("test text for insufficient samples")
    check result == baseEstimate  # No correction applied

  test "Extreme corrections are ignored":
    let modelName = "extreme-test"
    let estimate = 10
    
    # Record extreme ratios that would be ignored
    recordTokenCountCorrection(modelName, estimate, 25)  # 2.5x ratio - too high
    recordTokenCountCorrection(modelName, estimate, 30)  # 3.0x ratio - way too high  
    recordTokenCountCorrection(modelName, estimate, 35)  # 3.5x ratio - extreme
    
    # Should not apply extreme correction
    let testText = "test text for extreme correction"
    let result = countTokensForModel(testText, modelName)
    let baseEstimate = estimateTokens(testText)
    check result == baseEstimate  # No correction applied due to extreme ratios

echo "Running dynamic correction factor tests..."