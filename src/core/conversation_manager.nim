## Conversation Management Module
##
## This module provides comprehensive conversation management functionality:
## - Create, list, switch, archive, and delete conversations
## - Maintain conversation metadata (mode, model, activity)
## - Handle conversation session state
## - Integrate with database for persistence

import std/[options, strformat, times, logging, locks, strutils, json]
import ../types/[mode, messages, thinking_tokens]
import ../tokenization/tokenizer
import database
import debby/pools
import debby/sqlite

# Global conversation session state
var currentSession: Option[ConversationSession]

# Thread-local conversation context cache
type ConversationCache = object
  messages: seq[Message]
  toolCallCount: int
  lastCacheTime: Time
  conversationId: int

var cachedContext {.threadvar.}: ConversationCache
var cacheValid {.threadvar.}: bool

proc invalidateConversationCache*() {.gcsafe.} =
  ## Invalidate the conversation context cache
  cacheValid = false

# Session management for message history and tokens
type
  SessionManager = object
    pool: Pool
    conversationId: int
    # Session token tracking
    sessionPromptTokens: int
    sessionCompletionTokens: int
    # App session tracking
    appStartTime: DateTime
    # Thread-safe access
    lock: Lock

var globalSession: SessionManager

# Initialize lock at module load time to prevent race conditions
initLock(globalSession.lock)

proc getCurrentSession*(): Option[ConversationSession] =
  ## Get the current conversation session if one is active (thread-safe)
  acquire(globalSession.lock)
  try:
    result = currentSession
  finally:
    release(globalSession.lock)

proc clearCurrentSession*() =
  ## Clear the current session (for testing or cleanup)
  acquire(globalSession.lock)
  try:
    currentSession = none(ConversationSession)
  finally:
    release(globalSession.lock)

proc syncSessionState*(conversationId: int) =
  ## Synchronize both session systems with the same conversation ID
  acquire(globalSession.lock)
  try:
    globalSession.conversationId = conversationId
    debug(fmt"Synced globalSession.conversationId to {conversationId}")
  finally:
    release(globalSession.lock)

proc validateSessionState*(): tuple[valid: bool, message: string] =
  ## Validate that both session systems are properly synchronized
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

proc getAppStartTime*(): DateTime =
  ## Get the application start time for session cost calculations
  acquire(globalSession.lock)
  defer: release(globalSession.lock)
  return globalSession.appStartTime

type
  ConversationFilter* = enum
    cfAll = "all"
    cfActive = "active"
    cfArchived = "archived"

proc listConversations*(backend: DatabaseBackend, filter: ConversationFilter = cfAll): seq[Conversation] =
  ## List conversations with optional filtering, ordered by last activity descending
  if backend == nil:
    return @[]
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let whereClause = case filter:
          of cfActive: "WHERE is_active = 1"
          of cfArchived: "WHERE is_active = 0"
          of cfAll: ""
        
        let query = fmt"""
          SELECT id, created_at, updated_at, session_id, title, is_active,
                 mode, model_nickname, message_count, last_activity,
                 plan_mode_entered_at, plan_mode_created_files,
                 parent_conversation_id, condensed_from_message_count,
                 condensation_strategy, condensation_metadata
          FROM conversation
          {whereClause}
          ORDER BY last_activity DESC
        """
        
        result = db.query(Conversation, query)
        
        let filterDesc = case filter:
          of cfActive: "active"
          of cfArchived: "archived" 
          of cfAll: "total"
        debug(fmt"Retrieved {result.len} {filterDesc} conversations from database")
    except Exception as e:
      let filterDesc = case filter:
        of cfActive: "active"
        of cfArchived: "archived"
        of cfAll: "all"
      error(fmt"Failed to list {filterDesc} conversations: {e.msg}")
      result = @[]

proc listActiveConversations*(backend: DatabaseBackend): seq[Conversation] =
  ## List only active conversations, ordered by last activity
  listConversations(backend, cfActive)

proc listArchivedConversations*(backend: DatabaseBackend): seq[Conversation] =
  ## List only archived conversations, ordered by last activity
  listConversations(backend, cfArchived)

proc createConversation*(backend: DatabaseBackend, title: string = "", 
                        mode: AgentMode = amPlan, modelNickname: string = ""): Option[Conversation] =
  ## Create a new conversation with specified parameters, returns the created conversation
  if backend == nil:
    return none(Conversation)
  
  let actualTitle = if title.len > 0: title else: "Conversation " & $epochTime().int64
  let actualModelNickname = if modelNickname.len > 0: modelNickname else: "default"
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    var conversation = Conversation(
      id: 0,  # Will be set by database
      created_at: now().utc(),
      updated_at: now().utc(),
      sessionId: fmt"conv_{epochTime().int64}",
      title: actualTitle,
      isActive: true,
      mode: mode,
      modelNickname: actualModelNickname,
      messageCount: 0,
      lastActivity: now().utc(),
      planModeEnteredAt: if mode == amPlan: now().utc() else: fromUnix(0).utc(),  # Set to current time if creating in plan mode
      planModeCreatedFiles: ""  # Initialize to empty string
    )
    
    try:
      backend.pool.insert(conversation)
      info(fmt"Created conversation: {conversation.title} (ID: {conversation.id})")
      result = some(conversation)
    except Exception as e:
      error(fmt"Failed to create conversation: {e.msg}")
      result = none(Conversation)

proc getConversationById*(backend: DatabaseBackend, id: int): Option[Conversation] =
  ## Retrieve a conversation by its unique ID
  if backend == nil:
    return none(Conversation)
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let query = """
          SELECT id, created_at, updated_at, session_id, title, is_active,
                 mode, model_nickname, message_count, last_activity,
                 plan_mode_entered_at, plan_mode_created_files,
                 parent_conversation_id, condensed_from_message_count,
                 condensation_strategy, condensation_metadata
          FROM conversation
          WHERE id = ?
        """
        
        let conversations = db.query(Conversation, query, id)
        if conversations.len > 0:
          let conv = conversations[0]
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
        let currentTime = utcNow()
        db.query("UPDATE conversation SET last_activity = ?, updated_at = ? WHERE id = ?", 
                 currentTime, currentTime, conversationId)
        debug(fmt"Updated activity timestamp for conversation {conversationId}")
    except Exception as e:
      error(fmt"Failed to update conversation activity: {e.msg}")

proc updateConversationMessageCount*(backend: DatabaseBackend, conversationId: int) =
  ## Recalculate and update the message count for a conversation
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
        let currentTime = utcNow()
        db.query("UPDATE conversation SET message_count = ?, updated_at = ? WHERE id = ?", 
                 messageCount, currentTime, conversationId)
        
        debug(fmt"Updated message count for conversation {conversationId} to {messageCount}")
    except Exception as e:
      error(fmt"Failed to update conversation message count: {e.msg}")

proc updateConversationMode*(backend: DatabaseBackend, conversationId: int, mode: AgentMode) =
  ## Update the agent mode (Plan/Code) for a conversation
  if backend == nil or conversationId == 0:
    return
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let currentTime = utcNow()
        db.query("UPDATE conversation SET mode = ?, updated_at = ? WHERE id = ?", 
                 $mode, currentTime, conversationId)
        debug(fmt"Updated mode for conversation {conversationId} to {mode}")
    except Exception as e:
      error(fmt"Failed to update conversation mode: {e.msg}")

proc updateConversationModel*(backend: DatabaseBackend, conversationId: int, modelNickname: string) =
  ## Update the model nickname for a conversation
  if backend == nil or conversationId == 0:
    return
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let currentTime = utcNow()
        db.query("UPDATE conversation SET model_nickname = ?, updated_at = ? WHERE id = ?", 
                 modelNickname, currentTime, conversationId)
        debug(fmt"Updated model nickname for conversation {conversationId} to {modelNickname}")
    except Exception as e:
      error(fmt"Failed to update conversation model: {e.msg}")

proc switchToConversation*(backend: DatabaseBackend, conversationId: int): bool =
  ## Switch to a specific conversation and restore its context/mode/model settings
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
  
  # Mode restoration is handled in UI layer (commands.nim) to avoid circular imports
  debug(fmt"switchToConversation: mode {conversation.mode} will be restored by UI layer")
  
  # Update activity timestamp
  updateConversationActivity(backend, conversationId)
  
  info(fmt"Switched to conversation: {conversation.title}")
  return true

proc archiveConversation*(backend: DatabaseBackend, conversationId: int): bool =
  ## Archive a conversation (set isActive = false) to hide it from main list
  if backend == nil:
    return false
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        # First check if the conversation exists
        let existsRows = db.query("SELECT id, title FROM conversation WHERE id = ?", conversationId)
        if existsRows.len == 0:
          debug(fmt"Cannot archive conversation {conversationId}: conversation not found")
          return false
        
        let title = existsRows[0][1]
        let currentTime = utcNow()
        db.query("UPDATE conversation SET is_active = 0, updated_at = ? WHERE id = ?", 
                 currentTime, conversationId)
        
        info(fmt"Archived conversation {conversationId}: {title}")
        result = true
    except Exception as e:
      error(fmt"Failed to archive conversation {conversationId}: {e.msg}")
      result = false

proc unarchiveConversation*(backend: DatabaseBackend, conversationId: int): bool =
  ## Unarchive a conversation (set isActive = true) to restore it to main list
  if backend == nil:
    return false
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    try:
      backend.pool.withDb:
        let currentTime = utcNow()
        db.query("UPDATE conversation SET is_active = 1, updated_at = ? WHERE id = ?", 
                 currentTime, conversationId)
        
        # Get conversation title for logging
        let titleRows = db.query("SELECT title FROM conversation WHERE id = ?", conversationId)
        let title = if titleRows.len > 0: titleRows[0][0] else: "Unknown"
        
        info(fmt"Unarchived conversation {conversationId}: {title}")
        result = true
    except Exception as e:
      error(fmt"Failed to unarchive conversation {conversationId}: {e.msg}")
      result = false

proc deleteConversation*(backend: DatabaseBackend, conversationId: int): bool =
  ## Permanently delete a conversation and all its messages (cannot be undone)
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
  ## Search conversations by title or message content using SQL LIKE patterns
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
                 c.is_active, c.mode, c.model_nickname, c.message_count, c.last_activity,
                 c.plan_mode_entered_at, c.plan_mode_created_files,
                 c.parent_conversation_id, c.condensed_from_message_count,
                 c.condensation_strategy, c.condensation_metadata
          FROM conversation c
          LEFT JOIN conversation_message cm ON c.id = cm.conversation_id
          WHERE c.title LIKE ? OR cm.content LIKE ?
          ORDER BY c.last_activity DESC
        """
        
        result = db.query(Conversation, searchQuery, queryPattern, queryPattern)
        
        debug(fmt"Found {result.len} conversations matching '{query}'")
    except Exception as e:
      error(fmt"Failed to search conversations: {e.msg}")
      result = @[]

proc getCurrentConversationInfo*(): string =
  ## Get formatted string with current conversation info for display purposes
  if currentSession.isNone():
    return "No active conversation"
  
  let session = currentSession.get()
  let conv = session.conversation
  return fmt"{conv.title} (#{conv.id}) - {conv.mode}/{conv.modelNickname}"

proc initializeDefaultConversation*(backend: DatabaseBackend) =
  ## Initialize a default conversation if none exists or switch to most recent active
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
  ## Initialize session manager with database pool and conversation ID for thread-safe operations
  globalSession.pool = pool
  globalSession.conversationId = conversationId
  globalSession.sessionPromptTokens = 0
  globalSession.sessionCompletionTokens = 0
  globalSession.appStartTime = now()

proc addUserMessage*(content: string): Message =
  ## Add user message to current conversation and persist to database
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and globalSession.conversationId > 0:
        discard addUserMessageToDb(globalSession.pool, globalSession.conversationId, content)
        # Update message count
        let backend = getGlobalDatabase()
        if backend != nil:
          updateConversationMessageCount(backend, globalSession.conversationId)
      
      result = Message(
        role: mrUser,
        content: content
      )
      
      debug(fmt"Added user message: {content[0..min(50, content.len-1)]}")
      
      # Invalidate conversation context cache
      invalidateConversationCache()
    finally:
      release(globalSession.lock)

proc addAssistantMessage*(content: string, toolCalls: Option[seq[LLMToolCall]] = none(seq[LLMToolCall]),
                          outputTokens: int = 0, modelName: string = ""): Message =
  ## Add assistant message to current conversation with optional tool calls and token data
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and globalSession.conversationId > 0:
        discard addAssistantMessageToDb(globalSession.pool, globalSession.conversationId, content, toolCalls, modelName, outputTokens)
        # Update message count
        let backend = getGlobalDatabase()
        if backend != nil:
          updateConversationMessageCount(backend, globalSession.conversationId)
      
      result = Message(
        role: mrAssistant,
        content: content,
        toolCalls: toolCalls
      )
      
      let callsInfo = if toolCalls.isSome(): fmt" (with {toolCalls.get().len} tool calls)" else: ""
      debug(fmt"Added assistant message: {content[0..min(50, content.len-1)]}...{callsInfo}")
      
      # Invalidate conversation context cache
      invalidateConversationCache()
    finally:
      release(globalSession.lock)

proc addToolMessage*(content: string, toolCallId: string): Message =
  ## Add tool result message to current conversation with tool call ID reference
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and globalSession.conversationId > 0:
        discard addToolMessageToDb(globalSession.pool, globalSession.conversationId, content, toolCallId)
        # Update message count
        let backend = getGlobalDatabase()
        if backend != nil:
          updateConversationMessageCount(backend, globalSession.conversationId)
      
      result = Message(
        role: mrTool,
        content: content,
        toolCallId: some(toolCallId)
      )
      
      debug(fmt"Added tool result message (ID: {toolCallId}): {content[0..min(50, content.len-1)]}...")
      
      # Invalidate conversation context cache
      invalidateConversationCache()
    finally:
      release(globalSession.lock)

proc getRecentMessages*(maxMessages: int = 10): seq[Message] =
  ## Get recent messages from current conversation for display purposes
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

proc getConversationContext*(): seq[Message] {.gcsafe.} =
  ## Get full conversation context for LLM requests (includes all message types) with caching
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      if globalSession.pool != nil and globalSession.conversationId > 0:
        # Check if cache is valid and for the same conversation
        if cacheValid and 
           cachedContext.conversationId == globalSession.conversationId and
           (getTime() - cachedContext.lastCacheTime) < initDuration(seconds = 60):
          debug(fmt"Using cached conversation context with {cachedContext.messages.len} messages")
          result = cachedContext.messages
          return
        
        # Cache miss or invalid - fetch from database
        var toolCallCount: int
        (result, toolCallCount) = getConversationContextFromDb(globalSession.pool, globalSession.conversationId)
        
        # Update cache
        cachedContext.messages = result
        cachedContext.toolCallCount = toolCallCount
        cachedContext.lastCacheTime = getTime()
        cachedContext.conversationId = globalSession.conversationId
        cacheValid = true
        
        debug(fmt"Retrieved and cached {result.len} messages from database with {toolCallCount} tool calls")
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
  ## Get current session token counts for display and cost calculation
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
  ## Get the current conversation ID for database operations
  result = globalSession.conversationId.int64

proc getCurrentMessageId*(): int64 =
  ## Get the current message ID (placeholder implementation)
  result = 0

# Thinking Token Management Functions

proc addThinkingTokenToDb*(pool: Pool, conversationId: int, thinkingContent: ThinkingContent, 
                          messageId: Option[int] = none(int), format: ThinkingTokenFormat = ttfNone,
                          importance: string = "medium"): int =
  ## Add thinking token to database and return the assigned ID
  pool.withDb:
    # Extract content from ThinkingContent
    let content = if thinkingContent.reasoningContent.isSome(): 
                    thinkingContent.reasoningContent.get() 
                  elif thinkingContent.encryptedReasoningContent.isSome():
                    thinkingContent.encryptedReasoningContent.get()
                  else: ""
    
    let thinkingToken = ConversationThinkingToken(
      id: 0,
      conversationId: conversationId,
      messageId: messageId,
      created_at: now(),
      thinkingContent: $ %*thinkingContent,  # Serialize as JSON
      providerFormat: $format,
      importanceLevel: importance,
      tokenCount: estimateTokens(content),  # Proper token estimation
      keywords: "[]",  # Empty array for now
      contextId: fmt"ctx_{epochTime().int64}",
      reasoningId: thinkingContent.reasoningId
    )
    db.insert(thinkingToken)
    debug(fmt"Added thinking token to database: {format} format, {importance} importance")
    return thinkingToken.id

proc getThinkingTokenHistory*(pool: Pool, conversationId: int, limit: int = 50): seq[ThinkingContent] =
  ## Retrieve thinking token history for a conversation, most recent first
  result = @[]
  pool.withDb:
    let query = """
      SELECT thinking_content, provider_format, importance_level, token_count, 
             keywords, context_id, reasoning_id, created_at
      FROM conversation_thinking_token 
      WHERE conversation_id = ? 
      ORDER BY created_at DESC 
      LIMIT ?
    """
    
    try:
      let thinkingRows = db.query(ThinkingTokenRow, query, conversationId, limit)
      
      for thinkingRow in thinkingRows:
        # Parse the JSON thinking content back to ThinkingContent
        let thinkingJson = parseJson(thinkingRow.thinkingContent)
        
        let thinkingContent = ThinkingContent(
          reasoningContent: if thinkingJson.hasKey("reasoningContent"): 
                              some(thinkingJson{"reasoningContent"}.getStr("")) 
                            else: none(string),
          encryptedReasoningContent: if thinkingJson.hasKey("encryptedReasoningContent"): 
                                       some(thinkingJson{"encryptedReasoningContent"}.getStr(""))
                                     else: none(string),
          reasoningId: if thinkingRow.reasoningId.len > 0: some(thinkingRow.reasoningId) else: none(string),
          providerSpecific: if thinkingJson.hasKey("providerSpecific"): 
                              some(thinkingJson{"providerSpecific"})
                            else: none(JsonNode)
        )
        result.add(thinkingContent)
      
      debug(fmt"Retrieved {result.len} thinking tokens for conversation {conversationId}")
    except Exception as e:
      error(fmt"Failed to retrieve thinking token history: {e.msg}")

proc getThinkingTokensByImportance*(pool: Pool, conversationId: int, 
                                   importance: string, limit: int = 20): seq[ThinkingContent] =
  ## Get thinking tokens filtered by importance level (low/medium/high)
  result = @[]
  pool.withDb:
    let query = """
      SELECT thinking_content, provider_format, importance_level, token_count,
             keywords, context_id, reasoning_id, created_at
      FROM conversation_thinking_token 
      WHERE conversation_id = ? AND importance_level = ?
      ORDER BY created_at DESC 
      LIMIT ?
    """
    
    try:
      let thinkingRows = db.query(ThinkingTokenRow, query, conversationId, importance, limit)
      
      for thinkingRow in thinkingRows:
        # Parse the JSON thinking content back to ThinkingContent
        let thinkingJson = parseJson(thinkingRow.thinkingContent)
        
        let thinkingContent = ThinkingContent(
          reasoningContent: if thinkingJson.hasKey("reasoningContent"): 
                              some(thinkingJson{"reasoningContent"}.getStr("")) 
                            else: none(string),
          encryptedReasoningContent: if thinkingJson.hasKey("encryptedReasoningContent"): 
                                       some(thinkingJson{"encryptedReasoningContent"}.getStr(""))
                                     else: none(string),
          reasoningId: if thinkingRow.reasoningId.len > 0: some(thinkingRow.reasoningId) else: none(string),
          providerSpecific: if thinkingJson.hasKey("providerSpecific"): 
                              some(thinkingJson{"providerSpecific"})
                            else: none(JsonNode)
        )
        result.add(thinkingContent)
      
      debug(fmt"Retrieved {result.len} thinking tokens with {importance} importance for conversation {conversationId}")
    except Exception as e:
      error(fmt"Failed to retrieve thinking tokens by importance: {e.msg}")

proc storeThinkingTokenFromStreaming*(content: string, format: ThinkingTokenFormat, 
                                     messageId: Option[int] = none(int), 
                                     isEncrypted: bool = false): Option[int] =
  ## Store thinking token from streaming response in current conversation (thread-safe)
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Store thinking token if pool is available
      if globalSession.pool != nil and globalSession.conversationId > 0 and content.len > 0:
        # Create ThinkingContent from streaming data
        let thinkingContent = if isEncrypted:
          ThinkingContent(
            reasoningContent: none(string),
            encryptedReasoningContent: some(content),
            reasoningId: none(string),
            providerSpecific: some(%*{"format": $format, "timestamp": epochTime()})
          )
        else:
          ThinkingContent(
            reasoningContent: some(content),
            encryptedReasoningContent: none(string),
            reasoningId: none(string),
            providerSpecific: some(%*{"format": $format, "timestamp": epochTime()})
          )
        
        let thinkingId = addThinkingTokenToDb(globalSession.pool, globalSession.conversationId, 
                                            thinkingContent, messageId, format, "medium")
        debug(fmt"Stored thinking token from streaming: {format} format, {content.len} chars")
        return some(thinkingId)
      else:
        debug("Cannot store thinking token: no database pool or conversation ID")
        return none(int)
    except Exception as e:
      error(fmt"Failed to store thinking token from streaming: {e.msg}")
      return none(int)
    finally:
      release(globalSession.lock)

proc getRecentThinkingTokens*(maxTokens: int = 10): seq[ThinkingContent] =
  ## Get recent thinking tokens from current conversation for analysis
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Use database if available
      if globalSession.pool != nil and globalSession.conversationId > 0:
        result = getThinkingTokenHistory(globalSession.pool, globalSession.conversationId, maxTokens)
        debug(fmt"Retrieved {result.len} recent thinking tokens from database")
        return result
      
      # Fallback: no thinking tokens if no database
      result = @[]
      debug("No database available, returning empty thinking token history")
    finally:
      release(globalSession.lock)

