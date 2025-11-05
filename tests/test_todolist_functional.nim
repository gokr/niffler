import std/[unittest, json, options, strutils, tempfiles, os]
import ../src/tools/todolist
import ../src/core/database
import ../src/types/tools
import ../src/types/config

suite "Todolist Tool Functional Tests":
  var db: DatabaseBackend
  var tempDbFile: string
  
  setup:
    tempDbFile = genTempPath("test_todolist", ".db")
    let dbConfig = DatabaseConfig(
      `type`: dtSQLite,
      enabled: true,
      path: some(tempDbFile),
      walMode: false,
      busyTimeout: 1000,
      poolSize: 1
    )
    db = createDatabaseBackend(dbConfig)
    setGlobalDatabase(db)
  
  teardown:
    if db != nil:
      db.close()
    try:
      removeFile(tempDbFile)
    except:
      discard

  test "Add todo item - basic functionality":
    let args = %*{
      "operation": "add",
      "content": "Test todo item",
      "priority": "high"
    }
    
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response.hasKey("success")
    check response["success"].getBool() == true
    check response.hasKey("itemId")
    check response.hasKey("message")
    check response.hasKey("todoList")
    check response["todoList"].getStr().contains("Test todo item")
    check response["todoList"].getStr().contains("(!)")

  test "Add multiple todo items":
    let item1 = %*{"operation": "add", "content": "First item", "priority": "high"}
    let item2 = %*{"operation": "add", "content": "Second item", "priority": "medium"}
    let item3 = %*{"operation": "add", "content": "Third item", "priority": "low"}
    
    let result1 = executeTodolist(item1)
    let result2 = executeTodolist(item2)
    let result3 = executeTodolist(item3)
    
    let response3 = parseJson(result3)
    let todoList = response3["todoList"].getStr()
    
    check todoList.contains("First item")
    check todoList.contains("Second item") 
    check todoList.contains("Third item")
    check todoList.contains("(!)") # high priority indicator
    check todoList.contains("(low)") # low priority indicator

  test "Update todo item state":
    # First add an item
    let addArgs = %*{"operation": "add", "content": "Test item"}
    discard executeTodolist(addArgs)  # We add one item, so it will be itemNumber 1

    # Update its state to in_progress
    let updateArgs = %*{
      "operation": "update",
      "itemNumber": 1,
      "state": "in_progress"
    }
    
    let result = executeTodolist(updateArgs)
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["todoList"].getStr().contains("[~]") # in_progress marker

  test "Update todo item content":
    # Add an item
    let addArgs = %*{"operation": "add", "content": "Original content"}
    discard executeTodolist(addArgs)  # We add one item, so it will be itemNumber 1

    # Update content
    let updateArgs = %*{
      "operation": "update",
      "itemNumber": 1,
      "content": "Updated content"
    }
    
    let result = executeTodolist(updateArgs)
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["todoList"].getStr().contains("Updated content")
    check not response["todoList"].getStr().contains("Original content")

  test "Update todo item priority":
    # Add an item
    let addArgs = %*{"operation": "add", "content": "Test item", "priority": "medium"}
    discard executeTodolist(addArgs)  # We add one item, so it will be itemNumber 1

    # Update priority to high
    let updateArgs = %*{
      "operation": "update",
      "itemNumber": 1,
      "priority": "high"
    }
    
    let result = executeTodolist(updateArgs)
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["todoList"].getStr().contains("(!)")

  test "List empty todo list":
    let args = %*{"operation": "list"}
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["itemCount"].getInt() == 0
    check response["todoList"].getStr() == ""
    check response["message"].getStr() == "No active todo list found"

  test "List todo list with items":
    # Add some items
    discard executeTodolist(%*{"operation": "add", "content": "Item 1"})
    discard executeTodolist(%*{"operation": "add", "content": "Item 2"})
    
    let args = %*{"operation": "list"}
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["itemCount"].getInt() == 2
    check response["todoList"].getStr().contains("Item 1")
    check response["todoList"].getStr().contains("Item 2")

  test "Bulk update with markdown":
    let markdownTodos = """
- [ ] First task (!)
- [x] Completed task
- [~] In progress task
- [ ] Low priority task (low)
"""
    
    let args = %*{
      "operation": "bulk_update",
      "todos": markdownTodos
    }
    
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["message"].getStr().contains("4 items")
    
    let todoList = response["todoList"].getStr()
    check todoList.contains("First task")
    check todoList.contains("Completed task")
    check todoList.contains("In progress task")
    check todoList.contains("Low priority task")
    check todoList.contains("[x]") # completed
    check todoList.contains("[~]") # in progress
    check todoList.contains("(!)") # high priority
    check todoList.contains("(low)") # low priority

  test "Markdown parsing with various formats":
    let todos = parseTodoUpdates("""
- [ ] Basic task
- [x] Completed task (!)
- [~] Progress task (low)
- [-] Cancelled task
""")
    
    check todos.len == 4
    check todos[0] == ("Basic task", tsPending, tpMedium)
    check todos[1] == ("Completed task", tsCompleted, tpHigh)
    check todos[2] == ("Progress task", tsInProgress, tpLow)
    check todos[3] == ("Cancelled task", tsCancelled, tpMedium)

  test "Format todo list display":
    # Add items with different states and priorities
    discard executeTodolist(%*{"operation": "add", "content": "High priority", "priority": "high"})
    discard executeTodolist(%*{"operation": "add", "content": "Normal task"})
    discard executeTodolist(%*{"operation": "add", "content": "Low priority", "priority": "low"})
    
    # Get the active list
    let conversationId = 1
    let maybeList = getActiveTodoList(db, conversationId)
    check maybeList.isSome()
    
    let listId = maybeList.get().id
    let formatted = formatTodoList(db, listId)
    
    check formatted.contains("[ ] High priority (!)")
    check formatted.contains("[ ] Normal task")
    check formatted.contains("[ ] Low priority (low)")

  test "Error handling - invalid operation":
    let args = %*{"operation": "invalid_op"}
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response.hasKey("error")
    check response["error"].getStr().contains("Unknown operation")

  test "Error handling - update non-existent item":
    let args = %*{
      "operation": "update",
      "itemNumber": 99999,
      "state": "completed"
    }
    
    let result = executeTodolist(args)
    let response = parseJson(result)

    check response.hasKey("error")
    check response["error"].getStr().contains("No active todo list found")

echo "Running todolist functional tests..."