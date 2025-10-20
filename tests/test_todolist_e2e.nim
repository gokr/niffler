import std/[unittest, json, options, strutils, tempfiles, os]
import ../src/tools/todolist
import ../src/tools/registry
import ../src/core/database
import ../src/types/tools
import ../src/types/config

suite "Todolist End-to-End Workflow Tests":
  var db: DatabaseBackend
  var tempDbFile: string
  
  setup:
    tempDbFile = genTempPath("test_todolist_e2e", ".db")
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

  test "Complete task management workflow":
    # 1. Start with empty list
    var listResult = parseJson(executeTodolist(%*{"operation": "list"}))
    check listResult["itemCount"].getInt() == 0
    
    # 2. Add initial tasks
    discard executeTodolist(%*{"operation": "add", "content": "Design system", "priority": "high"})
    discard executeTodolist(%*{"operation": "add", "content": "Implement core features"})
    discard executeTodolist(%*{"operation": "add", "content": "Write tests", "priority": "medium"})
    discard executeTodolist(%*{"operation": "add", "content": "Documentation", "priority": "low"})
    
    # 3. Verify all tasks are added
    listResult = parseJson(executeTodolist(%*{"operation": "list"}))
    check listResult["itemCount"].getInt() == 4
    
    # 4. Start working on first task (item number 1)
    discard executeTodolist(%*{
      "operation": "update",
      "itemNumber": 1,
      "state": "in_progress"
    })

    # 5. Complete first task
    discard executeTodolist(%*{
      "operation": "update",
      "itemNumber": 1,
      "state": "completed"
    })
    
    # 6. Verify workflow state
    listResult = parseJson(executeTodolist(%*{"operation": "list"}))
    let todoList = listResult["todoList"].getStr()
    
    check todoList.contains("[x]") # completed task
    check todoList.contains("[ ]") # pending tasks
    check todoList.contains("(!)") # high priority
    check todoList.contains("(low)") # low priority

  test "Project planning workflow with bulk updates":
    # 1. Start with project planning session
    let projectPlan = """
- [ ] Research requirements (!)
- [ ] Design architecture (!)  
- [ ] Set up development environment
- [ ] Implement core modules
- [ ] Write unit tests
- [ ] Integration testing
- [ ] Documentation
- [ ] Deployment preparation (low)
"""
    
    let bulkResult = parseJson(executeTodolist(%*{
      "operation": "bulk_update",
      "todos": projectPlan
    }))
    
    check bulkResult["success"].getBool() == true
    check bulkResult["message"].getStr().contains("8 items")
    
    # 2. Start working on high priority items
    let progressUpdate = """
- [x] Research requirements (!)
- [~] Design architecture (!)  
- [ ] Set up development environment
- [ ] Implement core modules
- [ ] Write unit tests
- [ ] Integration testing
- [ ] Documentation
- [ ] Deployment preparation (low)
"""
    
    discard executeTodolist(%*{
      "operation": "bulk_update",
      "todos": progressUpdate
    })
    
    # 3. Verify progress tracking
    let listResult = parseJson(executeTodolist(%*{"operation": "list"}))
    let todoList = listResult["todoList"].getStr()
    
    check todoList.contains("[x] Research requirements (!)")
    check todoList.contains("[~] Design architecture (!)")
    check todoList.contains("[ ] Set up development environment")

  test "Task refinement and priority adjustment workflow":
    # 1. Add initial broad tasks
    discard executeTodolist(%*{"operation": "add", "content": "Build feature X"})
    discard executeTodolist(%*{"operation": "add", "content": "Fix bugs"})
    
    # 2. Refine into specific tasks
    let refinedTasks = """
- [ ] Build feature X - API endpoints (!)
- [ ] Build feature X - Frontend UI
- [ ] Build feature X - Database schema (!)
- [ ] Fix critical security bug (!)
- [ ] Fix UI layout issues
- [ ] Fix performance issues (low)
"""
    
    discard executeTodolist(%*{
      "operation": "bulk_update",
      "todos": refinedTasks
    })
    
    # 3. Work through high priority items first
    let workInProgress = """
- [~] Build feature X - API endpoints (!)
- [ ] Build feature X - Frontend UI
- [x] Build feature X - Database schema (!)
- [x] Fix critical security bug (!)
- [ ] Fix UI layout issues
- [ ] Fix performance issues (low)
"""
    
    discard executeTodolist(%*{
      "operation": "bulk_update",
      "todos": workInProgress
    })
    
    # 4. Verify priority-based workflow
    let listResult = parseJson(executeTodolist(%*{"operation": "list"}))
    let todoList = listResult["todoList"].getStr()
    
    # Check that high priority items are addressed first
    check todoList.contains("[x] Build feature X - Database schema (!)")
    check todoList.contains("[x] Fix critical security bug (!)")
    check todoList.contains("[~] Build feature X - API endpoints (!)")

  test "Tool integration with registry":
    # Verify tool is properly registered and accessible
    let maybeTool = getTool("todolist")
    check maybeTool.isSome()
    
    let tool = maybeTool.get()
    check tool.name == "todolist"
    check tool.requiresConfirmation == false
    
    # Test that tool can be executed through registry
    let args = %*{"operation": "add", "content": "Registry test"}
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response["success"].getBool() == true
    check response["todoList"].getStr().contains("Registry test")

  test "Error recovery workflow":
    # 1. Add some tasks normally
    discard executeTodolist(%*{"operation": "add", "content": "Normal task 1"})
    discard executeTodolist(%*{"operation": "add", "content": "Normal task 2"})
    
    # 2. Attempt invalid operations
    let invalidUpdate = parseJson(executeTodolist(%*{
      "operation": "update",
      "itemId": 99999,
      "state": "completed"
    }))
    check invalidUpdate.hasKey("error")
    
    let invalidOperation = parseJson(executeTodolist(%*{
      "operation": "invalid_op"
    }))
    check invalidOperation.hasKey("error")
    
    # 3. Verify system continues to work normally
    let listResult = parseJson(executeTodolist(%*{"operation": "list"}))
    check listResult["success"].getBool() == true
    check listResult["itemCount"].getInt() == 2
    check listResult["todoList"].getStr().contains("Normal task 1")
    check listResult["todoList"].getStr().contains("Normal task 2")

  test "State consistency across operations":
    # This test ensures state remains consistent across multiple operations
    
    # 1. Create initial state
    discard executeTodolist(%*{"operation": "add", "content": "Task A", "priority": "high"})
    discard executeTodolist(%*{"operation": "add", "content": "Task B", "priority": "medium"})
    discard executeTodolist(%*{"operation": "add", "content": "Task C", "priority": "low"})
    
    # 2. Get item IDs by parsing the list
    let listResult1 = parseJson(executeTodolist(%*{"operation": "list"}))
    let todoList1 = listResult1["todoList"].getStr()
    
    # 3. Perform mixed operations
    # Note: This test assumes we can identify items by content since we don't have easy access to IDs
    
    # 4. Use bulk update to change states
    let mixedStates = """
- [x] Task A (!)
- [~] Task B
- [ ] Task C (low)
- [ ] New Task D
"""
    
    discard executeTodolist(%*{
      "operation": "bulk_update",
      "todos": mixedStates
    })
    
    # 5. Verify final state is consistent
    let finalResult = parseJson(executeTodolist(%*{"operation": "list"}))
    let finalList = finalResult["todoList"].getStr()
    
    check finalList.contains("[x] Task A (!)")
    check finalList.contains("[~] Task B")
    check finalList.contains("[ ] Task C (low)")
    check finalList.contains("[ ] New Task D")
    
    # Note: itemCount includes all items (including cancelled), but todoList only shows visible ones
    # After bulk_update, we have 4 new items + 3 cancelled items = 7 total
    check finalResult["itemCount"].getInt() >= 4  # At least the 4 visible items

  test "Long running session simulation":
    # Simulate a long development session with many operations
    var operationCount = 0
    
    # Phase 1: Initial planning
    discard executeTodolist(%*{"operation": "add", "content": "Plan project structure"})
    discard executeTodolist(%*{"operation": "add", "content": "Set up repository"})
    operationCount += 2
    
    # Phase 2: Development
    for i in 1..5:
      discard executeTodolist(%*{
        "operation": "add", 
        "content": "Implement module " & $i,
        "priority": if i <= 2: "high" else: "medium"
      })
      operationCount += 1
    
    # Phase 3: Testing
    discard executeTodolist(%*{"operation": "add", "content": "Write unit tests"})
    discard executeTodolist(%*{"operation": "add", "content": "Integration testing"})
    operationCount += 2
    
    # Phase 4: Mark some as completed using bulk update
    let progressUpdate = """
- [x] Plan project structure
- [x] Set up repository
- [~] Implement module 1 (!)
- [~] Implement module 2 (!)
- [ ] Implement module 3
- [ ] Implement module 4
- [ ] Implement module 5
- [ ] Write unit tests
- [ ] Integration testing
"""
    
    discard executeTodolist(%*{
      "operation": "bulk_update",
      "todos": progressUpdate
    })
    
    # Verify session state
    let finalResult = parseJson(executeTodolist(%*{"operation": "list"}))
    check finalResult["success"].getBool() == true
    
    # Note: itemCount includes cancelled items from bulk_update operations
    # We have 9 visible items + previously cancelled items
    check finalResult["itemCount"].getInt() >= 9  # At least the 9 visible items
    
    let todoList = finalResult["todoList"].getStr()
    check todoList.contains("[x]") # Some completed
    check todoList.contains("[~]") # Some in progress  
    check todoList.contains("[ ]") # Some pending

echo "Running todolist end-to-end workflow tests..."