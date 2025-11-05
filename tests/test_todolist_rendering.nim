import std/[json, strutils, logging]
import ../src/tools/todolist
import ../src/core/database
import ../src/ui/tool_visualizer

# Initialize a test database
let db = initializeGlobalDatabase(lvlInfo)

# Create a todo list and add items
let listId = createTodoList(db, 1, "Test List")
discard addTodoItem(db, listId, "First task", tpMedium)
discard addTodoItem(db, listId, "Second task", tpHigh)
discard addTodoItem(db, listId, "Third task", tpLow)

# Get the formatted list
let formatted = formatTodoList(db, listId)
echo "Raw formatted output:"
echo repr(formatted)
echo ""
echo "Rendered output:"
echo formatted
echo ""
echo "Line count: ", formatted.splitLines().len

# Now test it through the tool visualizer
let toolResult = $ %*{
  "success": true,
  "todoList": formatted
}

echo "\nTool result JSON (first 200 chars):"
echo toolResult[0..min(199, toolResult.len - 1)]
echo ""

let summary = createToolResultSummary("todolist", toolResult, true)
echo "Tool summary:"
echo summary
