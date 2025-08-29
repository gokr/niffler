## Conversation Management Module
##
## This module provides comprehensive conversation management functionality:
## - Create, list, switch, archive, and delete conversations
## - Maintain conversation metadata (mode, model, activity)
## - Handle conversation session state
## - Integrate with database for persistence

import std/[options, strformat, times, logging, locks, strutils]
import ../types/[mode, messages]
import database
import debby/pools
import debby/sqlite

# Global conversation session state
var currentSession: Option[ConversationSession]

# Session management for message history and tokens
type
  SessionManager = object
    pool: Pool
    conversationId: int
    # Session token tracking
    sessionPromptTokens: int
    sessionCompletionTokens: int
    # Thread-safe access
    lock: Lock

var globalSession: SessionManager

proc getCurrentSession*(): Option[ConversationSession] =
  ## Get the current conversation session
  currentSession

proc syncSessionState*(conversationId: int) =
  ## Helper function to sync both session systems with the same conversation ID
  acquire(globalSession.lock)
  try:
    globalSession.conversationId = conversationId
    debug(fmt"Synced globalSession.conversationId to {conversationId}")
  finally:
    release(globalSession.lock)

proc validateSessionState*(): tuple[valid: bool, message: string] =
  ## Validate that both session systems are in sync
  let currentSessionOpt = getCurrentSession()
  if currentSessionOpt.isNone():
    return (valid: false, message: "No current session active")
  
  let currentConversationId = currentSessionOpt.get().conversation.id
  acquire(globalSession.lock)
  let globalConversationId = globalSession.conversationId
  release(globalSession.lock)
  
  if currentConversationId != globalConversationId:
    return (valid: false, message: fmt"Session state divergence: currentSession has conversation ID {currentConversationId}, globalSession has {globalConversationId}")
  else:
    return (valid: true, message: "Session states are synchronized")

proc listConversations*(backend: DatabaseBackend): seq[Conversation] =
  ## List all conversations, ordered by last activity
  if backend == nil:
    return @[]
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let query = """
          SELECT id, created_at, updated_at, session_id, title, is_active, 
                 mode, model_nickname, message_count, last_activity
          FROM conversation 
          ORDER BY last_activity DESC
        """
        
        let rows = db.query(query)
        result = @[]
        
        for row in rows:
          let conv = Conversation(
            id: parseInt(row[0]),
            created_at: now(),  # Use current time for now, improve later
            updated_at: now(),
            sessionId: row[3],
            title: row[4],
            isActive: row[5] == "1",
            mode: if row[6] == "code": amCode else: amPlan,
            modelNickname: row[7],
            messageCount: parseInt(row[8]),
            lastActivity: now()
          )
          result.add(conv)
        
        debug(fmt"Retrieved {result.len} conversations from database")
    except Exception as e:
      error(fmt"Failed to list conversations: {e.msg}")
      result = @[]

proc createConversation*(backend: DatabaseBackend, title: string = "", 
                        mode: AgentMode = amPlan, modelNickname: string = ""): Option[Conversation] =
  ## Create a new conversation with specified parameters
  if backend == nil:
    return none(Conversation)
  
  let actualTitle = if title.len > 0: title else: "Conversation " & $epochTime().int64
  let actualModelNickname = if modelNickname.len > 0: modelNickname else: "default"
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    var conversation = Conversation(
      id: 0,  # Will be set by database
      created_at: now(),
      updated_at: now(),
      sessionId: fmt"conv_{epochTime().int64}",
      title: actualTitle,
      isActive: true,
      mode: mode,
      modelNickname: actualModelNickname,
      messageCount: 0,
      lastActivity: now()
    )
    
    try:
      backend.pool.insert(conversation)
      info(fmt"Created conversation: {conversation.title} (ID: {conversation.id})")
      result = some(conversation)
    except Exception as e:
      error(fmt"Failed to create conversation: {e.msg}")
      result = none(Conversation)

proc getConversationById*(backend: DatabaseBackend, id: int): Option[Conversation] =
  ## Get a conversation by ID
  if backend == nil:
    return none(Conversation)
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let query = """
          SELECT id, created_at, updated_at, session_id, title, is_active, 
                 mode, model_nickname, message_count, last_activity
          FROM conversation 
          WHERE id = ?
        """
        
        let rows = db.query(query, id)
        if rows.len > 0:
          let row = rows[0]
          let conv = Conversation(
            id: parseInt(row[0]),
            created_at: now(),  # Use current time for now, improve later
            updated_at: now(),
            sessionId: row[3],
            title: row[4],
            isActive: row[5] == "1",
            mode: if row[6] == "code": amCode else: amPlan,
            modelNickname: row[7],
            messageCount: parseInt(row[8]),
            lastActivity: now()
          )
          debug(fmt"Found conversation with ID {id}: {conv.title}")
          result = some(conv)
        else:
          debug(fmt"No conversation found with ID {id}")
          result = none(Conversation)
    except Exception as e:
      error(fmt"Failed to get conversation by ID {id}: {e.msg}")
      result = none(Conversation)

proc updateConversationActivity*(backend: DatabaseBackend, conversationId: int) =
  ## Update the last activity timestamp for a conversation
  if backend == nil or conversationId == 0:
    return
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let currentTime = now().format("yyyy-MM-dd'T'HH:mm:ss")
        db.query("UPDATE conversation SET last_activity = ?, updated_at = ? WHERE id = ?", 
                 currentTime, currentTime, conversationId)
        debug(fmt"Updated activity timestamp for conversation {conversationId}")
    except Exception as e:
      error(fmt"Failed to update conversation activity: {e.msg}")

proc updateConversationMessageCount*(backend: DatabaseBackend, conversationId: int) =
  ## Update the message count for a conversation
  if backend == nil or conversationId == 0:
    return
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        # Count messages for this conversation
        let countRows = db.query("SELECT COUNT(*) FROM conversation_message WHERE conversation_id = ?", conversationId)
        let messageCount = parseInt(countRows[0][0])
        
        # Update conversation message count
        let currentTime = now().format("yyyy-MM-dd'T'HH:mm:ss")
        db.query("UPDATE conversation SET message_count = ?, updated_at = ? WHERE id = ?", 
                 messageCount, currentTime, conversationId)
        
        debug(fmt"Updated message count for conversation {conversationId} to {messageCount}")
    except Exception as e:
      error(fmt"Failed to update conversation message count: {e.msg}")

proc switchToConversation*(backend: DatabaseBackend, conversationId: int): bool =
  ## Switch to a specific conversation and restore its mode/model context
  if backend == nil:
    return false
  
  let conversationOpt = getConversationById(backend, conversationId)
  if conversationOpt.isNone():
    error(fmt"Conversation with ID {conversationId} not found")
    return false
  
  let conversation = conversationOpt.get()
  
  # Create new session
  let session = ConversationSession(
    conversation: conversation,
    isActive: true,
    startedAt: now()
  )
  
  # Update current session
  currentSession = some(session)
  
  # Sync globalSession with the new conversation ID
  syncSessionState(conversationId)
  
  # Restore mode context - TODO: implement when circular import is resolved
  debug(fmt"switchToConversation: should restore mode {conversation.mode}")
  
  # Update activity timestamp
  updateConversationActivity(backend, conversationId)
  
  info(fmt"Switched to conversation: {conversation.title} (Mode: {conversation.mode}, Model: {conversation.modelNickname})")
  return true

proc archiveConversation*(backend: DatabaseBackend, conversationId: int): bool =
  ## Archive a conversation (set isActive = false)
  if backend == nil:
    return false
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let currentTime = now().format("yyyy-MM-dd'T'HH:mm:ss")
        db.query("UPDATE conversation SET is_active = 0, updated_at = ? WHERE id = ?", 
                 currentTime, conversationId)
        
        # Get conversation title for logging
        let titleRows = db.query("SELECT title FROM conversation WHERE id = ?", conversationId)
        let title = if titleRows.len > 0: titleRows[0][0] else: "Unknown"
        
        info(fmt"Archived conversation {conversationId}: {title}")
        result = true
    except Exception as e:
      error(fmt"Failed to archive conversation {conversationId}: {e.msg}")
      result = false

proc deleteConversation*(backend: DatabaseBackend, conversationId: int): bool =
  ## Delete a conversation and all its messages (permanent)
  if backend == nil:
    return false
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      # Delete all messages first
      backend.pool.withDb:
        db.query("DELETE FROM conversation_message WHERE conversation_id = ?", conversationId)
        db.query("DELETE FROM model_token_usage WHERE conversation_id = ?", conversationId)
        db.query("DELETE FROM conversation WHERE id = ?", conversationId)
      
      info(fmt"Deleted conversation {conversationId} and all associated messages")
      result = true
    except Exception as e:
      error(fmt"Failed to delete conversation {conversationId}: {e.msg}")
      result = false

proc searchConversations*(backend: DatabaseBackend, query: string): seq[Conversation] =
  ## Search conversations by title or message content
  if backend == nil or query.len == 0:
    return @[]
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        # Search in conversation titles and message content
        let queryPattern = fmt"%{query}%"
        let searchQuery = """
          SELECT DISTINCT c.id, c.created_at, c.updated_at, c.session_id, c.title, 
                 c.is_active, c.mode, c.model_nickname, c.message_count, c.last_activity
          FROM conversation c
          LEFT JOIN conversation_message cm ON c.id = cm.conversation_id
          WHERE c.title LIKE ? OR cm.content LIKE ?
          ORDER BY c.last_activity DESC
        """
        
        let rows = db.query(searchQuery, queryPattern, queryPattern)
        result = @[]
        
        for row in rows:
          let conv = Conversation(
            id: parseInt(row[0]),
            created_at: now(),  # Use current time for now, improve later
            updated_at: now(),
            sessionId: row[3],
            title: row[4],
            isActive: row[5] == "1",
            mode: if row[6] == "code": amCode else: amPlan,
            modelNickname: row[7],
            messageCount: parseInt(row[8]),
            lastActivity: now()
          )
          result.add(conv)
        
        debug(fmt"Found {result.len} conversations matching '{query}'")
    except Exception as e:
      error(fmt"Failed to search conversations: {e.msg}")
      result = @[]

proc getCurrentConversationInfo*(): string =
  ## Get formatted string with current conversation info for display
  if currentSession.isNone():
    return "No active conversation"
  
  let session = currentSession.get()
  let conv = session.conversation
  return fmt"{conv.title} (#{conv.id}) - {conv.mode}/{conv.modelNickname}"

proc initializeDefaultConversation*(backend: DatabaseBackend) =
  ## Initialize a default conversation if none exists
  if backend == nil:
    return
  
  let conversations = listConversations(backend)
  if conversations.len == 0:
    debug("No conversations found, creating default conversation")
    let defaultConv = createConversation(backend, "Default Conversation", getDefaultMode(), "default")
    if defaultConv.isSome():
      discard switchToConversation(backend, defaultConv.get().id)
  else:
    # Switch to the most recent active conversation
    for conv in conversations:
      if conv.isActive:
        discard switchToConversation(backend, conv.id)
        break

# Message management functions for conversation persistence
proc initSessionManager*(pool: Pool = nil, conversationId: int = 0) =
  ## Initialize session manager with pool and conversation ID
  globalSession.pool = pool
  globalSession.conversationId = conversationId
  globalSession.sessionPromptTokens = 0
  globalSession.sessionCompletionTokens = 0
  initLock(globalSession.lock)

proc addUserMessage*(content: string): Message =
  ## Add user message to current conversation
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and globalSession.conversationId > 0:
        discard addUserMessageToDb(globalSession.pool, globalSession.conversationId, content)
      
      result = Message(
        role: mrUser,
        content: content
      )
      
      debug(fmt"Added user message: {content[0..min(50, content.len-1)]}")
    finally:
      release(globalSession.lock)

proc addAssistantMessage*(content: string, toolCalls: Option[seq[LLMToolCall]] = none(seq[LLMToolCall])): Message =
  ## Add assistant message to current conversation
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and globalSession.conversationId > 0:
        discard addAssistantMessageToDb(globalSession.pool, globalSession.conversationId, content, toolCalls, "")
      
      result = Message(
        role: mrAssistant,
        content: content,
        toolCalls: toolCalls
      )
      
      let callsInfo = if toolCalls.isSome(): fmt" (with {toolCalls.get().len} tool calls)" else: ""
      debug(fmt"Added assistant message: {content[0..min(50, content.len-1)]}...{callsInfo}")
    finally:
      release(globalSession.lock)

proc addToolMessage*(content: string, toolCallId: string): Message =
  ## Add tool result message to current conversation
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and globalSession.conversationId > 0:
        discard addToolMessageToDb(globalSession.pool, globalSession.conversationId, content, toolCallId)
      
      result = Message(
        role: mrTool,
        content: content,
        toolCallId: some(toolCallId)
      )
      
      debug(fmt"Added tool result message (ID: {toolCallId}): {content[0..min(50, content.len-1)]}...")
    finally:
      release(globalSession.lock)

proc getRecentMessages*(maxMessages: int = 10): seq[Message] =
  ## Get recent messages from current conversation
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Use database if available
      if globalSession.pool != nil and globalSession.conversationId > 0:
        result = getRecentMessagesFromDb(globalSession.pool, globalSession.conversationId, maxMessages)
        debug(fmt"Retrieved {result.len} recent messages from database")
        return result
      
      # Fallback: no messages if no database
      result = @[]
      debug("No database available, returning empty message history")
    finally:
      release(globalSession.lock)

proc getConversationContext*(): seq[Message] =
  ## Get conversation context for /context command - uses database
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      if globalSession.pool != nil and globalSession.conversationId > 0:
        let (messages, toolCallCount) = getConversationContextFromDb(globalSession.pool, globalSession.conversationId)
        debug(fmt"Retrieved {messages.len} messages from database with {toolCallCount} tool calls")
        return messages
      else:
        # Fallback: no messages if no database
        return @[]
    finally:
      release(globalSession.lock)


proc updateSessionTokens*(inputTokens: int, outputTokens: int) =
  ## Update session token counts with exact values from LLM response
  acquire(globalSession.lock)
  try:
    # These are cumulative for the current conversation session
    globalSession.sessionPromptTokens += inputTokens
    globalSession.sessionCompletionTokens += outputTokens
    debug(fmt"Updated session tokens: {inputTokens} input, {outputTokens} output")
  finally:
    release(globalSession.lock)

proc getSessionTokens*(): tuple[inputTokens: int, outputTokens: int, totalTokens: int] =
  ## Get current session token counts
  acquire(globalSession.lock)
  try:
    result = (
      inputTokens: globalSession.sessionPromptTokens,
      outputTokens: globalSession.sessionCompletionTokens,
      totalTokens: globalSession.sessionPromptTokens + globalSession.sessionCompletionTokens
    )
  finally:
    release(globalSession.lock)

proc getCurrentConversationId*(): int64 =
  ## Get the current conversation ID
  result = globalSession.conversationId.int64

proc getCurrentMessageId*(): int64 =
  ## Get the current message ID (stub for now)
  result = 0

