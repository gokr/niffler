import std/[unittest, json, options, strutils]
import ../src/tools/todolist
import ../src/tools/registry
import ../src/core/database
import ../src/types/config
import test_utils

suite "Todolist LLM Integration Tests":
  var db: DatabaseBackend

  setup:
    db = createTestDatabaseBackend()
    clearTestDatabase(db)
    setGlobalDatabase(db)

  teardown:
    if db != nil:
      db.close()

  test "Tool schema is valid for LLM consumption":
    # Verify the todolist tool schema is properly formatted for LLM use
    let maybeSchema = getToolSchema("todolist")
    check maybeSchema.isSome()
    
    let schema = maybeSchema.get()
    check schema.function.name == "todolist"
    check schema.function.description != ""
    check schema.function.parameters.hasKey("properties")
    
    let properties = schema.function.parameters["properties"]
    check properties.hasKey("operation")
    
    # Verify operation enum includes all supported operations
    let operationProperty = properties["operation"]
    check operationProperty.hasKey("enum")
    let enumValues = operationProperty["enum"]
    
    var hasAdd, hasUpdate, hasList, hasBulkUpdate = false
    for item in enumValues:
      case item.getStr():
      of "add": hasAdd = true
      of "update": hasUpdate = true  
      of "list", "show": hasList = true
      of "bulk_update": hasBulkUpdate = true
      else: discard
    
    check hasAdd and hasUpdate and hasList and hasBulkUpdate

  test "Tool execution results are LLM-friendly":
    # Test that tool results are in a format that LLMs can easily parse and understand
    
    # Add a task
    let addResult = executeTodolist(%*{
      "operation": "add",
      "content": "Test LLM integration", 
      "priority": "high"
    })
    
    let addResponse = parseJson(addResult)
    check addResponse.hasKey("success")
    check addResponse.hasKey("todoList")
    check addResponse.hasKey("message")
    
    # Verify the todoList is markdown formatted (LLM friendly)
    let todoList = addResponse["todoList"].getStr()
    check todoList.startsWith("- [")
    check todoList.contains("(!)")
    
    # List tasks
    let listResult = executeTodolist(%*{"operation": "list"})
    let listResponse = parseJson(listResult)
    
    check listResponse.hasKey("todoList")
    check listResponse.hasKey("itemCount")
    check listResponse.hasKey("success")

  test "Error messages are informative for LLMs":
    # Test that error messages provide clear guidance
    
    # Missing required field
    let missingContentResult = executeTodolist(%*{"operation": "add"})
    let errorResponse = parseJson(missingContentResult)
    check errorResponse.hasKey("error")
    
    # Invalid operation
    let invalidOpResult = executeTodolist(%*{"operation": "invalid"})
    let invalidResponse = parseJson(invalidOpResult)
    check invalidResponse.hasKey("error")
    check invalidResponse["error"].getStr().contains("Unknown operation")

  test "Bulk update format matches LLM output style":
    # Test that the markdown format expected by bulk_update matches 
    # what LLMs typically generate
    
    let llmStyleMarkdown = """
Here are the updated tasks:

- [ ] First task that needs doing
- [x] Task that is completed  
- [~] Task currently in progress
- [ ] High priority urgent task (!)
- [ ] Low priority task for later (low)

This should work with the bulk update.
"""
    
    # Should parse correctly despite extra text
    let todos = parseTodoUpdates(llmStyleMarkdown)
    check todos.len == 5
    check todos[0] == ("First task that needs doing", tsPending, tpMedium)
    check todos[1] == ("Task that is completed", tsCompleted, tpMedium)
    check todos[2] == ("Task currently in progress", tsInProgress, tpMedium)
    check todos[3] == ("High priority urgent task", tsPending, tpHigh)
    check todos[4] == ("Low priority task for later", tsPending, tpLow)

  test "Conversation context preservation":
    # This test verifies that todo lists are properly scoped to conversations
    # (Currently all use conversationId 1, but the structure is there)
    
    # Add tasks in "conversation"
    discard executeTodolist(%*{"operation": "add", "content": "Conversation task 1"})
    discard executeTodolist(%*{"operation": "add", "content": "Conversation task 2"})
    
    # Verify they persist
    let listResult = parseJson(executeTodolist(%*{"operation": "list"}))
    check listResult["itemCount"].getInt() == 2

echo """
=== Manual LLM Integration Test Instructions ===

This test can be run manually with a real LLM to verify end-to-end functionality:

1. Compile and run: nim c -r tests/test_todolist_llm_integration.nim

2. To test with a real LLM, run niffler with a model that supports tool calling:
   ./niffler --model gpt-4 "I need to plan a software project. Please use the todolist tool to help me track tasks."

3. Expected LLM behavior:
   - Should use todolist tool with 'add' operation to create initial tasks
   - Should format tasks with priorities using (!) and (low) indicators  
   - Should use 'list' operation to show current tasks
   - Should use 'update' operations to change task states
   - Should use 'bulk_update' with markdown when reorganizing many tasks

4. Test scenarios to try:
   - "Add a task to implement authentication with high priority"
   - "Mark the first task as in progress"  
   - "Show me the current todo list"
   - "Update all tasks - I've completed authentication, started on database design, and need to add API endpoints"

5. Verify:
   - Tasks persist between tool calls
   - Markdown formatting is correct
   - Priority indicators work properly
   - State changes are reflected correctly
   - Error handling works for invalid operations

To run with a specific model: 
./niffler --model MODEL_NAME --interactive

Then test the todolist tool through natural conversation.
"""

echo "Running todolist LLM integration tests..."