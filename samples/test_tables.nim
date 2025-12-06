# Test file for Nim tables functionality
import std/[unittest, tables, hashes]

# Custom type for testing custom keys
type
  Person = object
    name: string
    age: int

proc hash(p: Person): Hash =
  result = p.name.hash
  result = result !& p.age.hash
  result = !$result

suite "Tables Tests":

  test "Basic Table operations":
    var t = initTable[string, int]()
    
    # Test insertion
    t["a"] = 1
    t["b"] = 2
    t["c"] = 3
    
    check len(t) == 3
    check t["a"] == 1
    check t["b"] == 2
    check t["c"] == 3
    
    # Test key existence
    check "a" in t
    check "d" notin t
    check t.hasKey("b")
    check not t.hasKey("x")
    
    # Test getOrDefault
    check t.getOrDefault("a") == 1
    check t.getOrDefault("x") == 0
    check t.getOrDefault("x", 99) == 99
    
    # Test deletion
    t.del("b")
    check len(t) == 2
    check "b" notin t

  test "Table from literal":
    let t = {"x": 10, "y": 20, "z": 30}.toTable
    check len(t) == 3
    check t["x"] == 10
    check t["y"] == 20
    check t["z"] == 30

  test "OrderedTable preserves insertion order":
    var ot = initOrderedTable[string, int]()
    ot["first"] = 1
    ot["second"] = 2
    ot["third"] = 3
    
    var keys: seq[string]
    for k in ot.keys:
      keys.add(k)
    
    check keys == @["first", "second", "third"]

  test "CountTable operations":
    var ct = initCountTable[char]()
    
    # Test increment
    ct.inc('a')
    ct.inc('a')
    ct.inc('b')
    
    check ct['a'] == 2
    check ct['b'] == 1
    check ct['c'] == 0
    
    # Test toCountTable from string
    let ct2 = toCountTable("hello")
    check ct2['h'] == 1
    check ct2['e'] == 1
    check ct2['l'] == 2
    check ct2['o'] == 1

  test "Table value semantics":
    let original = {"a": 1, "b": 2}.toTable
    var copy = original
    
    copy["c"] = 3
    
    check len(original) == 2
    check len(copy) == 3
    check original != copy

  test "TableRef reference semantics":
    let original = {"a": 1, "b": 2}.newTable
    var copy = original
    
    copy["c"] = 3
    
    check len(original) == 3
    check len(copy) == 3
    check original == copy

  test "mgetOrPut functionality":
    var t = initTable[string, int]()
    
    # First call should insert default
    let val1 = t.mgetOrPut("key", 42)
    check val1 == 42
    check t["key"] == 42
    
    # Second call should return existing value
    let val2 = t.mgetOrPut("key", 99)
    check val2 == 42
    check t["key"] == 42

  test "hasKeyOrPut functionality":
    var t = initTable[string, int]()
    
    # Key doesn't exist, should insert and return false
    let result1 = t.hasKeyOrPut("newkey", 123)
    check result1 == false
    check t["newkey"] == 123
    
    # Key exists, should return true
    let result2 = t.hasKeyOrPut("newkey", 456)
    check result2 == true
    check t["newkey"] == 123  # Value unchanged

  test "Custom objects as keys":
    var t = initTable[Person, string]()
    
    let p1 = Person(name: "Alice", age: 30)
    let p2 = Person(name: "Bob", age: 25)
    
    t[p1] = "Engineer"
    t[p2] = "Designer"
    
    check t[p1] == "Engineer"
    check t[p2] == "Designer"
    check len(t) == 2

  test "Table iteration":
    let t = {"a": 1, "b": 2, "c": 3}.toTable
    
    var keyCount = 0
    var valueSum = 0
    
    for k in t.keys:
      keyCount += 1
    check keyCount == 3
    
    for v in t.values:
      valueSum += v
    check valueSum == 6
    
    var pairCount = 0
    for k, v in t.pairs:
      pairCount += 1
      check v == t[k]
    check pairCount == 3

  test "Table equality":
    let t1 = {"a": 1, "b": 2}.toTable
    let t2 = {"b": 2, "a": 1}.toTable  # Different order
    let t3 = {"a": 1, "b": 3}.toTable   # Different value
    
    check t1 == t2  # Order doesn't matter for regular tables
    check t1 != t3

  test "OrderedTable equality":
    let ot1 = {"a": 1, "b": 2}.toOrderedTable
    let ot2 = {"b": 2, "a": 1}.toOrderedTable  # Different order
    
    check ot1 != ot2  # Order matters for ordered tables

  test "Table clearing":
    var t = {"a": 1, "b": 2, "c": 3}.toTable
    check len(t) == 3
    
    t.clear()
    check len(t) == 0
    check "a" notin t

  test "CountTable largest and smallest":
    let ct = toCountTable("banana")
    
    let largest = ct.largest()
    check largest.key == 'a'
    check largest.val == 3
    
    let smallest = ct.smallest()
    check smallest.key == 'b'
    check smallest.val == 1

  test "pop operation":
    var t = {"a": 1, "b": 2, "c": 3}.toTable
    
    var value: int
    let success = t.pop("b", value)
    
    check success == true
    check value == 2
    check "b" notin t
    check len(t) == 2
    
    # Try to pop non-existent key
    let success2 = t.pop("x", value)
    check success2 == false

  test "withValue template":
    var t = initTable[string, int]()
    t["existing"] = 42
    
    var called = false
    
    # Test with existing key
    t.withValue("existing", value):
      check value == 42
      called = true
    
    check called
    
    called = false
    
    # Test with non-existing key
    t.withValue("nonexisting", value):
      called = true
    do:
      check true  # else branch should execute
    
    check not called