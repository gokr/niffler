# Generics in Nim

Generics in Nim provide a powerful way to write type-safe, reusable code that works with multiple types while maintaining static type checking and performance.

## Basic Generic Procedures

Generic procedures are defined using square brackets `[]` after the procedure name to declare type parameters:

```nim
# A generic identity function
proc identity[T](x: T): T = x

echo identity(42)        # Works with int
echo identity("hello")   # Works with string
echo identity(3.14)      # Works with float

# Generic swap procedure
proc swap[T](a, b: var T) =
  let temp = a
  a = b
  b = temp

var x = 10
var y = 20
swap(x, y)
echo x, y  # Output: 20 10
```

## Generic Types

You can create generic types using the same syntax:

```nim
# Generic container type
type
  Container[T] = object
    data: seq[T]
    count: int

# Generic stack
  Stack[T] = object
    items: array[100, T]
    top: int

proc push[T](s: var Stack[T], item: T) =
  if s.top < 100:
    s.items[s.top] = item
    inc s.top

proc pop[T](s: var Stack[T]): T =
  if s.top > 0:
    dec s.top
    result = s.items[s.top]

# Usage
var intStack: Stack[int]
intStack.push(42)
intStack.push(24)
echo intStack.pop()  # 24

var stringStack: Stack[string]
stringStack.push("hello")
stringStack.push("world")
echo stringStack.pop()  # "world"
```

## Multiple Type Parameters

Generics can have multiple type parameters:

```nim
proc pairToTuple[K, V](key: K, value: V): (K, V) =
  (key, value)

let result = pairToTuple("age", 25)
echo result  # ("age", 25)

type
  KeyValuePair[K, V] = object
    key: K
    value: V

var kv: KeyValuePair[string, int]
kv.key = "score"
kv.value = 100
```

## Type Constraints and Concepts

Use concepts to constrain generic types:

```nim
type
  Addable = concept x, y
    x + y is typeof(x)

proc addAll[T: Addable](items: seq[T]): T =
  result = T(default)
  for item in items:
    result = result + item

echo addAll(@[1, 2, 3, 4])  # Works for numbers
echo addAll(@["a", "b", "c"])  # Works for strings

# Custom concept with requirements
type
  Comparable = concept x, y
    (x < y) is bool
    (x > y) is bool
    (x == y) is bool

proc max[T: Comparable](a, b: T): T =
  if a > b: a else: b

echo max(10, 20)     # 20
echo max("apple", "banana")  # "banana"
```

## Built-in Type Classes

Nim provides several built-in type classes:

```nim
# Using built-in type classes
proc processInts[T: SomeInteger](x: T) =
  echo "Processing integer: ", x

proc processFloats[T: SomeFloat](x: T) =
  echo "Processing float: ", x

processInts(42)        # Works
processInts(42'i8)     # Works
processFloats(3.14)    # Works
processFloats(2.5'f32) # Works
```

## Implicit Generics

Nim can automatically infer generics:

```nim
# This is automatically made generic by the compiler
proc add(x, y: untyped): untyped =
  x + y

echo add(1, 2)        # 3
echo add("hello", " world")  # "hello world"
```

## Generic Specialization

You can create specialized versions for specific types:

```nim
proc process[T](x: T) =
  echo "Generic version: ", x

proc process(x: string) =
  echo "String version: ", x.toUpper()

process(42)           # Generic version: 42
process("hello")      # String version: HELLO
```

## Advanced Examples

### Generic Algorithm

```nim
proc binarySearch[T: Ordinal](arr: openArray[T], target: T): int =
  var low = 0
  var high = arr.high
  
  while low <= high:
    let mid = (low + high) div 2
    if arr[mid] == target:
      return mid
    elif arr[mid] < target:
      low = mid + 1
    else:
      high = mid - 1
  
  return -1

let numbers = @[1, 3, 5, 7, 9, 11, 13]
echo binarySearch(numbers, 7)   # 3
echo binarySearch(numbers, 8)   # -1
```

### Generic Data Structures

```nim
type
  LinkedListNode[T] = ref object
    data: T
    next: LinkedListNode[T]
  
  LinkedList[T] = object
    head: LinkedListNode[T]

proc append[T](list: var LinkedList[T], data: T) =
  let newNode = LinkedListNode[T](data: data)
  if list.head == nil:
    list.head = newNode
  else:
    var current = list.head
    while current.next != nil:
      current = current.next
    current.next = newNode

proc print[T](list: LinkedList[T]) =
  var current = list.head
  while current != nil:
    echo current.data
    current = current.next

var list: LinkedList[int]
list.append(10)
list.append(20)
list.append(30)
list.print()  # 10, 20, 30
```

## Key Benefits

1. **Type Safety**: Compile-time type checking prevents runtime errors
2. **Performance**: No runtime overhead - generics are monomorphized
3. **Code Reuse**: Write once, use with many types
4. **Expressiveness**: Concepts allow precise type requirements
5. **Zero-cost abstractions**: Generics compile to optimized, type-specific code

## Tips

- Use descriptive names for type parameters (`T`, `K`, `V` are common conventions)
- Leverage concepts to create more expressive and safer generics
- Consider specializing for performance-critical types
- Use `SomeInteger`, `SomeFloat`, and other built-in type classes when appropriate
- Remember that generics are resolved at compile time, not runtime