import std/[options, tables, strformat, os, times, strutils, algorithm, logging, json, sequtils]
import ../types/[config, messages, mode]
import config
import debby/sqlite
import debby/pools

type
  DatabaseBackendKind* = enum
    dbkSQLite
    dbkTiDB
  
  DatabaseBackend* = ref object
    config*: DatabaseConfig
    case kind*: DatabaseBackendKind
    of dbkSQLite, dbkTiDB:
      pool*: Pool
  
  TokenLogEntry* = ref object of RootObj
    id*: int
    created_at*: DateTime
    model*: string
    inputTokens*: int
    outputTokens*: int
    totalTokens*: int
    inputCost*: float
    outputCost*: float
    totalCost*: float
    request*: string
    response*: string
  
  PromptHistoryEntry* = ref object of RootObj
    id*: int
    created_at*: DateTime
    userPrompt*: string
    assistantResponse*: string
    model*: string
    sessionId*: string

  # New types for conversation tracking
  Conversation* = ref object of RootObj
    id*: int
    created_at*: DateTime
    updated_at*: DateTime
    sessionId*: string
    title*: string
    isActive*: bool
    mode*: AgentMode
    modelNickname*: string
    messageCount*: int
    lastActivity*: DateTime

  ConversationSession* = object
    conversation*: Conversation
    isActive*: bool
    startedAt*: DateTime

  ConversationMessage* = ref object of RootObj
    id*: int
    conversationId*: int
    created_at*: DateTime
    role*: string
    content*: string
    toolCallId*: Option[string]
    model*: string
    inputTokens*: int
    outputTokens*: int
    inputCost*: float
    outputCost*: float
    # New fields for tool call storage
    toolCalls*: Option[string]  # JSON array of LLMToolCall
    sequenceId*: Option[int]    # Sequence ID for ordering
    messageType*: string        # 'content', 'tool_call', 'tool_result'

  ModelTokenUsage* = ref object of RootObj
    id*: int
    conversationId*: int
    messageId*: int
    created_at*: DateTime
    model*: string
    inputTokens*: int
    outputTokens*: int
    inputCost*: float
    outputCost*: float
    totalCost*: float

  # Todo system types
  TodoList* = ref object of RootObj
    id*: int
    conversationId*: int
    title*: string
    description*: string
    createdAt*: DateTime
    updatedAt*: DateTime
    isActive*: bool

  TodoState* = enum
    tsPending = "pending"
    tsInProgress = "in_progress" 
    tsCompleted = "completed"
    tsCancelled = "cancelled"

  TodoPriority* = enum
    tpLow = "low"
    tpMedium = "medium"
    tpHigh = "high"

  TodoItem* = ref object of RootObj
    id*: int
    listId*: int
    content*: string
    state*: TodoState
    priority*: TodoPriority
    createdAt*: DateTime
    updatedAt*: DateTime
    orderIndex*: int

# Helper procedures for tool call serialization
proc serializeToolCalls*(toolCalls: seq[LLMToolCall]): string =
  ## Convert LLMToolCall sequence to JSON string for database storage
  try:
    let jsonNode = %(toolCalls)
    return $jsonNode
  except Exception as e:
    error(fmt"Failed to serialize tool calls: {e.msg}")
    return "[]"

proc deserializeToolCalls*(jsonStr: string): seq[LLMToolCall] =
  ## Convert JSON string back to LLMToolCall sequence
  try:
    let jsonNode = parseJson(jsonStr)
    return to(jsonNode, seq[LLMToolCall])
  except Exception as e:
    error(fmt"Failed to deserialize tool calls: {e.msg}")
    return @[]

proc migrateConversationMessageSchema*(conn: sqlite.Db) =
  ## Add new columns to ConversationMessage table for tool call storage
  try:
    # Check if tool_calls column exists
    let hasToolCalls = conn.query("PRAGMA table_info(conversation_message)").anyIt(it[1] == "tool_calls")
    if not hasToolCalls:
      debug("Adding tool_calls column to conversation_message table")
      conn.query("ALTER TABLE conversation_message ADD COLUMN tool_calls TEXT")
    
    # Check if sequence_id column exists
    let hasSequenceId = conn.query("PRAGMA table_info(conversation_message)").anyIt(it[1] == "sequence_id")
    if not hasSequenceId:
      debug("Adding sequence_id column to conversation_message table")
      conn.query("ALTER TABLE conversation_message ADD COLUMN sequence_id INTEGER")
    
    # Check if message_type column exists
    let hasMessageType = conn.query("PRAGMA table_info(conversation_message)").anyIt(it[1] == "message_type")
    if not hasMessageType:
      debug("Adding message_type column to conversation_message table")
      conn.query("ALTER TABLE conversation_message ADD COLUMN message_type TEXT DEFAULT 'content'")
    
    debug("ConversationMessage schema migration completed")
  except Exception as e:
    error(fmt"Failed to migrate ConversationMessage schema: {e.msg}")

proc migrateConversationSchema*(conn: sqlite.Db) =
  ## Add new columns to Conversation table for mode and model tracking
  try:
    # Check if mode column exists
    let hasMode = conn.query("PRAGMA table_info(conversation)").anyIt(it[1] == "mode")
    if not hasMode:
      debug("Adding mode column to conversation table")
      conn.query("ALTER TABLE conversation ADD COLUMN mode TEXT DEFAULT 'plan'")
    
    # Check if model_nickname column exists  
    let hasModelNickname = conn.query("PRAGMA table_info(conversation)").anyIt(it[1] == "model_nickname")
    if not hasModelNickname:
      debug("Adding model_nickname column to conversation table")
      conn.query("ALTER TABLE conversation ADD COLUMN model_nickname TEXT DEFAULT ''")
    
    # Check if message_count column exists
    let hasMessageCount = conn.query("PRAGMA table_info(conversation)").anyIt(it[1] == "message_count")
    if not hasMessageCount:
      debug("Adding message_count column to conversation table")
      conn.query("ALTER TABLE conversation ADD COLUMN message_count INTEGER DEFAULT 0")
    
    # Check if last_activity column exists
    let hasLastActivity = conn.query("PRAGMA table_info(conversation)").anyIt(it[1] == "last_activity")
    if not hasLastActivity:
      debug("Adding last_activity column to conversation table")
      conn.query("ALTER TABLE conversation ADD COLUMN last_activity DATETIME DEFAULT CURRENT_TIMESTAMP")
    
    debug("Conversation schema migration completed")
  except Exception as e:
    error(fmt"Failed to migrate Conversation schema: {e.msg}")

proc initializeDatabase*(backend: DatabaseBackend) =
  ## This is where we create the tables if they are not already created.
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      # When running this for the first time, it will create the tables
      if not db.tableExists(TokenLogEntry):
        db.createTable(TokenLogEntry)
        # Create indexes for better performance
        db.createIndexIfNotExists(TokenLogEntry, "model")
        db.createIndexIfNotExists(TokenLogEntry, "created_at")
      
      if not db.tableExists(PromptHistoryEntry):
        db.createTable(PromptHistoryEntry)
        # Create indexes for better performance
        db.createIndexIfNotExists(PromptHistoryEntry, "created_at")
        db.createIndexIfNotExists(PromptHistoryEntry, "sessionId")
      
      # Create new conversation tracking tables
      if not db.tableExists(Conversation):
        db.createTable(Conversation)
        # Create indexes for better performance
        db.createIndexIfNotExists(Conversation, "sessionId")
        db.createIndexIfNotExists(Conversation, "isActive")
      
      if not db.tableExists(ConversationMessage):
        db.createTable(ConversationMessage)
        # Create indexes for better performance
        db.createIndexIfNotExists(ConversationMessage, "conversationId")
        db.createIndexIfNotExists(ConversationMessage, "model")
        db.createIndexIfNotExists(ConversationMessage, "created_at")
      
      # Run schema migrations to add new columns
      migrateConversationMessageSchema(db)
      migrateConversationSchema(db)
      
      if not db.tableExists(ModelTokenUsage):
        db.createTable(ModelTokenUsage)
        # Create indexes for better performance
        db.createIndexIfNotExists(ModelTokenUsage, "conversationId")
        db.createIndexIfNotExists(ModelTokenUsage, "model")
        db.createIndexIfNotExists(ModelTokenUsage, "created_at")
      
      # Create todo system tables
      if not db.tableExists(TodoList):
        db.createTable(TodoList)
        db.createIndexIfNotExists(TodoList, "conversationId")
        db.createIndexIfNotExists(TodoList, "isActive")
      
      if not db.tableExists(TodoItem):
        db.createTable(TodoItem)
        db.createIndexIfNotExists(TodoItem, "listId")
        db.createIndexIfNotExists(TodoItem, "state")
        db.createIndexIfNotExists(TodoItem, "orderIndex")

proc checkDatabase*(backend: DatabaseBackend) =
  ## Verify structure of database against model definitions
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      db.checkTable(TokenLogEntry)
      db.checkTable(PromptHistoryEntry)
      db.checkTable(Conversation)
      db.checkTable(ConversationMessage)
      db.checkTable(ModelTokenUsage)
      db.checkTable(TodoList)
      db.checkTable(TodoItem)
  echo "Database checked"

proc init*(backend: DatabaseBackend) =
  case backend.kind:
  of dbkSQLite:
    let fullPath = backend.config.path.get()
    
    try:
      # Create directory if it doesn't exist
      createDir(parentDir(fullPath))
      
      # Check if file is missing
      if not fileExists(fullPath):
        echo "Creating Sqlite3 database at: ", fullPath

      # Create connection pool
      let poolSize = backend.config.poolSize
      backend.pool = newPool()
      for i in 0 ..< poolSize:
        backend.pool.add sqlite.openDatabase(fullPath)

      # Configure connections with WAL mode and timeouts
      if backend.config.walMode or backend.config.busyTimeout > 0:
        backend.pool.withDb:
          # Enable WAL mode for better concurrency
          if backend.config.walMode:
            db.query("PRAGMA journal_mode=WAL")
            db.query("PRAGMA synchronous=NORMAL")
          
          # Set busy timeout
          if backend.config.busyTimeout > 0:
            db.query(fmt"PRAGMA busy_timeout = {backend.config.busyTimeout}")
      
      # Create tables using debby's ORM
      backend.initializeDatabase()
      
      echo "Database pool initialized successfully at: ", fullPath, " with ", poolSize, " connections"
    except Exception as e:
      error(fmt"Failed to initialize SQLite database pool: {e.msg}")
      raise e
  
  of dbkTiDB:
    #let host = db.config.host.get("localhost")
    #let port = db.config.port.get(4000)
    #let database = db.config.database.get("niffler")
    #let username = db.config.username.get("root")
    #let password = db.config.password.get("")
    
    # For now, use SQLite as a placeholder
    # In a real implementation, this would connect to TiDB using MySQL driver
    echo "Tidb backend not yet ready"
    #db.createTables()

proc close*(backend: DatabaseBackend) =
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    if cast[pointer](backend.pool) != nil:
      backend.pool.close()

proc logTokenUsage*(backend: DatabaseBackend, entry: TokenLogEntry) =
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      # Insert using debby's ORM
      db.insert(entry)

proc getTokenStats*(backend: DatabaseBackend, model: string, startDate, endDate: DateTime): tuple[totalInputTokens: int, totalOutputTokens: int, totalCost: float] =
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    # Query using debby's ORM - directly use startDate and endDate in filter
    let entries = if model.len > 0:
      backend.pool.filter(TokenLogEntry, it.model == model and it.created_at >= startDate and it.created_at <= endDate)
    else:
      backend.pool.filter(TokenLogEntry, it.created_at >= startDate and it.created_at <= endDate)
    
    # Calculate totals
    result = (0, 0, 0.0)
    for entry in entries:
      result.totalInputTokens += entry.inputTokens
      result.totalOutputTokens += entry.outputTokens
      result.totalCost += entry.totalCost

proc logPromptHistory*(backend: DatabaseBackend, entry: PromptHistoryEntry) =
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      # Insert using debby's ORM
      db.insert(entry)



proc getPromptHistory*(backend: DatabaseBackend, sessionId: string = "", maxEntries: int = 50): seq[PromptHistoryEntry] =
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    # Query using debby's ORM
    let entries = if sessionId.len > 0:
      backend.pool.filter(PromptHistoryEntry, it.sessionId == sessionId)
    else:
      # Get all entries by filtering with a condition that's always true
      backend.pool.filter(PromptHistoryEntry, it.id > 0)
    
    # Sort by created_at descending and limit results
    result = entries.sortedByIt(-it.created_at.toTime().toUnix())
    if result.len > maxEntries:
      result = result[0..<maxEntries]

proc getRecentPrompts*(backend: DatabaseBackend, maxEntries: int = 20): seq[string] =
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    # Get recent user prompts only
    let entries = backend.pool.filter(PromptHistoryEntry, it.id > 0)
    let sortedEntries = entries.sortedByIt(-it.created_at.toTime().toUnix())
    
    result = @[]
    for entry in sortedEntries:
      if entry.userPrompt.len > 0:
        result.add(entry.userPrompt)
        if result.len >= maxEntries:
          break

# Factory function to create database backend
proc createDatabaseBackend*(config: DatabaseConfig): DatabaseBackend =
  if not config.enabled:
    return nil
  
  case config.`type`:
  of dtSQLite:
    let backend = DatabaseBackend(config: config, kind: dbkSQLite)
    backend.init()
    return backend
  of dtTiDB:
    let backend = DatabaseBackend(config: config, kind: dbkTiDB)
    backend.init()
    return backend

# Helper functions
proc logTokenUsage*(backend: DatabaseBackend, model: string, inputTokens, outputTokens: int, 
                   inputCost, outputCost: float, request: string = "", response: string = "") =
  if backend == nil:
    return
  
  let entry = TokenLogEntry(
    id: 0,  # Will be set by database
    created_at: now(),
    model: model,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    totalTokens: inputTokens + outputTokens,
    inputCost: inputCost,
    outputCost: outputCost,
    totalCost: inputCost + outputCost,
    request: request,
    response: response
  )
  
  backend.logTokenUsage(entry)

proc getTokenStats*(backend: DatabaseBackend, model: string = "", days: int = 30): tuple[totalInputTokens: int, totalOutputTokens: int, totalCost: float] =
  if backend == nil:
    return (0, 0, 0.0)
  
  let endDate = now()
  let startDate = endDate - initDuration(days = days)
  
  return backend.getTokenStats(model, startDate, endDate)

# Helper functions for prompt history
proc logPromptHistory*(backend: DatabaseBackend, userPrompt: string, assistantResponse: string, 
                      model: string, sessionId: string = "") =
  if backend == nil:
    return
  
  let entry = PromptHistoryEntry(
    id: 0,  # Will be set by database
    created_at: now(),
    userPrompt: userPrompt,
    assistantResponse: assistantResponse,
    model: model,
    sessionId: sessionId
  )
  
  backend.logPromptHistory(entry)

# New conversation tracking functions
proc startConversation*(backend: DatabaseBackend, sessionId: string, title: string): int =
  ## Start a new conversation and return its ID
  if backend == nil:
    return 0
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    let conv = Conversation(
      id: 0,
      created_at: now(),
      updated_at: now(),
      sessionId: sessionId,
      title: title,
      isActive: true
    )
    backend.pool.insert(conv)
    return conv.id

proc logConversationMessage*(backend: DatabaseBackend, conversationId: int, role: string,
                           content: string, model: string, toolCallId: Option[string] = none(string),
                           inputTokens: int = 0, outputTokens: int = 0,
                           inputCost: float = 0.0, outputCost: float = 0.0) =
  ## Log a message in a conversation
  if backend == nil or conversationId == 0:
    return
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    let msg = ConversationMessage(
      id: 0,
      conversationId: conversationId,
      created_at: now(),
      role: role,
      content: content,
      toolCallId: toolCallId,
      model: model,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      inputCost: inputCost,
      outputCost: outputCost
    )
    backend.pool.insert(msg)

proc logModelTokenUsage*(backend: DatabaseBackend, conversationId: int, messageId: int,
                        model: string, inputTokens: int, outputTokens: int,
                        inputCostPerMToken: Option[float], outputCostPerMToken: Option[float]) =
  ## Log model-specific token usage for accurate cost calculation
  if backend == nil or conversationId == 0:
    return
  
  let inputCost = if inputCostPerMToken.isSome():
    float(inputTokens) * (inputCostPerMToken.get() / 1_000_000.0)
  else: 0.0
  
  let outputCost = if outputCostPerMToken.isSome():
    float(outputTokens) * (outputCostPerMToken.get() / 1_000_000.0)
  else: 0.0
  
  let totalCost = inputCost + outputCost
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    let usage = ModelTokenUsage(
      id: 0,
      conversationId: conversationId,
      messageId: messageId,
      created_at: now(),
      model: model,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      inputCost: inputCost,
      outputCost: outputCost,
      totalCost: totalCost
    )
    backend.pool.insert(usage)

proc getConversationCostBreakdown*(backend: DatabaseBackend, conversationId: int): tuple[totalCost: float, breakdown: seq[string]] =
  ## Calculate accurate cost breakdown by model for a conversation
  if backend == nil or conversationId == 0:
    return (0.0, @[])
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      # Group by model and sum costs
      let query = """
        SELECT model,
              SUM(input_tokens) as totalInputTokens,
              SUM(output_tokens) as totalOutputTokens,
              SUM(input_cost) as totalInputCost,
              SUM(output_cost) as totalOutputCost,
              SUM(total_cost) as totalModelCost
        FROM model_token_usage
        WHERE conversation_id = ?
        GROUP BY model
        ORDER BY created_at
      """
      
      let rows = db.query(query, conversationId)
      result.totalCost = 0.0
      result.breakdown = @[]
      
      for row in rows:
        let model = row[0]
        let inputTokens = parseInt(row[1])
        let outputTokens = parseInt(row[2])
        let inputCost = parseFloat(row[3])
        let outputCost = parseFloat(row[4])
        let modelCost = parseFloat(row[5])
        
        result.totalCost += modelCost
        result.breakdown.add(fmt"{model}: {inputTokens} input tokens (${inputCost:.4f}) + {outputTokens} output tokens (${outputCost:.4f}) = ${modelCost:.4f}")

# New database-backed history procedures (replaces threadvar history)
proc addUserMessageToDb*(pool: Pool, conversationId: int, content: string): int =
  ## Add user message to database and return message ID
  pool.withDb:
    let msg = ConversationMessage(
      id: 0,
      conversationId: conversationId,
      created_at: now(),
      role: "user",
      content: content,
      toolCallId: none(string),
      model: "",
      inputTokens: 0,
      outputTokens: 0,
      inputCost: 0.0,
      outputCost: 0.0,
      toolCalls: none(string),
      sequenceId: none(int),  # Let database handle ordering
      messageType: "content"
    )
    db.insert(msg)
    return msg.id

proc addAssistantMessageToDb*(pool: Pool, conversationId: int, content: string, 
                             toolCalls: Option[seq[LLMToolCall]], model: string): int =
  ## Add assistant message to database and return message ID
  pool.withDb:
    let toolCallsJson = if toolCalls.isSome():
      some(serializeToolCalls(toolCalls.get()))
    else:
      none(string)
    
    let messageType = if toolCalls.isSome(): "tool_call" else: "content"
    
    let msg = ConversationMessage(
      id: 0,
      conversationId: conversationId,
      created_at: now(),
      role: "assistant",
      content: content,
      toolCallId: none(string),
      model: model,
      inputTokens: 0,
      outputTokens: 0,
      inputCost: 0.0,
      outputCost: 0.0,
      toolCalls: toolCallsJson,
      sequenceId: none(int),  # Let database handle ordering
      messageType: messageType
    )
    db.insert(msg)
    return msg.id

proc addToolMessageToDb*(pool: Pool, conversationId: int, content: string, 
                        toolCallId: string): int =
  ## Add tool result message to database and return message ID  
  pool.withDb:
    let msg = ConversationMessage(
      id: 0,
      conversationId: conversationId,
      created_at: now(),
      role: "tool",
      content: content,
      toolCallId: some(toolCallId),
      model: "",
      inputTokens: 0,
      outputTokens: 0,
      inputCost: 0.0,
      outputCost: 0.0,
      toolCalls: none(string),
      sequenceId: none(int),  # Let database handle ordering
      messageType: "tool_result"
    )
    db.insert(msg)
    return msg.id

proc getRecentMessagesFromDb*(pool: Pool, conversationId: int, maxMessages: int = 10): seq[Message] =
  ## Get recent messages from database, converted to Message format for LLM
  pool.withDb:
    let messages = db.filter(ConversationMessage, it.conversationId == conversationId)
    let sortedMessages = messages.sortedByIt(it.id)  # Sort by auto-incrementing ID for chronological order
    
    result = @[]
    let startIdx = max(0, sortedMessages.len - maxMessages)
    
    for i in startIdx..<sortedMessages.len:
      let dbMsg = sortedMessages[i]
      
      # Convert database message to LLM Message
      case dbMsg.role:
      of "user":
        result.add(Message(role: mrUser, content: dbMsg.content))
      of "assistant":
        let toolCalls = if dbMsg.toolCalls.isSome():
          some(deserializeToolCalls(dbMsg.toolCalls.get()))
        else:
          none(seq[LLMToolCall])
        result.add(Message(
          role: mrAssistant,
          content: dbMsg.content,
          toolCalls: toolCalls
        ))
      of "tool":
        result.add(Message(
          role: mrTool,
          content: dbMsg.content,
          toolCallId: dbMsg.toolCallId
        ))
      else:
        debug(fmt"Skipping message with unknown role: {dbMsg.role}")

proc getConversationContextFromDb*(pool: Pool, conversationId: int): tuple[messages: seq[Message], toolCallCount: int] =
  ## Get conversation context with tool call count for /context command
  pool.withDb:
    let messages = db.filter(ConversationMessage, it.conversationId == conversationId)
    let sortedMessages = messages.sortedByIt(it.id)  # Sort by auto-incrementing ID for chronological order
    
    result.messages = @[]
    result.toolCallCount = 0
    
    for dbMsg in sortedMessages:
      # Count tool calls
      if dbMsg.toolCalls.isSome():
        let toolCalls = deserializeToolCalls(dbMsg.toolCalls.get())
        result.toolCallCount += toolCalls.len
      
      # Convert to Message format
      case dbMsg.role:
      of "user":
        result.messages.add(Message(role: mrUser, content: dbMsg.content))
      of "assistant":
        let toolCalls = if dbMsg.toolCalls.isSome():
          some(deserializeToolCalls(dbMsg.toolCalls.get()))
        else:
          none(seq[LLMToolCall])
        result.messages.add(Message(
          role: mrAssistant,
          content: dbMsg.content,
          toolCalls: toolCalls
        ))
      of "tool":
        result.messages.add(Message(
          role: mrTool,
          content: dbMsg.content,
          toolCallId: dbMsg.toolCallId
        ))

# Global database instance - not threadvar anymore to avoid thread isolation
var globalDatabase: DatabaseBackend

# Forward declaration for getGlobalDatabase
proc initializeGlobalDatabase*(level: Level): DatabaseBackend

proc getGlobalDatabase*(): DatabaseBackend =
  ## Get the global database instance, attempting to initialize if nil
  if globalDatabase == nil:
    try:
      debug("Global database is nil, attempting to initialize")
      globalDatabase = initializeGlobalDatabase(lvlWarn)
    except Exception as e:
      error(fmt"Failed to initialize global database: {e.msg}")
      return nil
  result = globalDatabase

proc setGlobalDatabase*(db: DatabaseBackend) =
  ## Set the global database instance
  globalDatabase = db

proc verifyDatabaseHealth*(): bool =
  ## Verify that the database is healthy and all required tables exist
  let database = getGlobalDatabase()
  if database == nil:
    return false
  
  case database.kind:
  of dbkSQLite, dbkTiDB:
    database.pool.withDb:
      try:
        # Check if all required tables exist
        if not db.tableExists(TokenLogEntry):
          warn("TokenLogEntry table missing")
          return false
        if not db.tableExists(PromptHistoryEntry):
          warn("PromptHistoryEntry table missing")
          return false
        if not db.tableExists(Conversation):
          warn("Conversation table missing")
          return false
        if not db.tableExists(ConversationMessage):
          warn("ConversationMessage table missing")
          return false
        if not db.tableExists(ModelTokenUsage):
          warn("ModelTokenUsage table missing")
          return false
        
        debug("Database health check passed")
        return true
      except Exception as e:
        error(fmt"Database health check failed: {e.msg}")
        return false

proc initializeGlobalDatabase*(level: Level): DatabaseBackend =
  ## Initialize global database backend from configuration
  try:
    let config = loadConfig()
    if config.database.isSome():
      let dbConfig = config.database.get()
      if dbConfig.enabled:
        result = createDatabaseBackend(dbConfig)
        if result != nil:
          debug("Database backend initialized successfully")
          setGlobalDatabase(result)  # Set the global database instance
        else:
          error("Failed to create database backend")
          result = nil
      else:
        debug("Database backend disabled in configuration")
        result = nil
    else:
      # No database configuration found - create default SQLite configuration
      debug("No database configuration found, creating default SQLite database")
      let defaultDbConfig = DatabaseConfig(
        `type`: dtSQLite,
        enabled: true,
        path: some(getDefaultSqlitePath()),
        walMode: true,
        busyTimeout: 5000,
        poolSize: 10
      )
      
      result = createDatabaseBackend(defaultDbConfig)
      if result != nil:
        debug("Default database backend initialized successfully")
        setGlobalDatabase(result)
      else:
        error("Failed to create default database backend")
        result = nil
  except Exception as e:
    error(fmt"Failed to initialize database backend: {e.msg}")
    result = nil

# Todo system database functions
proc createTodoList*(backend: DatabaseBackend, conversationId: int, title: string, description: string = ""): int =
  ## Create a new todo list and return its ID
  if backend == nil:
    return 0
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      let todoList = TodoList(
        id: 0,
        conversationId: conversationId,
        title: title,
        description: description,
        createdAt: now(),
        updatedAt: now(),
        isActive: true
      )
      db.insert(todoList)
      return todoList.id

proc addTodoItem*(backend: DatabaseBackend, listId: int, content: string, priority: TodoPriority = tpMedium): int =
  ## Add a new todo item to a list
  if backend == nil:
    return 0
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      
      # Get the next order index
      let existingItems = db.filter(TodoItem, it.listId == listId)
      let nextOrder = if existingItems.len > 0: existingItems.len else: 0
      
      let todoItem = TodoItem(
        id: 0,
        listId: listId,
        content: content,
        state: tsPending,
        priority: priority,
        createdAt: now(),
        updatedAt: now(),
        orderIndex: nextOrder
      )
      db.insert(todoItem)
      return todoItem.id

proc updateTodoItem*(backend: DatabaseBackend, itemId: int, newState: Option[TodoState] = none(TodoState),
                    newContent: Option[string] = none(string), newPriority: Option[TodoPriority] = none(TodoPriority)): bool =
  ## Update a todo item's state, content, or priority
  if backend == nil:
    return false
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      
      let items = db.filter(TodoItem, it.id == itemId)
      if items.len == 0:
        return false
      
      var item = items[0]
      item.updatedAt = now()
      
      if newState.isSome():
        item.state = newState.get()
      if newContent.isSome():
        item.content = newContent.get()
      if newPriority.isSome():
        item.priority = newPriority.get()
      
      db.update(item)
      return true

proc getTodoItems*(backend: DatabaseBackend, listId: int): seq[TodoItem] =
  ## Get all todo items for a list, sorted by order index
  if backend == nil:
    return @[]
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:    
      let items = db.filter(TodoItem, it.listId == listId)
      return items.sortedByIt(it.orderIndex)

proc getActiveTodoList*(backend: DatabaseBackend, conversationId: int): Option[TodoList] =
  ## Get the active todo list for a conversation
  if backend == nil:
    return none(TodoList)
  
  case backend.kind:
  of dbkSQLite, dbkTiDB:
    backend.pool.withDb:
      let lists = db.filter(TodoList, it.conversationId == conversationId and it.isActive == true)
      if lists.len > 0:
        return some(lists[0])
      else:
        return none(TodoList)