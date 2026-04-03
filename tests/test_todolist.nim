import std/[unittest, json, options, strutils]
import ../src/tools/[todolist, common]
import ../src/tools/context
import ../src/tools/registry
import ../src/core/database
import ../src/types/tools
import ../src/types/config
import test_utils

suite "Todolist Functional Tests":
  var db: DatabaseBackend

  setup:
    db = createTestDatabaseBackend()
    clearTestDatabase(db)
    setGlobalDatabase(db)
    setCurrentToolConversationId(1)

  teardown:
    if db != nil:
      db.close()

  test "Add todo item - basic":
    let args = %*{
      "operation": "add",
      "content": "Test todo item",
      "priority": "high"
    }
    
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response.hasKey("itemId")
    check response["todoList"].getStr().contains("Test todo item")
    check response["todoList"].getStr().contains("(!)")

  test "Add multiple items with priorities":
    discard executeTodolist(%*{"operation": "add", "content": "First item", "priority": "high"})
    discard executeTodolist(%*{"operation": "add", "content": "Second item", "priority": "medium"})
    discard executeTodolist(%*{"operation": "add", "content": "Third item", "priority": "low"})
    
    let response = parseJson(executeTodolist(%*{"operation": "list"}))
    let todoList = response["todoList"].getStr()
    
    check todoList.contains("First item")
    check todoList.contains("Second item")
    check todoList.contains("Third item")
    check todoList.contains("(!)")
    check todoList.contains("(low)")

  test "Update item state":
    discard executeTodolist(%*{"operation": "add", "content": "Test item"})
    
    let result = executeTodolist(%*{
      "operation": "update",
      "itemNumber": 1,
      "state": "in_progress"
    })
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["todoList"].getStr().contains("[~]")

  test "Update item content":
    discard executeTodolist(%*{"operation": "add", "content": "Original content"})
    
    let result = executeTodolist(%*{
      "operation": "update",
      "itemNumber": 1,
      "content": "Updated content"
    })
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["todoList"].getStr().contains("Updated content")
    check not response["todoList"].getStr().contains("Original content")

  test "Update item priority":
    discard executeTodolist(%*{"operation": "add", "content": "Test item", "priority": "medium"})
    
    let result = executeTodolist(%*{
      "operation": "update",
      "itemNumber": 1,
      "priority": "high"
    })
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["todoList"].getStr().contains("(!)")

  test "List empty todo list":
    let response = parseJson(executeTodolist(%*{"operation": "list"}))
    
    check response["success"].getBool() == true
    check response["itemCount"].getInt() == 0
    check response["todoList"].getStr() == ""
    check response["message"].getStr() == "No active todo list found"

  test "List with items":
    discard executeTodolist(%*{"operation": "add", "content": "Item 1"})
    discard executeTodolist(%*{"operation": "add", "content": "Item 2"})
    
    let response = parseJson(executeTodolist(%*{"operation": "list"}))
    
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
    
    let response = parseJson(executeTodolist(%*{
      "operation": "bulk_update",
      "todos": markdownTodos
    }))
    
    check response["success"].getBool() == true
    check response["message"].getStr().contains("4 items")
    
    let todoList = response["todoList"].getStr()
    check todoList.contains("First task")
    check todoList.contains("Completed task")
    check todoList.contains("[x]")
    check todoList.contains("[~]")
    check todoList.contains("(!)")
    check todoList.contains("(low)")

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

  test "Markdown parsing handles malformed content":
    let todos = parseTodoUpdates("""
Not a todo item
- This is not a checkbox
- [ Invalid checkbox format
- [y] Invalid state marker
- [ ] Valid task only
""")
    check todos.len == 1
    check todos[0].content == "Valid task only"

  test "Markdown parsing handles edge cases":
    check parseTodoUpdates("").len == 0
    check parseTodoUpdates("   \n  \n  ").len == 0
    check parseTodoUpdates("- [ ] Task 1\n\n- [x] Task 2\n  \n").len == 2

  test "Format todo list display":
    discard executeTodolist(%*{"operation": "add", "content": "High priority", "priority": "high"})
    discard executeTodolist(%*{"operation": "add", "content": "Normal task"})
    discard executeTodolist(%*{"operation": "add", "content": "Low priority", "priority": "low"})
    
    let conversationId = 1
    let maybeList = getActiveTodoList(db, conversationId)
    check maybeList.isSome()
    
    let formatted = formatTodoList(db, maybeList.get().id)
    check formatted.contains("[ ] High priority (!)")
    check formatted.contains("[ ] Normal task")
    check formatted.contains("[ ] Low priority (low)")

  test "Error handling - invalid operation":
    let response = parseJson(executeTodolist(%*{"operation": "invalid_op"}))
    check response.hasKey("error")
    check response["error"].getStr().contains("Unknown operation")

  test "Error handling - update non-existent item":
    let response = parseJson(executeTodolist(%*{
      "operation": "update",
      "itemNumber": 99999,
      "state": "completed"
    }))
    check response.hasKey("error")

suite "Todolist Validation Tests":
  test "Valid operations":
    validateTodolistArgs(%*{"operation": "add", "content": "Test", "priority": "high"})
    validateTodolistArgs(%*{"operation": "update", "itemId": 1, "state": "completed"})
    validateTodolistArgs(%*{"operation": "list"})
    validateTodolistArgs(%*{"operation": "bulk_update", "todos": "- [ ] Task"})

  test "Invalid operation":
    expect(ToolValidationError):
      validateTodolistArgs(%*{"operation": "invalid"})

  test "Missing operation":
    expect(ToolValidationError):
      validateTodolistArgs(%*{"content": "Test"})

  test "Add with missing content":
    expect(ToolValidationError):
      validateTodolistArgs(%*{"operation": "add"})

  test "Add with empty content":
    expect(ToolValidationError):
      validateTodolistArgs(%*{"operation": "add", "content": ""})

  test "Update with missing itemId":
    expect(ToolValidationError):
      validateTodolistArgs(%*{"operation": "update", "content": "New"})

  test "Update with no changes":
    expect(ToolValidationError):
      validateTodolistArgs(%*{"operation": "update", "itemId": 1})

  test "Invalid priority":
    expect(ToolValidationError):
      validateTodolistArgs(%*{"operation": "add", "content": "Test", "priority": "urgent"})

  test "Invalid state":
    expect(ToolValidationError):
      validateTodolistArgs(%*{"operation": "update", "itemId": 1, "state": "unknown"})

suite "Todolist Database Tests":
  var db: DatabaseBackend

  setup:
    db = createTestDatabaseBackend()
    clearTestDatabase(db)
    setGlobalDatabase(db)
    setCurrentToolConversationId(1)

  teardown:
    if db != nil:
      db.close()

  test "Persistence across operations":
    let addResult = parseJson(executeTodolist(%*{"operation": "add", "content": "Persistent item"}))
    
    let listResult = parseJson(executeTodolist(%*{"operation": "list"}))
    check listResult["success"].getBool() == true
    check listResult["itemCount"].getInt() == 1
    check listResult["todoList"].getStr().contains("Persistent item")

  test "Todo list creation and retrieval":
    let conversationId = 1
    check getActiveTodoList(db, conversationId).isNone()
    
    discard executeTodolist(%*{"operation": "add", "content": "First item"})
    
    let maybeList = getActiveTodoList(db, conversationId)
    check maybeList.isSome()
    check maybeList.get().title == "Current Tasks"

  test "State transitions":
    discard executeTodolist(%*{"operation": "add", "content": "Pending test"})
    discard executeTodolist(%*{"operation": "add", "content": "Progress test"})
    discard executeTodolist(%*{"operation": "add", "content": "Complete test"})
    discard executeTodolist(%*{"operation": "add", "content": "Cancel test"})

    let states = ["pending", "in_progress", "completed", "cancelled"]
    let markers = ["[ ]", "[~]", "[x]", "[-]"]

    for i, state in states:
      let result = parseJson(executeTodolist(%*{
        "operation": "update",
        "itemNumber": i + 1,
        "state": state
      }))
      check result["success"].getBool() == true
      check result["todoList"].getStr().contains(markers[i])

  test "Priority persistence":
    discard executeTodolist(%*{"operation": "add", "content": "High item", "priority": "high"})
    discard executeTodolist(%*{"operation": "add", "content": "Medium item", "priority": "medium"})
    discard executeTodolist(%*{"operation": "add", "content": "Low item", "priority": "low"})
    
    let todoList = parseJson(executeTodolist(%*{"operation": "list"}))["todoList"].getStr()
    
    check todoList.contains("High item (!)")
    check todoList.contains("Low item (low)")

  test "Bulk update replaces existing items":
    discard executeTodolist(%*{"operation": "add", "content": "Original 1"})
    discard executeTodolist(%*{"operation": "add", "content": "Original 2"})
    
    discard executeTodolist(%*{
      "operation": "bulk_update",
      "todos": "- [ ] New task 1\n- [x] New task 2"
    })
    
    let todoList = parseJson(executeTodolist(%*{"operation": "list"}))["todoList"].getStr()
    
    check not todoList.contains("Original 1")
    check todoList.contains("New task 1")

  test "Concurrent modifications":
    discard executeTodolist(%*{"operation": "add", "content": "Concurrent test"})
    
    let result1 = parseJson(executeTodolist(%*{"operation": "update", "itemNumber": 1, "state": "in_progress"}))
    let result2 = parseJson(executeTodolist(%*{"operation": "update", "itemNumber": 1, "priority": "high"}))
    
    check result1["success"].getBool() == true
    check result2["success"].getBool() == true
    
    let todoList = parseJson(executeTodolist(%*{"operation": "list"}))["todoList"].getStr()
    check todoList.contains("[~]")
    check todoList.contains("(!)")

  test "Large todo list performance":
    for i in 1..100:
      let priority = if i mod 3 == 0: "high" elif i mod 2 == 0: "low" else: "medium"
      discard executeTodolist(%*{"operation": "add", "content": "Task " & $i, "priority": priority})
    
    let result = parseJson(executeTodolist(%*{"operation": "list"}))
    check result["success"].getBool() == true
    check result["itemCount"].getInt() == 100

suite "Todolist Workflow Tests":
  var db: DatabaseBackend

  setup:
    db = createTestDatabaseBackend()
    clearTestDatabase(db)
    setGlobalDatabase(db)
    setCurrentToolConversationId(1)

  teardown:
    if db != nil:
      db.close()

  test "Complete task management workflow":
    check parseJson(executeTodolist(%*{"operation": "list"}))["itemCount"].getInt() == 0
    
    discard executeTodolist(%*{"operation": "add", "content": "Design system", "priority": "high"})
    discard executeTodolist(%*{"operation": "add", "content": "Implement core"})
    discard executeTodolist(%*{"operation": "add", "content": "Write tests", "priority": "medium"})
    
    check parseJson(executeTodolist(%*{"operation": "list"}))["itemCount"].getInt() == 3
    
    discard executeTodolist(%*{"operation": "update", "itemNumber": 1, "state": "in_progress"})
    discard executeTodolist(%*{"operation": "update", "itemNumber": 1, "state": "completed"})
    
    let todoList = parseJson(executeTodolist(%*{"operation": "list"}))["todoList"].getStr()
    check todoList.contains("[x]")
    check todoList.contains("[ ]")

  test "Project planning with bulk updates":
    let projectPlan = """
- [ ] Research requirements (!)
- [ ] Design architecture (!)
- [ ] Set up environment
- [ ] Implement core
- [ ] Write tests
"""
    
    let bulkResult = parseJson(executeTodolist(%*{
      "operation": "bulk_update",
      "todos": projectPlan
    }))
    
    check bulkResult["success"].getBool() == true
    check bulkResult["message"].getStr().contains("5 items")

  test "Tool integration with registry":
    let maybeTool = getTool("todolist")
    check maybeTool.isSome()
    
    let tool = maybeTool.get()
    check tool.name == "todolist"
    check tool.requiresConfirmation == false

  test "Error recovery":
    discard executeTodolist(%*{"operation": "add", "content": "Task 1"})
    discard executeTodolist(%*{"operation": "add", "content": "Task 2"})
    
    check parseJson(executeTodolist(%*{"operation": "update", "itemId": 99999, "state": "completed"})).hasKey("error")
    check parseJson(executeTodolist(%*{"operation": "invalid"})).hasKey("error")
    
    let result = parseJson(executeTodolist(%*{"operation": "list"}))
    check result["success"].getBool() == true
    check result["itemCount"].getInt() == 2

  test "Long running session simulation":
    discard executeTodolist(%*{"operation": "add", "content": "Plan project"})
    discard executeTodolist(%*{"operation": "add", "content": "Set up repo"})
    
    for i in 1..5:
      let priority = if i <= 2: "high" else: "medium"
      discard executeTodolist(%*{"operation": "add", "content": "Module " & $i, "priority": priority})
    
    let progressUpdate = """
- [x] Plan project
- [x] Set up repo
- [~] Module 1 (!)
- [ ] Module 2 (!)
- [ ] Module 3
- [ ] Module 4
- [ ] Module 5
"""
    
    discard executeTodolist(%*{"operation": "bulk_update", "todos": progressUpdate})
    
    let result = parseJson(executeTodolist(%*{"operation": "list"}))
    check result["success"].getBool() == true
    
    let todoList = result["todoList"].getStr()
    check todoList.contains("[x]")
    check todoList.contains("[~]")
    check todoList.contains("[ ]")

echo "All todolist tests completed"
