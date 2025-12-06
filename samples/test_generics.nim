import unittest
import std/[sequtils, strformat]

# Test implementations from GENERICS.md

# Basic Generic Procedures
proc identity[T](x: T): T = x

proc swap[T](a, b: var T) =
  let temp = a
  a = b
  b = temp

# Generic Types
type
  Container[T] = object
    data: seq[T]
    count: int

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

# Multiple Type Parameters
type
  KeyValuePair[K, V] = object
    key: K
    value: V

proc pairToTuple[K, V](key: K, value: V): (K, V) =
  (key, value)

# Type Constraints and Concepts
type
  Addable = concept x, y
    x + y is typeof(x)

  Comparable = concept x, y
    (x < y) is bool
    (x > y) is bool
    (x == y) is bool

proc addAll[T: Addable](items: seq[T]): T =
  result = items[0]
  for item in items[1..^1]:
    result = result + item

proc max[T: Comparable](a, b: T): T =
  if a > b: a else: b

# Generic Algorithm
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

# Generic Data Structures
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

proc toSeq[T](list: LinkedList[T]): seq[T] =
  result = @[]
  var current = list.head
  while current != nil:
    result.add(current.data)
    current = current.next

# Test suite
suite "Generics Tests":
  
  test "Basic Generic Procedures - identity":
    check identity(42) == 42
    check identity("hello") == "hello"
    check identity(3.14) == 3.14
    check identity(true) == true

  test "Basic Generic Procedures - swap":
    var x = 10
    var y = 20
    swap(x, y)
    check x == 20
    check y == 10
    
    var a = "hello"
    var b = "world"
    swap(a, b)
    check a == "world"
    check b == "hello"

  test "Generic Types - Stack":
    var intStack: Stack[int]
    intStack.push(42)
    intStack.push(24)
    intStack.push(100)
    
    check intStack.pop() == 100
    check intStack.pop() == 24
    check intStack.pop() == 42

  test "Generic Types - Stack with strings":
    var stringStack: Stack[string]
    stringStack.push("hello")
    stringStack.push("world")
    stringStack.push("nim")
    
    check stringStack.pop() == "nim"
    check stringStack.pop() == "world"
    check stringStack.pop() == "hello"

  test "Multiple Type Parameters":
    let result1 = pairToTuple("age", 25)
    check result1[0] == "age"
    check result1[1] == 25
    
    let result2 = pairToTuple(1, "one")
    check result2[0] == 1
    check result2[1] == "one"
    
    var kv: KeyValuePair[string, int]
    kv.key = "score"
    kv.value = 100
    check kv.key == "score"
    check kv.value == 100

  test "Type Constraints - Addable":
    let intSum = addAll(@[1, 2, 3, 4])
    check intSum == 10
    
    let stringSum = addAll(@["a", "b", "c"])
    check stringSum == "abc"
    
    let floatSum = addAll(@[1.5, 2.5, 3.0])
    check floatSum == 7.0

  test "Type Constraints - Comparable":
    check max(10, 20) == 20
    check max(20, 10) == 20
    check max(-5, -3) == -3
    
    check max("apple", "banana") == "banana"
    check max("zebra", "aardvark") == "zebra"
    
    check max('a', 'b') == 'b'
    check max('z', 'a') == 'z'

  test "Generic Algorithm - binary search":
    let numbers = @[1, 3, 5, 7, 9, 11, 13]
    
    check binarySearch(numbers, 7) == 3
    check binarySearch(numbers, 1) == 0
    check binarySearch(numbers, 13) == 6
    check binarySearch(numbers, 8) == -1
    check binarySearch(numbers, 0) == -1
    check binarySearch(numbers, 14) == -1
    
    let chars = @['a', 'c', 'e', 'g', 'i']
    check binarySearch(chars, 'e') == 2
    check binarySearch(chars, 'a') == 0
    check binarySearch(chars, 'i') == 4
    check binarySearch(chars, 'b') == -1

  test "Generic Data Structures - LinkedList":
    var list: LinkedList[int]
    
    # Test empty list
    check list.toSeq().len == 0
    
    # Test adding elements
    list.append(10)
    list.append(20)
    list.append(30)
    
    let result = list.toSeq()
    check result == @[10, 20, 30]
    
    # Test with strings
    var stringList: LinkedList[string]
    stringList.append("hello")
    stringList.append("world")
    stringList.append("nim")
    
    let stringResult = stringList.toSeq()
    check stringResult == @["hello", "world", "nim"]

  test "Generic Data Structures - LinkedList with complex types":
    var tupleList: LinkedList[(string, int)]
    tupleList.append(("alice", 25))
    tupleList.append(("bob", 30))
    tupleList.append(("charlie", 35))
    
    let tupleResult = tupleList.toSeq()
    check tupleResult == @[("alice", 25), ("bob", 30), ("charlie", 35)]

  test "Container operations":
    var intContainer: Container[int]
    intContainer.data = @[1, 2, 3, 4, 5]
    intContainer.count = 5
    
    check intContainer.data.len == 5
    check intContainer.data[0] == 1
    check intContainer.data[4] == 5
    
    var stringContainer: Container[string]
    stringContainer.data = @["a", "b", "c"]
    stringContainer.count = 3
    
    check stringContainer.data.len == 3
    check stringContainer.data[0] == "a"
    check stringContainer.data[2] == "c"

  test "Edge cases - empty collections":
    check addAll(@[]) == 0
    check binarySearch(@[], 5) == -1
    
    var emptyList: LinkedList[int]
    check emptyList.toSeq() == @[]
    
    var emptyStack: Stack[int]
    # Should not crash when popping from empty
    # Note: In a real implementation, you might want to handle this case

  test "Edge cases - single element collections":
    check addAll(@[5]) == 5
    check binarySearch(@[5], 5) == 0
    check binarySearch(@[5], 3) == -1
    
    var singleList: LinkedList[int]
    singleList.append(42)
    check singleList.toSeq() == @[42]

# Run tests when executed directly
when isMainModule:
  echo "Running Nim generics tests..."
  echo "Use: nim c -r test_generics.nim to run all tests"