# Nim Sequence (seq) Tutorial

This tutorial covers the fundamentals of using sequences (`seq`) in Nim, one of the most commonly used data structures in the language.

## Table of Contents
- [What is a seq?](#what-is-a-seq)
- [Creating Sequences](#creating-sequences)
- [Basic Operations](#basic-operations)
- [Adding and Removing Elements](#adding-and-removing-elements)
- [Accessing Elements](#accessing-elements)
- [Iterating Over Sequences](#iterating-over-sequences)
- [Useful Procedures](#useful-procedures)
- [Memory Management](#memory-management)
- [Common Patterns](#common-patterns)
- [Complete Example](#complete-example)

## What is a seq?

A `seq` is Nim's built-in dynamic array data structure. Unlike static arrays, sequences can grow and shrink at runtime, making them perfect for collections of items where the size isn't known at compile time.

Key characteristics:
- **Dynamic size**: Can grow and shrink as needed
- **Heap allocated**: Stored on the heap, not the stack
- **Type-safe**: All elements must be of the same type
- **Zero-based indexing**: First element is at index 0

## Creating Sequences

### Empty Sequences

```nim
# Create an empty sequence of integers
var numbers: seq[int] = @[]

# Or using the newSeq procedure
var strings = newSeq[string]()
```

### Sequences with Initial Values

```nim
# Create a sequence with initial values
var fruits = @["apple", "banana", "cherry"]

# Using the newSeqOfCap procedure (more efficient for large sequences)
var largeSeq = newSeqOfCap[int](1000)  # Pre-allocate capacity
```

### Sequences from Ranges

```nim
# Create a sequence from a range
var countTo10 = @[1..10]  # Result: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

# Or using toSeq from the sequtils module
import sequtils
var numbers = toSeq(1..5)  # Result: [1, 2, 3, 4, 5]
```

## Basic Operations

### Length and Capacity

```nim
var nums = @[1, 2, 3, 4, 5]

echo "Length: ", nums.len        # Output: Length: 5
echo "Capacity: ", nums.cap      # Output: Capacity: 5 (may be >= len)
echo "Is empty: ", nums.isEmpty  # Output: Is empty: false
```

### Checking if Empty

```nim
var emptySeq: seq[int] = @[]

if emptySeq.len == 0:
  echo "Sequence is empty"

# Or using the isEmpty procedure
import sequtils
if emptySeq.isEmpty:
  echo "Sequence is empty"
```

## Adding and Removing Elements

### Adding Elements

```nim
var items = @["a", "b", "c"]

# Add single element to the end
items.add("d")  # Result: ["a", "b", "c", "d"]

# Add multiple elements
items.add(["e", "f"])  # Result: ["a", "b", "c", "d", "e", "f"]

# Using the & operator (creates a new sequence)
var newItems = items & @["g", "h"]  # Result: ["a", "b", "c", "d", "e", "f", "g", "h"]

# Insert at specific position
items.insert("x", 2)  # Insert "x" at index 2
```

### Removing Elements

```nim
var data = @[10, 20, 30, 40, 50]

# Remove last element
data.delete(data.high)  # Result: [10, 20, 30, 40]

# Remove element at specific index
data.delete(1)  # Remove element at index 1 (20), result: [10, 30, 40]

# Remove range of elements
data.delete(0..1)  # Remove elements at indices 0 and 1, result: [40]

# Clear all elements
data.setLen(0)  # Result: []
```

## Accessing Elements

### Indexing

```nim
var colors = @["red", "green", "blue", "yellow"]

# Access by index (zero-based)
echo colors[0]  # Output: red
echo colors[2]  # Output: blue

# Using high to get last index
echo colors[colors.high]  # Output: yellow

# Using len - 1 for last index
echo colors[colors.len - 1]  # Output: yellow
```

### Slicing

```nim
var numbers = @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

# Get a subset (slice)
echo numbers[1..4]    # Output: [2, 3, 4, 5]
echo numbers[0..<3]   # Output: [1, 2, 3] (0 to 2)
echo numbers[5..]     # Output: [6, 7, 8, 9, 10] (from index 5 to end)
echo numbers[^3..^1]  # Output: [8, 9, 10] (last 3 elements)
```

### Safe Access

```nim
var data = @[10, 20, 30]

# Safe access using try-except
try:
  echo data[10]  # This will raise an IndexError
except IndexError:
  echo "Index out of bounds!"

# Check bounds before access
let index = 2
if index < data.len:
  echo data[index]
else:
  echo "Index out of bounds!"
```

## Iterating Over Sequences

### Basic For Loop

```nim
var fruits = @["apple", "banana", "cherry"]

for fruit in fruits:
  echo "I like ", fruit
```

### With Index

```nim
for i, fruit in fruits:
  echo i, ": ", fruit
```

### While Loop

```nim
var i = 0
while i < fruits.len:
  echo fruits[i]
  inc(i)
```

### Reverse Iteration

```nim
# Using countdown
for i in countdown(fruits.high, 0):
  echo fruits[i]

# Or using reversed from sequtils
import sequtils
for fruit in fruits.reversed:
  echo fruit
```

## Useful Procedures

### From the sequtils module

```nim
import sequtils

var numbers = @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

# Filter
var evenNumbers = numbers.filter(x => x mod 2 == 0)  # [2, 4, 6, 8, 10]

# Map
var squares = numbers.map(x => x * x)  # [1, 4, 9, 16, 25, 36, 49, 64, 81, 100]

# Fold (reduce)
var sum = numbers.foldl(a + b)  # 55

# Any and All
var hasEven = numbers.any(x => x mod 2 == 0)  # true
var allPositive = numbers.all(x => x > 0)  # true

# Join
var words = @["hello", "world", "nim"]
var sentence = words.join(" ")  # "hello world nim"
```

### Sorting and Searching

```nim
import algorithm

var unsorted = @[3, 1, 4, 1, 5, 9, 2, 6]

# Sort in place
unsorted.sort()  # [1, 1, 2, 3, 4, 5, 6, 9]

# Sort with custom comparator
var words = @["banana", "apple", "cherry"]
words.sort(cmp)  # ["apple", "banana", "cherry"]

# Binary search (sequence must be sorted)
let index = unsorted.binarySearch(5)  # Returns index or -1 if not found
```

## Memory Management

### Capacity Management

```nim
var data = newSeq[int]()

# Reserve capacity for better performance
data.setLen(0)  # Clear but keep capacity
data.setCap(1000)  # Set capacity to 1000

# Check current capacity
echo "Current capacity: ", data.cap
```

### Performance Tips

```nim
# Use newSeqOfCap when you know approximate size
var items = newSeqOfCap[string](1000)
for i in 0..<1000:
  items.add("item " & $i)

# Avoid repeated concatenation with & operator in loops
# Instead, use add() for better performance
var result = newSeq[string]()
for i in 0..<1000:
  result.add("item " & $i)  # Good
  # result = result & @["item " & $i]  # Bad - creates new sequence each time
```

## Common Patterns

### Building a sequence

```nim
# Pattern 1: Using add()
var result: seq[int] = @[]
for i in 1..10:
  if i mod 2 == 0:
    result.add(i)

# Pattern 2: Using filter from sequtils
import sequtils
var result2 = toSeq(1..10).filter(x => x mod 2 == 0)
```

### Processing sequences

```nim
# Chain operations
import sequtils

var numbers = @[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
var result = numbers
  .filter(x => x mod 2 == 0)  # Get even numbers
  .map(x => x * x)           # Square them
  .filter(x => x > 20)       # Keep only > 20
# Result: [36, 64, 100]
```

### Working with strings

```nim
# Split string into sequence of words
import strutils
var text = "hello world nim programming"
var words = text.split()  # ["hello", "world", "nim", "programming"]

# Join sequence into string
var sentence = words.join(" ")  # "hello world nim programming"
```

## Complete Example

Here's a complete program that demonstrates many sequence operations:

```nim
import sequtils, algorithm, strutils

proc demonstrateSequences() =
  echo "=== Nim Sequence Tutorial Demo ===\n"
  
  # 1. Creating sequences
  var numbers = @[1, 2, 3, 4, 5]
  var strings = @["hello", "world", "nim"]
  
  echo "1. Initial sequences:"
  echo "Numbers: ", numbers
  echo "Strings: ", strings
  echo()
  
  # 2. Adding elements
  numbers.add(6)
  numbers.add([7, 8, 9, 10])
  strings.add("programming")
  
  echo "2. After adding elements:"
  echo "Numbers: ", numbers
  echo "Strings: ", strings
  echo()
  
  # 3. Accessing elements
  echo "3. Accessing elements:"
  echo "First number: ", numbers[0]
  echo "Last number: ", numbers[numbers.high]
  echo "Slice [1..3]: ", numbers[1..3]
  echo()
  
  # 4. Functional operations
  echo "4. Functional operations:"
  echo "Even numbers: ", numbers.filter(x => x mod 2 == 0)
  echo "Squares: ", numbers.map(x => x * x)
  echo "Sum: ", numbers.foldl(a + b)
  echo()
  
  # 5. Sorting
  var unsorted = @[3, 1, 4, 1, 5, 9, 2, 6]
  echo "5. Sorting:"
  echo "Unsorted: ", unsorted
  unsorted.sort()
  echo "Sorted: ", unsorted
  echo()
  
  # 6. String operations
  echo "6. String operations:"
  var sentence = "The quick brown fox jumps over the lazy dog"
  var words = sentence.split()
  echo "Words: ", words
  echo "Joined with '-': ", words.join("-")
  echo "Word count: ", words.len
  echo()
  
  # 7. Performance demonstration
  echo "7. Performance pattern:"
  var largeSeq = newSeqOfCap[int](1000)
  for i in 0..<1000:
    largeSeq.add(i * i)
  echo "Created sequence with ", largeSeq.len, " elements"
  echo "First 10: ", largeSeq[0..9]

# Run the demonstration
when isMainModule:
  demonstrateSequences()
```

## Summary

Sequences are a fundamental and powerful data structure in Nim. Here are the key takeaways:

1. **Dynamic**: They can grow and shrink at runtime
2. **Efficient**: Use `newSeqOfCap()` when you know the approximate size
3. **Flexible**: Support slicing, functional programming, and many built-in operations
4. **Type-safe**: All elements must be of the same type
5. **Memory-managed**: Nim handles memory allocation and deallocation automatically

The `sequtils` and `algorithm` modules provide many additional useful procedures for working with sequences. Mastering sequences will make you much more productive in Nim programming!