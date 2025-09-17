# Dynamic Token Correction System

This document describes how Niffler's dynamic correction factor system works to provide increasingly accurate token estimates for different LLM models.

## Overview

Niffler uses a **self-improving token estimation system** that learns from actual API responses to provide more accurate token counts over time. The system combines heuristic estimation with machine learning-based correction factors, providing 7-16% accuracy compared to 200%+ deviation with simple character-based estimation.

## How It Works

### 1. Initial Token Estimation

When making API requests, Niffler estimates tokens using `countTokensForModel(text, modelName)`:
- Uses heuristic estimation based on language rules and patterns
- Applies any existing correction factor from the database
- The estimated count is used for cost projections and context planning

### 2. API Response Processing

When API responses return with actual token usage (`TokenUsage` object):
- The `logModelTokenUsage()` function stores **actual token counts** from the API
- This includes input tokens, output tokens, and reasoning tokens (for models that support thinking)

### 3. Correction Factor Learning

The `recordTokenCorrection()` function is called with:
- `estimatedTokens`: What Niffler predicted
- `actualTokens`: What the API actually charged  
- `modelName`: The specific model (e.g., "gpt-4", "claude-3-sonnet")

### 4. Database Storage & Calculation

`recordTokenCorrectionToDB()` processes each sample:
- Calculates ratio: `actualTokens / estimatedTokens`
- Updates rolling average: `avgCorrection = sumRatio / totalSamples`
- Stores per-model correction factors in `TokenCorrectionFactor` table

### 5. Dynamic Learning Algorithm

```nim
# For existing models:
factor.totalSamples += 1
factor.sumRatio += ratio  
factor.avgCorrection = factor.sumRatio / factor.totalSamples.float

# Example: If we estimated 1000 tokens but API charged 1100:
# ratio = 1100/1000 = 1.1
# This gets averaged with all previous samples for that model
```

### 6. Future Applications

Next time `countTokensForModel()` is called for that model:
- `applyCorrectionFactor()` retrieves the learned factor from database
- Applies it: `(estimatedTokens.float * factor).int`
- Each model gets its own correction factor (GPT-4 vs Claude vs Gemini, etc.)

## Database Schema

The correction factors are stored in the `TokenCorrectionFactor` table:

```nim
TokenCorrectionFactor = object
  modelName: string        # "gpt-4", "claude-3-sonnet", etc.
  totalSamples: int        # Number of API calls analyzed  
  sumRatio: float         # Sum of all actual/estimated ratios
  avgCorrection: float    # Current correction factor (sumRatio/totalSamples)
  createdAt: DateTime     # When first learned
  updatedAt: DateTime     # Last update
```

## Continuous Improvement

- **Each API call** provides a new training sample
- **Model-specific learning**: GPT-4 might need 1.05x correction, Claude might need 0.95x
- **Persistent across sessions**: Correction factors survive app restarts
- **Adaptive**: Automatically adjusts to tokenizer improvements or model updates

## Example Evolution

```
Sample 1: Estimated 1000, Actual 1100 → Factor = 1.100
Sample 2: Estimated 1000, Actual 1050 → Factor = 1.075 
Sample 3: Estimated 1000, Actual 1080 → Factor = 1.077
... after 100+ samples → Factor converges to ~1.073
```

## Key Components

### File Locations

- **Token estimation**: `src/tokenization/tokenizer.nim`
- **Database operations**: `src/core/database.nim`
- **Correction recording**: `tokenizer.nim:45-55`
- **Factor application**: `tokenizer.nim:applyCorrectionFactor()`
- **Database storage**: `database.nim:recordTokenCorrectionToDB()`

### Functions

- `countTokensForModel(text, modelName)`: Main estimation function with correction
- `recordTokenCorrection(modelName, estimated, actual)`: Records new training samples
- `applyCorrectionFactor(modelName, tokens)`: Applies learned corrections
- `getCorrectionFactorFromDB(database, model)`: Retrieves current factor

## Display in /context Command

The current correction factor is displayed in the `/context` command output:

```
💡 Using correction factor 1.073 for gpt-4
```

This shows:
- The exact correction factor currently being applied
- Which model it applies to
- All token counts in the context table use this correction factor

## Performance Results

The heuristic + correction system provides significant accuracy improvements:

| System | Niffler System Prompt | Actual API Usage | Deviation |
|--------|----------------------|------------------|-----------|
| **Old char/4** | 13,533 tokens | 4,800 tokens | **+182%** |
| **New Heuristic + Correction** | ~4,200 tokens | 4,800 tokens | **~12%** |

**Improvement**: From 182% overestimation to ~12% deviation - a 170 percentage point improvement.

## Benefits

1. **Accuracy**: Self-correcting estimates get more precise over time
2. **Model-specific**: Each LLM gets its own learned correction factor
3. **Transparent**: Users can see exactly what correction is being applied
4. **Persistent**: Learning survives across app sessions
5. **Automatic**: No manual configuration required
6. **Cost-effective**: More accurate token estimates lead to better cost predictions