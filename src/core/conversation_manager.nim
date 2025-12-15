## Conversation Management Module
##
## This module provides comprehensive conversation management functionality:
## - Create, list, switch, archive, and delete conversations
## - Maintain conversation metadata (mode, model, activity)
## - Handle conversation session state
## - Integrate with database for persistence

import std/[options, strformat, times, logging, locks, strutils, sequtils, json, sets]
import ../types/[mode, messages, thinking_tokens]
import ../tokenization/tokenizer
import database
import debby/pools
import debby/mysql

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

proc updateCurrentSessionMode*(mode: AgentMode) =
  ## Update the current session's conversation mode (thread-safe)
  acquire(globalSession.lock)
  try:
    if currentSession.isSome():
      var session = currentSession.get()
      session.conversation.mode = mode
      currentSession = some(session)
  finally:
    release(globalSession.lock)

proc initSessionManager*(pool: Pool = nil) {.gcsafe.}

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

  # Initialize session manager for token tracking
  initSessionManager(backend.pool)

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
proc initSessionManager*(pool: Pool = nil) {.gcsafe.} =
  ## Initialize session manager with database pool for thread-safe operations
  acquire(globalSession.lock)
  try:
    globalSession.pool = pool
    globalSession.sessionPromptTokens = 0
    globalSession.sessionCompletionTokens = 0
    globalSession.appStartTime = now()
    debug("Initialized session manager")
  finally:
    release(globalSession.lock)


proc getCurrentConversationId*(): int64 =
  ## Get the current conversation ID for database operations
  {.gcsafe.}:
    let currentSessionOpt = getCurrentSession()
    if currentSessionOpt.isNone():
      result = 0
    else:
      result = currentSessionOpt.get().conversation.id.int64
proc addUserMessage*(content: string): Message =
  ## Add user message to current conversation and persist to database
  let conversationId = getCurrentConversationId().int  # Get ID before acquiring lock to avoid deadlock
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and conversationId > 0:
        discard addUserMessageToDb(globalSession.pool, conversationId, content)
        # Update message count
        let backend = getGlobalDatabase()
        if backend != nil:
          updateConversationMessageCount(backend, conversationId)

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
                          outputTokens: int = 0, modelName: string = ""): tuple[message: Message, messageId: int] =
  ## Add assistant message to current conversation with optional tool calls and token data
  ## Returns both the Message object and the database message ID
  let conversationId = getCurrentConversationId().int  # Get ID before acquiring lock to avoid deadlock
  var msgId = 0
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and conversationId > 0:
        let toolInfo = if toolCalls.isSome(): fmt" with {toolCalls.get().len} tool calls" else: ""
        debug(fmt"[DB-INSERT] Assistant message: conv={conversationId}, content_len={content.len}{toolInfo}, model={modelName}")
        msgId = addAssistantMessageToDb(globalSession.pool, conversationId, content, toolCalls, modelName, outputTokens)
        # Update message count
        let backend = getGlobalDatabase()
        if backend != nil:
          updateConversationMessageCount(backend, conversationId)

      result = (
        message: Message(
          role: mrAssistant,
          content: content,
          toolCalls: toolCalls
        ),
        messageId: msgId
      )

      let callsInfo = if toolCalls.isSome(): fmt" (with {toolCalls.get().len} tool calls)" else: ""
      debug(fmt"Added assistant message (id={msgId}): {content[0..min(50, content.len-1)]}...{callsInfo}")
      debug(fmt"[DB-INSERT] Completed successfully")

      # Invalidate conversation context cache
      invalidateConversationCache()
    finally:
      release(globalSession.lock)

proc addToolMessage*(content: string, toolCallId: string): Message =
  ## Add tool result message to current conversation with tool call ID reference
  let conversationId = getCurrentConversationId().int  # Get ID before acquiring lock to avoid deadlock
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Add to database if pool is available
      if globalSession.pool != nil and conversationId > 0:
        debug(fmt"[DB-INSERT] Tool message: conv={conversationId}, content_len={content.len}, tool_call_id={toolCallId}")
        discard addToolMessageToDb(globalSession.pool, conversationId, content, toolCallId)
        # Update message count
        let backend = getGlobalDatabase()
        if backend != nil:
          updateConversationMessageCount(backend, conversationId)

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
  let conversationId = getCurrentConversationId().int  # Get ID before acquiring lock to avoid deadlock
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Use database if available
      if globalSession.pool != nil and conversationId > 0:
        result = getRecentMessagesFromDb(globalSession.pool, conversationId, maxMessages)
        debug(fmt"Retrieved {result.len} recent messages from database")
        return result

      # Fallback: no messages if no database
      result = @[]
      debug("No database available, returning empty message history")
    finally:
      release(globalSession.lock)

proc getConversationContext*(): seq[Message] {.gcsafe.} =
  ## Get full conversation context for LLM requests (includes all message types)
  ## Simplified: always fetch from database to avoid cache mutation issues
  let conversationId = getCurrentConversationId().int
  {.gcsafe.}:
    if globalSession.pool != nil and conversationId > 0:
      var toolCallCount: int
      (result, toolCallCount) = getConversationContextFromDb(globalSession.pool, conversationId)
      debug(fmt"Retrieved {result.len} messages from database with {toolCallCount} tool calls")

proc validateCacheIntegrity*(): bool =
  ## Verify cached messages match database
  if not cacheValid:
    debug("Cache validation skipped: cache not valid")
    return true

  if globalSession.pool == nil:
    debug("Cache validation skipped: no database pool")
    return true

  try:
    let freshMessages = getConversationContextFromDb(
      globalSession.pool,
      cachedContext.conversationId
    ).messages

    if freshMessages.len != cachedContext.messages.len:
      error(fmt"Cache length mismatch! Cache: {cachedContext.messages.len}, DB: {freshMessages.len}")
      return false

    for i in 0..<cachedContext.messages.len:
      let cached = cachedContext.messages[i]
      let fresh = freshMessages[i]

      # Compare tool call IDs
      if cached.toolCalls.isSome() and fresh.toolCalls.isSome():
        var cachedIds: HashSet[string]
        for tc in cached.toolCalls.get():
          cachedIds.incl(tc.id)
        var freshIds: HashSet[string]
        for tc in fresh.toolCalls.get():
          freshIds.incl(tc.id)

        if cachedIds != freshIds:
          error(fmt"Cache mismatch at message {i}!")
          var cachedSeq: seq[string] = @[]
          for id in cachedIds:
            cachedSeq.add(id)
          var freshSeq: seq[string] = @[]
          for id in freshIds:
            freshSeq.add(id)
          let cachedStr = cachedSeq.join(", ")
          let freshStr = freshSeq.join(", ")
          error(fmt"  Cached IDs: {cachedStr}")
          error(fmt"  Fresh IDs: {freshStr}")
          return false
      elif cached.toolCalls.isSome() != fresh.toolCalls.isSome():
        error(fmt"Cache mismatch at message {i}: toolCalls presence differs!")
        return false

    debug("Cache validation passed: cached messages match database")
    return true
  except Exception as e:
    error(fmt"Cache validation error: {e.msg}")
    return false


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

proc getCurrentMessageId*(): int64 =
  ## Get the current message ID (placeholder implementation)
  result = 0

# Thinking Token Management Functions

proc addThinkingTokenToDb*(pool: Pool, conversationId: int, thinkingContent: ThinkingContent, 
                          messageId: Option[int] = none(int), format: ThinkingTokenFormat = ttfNone,
                          importance: string = "medium"): int =
  ## Add thinking token to database and return the assigned ID
  pool.withDb:
    # Extract content from ThinkingContent blocks
    let content = if thinkingContent.blocks.len > 0:
                    thinkingContent.blocks[0].content  # For now, just get first block
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
    # Build query with direct limit value instead of parameter to avoid binding issues
    let query = fmt"""
      SELECT thinking_content, provider_format, importance_level, token_count,
             keywords, context_id, reasoning_id, created_at
      FROM conversation_thinking_token
      WHERE conversation_id = {conversationId}
      ORDER BY created_at DESC
      LIMIT {limit}
    """

    try:
      let thinkingRows = db.query(ThinkingTokenRow, query)

      for thinkingRow in thinkingRows:
        # Parse the JSON thinking content back to ThinkingContent
        let thinkingJson = parseJson(thinkingRow.thinkingContent)

        # Parse thinking content from JSON
        var thinkingContent: ThinkingContent

        # Check if it's the new format with blocks or old format
        if thinkingJson.hasKey("blocks"):
          # New format with blocks
          var blocks: seq[ThinkingBlock] = @[]
          for blockJson in thinkingJson["blocks"]:
            blocks.add(ThinkingBlock(
              id: blockJson["id"].getStr(),
              position: blockJson["position"].getInt(),
              blockType: parseEnum[ThinkingBlockType](blockJson["blockType"].getStr()),
              content: blockJson["content"].getStr(),
              timestamp: blockJson["timestamp"].getFloat(),
              providerType: blockJson{"providerType"}.getStr("unknown"),
              isEncrypted: blockJson{"isEncrypted"}.getBool(false),
              metadata: if blockJson.hasKey("metadata"): blockJson["metadata"] else: newJObject()
            ))

          thinkingContent = ThinkingContent(
            messageId: if thinkingJson.hasKey("messageId"): some(thinkingJson{"messageId"}.getInt()) else: none(int),
            totalTokens: thinkingJson{"totalTokens"}.getInt(0),
            blocks: blocks,
            reasoningId: if thinkingJson.hasKey("reasoningId"): some(thinkingJson{"reasoningId"}.getStr()) else: none(string)
          )
        else:
          # Old format - convert to new structure
          let content = if thinkingJson.hasKey("reasoningContent"):
                          some(thinkingJson{"reasoningContent"}.getStr())
                        elif thinkingJson.hasKey("encryptedReasoningContent"):
                          some(thinkingJson{"encryptedReasoningContent"}.getStr())
                        else: some("")

          thinkingContent = ThinkingContent(
            messageId: if thinkingJson.hasKey("messageId"): some(thinkingJson{"messageId"}.getInt()) else: none(int),
            totalTokens: thinkingJson{"totalTokens"}.getInt(0),
            blocks: if content.isSome():
              @[ThinkingBlock(
                id: "legacy_" & epochTime().int.toHex,
                position: 0,
                blockType: tbtPre,
                content: content.get(),
                timestamp: epochTime(),
                providerType: "legacy",
                isEncrypted: thinkingJson.hasKey("encryptedReasoningContent"),
                metadata: newJObject()
              )]
            else: @[],
            reasoningId: if thinkingJson.hasKey("reasoningId"): some(thinkingJson{"reasoningId"}.getStr()) else: none(string)
          )
        result.add(thinkingContent)

      debug(fmt"Retrieved {result.len} thinking tokens for conversation {conversationId}")
    except Exception as e:
      error(fmt"Failed to retrieve thinking token history: {e.msg}")
      raise

proc getThinkingTokensByImportance*(pool: Pool, conversationId: int,
                                   importance: string, limit: int = 20): seq[ThinkingContent] =
  ## Get thinking tokens filtered by importance level (low/medium/high)
  result = @[]
  pool.withDb:
    # Build query with direct values instead of parameters to avoid binding issues
    let query = fmt"""
      SELECT thinking_content, provider_format, importance_level, token_count,
             keywords, context_id, reasoning_id, created_at
      FROM conversation_thinking_token
      WHERE conversation_id = {conversationId} AND importance_level = '{importance}'
      ORDER BY created_at DESC
      LIMIT {limit}
    """

    try:
      let thinkingRows = db.query(ThinkingTokenRow, query)

      for thinkingRow in thinkingRows:
        # Parse the JSON thinking content back to ThinkingContent
        let thinkingJson = parseJson(thinkingRow.thinking_content)

        # Parse thinking content from JSON
        var thinkingContent: ThinkingContent

        # Check if it's the new format with blocks or old format
        if thinkingJson.hasKey("blocks"):
          # New format with blocks
          var blocks: seq[ThinkingBlock] = @[]
          for blockJson in thinkingJson["blocks"]:
            blocks.add(ThinkingBlock(
              id: blockJson["id"].getStr(),
              position: blockJson["position"].getInt(),
              blockType: parseEnum[ThinkingBlockType](blockJson["blockType"].getStr()),
              content: blockJson["content"].getStr(),
              timestamp: blockJson["timestamp"].getFloat(),
              providerType: blockJson{"providerType"}.getStr("unknown"),
              isEncrypted: blockJson{"isEncrypted"}.getBool(false),
              metadata: if blockJson.hasKey("metadata"): blockJson["metadata"] else: newJObject()
            ))
          thinkingContent = ThinkingContent(
            messageId: if thinkingJson.hasKey("messageId"): some(thinkingJson{"messageId"}.getInt()) else: none(int),
            totalTokens: thinkingJson{"totalTokens"}.getInt(0),
            blocks: blocks,
            reasoningId: if thinkingJson.hasKey("reasoningId"): some(thinkingJson{"reasoningId"}.getStr()) else: none(string)
          )
        else:
          # Old format - convert to new structure
          let content = if thinkingJson.hasKey("reasoningContent"):
                          some(thinkingJson{"reasoningContent"}.getStr())
                        elif thinkingJson.hasKey("encryptedReasoningContent"):
                          some(thinkingJson{"encryptedReasoningContent"}.getStr())
                        else: some("")
          thinkingContent = ThinkingContent(
            messageId: if thinkingJson.hasKey("messageId"): some(thinkingJson{"messageId"}.getInt()) else: none(int),
            totalTokens: thinkingJson{"totalTokens"}.getInt(0),
            blocks: if content.isSome():
              @[ThinkingBlock(
                id: "legacy_" & epochTime().int.toHex,
                position: 0,
                blockType: tbtPre,
                content: content.get(),
                timestamp: epochTime(),
                providerType: "legacy",
                isEncrypted: thinkingJson.hasKey("encryptedReasoningContent"),
                metadata: newJObject()
              )]
            else: @[],
            reasoningId: if thinkingJson.hasKey("reasoningId"): some(thinkingJson{"reasoningId"}.getStr()) else: none(string)
          )
        result.add(thinkingContent)
      
      debug(fmt"Retrieved {result.len} thinking tokens with {importance} importance for conversation {conversationId}")
    except Exception as e:
      error(fmt"Failed to retrieve thinking tokens by importance: {e.msg}")

proc storeThinkingTokenFromStreaming*(content: string, format: ThinkingTokenFormat,
                                     messageId: Option[int] = none(int),
                                     isEncrypted: bool = false): Option[int] =
  ## Store thinking token from streaming response in current conversation (thread-safe)
  let conversationId = getCurrentConversationId().int  # Get ID before acquiring lock to avoid deadlock
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Store thinking token if pool is available
      if globalSession.pool != nil and conversationId > 0 and content.len > 0:
        # Create ThinkingContent from streaming data
        let thinkingContent = ThinkingContent(
          messageId: messageId,
          totalTokens: content.len div 4,
          blocks: @[ThinkingBlock(
            id: "stream_" & epochTime().int.toHex,
            position: 0,
            blockType: tbtPre,
            content: content,
            timestamp: epochTime(),
            providerType: $format,
            isEncrypted: isEncrypted,
            metadata: %*{"format": $format, "timestamp": epochTime()}
          )],
          reasoningId: none(string)
        )

        let thinkingId = addThinkingTokenToDb(globalSession.pool, conversationId,
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
  let conversationId = getCurrentConversationId().int  # Get ID before acquiring lock to avoid deadlock
  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      # Use database if available
      if globalSession.pool != nil and conversationId > 0:
        result = getThinkingTokenHistory(globalSession.pool, conversationId, maxTokens)
        debug(fmt"Retrieved {result.len} recent thinking tokens from database")
        return result

      # Fallback: no thinking tokens if no database
      result = @[]
      debug("No database available, returning empty thinking token history")
    finally:
      release(globalSession.lock)

proc linkPendingThinkingTokensToMessage*(messageId: int): int {.gcsafe.} =
  ## Link all unlinked thinking tokens (message_id = 0) in current conversation to the given message
  ## Returns the number of thinking tokens that were linked
  let conversationId = getCurrentConversationId().int
  if messageId <= 0 or conversationId <= 0:
    return 0

  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      if globalSession.pool != nil:
        globalSession.pool.withDb:
          # Update all thinking tokens with message_id = 0 for this conversation
          db.query("""
            UPDATE conversation_thinking_token
            SET message_id = ?
            WHERE conversation_id = ? AND (message_id = 0 OR message_id IS NULL)
          """, messageId, conversationId)

          # Get count of updated rows
          let countRows = db.query("""
            SELECT COUNT(*) FROM conversation_thinking_token
            WHERE conversation_id = ? AND message_id = ?
          """, conversationId, messageId)

          if countRows.len > 0:
            result = parseInt(countRows[0][0])
            if result > 0:
              debug(fmt"Linked {result} thinking tokens to message {messageId}")
          else:
            result = 0
      else:
        result = 0
    except Exception as e:
      error(fmt"Failed to link thinking tokens to message: {e.msg}")
      result = 0
    finally:
      release(globalSession.lock)

# ============================================================================
# New Interleaved Thinking Block Functions
# ============================================================================

proc addThinkingBlock*(pool: Pool, conversationId: int, messageId: int,
                     thinkingBlock: ThinkingBlock): int =
  ## Store a single thinking block with position tracking
  if pool == nil or messageId == 0:
    return 0

  var result = 0
  pool.withDb:
    try:
      # Create MessageThinkingBlock object for insertion
      var mtb = MessageThinkingBlock(
        id: 0,
        messageId: messageId,
        positionIndex: thinkingBlock.position,
        blockType: $thinkingBlock.blockType,
        blockId: thinkingBlock.id,
        content: thinkingBlock.content,
        timestamp: thinkingBlock.timestamp,
        isEncrypted: thinkingBlock.isEncrypted,
        metadata: if thinkingBlock.metadata != nil: $thinkingBlock.metadata else: "{}",
        tokenCount: thinkingBlock.content.len div 4,
      )
      mtb.reasoningId = thinkingBlock.reasoningId

      # Insert and get back the ID
      db.insert(mtb)
      result = mtb.id

      debug(fmt"Stored thinking block {thinkingBlock.id} at position {thinkingBlock.position} for message {messageId}")
    except Exception as e:
      error(fmt"Failed to add thinking block: {e.msg}")
      result = 0

  return result


proc storeThinkingBlockFromStreaming*(conversationId: int, blockType: ThinkingBlockType,
                                     content: string, providerType: string,
                                     position: int): Option[ThinkingBlock] =
  ## Store thinking block from streaming response with position
  let pool = globalSession.pool
  if pool == nil:
    return none(ThinkingBlock)

  {.gcsafe.}:
    acquire(globalSession.lock)
    try:
      let thinkingBlock = ThinkingBlock(
        id: "tb_" & epochTime().int.toHex & "_" & position.toHex,
        position: position,
        blockType: blockType,
        content: content,
        timestamp: epochTime(),
        providerType: providerType,
        isEncrypted: false,
        metadata: newJObject()
      )

      let messageId = getCurrentConversationId()
      if messageId != 0:
        discard addThinkingBlock(pool, conversationId, messageId.int, thinkingBlock)
        debug(fmt"Stored thinking block from streaming: {blockType} at position {position}")
        return some(thinkingBlock)
      else:
        warn("Cannot store thinking block: no current message")
        return none(ThinkingBlock)
    except Exception as e:
      error(fmt"Failed to store thinking block from streaming: {e.msg}")
      return none(ThinkingBlock)
    finally:
      release(globalSession.lock)


