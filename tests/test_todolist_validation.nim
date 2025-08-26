import std/[unittest, json]
import ../src/tools/common
import ../src/types/tools

suite "Todolist Tool Validation":
  test "Valid add operation":
    let validAddArgs = %*{
      "operation": "add",
      "content": "Test todo item",
      "priority": "high"
    }
    # Should not throw any exceptions
    validateTodolistArgs(validAddArgs)
  
  test "Valid update operation":
    let validUpdateArgs = %*{
      "operation": "update", 
      "itemId": 1,
      "state": "completed",
      "content": "Updated content"
    }
    # Should not throw any exceptions
    validateTodolistArgs(validUpdateArgs)
  
  test "Valid list operation":
    let validListArgs = %*{
      "operation": "list"
    }
    # Should not throw any exceptions  
    validateTodolistArgs(validListArgs)
  
  test "Valid bulk_update operation":
    let validBulkArgs = %*{
      "operation": "bulk_update",
      "todos": "- [ ] First task\n- [x] Completed task"
    }
    # Should not throw any exceptions
    validateTodolistArgs(validBulkArgs)
  
  test "Invalid operation":
    let invalidArgs = %*{
      "operation": "invalid_operation"
    }
    expect(ToolValidationError):
      validateTodolistArgs(invalidArgs)
  
  test "Missing operation":
    let missingOpArgs = %*{
      "content": "Test content"
    }
    expect(ToolValidationError):
      validateTodolistArgs(missingOpArgs)
  
  test "Add with missing content":
    let missingContentArgs = %*{
      "operation": "add"
    }
    expect(ToolValidationError):
      validateTodolistArgs(missingContentArgs)
  
  test "Add with empty content":
    let emptyContentArgs = %*{
      "operation": "add",
      "content": ""
    }
    expect(ToolValidationError):
      validateTodolistArgs(emptyContentArgs)
  
  test "Update with missing itemId":
    let missingIdArgs = %*{
      "operation": "update",
      "content": "New content"
    }
    expect(ToolValidationError):
      validateTodolistArgs(missingIdArgs)
  
  test "Update with no changes":
    let noChangesArgs = %*{
      "operation": "update",
      "itemId": 1
    }
    expect(ToolValidationError):
      validateTodolistArgs(noChangesArgs)
  
  test "Invalid priority":
    let invalidPriorityArgs = %*{
      "operation": "add",
      "content": "Test content",
      "priority": "urgent"
    }
    expect(ToolValidationError):
      validateTodolistArgs(invalidPriorityArgs)
  
  test "Invalid state":
    let invalidStateArgs = %*{
      "operation": "update",
      "itemId": 1,
      "state": "unknown"
    }
    expect(ToolValidationError):
      validateTodolistArgs(invalidStateArgs)

echo "Running todolist validation tests..."