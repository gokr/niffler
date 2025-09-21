# Stream-Based BPE Training for Large Corpora

This document explains how Byte Pair Encoding (BPE) works for LLM tokenizers and how to train it efficiently on large text corpora using chunk-wise processing.

## How BPE (Byte Pair Encoding) Works

BPE is a greedy algorithm that builds a vocabulary by iteratively merging the most frequent pairs of tokens.

### Step-by-Step Algorithm:

1. **Start with base vocabulary**: Begin with individual characters or bytes as tokens
2. **Count frequency pairs**: Go through training text and count how often each pair of tokens appears together
3. **Find most frequent pair**: Identify the pair that occurs most frequently
4. **Merge the pair**: Create a new token that represents this pair
5. **Update text**: Replace all instances of that pair with the new merged token
6. **Repeat**: Continue the process until reaching desired vocabulary size

### Example:

```
Initial text: "low lower widest"
Base tokens: ['l','o','w',' ','l','o','w','e','r',' ','w','i','d','e','s','t']

Iteration 1: 'l' + 'o' = 'lo' (appears 2 times)
Tokens: ['lo','w',' ','lo','w','e','r',' ','w','i','d','e','s','t']

Iteration 2: 'lo' + 'w' = 'low' (appears 2 times)  
Tokens: ['low',' ','low','e','r',' ','w','i','d','e','s','t']

...continue until vocabulary size limit reached
```

### Key Properties:

- **Data-driven**: Vocabulary is learned from training text, not predefined
- **Subword tokens**: Can handle rare words by breaking them into familiar subwords
- **Efficient encoding**: Common words become single tokens, rare words use multiple tokens

## Training Data Requirements

### For a "Good" Tokenizer:

**Minimum viable**: ~100 MB - 1 GB of text
- Can create basic vocabulary
- Handles common words reasonably well
- May struggle with domain-specific terms

**Good quality**: 1-10 GB of text  
- Covers most common word patterns
- Better handling of compound words and technical terms
- Vocabulary starts to stabilize

**High quality**: 10-100+ GB of text
- Comprehensive vocabulary coverage
- Excellent for domain-specific applications
- Stable, general-purpose tokenizer

### Real-World Examples:

- **GPT-2**: ~40 GB of web text (trained on 40K merge operations)
- **LLaMA**: Hundreds of GB to TBs of diverse text
- **Most open-source models**: 5-50 GB range

### Factors Affecting Quality:

1. **Diversity**: Mix of different domains (news, books, code, conversations)
2. **Quality**: Clean, well-formatted text works better than noisy data
3. **Domain match**: Training data should match intended use case
4. **Vocabulary size**: 30K-100K tokens is typical (more isn't always better)

### Practical Advice:

For most applications, **5-20 GB of diverse, high-quality text** produces excellent results. The key is diversity and quality rather than just raw volume. A tokenizer trained on well-curated 10GB of diverse text often outperforms one trained on 100GB of low-quality, repetitive data.

## Memory Requirements for BPE Training

### Typical Memory Usage:

**For small corpora (100 MB - 1 GB):**
- **RAM needed**: 1-8 GB
- Can keep entire corpus in memory
- Fast processing, simple implementation

**For medium corpora (1-10 GB):**
- **RAM needed**: 4-32 GB  
- May need chunk-wise processing
- Frequency counting becomes memory-intensive

**For large corpora (10-100+ GB):**
- **RAM needed**: 8-64 GB+ (with chunk-wise processing)
- **Definitely requires chunk-wise processing**
- Memory used for frequency tables, not the corpus itself

### Memory Breakdown:

1. **Frequency tables**: O(vocabulary_size²) for pair counts
   - 50K vocabulary → ~2.5B possible pairs
   - But most pairs have zero frequency → sparse storage

2. **Vocabulary storage**: O(vocabulary_size)
   - 50K tokens × average 4 bytes/token ≈ 200 KB

3. **Corpus processing**: Can be streamed, doesn't need full storage

## Stream-Based Chunk-wise Processing

### Chunk-wise Processing Strategy:

```
Initialize empty frequency table
For each chunk of text:
    Tokenize chunk with current vocabulary
    Count token pair frequencies in chunk
    Add counts to global frequency table
    Discard chunk (free memory)
Find most frequent pair globally
Merge pair into vocabulary
Repeat until desired vocabulary size
```

### Real-World Implementation:

```python
# Pseudocode for chunk-wise BPE
vocab = initial_characters()  # Start with chars/bytes

for merge_iteration in range(num_merges):
    pair_counts = defaultdict(int)
    
    # Process corpus in chunks
    for chunk in load_text_chunks(chunk_size="100MB"):
        tokens = tokenize_with_vocab(chunk, vocab)
        for i in range(len(tokens) - 1):
            pair = (tokens[i], tokens[i + 1])
            pair_counts[pair] += 1
    
    # Find and merge most frequent pair
    best_pair = max(pair_counts, key=pair_counts.get)
    vocab.add(merge_tokens(best_pair))
```

### Practical Memory Optimization:

**Chunk size recommendations:**
- **Small memory**: 10-50 MB chunks
- **Medium memory**: 50-200 MB chunks  
- **Large memory**: 200 MB - 1 GB chunks

**Memory-saving techniques:**
1. **Streaming**: Process text line-by-line or in fixed chunks
2. **Sparse storage**: Use hash tables for frequency counts (only store pairs that actually occur)
3. **Disk-backed storage**: For extremely large frequency tables
4. **Sampling**: Use random subsets for initial iterations

## Real-World Implementations

### HuggingFace tokenizers library:
- Processes ~1 GB chunks
- Uses ~4-16 GB RAM for 100GB corpus
- Parallel processing with multiple workers

### SentencePiece (Google):
- Designed for massive corpora
- Memory-efficient chunk-wise processing
- Can handle TB-scale datasets on modest hardware

## Key Insight

**You don't need RAM = corpus_size.** You need RAM = frequency_table_size + chunk_size + vocabulary_size.

For training on 100GB of text:
- **Chunk size**: 100MB (in memory at once)
- **Frequency table**: ~1-4 GB (sparse storage)
- **Vocabulary**: ~200 KB
- **Total RAM needed**: ~2-6 GB

This makes BPE training feasible even on consumer hardware for very large corpora!

## Summary

Stream-based BPE training enables efficient tokenizer training on massive text corpora by:

1. **Processing text in chunks**: Only small portions loaded into memory at once
2. **Accumulating frequency counts**: Global statistics built incrementally
3. **Memory-efficient storage**: Sparse data structures for frequency tables
4. **Scalable architecture**: Can handle TB-scale datasets on modest hardware

The combination of chunk-wise processing and sparse data structures makes modern BPE training both memory-efficient and scalable, enabling high-quality tokenizer creation without requiring massive RAM resources.