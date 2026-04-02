import std/[strutils, options, strformat]
import database
import conversation_manager
import logging

type
  CompletionSignal* = enum
    csNone = "none"
    csPhrase = "completion_phrase"
    csMarkdownSummary = "markdown_summary"
    csBoth = "phrase_and_markdown"
  
  TodolistStatus* = object
    hasActiveTodolist*: bool
    pendingItems*: seq[string]
    inProgressItems*: seq[string]
    completedCount*: int
    totalCount*: int

const COMPLETION_PHRASES = [
  "task complete",
  "task completed",
  "successfully completed",
  "work is done",
  "work is complete",
  "everything is done",
  "all done",
  "finished successfully",
  "completed successfully"
]

const MARKDOWN_SUMMARY_HEADERS = [
  "## summary",
  "## results",
  "## conclusion",
  "## completed",
  "## done",
  "## final"
]

proc hasCompletionPhrase*(content: string): bool =
  ## Check if content contains completion phrases in last 500 chars
  let tail = if content.len > 500: content[^500..^1] else: content
  let lowerTail = tail.toLowerAscii()

  for phrase in COMPLETION_PHRASES:
    if phrase in lowerTail:
      return true
  return false

proc hasMarkdownSummary*(content: string): bool =
  ## Check if content contains markdown summary headers
  let lowerContent = content.toLowerAscii()

  for header in MARKDOWN_SUMMARY_HEADERS:
    if ("\n" & header & " ") in lowerContent or
       ("\n" & header & "\n") in lowerContent or
       lowerContent.startsWith(header & " ") or
       lowerContent.startsWith(header & "\n"):
      return true
  return false

proc detectCompletionSignal*(content: string): CompletionSignal =
  ## Detect completion signal in LLM response content
  let hasPhrase = hasCompletionPhrase(content)
  let hasSummary = hasMarkdownSummary(content)

  if hasPhrase and hasSummary:
    return csBoth
  elif hasPhrase:
    return csPhrase
  elif hasSummary:
    return csMarkdownSummary
  else:
    return csNone

proc getTodolistCompletionStatus*(db: DatabaseBackend): TodolistStatus {.gcsafe.} =
  ## Check if there's an active todolist with pending/in-progress items
  ## Returns status with pending items that need to be completed
  ## Used to prevent premature task completion when todolist is not finished
  {.gcsafe.}:
    result = TodolistStatus(
      hasActiveTodolist: false,
      pendingItems: @[],
      inProgressItems: @[],
      completedCount: 0,
      totalCount: 0
    )
    
    try:
      if db == nil:
        return
      
      let conversationId = getCurrentConversationId().int
      if conversationId == 0:
        return
      
      let maybeList = getActiveTodoList(db, conversationId)
      if maybeList.isNone():
        return
      
      let todoList = maybeList.get()
      let items = getTodoItems(db, todoList.id)
      
      result.hasActiveTodolist = true
      result.totalCount = items.len
      
      for item in items:
        case item.state:
        of tsPending:
          result.pendingItems.add(item.content)
        of tsInProgress:
          result.inProgressItems.add(item.content)
        of tsCompleted:
          result.completedCount += 1
        of tsCancelled:
          discard  # Cancelled items don't count toward completion
      
      debug(fmt"Todolist check: {result.completedCount}/{result.totalCount} completed, {result.pendingItems.len} pending, {result.inProgressItems.len} in progress")
      
    except Exception as e:
      error(fmt"Error checking todolist completion status: {e.msg}")
      return

proc buildTodolistReminder*(status: TodolistStatus): string =
  ## Build a reminder message for the LLM about remaining todolist items
  ## Returns empty string if no reminder needed
  if not status.hasActiveTodolist:
    return ""
  
  let incompleteCount = status.pendingItems.len + status.inProgressItems.len
  if incompleteCount == 0:
    return ""
  
  var reminder = "⚠️ Task not complete. The todolist shows " & $incompleteCount & " item(s) still pending:\n\n"
  
  if status.inProgressItems.len > 0:
    reminder &= "**Currently in progress:**\n"
    for i, item in status.inProgressItems:
      reminder &= fmt"  {i+1}. {item}" & "\n"
    reminder &= "\n"
  
  if status.pendingItems.len > 0:
    reminder &= "**Still pending:**\n"
    for i, item in status.pendingItems:
      reminder &= fmt"  {i+1}. {item}" & "\n"
    reminder &= "\n"
  
  reminder &= fmt"Progress: {status.completedCount}/{status.totalCount} items completed.\n\n"
  reminder &= "Please continue working on the remaining items. Mark items as completed using the todolist tool when done."
  
  return reminder
