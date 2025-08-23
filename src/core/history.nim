import std/[strformat, locks, options, times]
import ../types/[messages, history]
import std/logging

# Note: Conversion functions removed - now using LLMToolCall directly throughout

type
  HistoryManager* = object
    history: History
    lock: Lock
    # Session token tracking
    sessionPromptTokens: int
    sessionCompletionTokens: int

var globalHistory {.threadvar.}: HistoryManager

proc initHistoryManager*() =
  globalHistory.history = @[]
  globalHistory.sessionPromptTokens = 0
  globalHistory.sessionCompletionTokens = 0
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

proc addAssistantMessage*(content: string, toolCalls: Option[seq[LLMToolCall]] = none(seq[LLMToolCall])): Message =
  acquire(globalHistory.lock)
  try:
    # Store LLMToolCall directly in history (no conversion needed)
    let assistantItem = newAssistantItem(content, toolCalls)
    globalHistory.history.add(assistantItem)
    
    result = Message(
      role: mrAssistant,
      content: content,
      toolCalls: toolCalls
    )
    
    let callsInfo = if toolCalls.isSome(): fmt" (with {toolCalls.get().len} tool calls)" else: ""
    debug(fmt"Added assistant message: {content[0..min(50, content.len-1)]}...{callsInfo}")
    
    # Debug: Verify toolCalls were stored properly
    if toolCalls.isSome():
      debug(fmt"DEBUG: Assistant item toolCalls stored: {assistantItem.toolCalls.isSome()}")
      debug(fmt"DEBUG: Assistant item toolCalls count: {assistantItem.toolCalls.get().len}")
    else:
      debug("DEBUG: No tool calls in assistant message")
  finally:
    release(globalHistory.lock)

proc addToolMessage*(content: string, toolCallId: string): Message =
  ## Add a tool result message to history
  acquire(globalHistory.lock)
  try:
    let toolItem = newToolOutputItem(content, toolCallId)
    globalHistory.history.add(toolItem)
    
    result = Message(
      role: mrTool,
      content: content,
      toolCallId: some(toolCallId)
    )
    
    debug(fmt"Added tool result message (ID: {toolCallId}): {content[0..min(50, content.len-1)]}...")
  finally:
    release(globalHistory.lock)

proc getRecentMessages*(maxMessages: int = 10): seq[Message] =
  acquire(globalHistory.lock)
  try:
    result = @[]
    let startIdx = max(0, globalHistory.history.len - maxMessages)
    
    var userCount = 0
    var assistantCount = 0
    var toolCount = 0  # Tool result messages (hitToolOutput)
    var toolCallCount = 0  # Tool calls embedded in assistant messages
    var skippedCount = 0
    
    for i in startIdx..<globalHistory.history.len:
      let item = globalHistory.history[i]
      
      # Convert history items to messages
      case item.itemType:
      of hitUser:
        result.add(Message(role: mrUser, content: item.userContent))
        inc userCount
      of hitAssistant:
        # Tool calls are already LLMToolCall - use directly
        result.add(Message(
          role: mrAssistant, 
          content: item.assistantContent,
          toolCalls: item.toolCalls
        ))
        inc assistantCount
        
        # Count tool calls in this assistant message
        debug(fmt"DEBUG: Processing assistant item - toolCalls.isSome(): {item.toolCalls.isSome()}")
        if item.toolCalls.isSome():
          let toolCallsLen = item.toolCalls.get().len
          debug(fmt"DEBUG: Found {toolCallsLen} tool calls in assistant message")
          toolCallCount += toolCallsLen
        else:
          debug("DEBUG: No tool calls found in assistant message")
      of hitToolOutput:
        result.add(Message(
          role: mrTool,
          content: item.toolOutputContent,
          toolCallId: some(item.toolCallId)
        ))
        inc toolCount
      else:
        # Skip other types like hitToolFailed, hitNotification, etc.
        # These are for internal tracking and don't belong in LLM context
        inc skippedCount
        discard
        
    debug(fmt"History breakdown: {userCount} user, {assistantCount} assistant, {toolCount} tool, {skippedCount} skipped (total: {globalHistory.history.len})")
    debug(fmt"Tool calls in context: {toolCallCount}")
    debug(fmt"Retrieved {result.len} recent messages (including tool results)")
  finally:
    release(globalHistory.lock)

proc clearHistory*() =
  acquire(globalHistory.lock)
  try:
    globalHistory.history.setLen(0)
    # Reset session token counts when clearing history
    globalHistory.sessionPromptTokens = 0
    globalHistory.sessionCompletionTokens = 0
    info("History cleared")
  finally:
    release(globalHistory.lock)

proc getHistoryLength*(): int =
  acquire(globalHistory.lock)
  try:
    result = globalHistory.history.len
  finally:
    release(globalHistory.lock)

# Conversation tracking for database integration
var currentConversationId: int64 = 0
var currentMessageId: int64 = 0

proc getCurrentConversationId*(): int64 =
  ## Get the current conversation ID
  result = currentConversationId

proc getCurrentMessageId*(): int64 =
  ## Get the current message ID
  result = currentMessageId

proc startNewConversation*(): int64 =
  ## Start a new conversation and return its ID
  currentConversationId = epochTime().int64  # Use timestamp as conversation ID
  currentMessageId = 0  # Reset message ID for new conversation
  debug(fmt"Started new conversation with ID: {currentConversationId}")
  result = currentConversationId

proc incrementMessageId*(): int64 =
  ## Increment and return the next message ID
  currentMessageId += 1
  result = currentMessageId

proc updateSessionTokens*(inputTokens: int, outputTokens: int) =
  ## Update session token counts with exact values from LLM response
  acquire(globalHistory.lock)
  try:
    # These are cumulative for the current conversation session
    globalHistory.sessionPromptTokens = inputTokens  # Note: keeping internal field names for now
    globalHistory.sessionCompletionTokens = outputTokens
    debug(fmt"Updated session tokens: {inputTokens} input, {outputTokens} output")
  finally:
    release(globalHistory.lock)

proc getSessionTokens*(): tuple[inputTokens: int, outputTokens: int, totalTokens: int] =
  ## Get current session token counts
  acquire(globalHistory.lock)
  try:
    result = (
      inputTokens: globalHistory.sessionPromptTokens,  # Note: keeping internal field names for now
      outputTokens: globalHistory.sessionCompletionTokens,
      totalTokens: globalHistory.sessionPromptTokens + globalHistory.sessionCompletionTokens
    )
  finally:
    release(globalHistory.lock)