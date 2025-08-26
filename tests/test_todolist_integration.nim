import std/[unittest, json, options, sequtils, strutils]
import ../src/tools/registry

suite "Todolist Tool Integration":
  test "Todolist tool is registered":
    let maybeTool = getTool("todolist")
    check maybeTool.isSome()
    
    let tool = maybeTool.get()
    check tool.name == "todolist"
    check tool.description == "Manage todo lists and task tracking"
    check tool.requiresConfirmation == false
  
  test "Todolist tool schema is accessible":
    let maybeSchema = getToolSchema("todolist")
    check maybeSchema.isSome()
    
    let schema = maybeSchema.get()
    check schema.function.name == "todolist"
    check schema.function.description == "Manage todo lists and task tracking"
  
  test "Todolist tool is in all tools list":
    let allTools = getAllTools()
    let todolistTool = allTools.filter(proc(t: Tool): bool = t.name == "todolist")
    check todolistTool.len == 1
    check todolistTool[0].name == "todolist"
  
  test "Available tools list includes todolist":
    let toolsList = getAvailableToolsList()
    check toolsList.contains("todolist")
    check toolsList.contains("Manage todo lists and task tracking")

echo "Running todolist integration tests..."