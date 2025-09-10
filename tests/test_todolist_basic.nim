import std/[unittest, json, strutils]
import ../src/tools/todolist
import ../src/core/database

suite "Todolist Tool Basic Tests":
  
  test "Markdown parsing functionality":
    let markdownTodos = """
- [ ] First task
- [x] Completed task  
- [~] In progress task
- [ ] High priority task (!)
- [ ] Low priority task (low)
- [-] Cancelled task
"""
    
    let todos = parseTodoUpdates(markdownTodos)
    
    check todos.len == 6
    check todos[0] == ("First task", tsPending, tpMedium)
    check todos[1] == ("Completed task", tsCompleted, tpMedium)
    check todos[2] == ("In progress task", tsInProgress, tpMedium)
    check todos[3] == ("High priority task", tsPending, tpHigh)
    check todos[4] == ("Low priority task", tsPending, tpLow)
    check todos[5] == ("Cancelled task", tsCancelled, tpMedium)

  test "Markdown parsing handles malformed content":
    let malformedContent = """
Not a todo item
- This is not a checkbox
- [ Invalid checkbox format
- [y] Invalid state marker
- [ ] Valid task only
Random text here
"""
    
    let todos = parseTodoUpdates(malformedContent)
    check todos.len == 1
    check todos[0].content == "Valid task only"

  test "Markdown parsing handles empty and edge cases":
    # Empty content
    var todos = parseTodoUpdates("")
    check todos.len == 0
    
    # Only whitespace
    todos = parseTodoUpdates("   \n  \n  ")
    check todos.len == 0
    
    # Mixed with empty lines
    todos = parseTodoUpdates("- [ ] Task 1\n\n- [x] Task 2\n  \n")
    check todos.len == 2

  test "Priority indicator parsing":
    let priorityTests = """
- [ ] No priority
- [ ] High priority (!)
- [ ] Low priority (low)  
- [ ] Simple high (!)
- [ ] Simple low (low)
"""
    
    let todos = parseTodoUpdates(priorityTests)
    check todos.len == 5
    check todos[0].priority == tpMedium
    check todos[1].priority == tpHigh
    check todos[1].content == "High priority"
    check todos[2].priority == tpLow
    check todos[2].content == "Low priority"
    check todos[3].priority == tpHigh
    check todos[3].content == "Simple high"
    check todos[4].priority == tpLow
    check todos[4].content == "Simple low"

  test "State marker parsing":
    let stateTests = """
- [ ] Pending task
- [x] Completed task
- [~] In progress task
- [-] Cancelled task
"""
    
    let todos = parseTodoUpdates(stateTests)
    check todos.len == 4
    check todos[0].state == tsPending
    check todos[1].state == tsCompleted
    check todos[2].state == tsInProgress
    check todos[3].state == tsCancelled

  test "Tool execution with database available":
    # Since database initializes automatically, test that the tool works
    let args = %*{"operation": "list"}
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response.hasKey("success")
    check response["success"].getBool() == true

  test "Tool execution with invalid operation":
    let args = %*{"operation": "invalid_operation"}
    let result = executeTodolist(args)
    let response = parseJson(result)
    
    check response.hasKey("error")
    check response["error"].getStr().contains("Unknown operation")

echo "Running basic todolist tests..."