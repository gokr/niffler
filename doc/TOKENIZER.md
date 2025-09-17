
## Token Estimation Systems

Niffler provides two complementary approaches for token counting:

1. **Heuristic Estimation** (Primary): Fast, lightweight token counting using intelligent language rules
2. **BPE Tokenizer Training** (Research): Advanced training system for precise tokenization research

### Heuristic Token Estimation (Primary System)

The main token estimation system uses heuristic analysis based on the tokenx library approach, providing 7-16% accuracy without requiring tokenizer training.

#### Quick Usage

```bash
# Test heuristic estimation accuracy
nim r test_heuristic_estimation.nim

# Test system prompt calculation with new estimation
nim r test_optimized_system_prompt.nim
```

#### Key Features

- **Fast**: No training required, instant estimation
- **Accurate**: 7-16% deviation from actual token counts vs 200%+ with char/4
- **Multi-language**: Built-in support for European languages, CJK characters
- **Lightweight**: Minimal memory usage, ~1MB/sec processing speed
- **Smart Rules**: Different handling for code, numbers, punctuation, whitespace

#### How It Works

1. **Text Segmentation**: Splits text by whitespace and punctuation
2. **Pattern Recognition**: Applies language-specific rules:
   - **CJK Characters**: 1 character = 1 token
   - **Numbers**: Entire number = 1 token  
   - **Short tokens** (≤3 chars): 1 token
   - **Punctuation**: Smart chunking
   - **European languages**: 3-3.5 chars per token (German, French, etc.)
   - **Default**: 6 characters per token
3. **Dynamic Correction**: Learns from actual API responses to improve accuracy

#### Integration

The heuristic system integrates seamlessly with Niffler's existing correction factor system:

```nim
# Main estimation function (now uses heuristics)
let baseEstimate = estimateTokens(text)

# Apply learned correction factors from API responses
let finalEstimate = countTokensForModel(text, "gpt-4")
```

#### Performance Results

The heuristic system provides significant accuracy improvements:

| System | Niffler System Prompt | Actual API Usage | Deviation |
|--------|----------------------|------------------|-----------|
| **Old BPE** | 13,533 tokens | 4,800 tokens | **+182%** |
| **New Heuristic** | 3,965 tokens | 4,800 tokens | **-17%** |

**Improvement**: From 182% overestimation to 17% underestimation (199 percentage point improvement)

### Optimized BPE Tokenizer Training (Research System)

Niffler includes an advanced BPE (Byte Pair Encoding) tokenizer training system with six algorithmic optimizations that achieve 20-100x speedup over standard implementations while maintaining identical accuracy.

#### Quick Start: Generate an Optimized BPE Tokenizer (Optional)

**Note**: This is for research purposes. The main system uses heuristic estimation.

```bash
# 1. Download a programming-focused training corpus (40MB)
scripts/py.sh

# 2. Generate optimized tokenizer from corpus
nim r generate_optimized_tokenizer.nim training_corpus.txt

# 3. Test the generated tokenizer performance
nim r test_optimized_system_prompt.nim
```

### Step-by-Step Process

#### 1. Download Training Corpus

The `scripts/py.sh` script downloads a curated 40MB programming corpus optimized for technical tokenization:

```bash
# Downloads training_corpus.txt with Python, JavaScript, web code, and documentation
scripts/py.sh
```

**Alternative**: Use any text file as training corpus:
```bash
nim r generate_optimized_tokenizer.nim your_corpus.txt
```

#### 2. Generate Optimized Tokenizer

```bash
# Generate with convergence-based adaptive vocabulary sizing
nim r generate_optimized_tokenizer.nim training_corpus.txt
```

**What this does:**
- Applies 6x BPE training optimizations for dramatic speedup
- Uses convergence detection to automatically determine optimal vocabulary size
- Generates `src/tokenization/optimized_trained_tokenizer.nim` with compile-time tables
- Achieves ~15 seconds training time for 40MB corpus (vs hours with standard BPE)
- Results in ~370 vocabulary size with 31% compression ratio

**Available options:**
```bash
nim r generate_optimized_tokenizer.nim                    # Uses default training_corpus.txt
nim r generate_optimized_tokenizer.nim custom_corpus.txt  # Uses custom corpus file
```

#### 3. Test Tokenizer Performance

```bash
# Test system prompt tokenization with optimized tokenizer
nim r test_optimized_system_prompt.nim
```

**This test shows:**
- Token count comparisons vs character/4 estimates
- System prompt breakdown with optimized tokenizer
- Compression efficiency and performance metrics
- Direct encoding vs system result comparisons

#### 4. Benchmark Against Current Implementation

```bash
# Compare optimized vs current tokenizer performance
nim r test_optimized_training.nim
```

**Benchmark results:**
- Training speed comparison (typically 20-100x faster)
- Vocabulary size accuracy verification
- Memory usage and compression ratios

### Six BPE Training Optimizations

The optimized tokenizer implements research from "From Hours to Seconds: Optimising BPE Tokeniser Training":

1. **Chunk Deduplication**: Process unique chunks only, weighted by frequency
2. **Incremental Counting**: Track pair count deltas instead of full recounts  
3. **Pair Location Tracking**: Index which chunks contain each pair
4. **In-place Operations**: Reduce memory allocation and GC pressure
5. **Fast Max Lookup**: O(1) max pair finding with priority queue
6. **Parallelization**: Distribute chunk processing across workers

### Generated Files

- `src/tokenization/optimized_trained_tokenizer.nim`: Auto-generated optimized tokenizer
- `src/tokenization/optimized_core.nim`: Core optimization algorithms and data structures
- `generate_optimized_tokenizer.nim`: Generator script with convergence training
- `test_optimized_training.nim`: Benchmark suite comparing implementations

### Integration with Niffler

The optimized tokenizer can be used throughout Niffler by replacing calls to:
```nim
# Old approach
let tokens = estimateTokens(text)

# New optimized approach  
let optimizedTokenizer = newOptimizedTrainedTokenizer()
let tokens = encode(optimizedTokenizer, text)
```

### Performance Characteristics

- **Training Time**: 15-30 seconds for 40MB corpus (vs hours with standard BPE)
- **Speedup**: 20-100x faster training depending on corpus size
- **Accuracy**: Identical results to standard BPE (verified)
- **Vocabulary Size**: Adaptive convergence-based sizing (typically 300-500 tokens)
- **Compression**: 30-35% typical compression ratio for programming text
- **Memory**: Optimized for low memory usage with in-place operations