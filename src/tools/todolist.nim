## Todolist Tool Implementation
##
## This module implements a comprehensive todolist tool for task breakdown and tracking,
## essential for agentic behavior. It provides structured todo management with state
## persistence, user approval flows, and integration with Plan/Code modes.
##
## Key Features:
## - Structured todo management with markdown checklist parsing/generation
## - State persistence across conversation turns using SQLite
## - User approval flows for todo updates
## - Progress integration linking todos to implementation progress
## - Plan mode integration for comprehensive task breakdown

import std/[json, options, strformat, strutils, logging]
import ../types/tools
import ../core/database

type
  TodoOperation* = enum
    toAdd = "add"
    toUpdate = "update"
    toDelete = "delete"
    toList = "list"
    toShow = "show"

# Todo database functions are now in ../core/database.nim

proc formatTodoList*(db: DatabaseBackend, listId: int): string =
  ## Format a todo list as numbered markdown checklist with stable positions
  let items = getTodoItems(db, listId)
  var lines: seq[string] = @[]

  for i, item in items:
    let itemNumber = i + 1
    let checkbox = case item.state:
      of tsPending: "[ ]"
      of tsInProgress: "[~]"
      of tsCompleted: "[x]"
      of tsCancelled: "[-]"

    let priorityIndicator = case item.priority:
      of tpHigh: " (!)"
      of tpMedium: ""
      of tpLow: " (low)"

    lines.add(fmt"{itemNumber}. {checkbox} {item.content}{priorityIndicator}")

  return lines.join("\n")

proc getItemByNumber*(db: DatabaseBackend, listId: int, itemNumber: int): Option[int] =
  ## Map item number (1-N position) to database ID
  ## Returns the database ID if valid, none otherwise
  let items = getTodoItems(db, listId)

  if itemNumber < 1 or itemNumber > items.len:
    return none(int)

  return some(items[itemNumber - 1].id)

proc parseTodoUpdates*(markdownContent: string): seq[tuple[content: string, state: TodoState, priority: TodoPriority]] =
  ## Parse markdown checklist and extract todo updates
  result = @[]
  
  for line in markdownContent.splitLines():
    let trimmed = line.strip()
    if not trimmed.startsWith("- ["):
      continue
    
    var state: TodoState
    var content: string
    var priority = tpMedium
    
    if trimmed.startsWith("- [ ]"):
      state = tsPending
      content = trimmed[5..^1].strip()
    elif trimmed.startsWith("- [x]"):
      state = tsCompleted
      content = trimmed[5..^1].strip()
    elif trimmed.startsWith("- [~]"):
      state = tsInProgress
      content = trimmed[5..^1].strip()
    elif trimmed.startsWith("- [-]"):
      state = tsCancelled
      content = trimmed[5..^1].strip()
    else:
      continue
    
    # Parse priority indicators
    if content.endsWith(" (!)"):
      priority = tpHigh
      content = content[0..^4].strip()
    elif content.endsWith(" (low)"):
      priority = tpLow
      content = content[0..^6].strip()
    
    result.add((content, state, priority))

proc executeTodolist*(args: JsonNode): string {.gcsafe.} =
  ## Execute todolist tool operations
  {.gcsafe.}:
    try:
      let operation = getArgStr(args, "operation")
      let db = getGlobalDatabase()
      
      if db == nil:
        return $ %*{"error": "Database not available"}
      
      case operation:
      of "add":
        let content = getArgStr(args, "content")
        let priority = if args.hasKey("priority"): 
          case getArgStr(args, "priority"):
            of "high": tpHigh
            of "low": tpLow
            else: tpMedium
        else: tpMedium
        
        # Get or create active todo list (using conversation ID 1 for now)
        let conversationId = 1
        var listId = 0
        let maybeList = getActiveTodoList(db, conversationId)
        
        if maybeList.isSome():
          listId = maybeList.get().id
        else:
          listId = createTodoList(db, conversationId, "Current Tasks")
        
        let itemId = addTodoItem(db, listId, content, priority)
        let formattedList = formatTodoList(db, listId)
        
        return $ %*{
          "success": true,
          "itemId": itemId,
          "message": fmt"Added todo item: {content}",
          "todoList": formattedList
        }
      
      of "update":
        let itemNumber = getArgInt(args, "itemNumber")

        # Get or create active todo list
        let conversationId = 1
        let maybeList = getActiveTodoList(db, conversationId)

        if maybeList.isNone():
          return $ %*{"error": "No active todo list found"}

        let listId = maybeList.get().id
        let items = getTodoItems(db, listId)

        # Validate itemNumber
        if itemNumber < 1 or itemNumber > items.len:
          return $ %*{
            "error": fmt"Invalid item number {itemNumber}. Valid range: 1-{items.len}"
          }

        # Map itemNumber to database ID
        let maybeItemId = getItemByNumber(db, listId, itemNumber)
        if maybeItemId.isNone():
          return $ %*{
            "error": fmt"Failed to find item at position {itemNumber}"
          }

        let itemId = maybeItemId.get()

        # Parse state/content/priority updates
        var newState = none(TodoState)
        var newContent = none(string)
        var newPriority = none(TodoPriority)

        if args.hasKey("state"):
          newState = some(case getArgStr(args, "state"):
            of "pending": tsPending
            of "in_progress": tsInProgress
            of "completed": tsCompleted
            of "cancelled": tsCancelled
            else: tsPending)

        if args.hasKey("content"):
          newContent = some(getArgStr(args, "content"))

        if args.hasKey("priority"):
          newPriority = some(case getArgStr(args, "priority"):
            of "high": tpHigh
            of "low": tpLow
            else: tpMedium)

        let success = updateTodoItem(db, itemId, newState, newContent, newPriority)

        if success:
          let formattedList = formatTodoList(db, listId)

          return $ %*{
            "success": true,
            "message": fmt"Updated item {itemNumber}",
            "todoList": formattedList
          }
        else:
          return $ %*{"error": fmt"Failed to update item {itemNumber}"}

      of "delete":
        let itemNumber = getArgInt(args, "itemNumber")

        # Get active todo list
        let conversationId = 1
        let maybeList = getActiveTodoList(db, conversationId)

        if maybeList.isNone():
          return $ %*{"error": "No active todo list found"}

        let listId = maybeList.get().id
        let items = getTodoItems(db, listId)

        # Validate itemNumber
        if itemNumber < 1 or itemNumber > items.len:
          return $ %*{
            "error": fmt"Invalid item number {itemNumber}. Valid range: 1-{items.len}"
          }

        # Map itemNumber to database ID
        let maybeItemId = getItemByNumber(db, listId, itemNumber)
        if maybeItemId.isNone():
          return $ %*{
            "error": fmt"Failed to find item at position {itemNumber}"
          }

        let itemId = maybeItemId.get()

        # Soft delete: set state to cancelled
        let success = updateTodoItem(db, itemId, some(tsCancelled))

        if success:
          let formattedList = formatTodoList(db, listId)

          return $ %*{
            "success": true,
            "message": fmt"Cancelled item {itemNumber}",
            "todoList": formattedList
          }
        else:
          return $ %*{"error": fmt"Failed to cancel item {itemNumber}"}

      of "list", "show":
        let conversationId = 1
        let maybeList = getActiveTodoList(db, conversationId)
        
        if maybeList.isSome():
          let todoList = maybeList.get()
          let formattedList = formatTodoList(db, todoList.id)
          let items = getTodoItems(db, todoList.id)
          
          return $ %*{
            "success": true,
            "title": todoList.title,
            "description": todoList.description,
            "todoList": formattedList,
            "itemCount": items.len
          }
        else:
          return $ %*{
            "success": true,
            "message": "No active todo list found",
            "todoList": "",
            "itemCount": 0
          }
      
      of "bulk_update":
        let markdownContent = getArgStr(args, "todos")
        let updates = parseTodoUpdates(markdownContent)
        
        let conversationId = 1
        var listId = 0
        let maybeList = getActiveTodoList(db, conversationId)
        
        if maybeList.isSome():
          listId = maybeList.get().id
        else:
          listId = createTodoList(db, conversationId, "Current Tasks")
        
        # Hard delete all existing items (fresh start)
        let existingItems = getTodoItems(db, listId)
        for item in existingItems:
          discard deleteTodoItem(db, item.id)
        
        var addedCount = 0
        for update in updates:
          let itemId = addTodoItem(db, listId, update.content, update.priority)
          if update.state != tsPending:
            discard updateTodoItem(db, itemId, some(update.state))
          addedCount += 1
        
        let formattedList = formatTodoList(db, listId)
        
        return $ %*{
          "success": true,
          "message": fmt"Updated todo list with {addedCount} items",
          "todoList": formattedList
        }
      
      else:
        return $ %*{"error": fmt"Unknown operation: {operation}"}
      
    except Exception as e:
      error(fmt"Todolist tool error: {e.msg}")
      return $ %*{"error": e.msg}