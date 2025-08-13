import std/[strformat, locks]
import ../types/[messages, history]
import std/logging

type
  HistoryManager* = object
    history: History
    lock: Lock

var globalHistory {.threadvar.}: HistoryManager

proc initHistoryManager*() =
  globalHistory.history = @[]
  initLock(globalHistory.lock)

proc addUserMessage*(content: string): Message =
  acquire(globalHistory.lock)
  try:
    let userItem = newUserItem(content)
    globalHistory.history.add(userItem)
    
    result = Message(
      role: mrUser,
      content: content
    )
    
    debug(fmt"Added user message: {content[0..min(50, content.len-1)]}")
  finally:
    release(globalHistory.lock)

proc addAssistantMessage*(content: string): Message =
  acquire(globalHistory.lock)
  try:
    let assistantItem = newAssistantItem(content)
    globalHistory.history.add(assistantItem)
    
    result = Message(
      role: mrAssistant,
      content: content
    )
    
    debug(fmt"Added assistant message: {content[0..min(50, content.len-1)]}...")
  finally:
    release(globalHistory.lock)

proc getRecentMessages*(maxMessages: int = 10): seq[Message] =
  acquire(globalHistory.lock)
  try:
    result = @[]
    let startIdx = max(0, globalHistory.history.len - maxMessages)
    
    for i in startIdx..<globalHistory.history.len:
      let item = globalHistory.history[i]
      
      # Convert history items to messages
      case item.itemType:
      of hitUser:
        result.add(Message(role: mrUser, content: item.userContent))
      of hitAssistant:
        result.add(Message(role: mrAssistant, content: item.assistantContent))
      else:
        discard  # Skip other types for now
        
    debug(fmt"Retrieved {result.len} recent messages")
  finally:
    release(globalHistory.lock)

proc clearHistory*() =
  acquire(globalHistory.lock)
  try:
    globalHistory.history.setLen(0)
    info("History cleared")
  finally:
    release(globalHistory.lock)

proc getHistoryLength*(): int =
  acquire(globalHistory.lock)
  try:
    result = globalHistory.history.len
  finally:
    release(globalHistory.lock)