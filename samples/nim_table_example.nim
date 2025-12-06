import std/[tables, sequtils]

# Basic table operations example
proc demonstrateTables() =
  echo "=== Nim Tables Demo ==="
  
  # 1. Creating and initializing a table
  echo "\n1. Creating tables:"
  
  # Method 1: Using toTable literal
  let scores = {"Alice": 95, "Bob": 87, "Charlie": 92}.toTable()
  echo "Scores table: ", scores
  
  # Method 2: Empty table and adding items
  var ages = initTable[string, int]()
  ages["Alice"] = 25
  ages["Bob"] = 30
  ages["Charlie"] = 28
  echo "Ages table: ", ages
  
  # 2. Accessing values
  echo "\n2. Accessing values:"
  echo "Alice's score: ", scores["Alice"]
  echo "Bob's age: ", ages["Bob"]
  
  # Safe access with getOrDefault
  let unknownScore = scores.getOrDefault("David", 0)  # Default value if key doesn't exist
  echo "David's score (default): ", unknownScore
  
  # 3. Checking for key existence
  echo "\n3. Key existence:"
  if "Alice" in scores:
    echo "Alice exists in scores table"
  if "David" notin scores:
    echo "David does not exist in scores table"
  
  # 4. Modifying values
  echo "\n4. Modifying values:"
  ages["Alice"] = 26  # Update existing value
  echo "Updated Alice's age: ", ages["Alice"]
  
  # 5. Adding new key-value pairs
  echo "\n5. Adding new pairs:"
  scores["David"] = 88
  ages["David"] = 35
  echo "Scores after adding David: ", scores
  echo "Ages after adding David: ", ages
  
  # 6. Iterating over tables
  echo "\n6. Iterating over tables:"
  
  echo "All scores:"
  for name, score in scores.pairs:
    echo "  ", name, ": ", score
  
  echo "All ages:"
  for name, age in ages.pairs:
    echo "  ", name, ": ", age
  
  # 7. Getting keys and values separately
  echo "\n7. Keys and values:"
  echo "Score names: ", toSeq(scores.keys)
  echo "Score values: ", toSeq(scores.values)
  
  # 8. Removing items
  echo "\n8. Removing items:"
  ages.del("Charlie")
  echo "Ages after removing Charlie: ", ages
  
  # 9. Table properties
  echo "\n9. Table properties:"
  echo "Number of scores: ", scores.len
  echo "Is ages table empty? ", ages.len == 0
  
  # 10. Copying tables
  echo "\n10. Copying tables:"
  let scoresCopy = scores
  scoresCopy["Alice"] = 100  # This creates a new table, doesn't affect original
  echo "Original scores: ", scores
  echo "Modified copy: ", scoresCopy

# Additional examples with different data types
proc advancedTableExamples() =
  echo "\n\n=== Advanced Table Examples ==="
  
  # Table with different value types
  var personInfo = initTable[string, string]()
  personInfo["name"] = "John Doe"
  personInfo["email"] = "john@example.com"
  personInfo["city"] = "New York"
  
  echo "Person info: ", personInfo
  
  # Table with boolean values
  var permissions = initTable[string, bool]()
  permissions["read"] = true
  permissions["write"] = false
  permissions["execute"] = true
  
  echo "Permissions: ", permissions
  
  # Counting occurrences using a table
  let text = "hello world hello nim hello programming"
  var wordCount = initTable[string, int]()
  
  for word in text.split():
    if word in wordCount:
      wordCount[word] += 1
    else:
      wordCount[word] = 1
  
  echo "Word count: ", wordCount

# Main execution
when isMainModule:
  demonstrateTables()
  advancedTableExamples()
  
  echo "\n=== Performance Notes ==="
  echo "- Tables provide O(1) average time complexity for insert, delete, and lookup"
  echo "- Tables are implemented as hash tables internally"
  echo "- Keys must be hashable types (strings, ints, etc.)"
  echo "- Use CountTable for counting occurrences efficiently"
  echo "- Use OrderedTable when you need to maintain insertion order"