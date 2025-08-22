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
  ## Format a todo list as markdown checklist
  let items = getTodoItems(db, listId)
  var lines: seq[string] = @[]
  
  for item in items:
    let checkbox = case item.state:
      of tsPending: "[ ]"
      of tsInProgress: "[~]"
      of tsCompleted: "[x]"
      of tsCancelled: "[-]"
    
    let priorityIndicator = case item.priority:
      of tpHigh: " (!)"
      of tpMedium: ""
      of tpLow: " (low)"
    
    lines.add(fmt"- {checkbox} {item.content}{priorityIndicator}")
  
  return lines.join("\n")

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
        let itemId = getArgInt(args, "itemId")
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
          # Find the list this item belongs to and format it
          let conversationId = 1
          let maybeList = getActiveTodoList(db, conversationId)
          let formattedList = if maybeList.isSome(): formatTodoList(db, maybeList.get().id) else: ""
          
          return $ %*{
            "success": true,
            "message": fmt"Updated todo item {itemId}",
            "todoList": formattedList
          }
        else:
          return $ %*{"error": fmt"Failed to update todo item {itemId}"}
      
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
        
        # Clear existing items and add new ones
        let existingItems = getTodoItems(db, listId)
        for item in existingItems:
          discard updateTodoItem(db, item.id, some(tsCancelled))
        
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