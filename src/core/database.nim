## Database Management Module
##
## This module provides comprehensive database functionality for Niffler:
## - TiDB (MySQL-compatible) backend with connection pooling
## - Conversation management with metadata tracking
## - Message persistence with tool call support
## - Token usage logging and cost tracking
## - Thinking token storage and retrieval
## - Automatic database migrations and schema management
##
## Architecture:
## - Uses debby for MySQL database abstraction with connection pooling
## - Thread-safe operations with proper transaction handling
## - Efficient querying with prepared statements and indexing

import std/[options, tables, strformat, times, strutils, algorithm, logging, json, sequtils]
import ../types/[config, messages, mode]
import config
import debby/mysql
import debby/pools

type
  DatabaseBackend* = ref object
    config*: DatabaseConfig
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
    planModeEnteredAt*: DateTime  # When plan mode was entered (default epoch if never entered)
    planModeCreatedFiles*: string  # JSON array of files created during this plan mode session
    parentConversationId*: Option[int]  # Link to parent conversation if this is a condensed conversation
    condensedFromMessageCount*: int  # Number of messages in original before condensation
    condensationStrategy*: string  # Strategy used: "llm_summary", "truncate", "smart_window"
    condensationMetadata*: string  # JSON metadata: timestamp, token savings, etc.

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
    outputTokens*: int          # Only output tokens for assistant messages
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
    reasoningTokens*: int          # New: thinking token count
    reasoningCost*: float          # New: thinking token cost

  # New table for conversation thinking token storage
  ConversationThinkingToken* = ref object of RootObj
    id*: int
    conversationId*: int
    messageId*: Option[int]         # Optional link to specific message
    created_at*: DateTime
    thinkingContent*: string       # JSON blob of ThinkingContent
    providerFormat*: string        # "anthropic", "openai", "encrypted", "none"
    importanceLevel*: string       # "low", "medium", "high", "essential"
    tokenCount*: int               # Estimated token count
    keywords*: string              # JSON array of extracted keywords
    contextId*: string             # Context identifier for windowing
    reasoningId*: Option[string]   # Optional reasoning correlation ID

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

  # Token correction factor system for tokenization counts
  TokenCorrectionFactor* = ref object of RootObj
    id*: int
    modelName*: string           ## Model identifier (e.g., "gpt-4", "qwen-plus")
    totalSamples*: int           ## Number of correction samples collected
    sumRatio*: float             ## Sum of actual/estimated ratios
    avgCorrection*: float        ## Current average correction factor
    createdAt*: DateTime         ## When first sample was recorded
    updatedAt*: DateTime         ## When this correction was last updated

  # System prompt token tracking
  SystemPromptTokenUsage* = ref object of RootObj
    id*: int
    conversationId*: int         ## Link to conversation
    messageId*: int              ## Link to specific message/request
    createdAt*: DateTime         ## When the request was made
    model*: string               ## Model used for request
    mode*: string                ## Agent mode (plan/code)
    basePromptTokens*: int       ## Base system prompt tokens
    modePromptTokens*: int       ## Mode-specific prompt tokens
    environmentTokens*: int      ## Environment info tokens
    instructionFileTokens*: int  ## CLAUDE.md etc. tokens
    toolInstructionTokens*: int  ## TodoList/thinking instructions
    availableToolsTokens*: int   ## Tools list tokens
    systemPromptTotal*: int      ## Total system prompt tokens
    toolSchemaTokens*: int       ## Tool schema JSON tokens
    totalOverhead*: int          ## Complete API request overhead

# Database utility functions for query building and schema operations
proc columnExists*(conn: mysql.Db, tableName: string, columnName: string): bool =
  ## Check if a column exists in a table
  let tableInfo = conn.query(fmt"SHOW COLUMNS FROM {tableName} LIKE '{columnName}'")
  return tableInfo.len > 0

proc indexExists*(conn: mysql.Db, tableName: string, indexName: string): bool =
  ## Check if an index exists in the database
  let indexList = conn.query(fmt"SHOW INDEX FROM {tableName} WHERE Key_name = '{indexName}'")
  return indexList.len > 0

proc addColumnIfNotExists*(conn: mysql.Db, tableName: string, columnName: string,
                          columnDef: string) =
  ## Add a column to a table if it doesn't already exist
  if not columnExists(conn, tableName, columnName):
    conn.query(fmt"ALTER TABLE {tableName} ADD COLUMN {columnName} {columnDef}")
    debug(fmt"Added column {columnName} to table {tableName}")

proc utcNow*(): string =
  ## Return current UTC time
  now().utc().format("yyyy-MM-dd'T'HH:mm:ss")

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

proc migrateConversationMessageSchema*(conn: mysql.Db) =
  ## Add new columns to ConversationMessage table for tool call storage
  try:
    # Add new columns using utility functions
    addColumnIfNotExists(conn, "conversation_message", "tool_calls", "TEXT")
    addColumnIfNotExists(conn, "conversation_message", "sequence_id", "INTEGER")
    addColumnIfNotExists(conn, "conversation_message", "message_type", "TEXT DEFAULT 'content'")

    debug("ConversationMessage schema migration completed")
  except Exception as e:
    error(fmt"Failed to migrate ConversationMessage schema: {e.msg}")

proc migrateModelTokenUsageSchema*(conn: mysql.Db) =
  ## Add thinking token columns to ModelTokenUsage table
  try:
    # Add thinking token columns using utility functions
    addColumnIfNotExists(conn, "model_token_usage", "reasoning_tokens", "INTEGER DEFAULT 0")
    addColumnIfNotExists(conn, "model_token_usage", "reasoning_cost", "DOUBLE DEFAULT 0.0")

    debug("ModelTokenUsage schema migration completed")
  except Exception as e:
    error(fmt"Failed to migrate ModelTokenUsage schema: {e.msg}")

proc migrateConversationSchema*(conn: mysql.Db) =
  ## Add new columns to Conversation table for mode and model tracking
  try:
    # Add new columns using utility functions
    addColumnIfNotExists(conn, "conversation", "mode", "TEXT DEFAULT 'plan'")
    addColumnIfNotExists(conn, "conversation", "model_nickname", "TEXT DEFAULT ''")
    addColumnIfNotExists(conn, "conversation", "message_count", "INTEGER DEFAULT 0")
    addColumnIfNotExists(conn, "conversation", "last_activity", "DATETIME DEFAULT CURRENT_TIMESTAMP")
    addColumnIfNotExists(conn, "conversation", "plan_mode_entered_at", "DATETIME DEFAULT '1970-01-01 00:00:00'")

    # Update any existing records that have NULL or empty values
    debug("Updating any NULL or empty plan_mode_entered_at values")
    conn.query("UPDATE conversation SET plan_mode_entered_at = '1970-01-01 00:00:00' WHERE plan_mode_entered_at IS NULL OR plan_mode_entered_at = ''")

    # Migrate to new plan_mode_created_files column (changed semantics)
    if not columnExists(conn, "conversation", "plan_mode_created_files"):
      debug("Adding plan_mode_created_files column to conversation table")
      conn.query("ALTER TABLE conversation ADD COLUMN plan_mode_created_files TEXT")
      # Clear old protection data since semantics changed completely
      debug("Clearing old plan mode protection data due to semantic change")
      conn.query("UPDATE conversation SET plan_mode_created_files = '', plan_mode_entered_at = '1970-01-01 00:00:00'")

    # Add condensation support columns
    addColumnIfNotExists(conn, "conversation", "parent_conversation_id", "INTEGER")
    addColumnIfNotExists(conn, "conversation", "condensed_from_message_count", "INTEGER DEFAULT 0")
    addColumnIfNotExists(conn, "conversation", "condensation_strategy", "TEXT DEFAULT ''")
    addColumnIfNotExists(conn, "conversation", "condensation_metadata", "TEXT DEFAULT '{}'")

    # Create index for parent conversation lookups
    if not indexExists(conn, "conversation", "idx_conversation_parent_id"):
      debug("Creating index idx_conversation_parent_id")
      conn.query("CREATE INDEX idx_conversation_parent_id ON conversation(parent_conversation_id)")

    debug("Conversation schema migration completed")
  except Exception as e:
    error(fmt"Failed to migrate Conversation schema: {e.msg}")

proc initializeDatabase*(backend: DatabaseBackend) =
  ## This is where we create the tables if they are not already created.
  backend.pool.withDb:
    # When running this for the first time, it will create the tables
    if not db.tableExists(TokenLogEntry):
      db.createTable(TokenLogEntry)
      # Create indexes for better performance (TEXT columns need key length)
      discard db.query("CREATE INDEX IF NOT EXISTS idx_token_log_entry_model ON token_log_entry (model(255))")
      db.createIndexIfNotExists(TokenLogEntry, "created_at")

    if not db.tableExists(PromptHistoryEntry):
      db.createTable(PromptHistoryEntry)
      # Create indexes for better performance (TEXT columns need key length)
      db.createIndexIfNotExists(PromptHistoryEntry, "created_at")
      discard db.query("CREATE INDEX IF NOT EXISTS idx_prompt_history_entry_session_id ON prompt_history_entry (session_id(255))")

    # Create new conversation tracking tables
    if not db.tableExists(Conversation):
      db.createTable(Conversation)
      # Create indexes for better performance (TEXT columns need key length)
      discard db.query("CREATE INDEX IF NOT EXISTS idx_conversation_session_id ON conversation (session_id(255))")
      db.createIndexIfNotExists(Conversation, "isActive")

    if not db.tableExists(ConversationMessage):
      db.createTable(ConversationMessage)
      # Create indexes for better performance (TEXT columns need key length)
      db.createIndexIfNotExists(ConversationMessage, "conversationId")
      discard db.query("CREATE INDEX IF NOT EXISTS idx_conversation_message_model ON conversation_message (model(255))")
      db.createIndexIfNotExists(ConversationMessage, "created_at")

    # Run schema migrations to add new columns
    migrateConversationMessageSchema(db)
    migrateConversationSchema(db)
    migrateModelTokenUsageSchema(db)

    if not db.tableExists(ModelTokenUsage):
      db.createTable(ModelTokenUsage)
      # Create indexes for better performance (TEXT columns need key length)
      db.createIndexIfNotExists(ModelTokenUsage, "conversationId")
      discard db.query("CREATE INDEX IF NOT EXISTS idx_model_token_usage_model ON model_token_usage (model(255))")
      db.createIndexIfNotExists(ModelTokenUsage, "created_at")

    # Create thinking token storage table
    if not db.tableExists(ConversationThinkingToken):
      db.createTable(ConversationThinkingToken)
      # Create indexes for better performance (TEXT columns need key length)
      db.createIndexIfNotExists(ConversationThinkingToken, "conversationId")
      db.createIndexIfNotExists(ConversationThinkingToken, "messageId")
      db.createIndexIfNotExists(ConversationThinkingToken, "created_at")
      discard db.query("CREATE INDEX IF NOT EXISTS idx_conversation_thinking_token_importance_level ON conversation_thinking_token (importance_level(50))")
      discard db.query("CREATE INDEX IF NOT EXISTS idx_conversation_thinking_token_provider_format ON conversation_thinking_token (provider_format(50))")

    # Create todo system tables
    if not db.tableExists(TodoList):
      db.createTable(TodoList)
      db.createIndexIfNotExists(TodoList, "conversationId")
      db.createIndexIfNotExists(TodoList, "isActive")

    if not db.tableExists(TodoItem):
      db.createTable(TodoItem)
      db.createIndexIfNotExists(TodoItem, "listId")
      discard db.query("CREATE INDEX IF NOT EXISTS idx_todo_item_state ON todo_item (state(50))")
      db.createIndexIfNotExists(TodoItem, "orderIndex")

    # Create token correction factor table
    if not db.tableExists(TokenCorrectionFactor):
      db.createTable(TokenCorrectionFactor)
      discard db.query("CREATE INDEX IF NOT EXISTS idx_token_correction_factor_model_name ON token_correction_factor (model_name(255))")
      db.createIndexIfNotExists(TokenCorrectionFactor, "updatedAt")

    # Create system prompt token usage table
    if not db.tableExists(SystemPromptTokenUsage):
      db.createTable(SystemPromptTokenUsage)
      db.createIndexIfNotExists(SystemPromptTokenUsage, "conversationId")
      db.createIndexIfNotExists(SystemPromptTokenUsage, "messageId")
      db.createIndexIfNotExists(SystemPromptTokenUsage, "createdAt")
      discard db.query("CREATE INDEX IF NOT EXISTS idx_system_prompt_token_usage_model ON system_prompt_token_usage (model(255))")

proc checkDatabase*(backend: DatabaseBackend) =
  ## Verify structure of database against model definitions
  backend.pool.withDb:
    db.checkTable(TokenLogEntry)
    db.checkTable(PromptHistoryEntry)
    db.checkTable(Conversation)
    db.checkTable(ConversationMessage)
    db.checkTable(ModelTokenUsage)
    db.checkTable(ConversationThinkingToken)
    db.checkTable(TodoList)
    db.checkTable(TodoItem)
    db.checkTable(TokenCorrectionFactor)
    db.checkTable(SystemPromptTokenUsage)
  echo "Database checked"

proc init*(backend: DatabaseBackend) =
  let host = backend.config.host
  let port = backend.config.port
  let database = backend.config.database
  let username = backend.config.username
  let password = backend.config.password

  try:
    echo fmt"Connecting to TiDB at {host}:{port}/{database}"

    # First, ensure the database exists by connecting to the mysql system database
    var dbCreated = false
    try:
      var sysDb = mysql.openDatabase("mysql", host, port, username, password)

      # Use CREATE DATABASE IF NOT EXISTS to auto-create the database
      discard sysDb.query(fmt"CREATE DATABASE IF NOT EXISTS {database}")
      dbCreated = true
      echo fmt"Verified/created database '{database}'"

      sysDb.close()
    except Exception as e:
      let errorMsg = e.msg.toLowerAscii()
      if "access denied" in errorMsg or "permission" in errorMsg:
        error(fmt"Cannot create database '{database}': permission denied")
        error("")
        error(fmt"The database user '{username}' does not have permission to create databases.")
        error("Please create the database using one of these methods:")
        error("")
        error(fmt"  1. Using mysql client (if installed):")
        error(fmt"     mysql -h {host} -P {port} -u <admin_user> -p -e " & "\"CREATE DATABASE " & database & "\"")
        error("")
        error("  2. Using TiDB Cloud console (if using cloud):")
        error("     https://tidbcloud.com - navigate to your cluster and create database")
        error("")
        error("  3. Have your database administrator create it for you")
        error("")
        raise e
      else:
        warn(fmt"Could not verify/create database: {e.msg}")
        # Continue anyway - the database might already exist

    # Create connection pool
    let poolSize = backend.config.poolSize
    backend.pool = newPool()
    for i in 0 ..< poolSize:
      try:
        backend.pool.add mysql.openDatabase(database, host, port, username, password)
      except Exception as e:
        if "Unknown database" in e.msg:
          error(fmt"Database '{database}' does not exist and could not be auto-created")
          error("")
          error("Please create the database using one of these methods:")
          error("")
          error(fmt"  1. Using mysql client (if installed):")
          error(fmt"     mysql -h {host} -P {port} -u root -p -e " & "\"CREATE DATABASE " & database & "\"")
          error("")
          error("  2. Using TiDB Cloud console (if using cloud):")
          error("     https://tidbcloud.com - navigate to your cluster and create database")
          error("")
          error("  3. Contact your database administrator")
          error("")
          raise e
        else:
          raise e

    # Create tables using debby's ORM
    backend.initializeDatabase()

    echo fmt"Database pool initialized successfully with {poolSize} connections to {host}:{port}/{database}"
  except Exception as e:
    error(fmt"Failed to initialize TiDB database pool: {e.msg}")
    raise e

proc close*(backend: DatabaseBackend) =
  if cast[pointer](backend.pool) != nil:
    backend.pool.close()

proc logTokenUsage*(backend: DatabaseBackend, entry: TokenLogEntry) =
  backend.pool.withDb:
    # Insert using debby's ORM
    db.insert(entry)

proc getTokenStats*(backend: DatabaseBackend, model: string, startDate, endDate: DateTime): tuple[totalInputTokens: int, totalOutputTokens: int, totalCost: float] =
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
  backend.pool.withDb:
    # Insert using debby's ORM
    db.insert(entry)



proc getPromptHistory*(backend: DatabaseBackend, sessionId: string = "", maxEntries: int = 50): seq[PromptHistoryEntry] =
  ## Return history entries, latest comes first in the seq
  backend.pool.withDb:
    result = if sessionId.len > 0:
      db.query(PromptHistoryEntry,
        fmt"SELECT * FROM prompt_history_entry WHERE session_id = '{sessionId}' ORDER BY created_at ASC LIMIT {maxEntries}")
    else:
      db.query(PromptHistoryEntry,
        fmt"SELECT * FROM prompt_history_entry ORDER BY created_at ASC LIMIT {maxEntries}")

proc getRecentPrompts*(backend: DatabaseBackend, maxEntries: int = 20): seq[string] =
  ## Return history prompts, latest comes first in the seq
  backend.pool.withDb:
    let entries = db.query(PromptHistoryEntry,
      fmt"SELECT * FROM prompt_history_entry WHERE user_prompt != '' ORDER BY created_at DESC LIMIT {maxEntries}")
    result = entries.map(proc(entry: PromptHistoryEntry): string = entry.userPrompt)

# Factory function to create database backend
proc createDatabaseBackend*(config: DatabaseConfig): DatabaseBackend =
  if not config.enabled:
    return nil

  let backend = DatabaseBackend(config: config)
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

  let conv = Conversation(
    id: 0,
    created_at: now().utc(),
    updated_at: now().utc(),
    sessionId: sessionId,
    title: title,
    isActive: true,
    mode: amCode,  # Default mode
    modelNickname: "default",  # Default model
    messageCount: 0,
    lastActivity: now().utc(),
    planModeEnteredAt: fromUnix(0).utc(),  # Initialize to epoch (not in plan mode)
    planModeCreatedFiles: ""  # Initialize to empty string
  )
  backend.pool.insert(conv)
  return conv.id

proc logConversationMessage*(backend: DatabaseBackend, conversationId: int, role: string,
                           content: string, model: string, toolCallId: Option[string] = none(string),
                           outputTokens: int = 0) =
  ## Log a message in a conversation
  if backend == nil or conversationId == 0:
    return

  let msg = ConversationMessage(
    id: 0,
    conversationId: conversationId,
    created_at: now().utc(),
    role: role,
    content: content,
    toolCallId: toolCallId,
    model: model,
    outputTokens: outputTokens,
    toolCalls: none(string),
    sequenceId: none(int),
    messageType: "content"
  )
  backend.pool.insert(msg)

proc logModelTokenUsage*(backend: DatabaseBackend, conversationId: int, messageId: int,
                        model: string, inputTokens: int, outputTokens: int,
                        inputCostPerMToken: Option[float], outputCostPerMToken: Option[float],
                        reasoningTokens: int = 0, reasoningCostPerMToken: Option[float] = none(float)) =
  ## Log model-specific token usage for accurate cost calculation including thinking tokens
  if backend == nil or conversationId == 0:
    return
  
  let inputCost = if inputCostPerMToken.isSome():
    float(inputTokens) * (inputCostPerMToken.get() / 1_000_000.0)
  else: 0.0
  
  let outputCost = if outputCostPerMToken.isSome():
    float(outputTokens) * (outputCostPerMToken.get() / 1_000_000.0)
  else: 0.0
  
  let reasoningCost = if reasoningCostPerMToken.isSome() and reasoningTokens > 0:
    float(reasoningTokens) * (reasoningCostPerMToken.get() / 1_000_000.0)
  else: 0.0
  
  let totalCost = inputCost + outputCost + reasoningCost

  debug(fmt"logModelTokenUsage: conversationId={conversationId}, messageId={messageId}, model={model}")
  debug(fmt"logModelTokenUsage: tokens=({inputTokens}, {outputTokens}, {reasoningTokens}), costs=({inputCost:.6f}, {outputCost:.6f}, {reasoningCost:.6f}, {totalCost:.6f})")

  let usage = ModelTokenUsage(
    id: 0,
    conversationId: conversationId,
    messageId: messageId,
    created_at: now().utc(),
    model: model,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    inputCost: inputCost,
    outputCost: outputCost,
    totalCost: totalCost,
    reasoningTokens: reasoningTokens,
    reasoningCost: reasoningCost
  )

  try:
    backend.pool.insert(usage)
    debug(fmt"Successfully inserted token usage record with ID: {usage.id}")
  except Exception as e:
    error(fmt"Failed to insert token usage to database: {e.msg}")
    error(fmt"Insert error stack trace: {e.getStackTrace()}")
    raise

type
  ConversationCostRow* = ref object of RootObj
    model*: string
    totalInputTokens*: int
    totalOutputTokens*: int
    totalReasoningTokens*: int
    totalInputCost*: float
    totalOutputCost*: float
    totalReasoningCost*: float
    totalModelCost*: float
  
  ReasoningTokenStats* = ref object of RootObj
    totalReasoning*: int
    totalOutput*: int
  
  SessionCostStats* = ref object of RootObj
    totalInputTokens*: int
    totalOutputTokens*: int
    totalReasoningTokens*: int
    totalInputCost*: float
    totalOutputCost*: float
    totalReasoningCost*: float
    totalCost*: float
    rowCount*: int
  
  TokenBreakdownRow* = ref object of RootObj
    role*: string
    totalTokens*: int
  
  ThinkingTokenRow* = ref object of RootObj
    thinkingContent*: string
    providerFormat*: string
    importanceLevel*: string
    tokenCount*: int
    keywords*: string
    contextId*: string
    reasoningId*: string
    createdAt*: DateTime

proc getConversationCostDetailed*(backend: DatabaseBackend, conversationId: int): tuple[rows: seq[ConversationCostRow], totalCost: float, totalInput: int, totalOutput: int, totalReasoning: int, totalInputCost: float, totalOutputCost: float, totalReasoningCost: float] =
  ## Calculate detailed cost breakdown by model for a conversation with reasoning token analysis
  if backend == nil or conversationId == 0:
    return (@[], 0.0, 0, 0, 0, 0.0, 0.0, 0.0)

  backend.pool.withDb:
    # Group by model and sum costs including reasoning tokens
    let query = """
      SELECT model,
            SUM(input_tokens) as total_input_tokens,
            SUM(output_tokens) as total_output_tokens,
            SUM(reasoning_tokens) as total_reasoning_tokens,
            SUM(input_cost) as total_input_cost,
            SUM(output_cost) as total_output_cost,
            SUM(reasoning_cost) as total_reasoning_cost,
            SUM(total_cost) as total_model_cost
      FROM model_token_usage
      WHERE conversation_id = ?
      GROUP BY model
      ORDER BY SUM(total_cost) DESC
    """

    result.rows = db.query(ConversationCostRow, query, conversationId)
    result.totalCost = 0.0
    result.totalInput = 0
    result.totalOutput = 0
    result.totalReasoning = 0
    result.totalInputCost = 0.0
    result.totalOutputCost = 0.0
    result.totalReasoningCost = 0.0

    for modelRow in result.rows:
      result.totalCost += modelRow.totalModelCost
      result.totalInput += modelRow.totalInputTokens
      result.totalOutput += modelRow.totalOutputTokens
      result.totalReasoning += modelRow.totalReasoningTokens
      result.totalInputCost += modelRow.totalInputCost
      result.totalOutputCost += modelRow.totalOutputCost
      result.totalReasoningCost += modelRow.totalReasoningCost

proc getConversationReasoningTokens*(backend: DatabaseBackend, conversationId: int): tuple[totalReasoning: int, totalOutput: int, reasoningPercent: float] =
  ## Get reasoning token statistics for a conversation
  if backend == nil or conversationId == 0:
    return (0, 0, 0.0)

  backend.pool.withDb:
    let query = """
      SELECT SUM(reasoning_tokens) as totalReasoning,
             SUM(output_tokens) as totalOutput
      FROM model_token_usage
      WHERE conversation_id = ?
    """

    let stats = db.query(ReasoningTokenStats, query, conversationId)
    if stats.len > 0:
      let stat = stats[0]
      result.totalReasoning = stat.totalReasoning
      result.totalOutput = stat.totalOutput
      result.reasoningPercent = if result.totalOutput > 0:
        (result.totalReasoning.float / result.totalOutput.float) * 100.0
      else:
        0.0

proc getConversationThinkingTokens*(backend: DatabaseBackend, conversationId: int): int =
  ## Get total thinking tokens from conversation_thinking_token table
  if backend == nil or conversationId == 0:
    return 0

  backend.pool.withDb:
    let query = """
      SELECT SUM(token_count) as totalThinking
      FROM conversation_thinking_token
      WHERE conversation_id = ?
    """

    let rows = db.query(query, conversationId)
    if rows.len > 0 and rows[0][0] != "" and rows[0][0] != "NULL":
      result = parseInt(rows[0][0])
    else:
      result = 0

proc getConversationCostBreakdown*(backend: DatabaseBackend, conversationId: int): tuple[totalCost: float, breakdown: seq[string]] =
  ## Calculate accurate cost breakdown by model for a conversation (legacy function)
  let detailedBreakdown = getConversationCostDetailed(backend, conversationId)
  result.totalCost = detailedBreakdown.totalCost
  result.breakdown = @[]
  
  for row in detailedBreakdown.rows:
    let reasoningInfo = if row.totalReasoningTokens > 0: 
      fmt" + {row.totalReasoningTokens} reasoning (${row.totalReasoningCost:.4f})"
    else: ""
    result.breakdown.add(fmt"{row.model}: {row.totalInputTokens} input (${row.totalInputCost:.4f}) + {row.totalOutputTokens} output (${row.totalOutputCost:.4f}){reasoningInfo} = ${row.totalModelCost:.4f}")

proc getSessionCostBreakdown*(backend: DatabaseBackend, appStartTime: DateTime): tuple[totalCost: float, inputCost: float, outputCost: float, reasoningCost: float, inputTokens: int, outputTokens: int, reasoningTokens: int] =
  ## Calculate session cost breakdown since app start time
  if backend == nil:
    return (0.0, 0.0, 0.0, 0.0, 0, 0, 0)

  backend.pool.withDb:
    let query = """
      SELECT SUM(input_tokens) as total_input_tokens,
             SUM(output_tokens) as total_output_tokens,
             SUM(reasoning_tokens) as total_reasoning_tokens,
             SUM(input_cost) as total_input_cost,
             SUM(output_cost) as total_output_cost,
             SUM(reasoning_cost) as total_reasoning_cost,
             SUM(total_cost) as total_cost,
             COUNT(*) as row_count
      FROM model_token_usage
      WHERE created_at >= ?
    """

    let timestampStr = $appStartTime
    debug(fmt"Session cost query: timestamp={timestampStr}")
    let stats = db.query(SessionCostStats, query, timestampStr)
    debug(fmt"Session cost query returned {stats.len} rows")
    if stats.len > 0:
      let stat = stats[0]
      debug(fmt"Session cost raw data: tokens=({stat.totalInputTokens}, {stat.totalOutputTokens}, {stat.totalReasoningTokens}), cost={stat.totalCost}")
      result.inputTokens = stat.totalInputTokens
      result.outputTokens = stat.totalOutputTokens
      result.reasoningTokens = stat.totalReasoningTokens
      result.inputCost = stat.totalInputCost
      result.outputCost = stat.totalOutputCost
      result.reasoningCost = stat.totalReasoningCost
      result.totalCost = stat.totalCost
      debug(fmt"Session cost breakdown: total={result.totalCost}, input={result.inputTokens}, output={result.outputTokens}")

proc getConversationTokenBreakdown*(backend: DatabaseBackend, conversationId: int): tuple[userTokens: int, assistantTokens: int, toolTokens: int] =
  ## Get token breakdown by message type for current conversation
  if backend == nil or conversationId == 0:
    return (0, 0, 0)

  backend.pool.withDb:
    let query = """
      SELECT cm.role,
             SUM(mtu.input_tokens + mtu.output_tokens + mtu.reasoning_tokens) as totalTokens
      FROM conversation_message cm
      LEFT JOIN model_token_usage mtu ON cm.id = mtu.message_id
      WHERE cm.conversation_id = ?
      GROUP BY cm.role
    """

    let tokenRows = db.query(TokenBreakdownRow, query, conversationId)
    for tokenRow in tokenRows:
      case tokenRow.role:
      of "user": result.userTokens = tokenRow.totalTokens
      of "assistant": result.assistantTokens = tokenRow.totalTokens
      of "tool": result.toolTokens = tokenRow.totalTokens

# New database-backed history procedures (replaces threadvar history)
proc addUserMessageToDb*(pool: Pool, conversationId: int, content: string): int =
  ## Add user message to database and return message ID
  pool.withDb:
    let msg = ConversationMessage(
      id: 0,
      conversationId: conversationId,
      created_at: now().utc(),
      role: "user",
      content: content,
      toolCallId: none(string),
      model: "",
      outputTokens: 0,
      toolCalls: none(string),
      sequenceId: none(int),  # Let database handle ordering
      messageType: "content"
    )
    db.insert(msg)
    return msg.id

proc addAssistantMessageToDb*(pool: Pool, conversationId: int, content: string,
                             toolCalls: Option[seq[LLMToolCall]], model: string, outputTokens: int = 0): int =
  ## Add assistant message to database and return message ID
  pool.withDb:
    let toolCallsJson = if toolCalls.isSome():
      some(serializeToolCalls(toolCalls.get()))
    else:
      none(string)

    let messageType = if toolCalls.isSome(): "tool_call" else: "content"

    debug(fmt("addAssistantMessageToDb: content='{content}', len={content.len}, toolCalls={toolCalls.isSome()}, messageType={messageType}"))

    let msg = ConversationMessage(
      id: 0,
      conversationId: conversationId,
      created_at: now().utc(),
      role: "assistant",
      content: content,
      toolCallId: none(string),
      model: model,
      outputTokens: outputTokens,
      toolCalls: toolCallsJson,
      sequenceId: none(int),  # Let database handle ordering
      messageType: messageType
    )
    try:
      db.insert(msg)
      debug(fmt("Successfully inserted assistant message, id={msg.id}"))
      return msg.id
    except Exception as e:
      warn(fmt("Failed to insert assistant message: {e.msg}"))
      warn(fmt("  content='{content}', len={content.len}"))
      warn(fmt("  model={model}, conversationId={conversationId}"))
      raise

proc addToolMessageToDb*(pool: Pool, conversationId: int, content: string,
                        toolCallId: string): int =
  ## Add tool result message to database and return message ID
  pool.withDb:
    let msg = ConversationMessage(
      id: 0,
      conversationId: conversationId,
      created_at: now().utc(),
      role: "tool",
      content: content,
      toolCallId: some(toolCallId),
      model: "",
      outputTokens: 0,
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
  result.messages = @[]
  result.toolCallCount = 0
  
  try:
    pool.withDb:
      let messages = db.filter(ConversationMessage, it.conversationId == conversationId)
      # Convert to proper heap-allocated seq and sort
      var sortedMessages = @messages
      sortedMessages.sort(proc(a, b: ConversationMessage): int = cmp(a.id, b.id))
      
      for dbMsg in sortedMessages:
        # Count tool calls
        if dbMsg.toolCalls.isSome():
          let toolCalls = deserializeToolCalls(dbMsg.toolCalls.get())
          result.toolCallCount += toolCalls.len
        
        # Convert to Message format
        case dbMsg.role:
        of "user":
          result.messages.add(Message(
            role: mrUser, 
            content: dbMsg.content,
            toolCalls: none(seq[LLMToolCall]),
            toolCallId: none(string),
            toolResults: none(seq[ToolResult]),
            thinkingContent: none(ThinkingContent)
          ))
        of "assistant":
          let toolCalls = if dbMsg.toolCalls.isSome():
            some(deserializeToolCalls(dbMsg.toolCalls.get()))
          else:
            none(seq[LLMToolCall])
          result.messages.add(Message(
            role: mrAssistant,
            content: dbMsg.content,
            toolCalls: toolCalls,
            toolCallId: none(string),
            toolResults: none(seq[ToolResult]),
            thinkingContent: none(ThinkingContent)
          ))
        of "tool":
          result.messages.add(Message(
            role: mrTool,
            content: dbMsg.content,
            toolCalls: none(seq[LLMToolCall]),
            toolCallId: dbMsg.toolCallId,
            toolResults: none(seq[ToolResult]),
            thinkingContent: none(ThinkingContent)
          ))
        else:
          debug(fmt"Skipping message with unknown role: {dbMsg.role}")
  except Exception as e:
    debug(fmt"Error getting conversation context: {e.msg}")
    result.messages = @[]
    result.toolCallCount = 0

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
      # No database configuration found - create default TiDB configuration
      debug("No database configuration found, creating default TiDB database")
      let defaultDbConfig = DatabaseConfig(
        enabled: true,
        host: "127.0.0.1",
        port: 4000,
        database: "niffler",
        username: "root",
        password: "",
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

# Database utility functions for model lookup and query building
proc findModelConfigByName*(modelName: string): Option[ModelConfig] =
  ## Find a model configuration by model name
  try:
    let config = loadConfig()
    for modelConfig in config.models:
      if modelConfig.model == modelName:
        return some(modelConfig)
  except Exception as e:
    debug(fmt"Failed to find model config for {modelName}: {e.msg}")
  return none(ModelConfig)

proc extractCostSettings*(modelConfig: Option[ModelConfig]): tuple[
  inputCost: Option[float], outputCost: Option[float], reasoningCost: Option[float]] =
  ## Extract cost settings from model config
  if modelConfig.isSome():
    let config = modelConfig.get()
    result.inputCost = config.inputCostPerMToken
    result.outputCost = config.outputCostPerMToken
    result.reasoningCost = config.reasoningCostPerMToken
  else:
    result.inputCost = none(float)
    result.outputCost = none(float)
    result.reasoningCost = none(float)


# Todo system database functions
proc logTokenUsageFromRequest*(requestModel: string, finalUsage: TokenUsage, conversationId: int, messageId: int, estimatedOutputTokens: int = 0) {.gcsafe.} =
  ## Centralized token logging that finds model config and logs usage - used from API worker
  debug("logTokenUsageFromRequest called")
  {.gcsafe.}:
    if conversationId == 0:
      return
    
    let database = getGlobalDatabase()
    if database == nil:
      return
    
    try:
      # Get the real model config to access cost information using utility functions
      let modelConfig = findModelConfigByName(requestModel)
      let (inputCostPerMToken, outputCostPerMToken, reasoningCostPerMToken) = extractCostSettings(modelConfig)
      let modelFound = modelConfig.isSome()
      
      debug(fmt"About to log token usage: conversationId={conversationId}, messageId={messageId}, model={requestModel}")
      debug(fmt"Token amounts: input={finalUsage.inputTokens}, output={finalUsage.outputTokens}")
      debug(fmt"Cost config: inputCost={inputCostPerMToken}, outputCost={outputCostPerMToken}, modelFound={modelFound}")
      
      # Extract reasoning tokens from usage if available
      let reasoningTokens = if finalUsage.reasoningTokens.isSome(): finalUsage.reasoningTokens.get() else: 0
      
      logModelTokenUsage(database, conversationId, messageId, requestModel,
                        finalUsage.inputTokens, finalUsage.outputTokens,
                        inputCostPerMToken, outputCostPerMToken,
                        reasoningTokens, reasoningCostPerMToken)
      
      debug(fmt"Successfully logged token usage: {finalUsage.inputTokens} input, {finalUsage.outputTokens} output, {reasoningTokens} reasoning")
    except Exception as e:
      error(fmt"Failed to log token usage: {e.msg}")

proc logSystemPromptTokenUsage*(backend: DatabaseBackend, conversationId: int, messageId: int,
                               model: string, mode: string, basePromptTokens: int, modePromptTokens: int,
                               environmentTokens: int, instructionFileTokens: int, toolInstructionTokens: int,
                               availableToolsTokens: int, systemPromptTotal: int, toolSchemaTokens: int) =
  ## Log system prompt token breakdown for overhead analysis
  if backend == nil:
    return

  backend.pool.withDb:
    try:
      let entry = SystemPromptTokenUsage(
        conversationId: conversationId,
        messageId: messageId,
        createdAt: now().utc(),
        model: model,
        mode: mode,
        basePromptTokens: basePromptTokens,
        modePromptTokens: modePromptTokens,
        environmentTokens: environmentTokens,
        instructionFileTokens: instructionFileTokens,
        toolInstructionTokens: toolInstructionTokens,
        availableToolsTokens: availableToolsTokens,
        systemPromptTotal: systemPromptTotal,
        toolSchemaTokens: toolSchemaTokens,
        totalOverhead: systemPromptTotal + toolSchemaTokens
      )

      db.insert(entry)
      debug(fmt"Logged system prompt token usage: {systemPromptTotal} system + {toolSchemaTokens} schemas = {entry.totalOverhead} total overhead")
    except Exception as e:
      error(fmt"Failed to log system prompt token usage: {e.msg}")

proc createTodoList*(backend: DatabaseBackend, conversationId: int, title: string, description: string = ""): int =
  ## Create a new todo list and return its ID
  if backend == nil:
    return 0

  backend.pool.withDb:
    let todoList = TodoList(
      id: 0,
      conversationId: conversationId,
      title: title,
      description: description,
      createdAt: now().utc(),
      updatedAt: now().utc(),
      isActive: true
    )
    db.insert(todoList)
    return todoList.id

proc addTodoItem*(backend: DatabaseBackend, listId: int, content: string, priority: TodoPriority = tpMedium): int =
  ## Add a new todo item to a list
  if backend == nil:
    return 0

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
      createdAt: now().utc(),
      updatedAt: now().utc(),
      orderIndex: nextOrder
    )
    db.insert(todoItem)
    return todoItem.id

proc updateTodoItem*(backend: DatabaseBackend, itemId: int, newState: Option[TodoState] = none(TodoState),
                    newContent: Option[string] = none(string), newPriority: Option[TodoPriority] = none(TodoPriority)): bool =
  ## Update a todo item's state, content, or priority
  if backend == nil:
    return false

  backend.pool.withDb:

    let items = db.filter(TodoItem, it.id == itemId)
    if items.len == 0:
      return false

    var item = items[0]
    item.updatedAt = now().utc()

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

  backend.pool.withDb:
    let items = db.filter(TodoItem, it.listId == listId)
    return items.sortedByIt(it.orderIndex)

proc deleteTodoItem*(backend: DatabaseBackend, itemId: int): bool =
  ## Delete a todo item from the database (hard delete)
  if backend == nil:
    return false

  backend.pool.withDb:
    let items = db.filter(TodoItem, it.id == itemId)
    if items.len == 0:
      return false

    db.delete(items[0])
    return true

proc getActiveTodoList*(backend: DatabaseBackend, conversationId: int): Option[TodoList] =
  ## Get the active todo list for a conversation
  if backend == nil:
    return none(TodoList)

  backend.pool.withDb:
    let lists = db.filter(TodoList, it.conversationId == conversationId and it.isActive == true)
    if lists.len > 0:
      return some(lists[0])
    else:
      return none(TodoList)

# Plan Mode Protection functions
proc setPlanModeCreatedFiles*(backend: DatabaseBackend, conversationId: int, createdFiles: seq[string]): bool =
  ## Set plan mode created files list for a conversation
  if backend == nil or conversationId == 0:
    return false

  backend.pool.withDb:
    try:
      let conversations = db.filter(Conversation, it.id == conversationId)
      if conversations.len == 0:
        debug(fmt"Conversation {conversationId} not found")
        return false

      var conv = conversations[0]
      debug(fmt"Found conversation {conversationId}, setting created files")
      conv.planModeEnteredAt = now().utc()
      conv.planModeCreatedFiles = $(%*createdFiles)  # Convert to JSON string
      conv.updated_at = now().utc()

      db.update(conv)
      debug(fmt"Plan mode created files set for conversation {conversationId} with {createdFiles.len} created files")
      return true
    except Exception as e:
      error(fmt"Failed to set plan mode created files: {e.msg}")
      return false

proc clearPlanModeCreatedFiles*(backend: DatabaseBackend, conversationId: int): bool =
  ## Clear plan mode created files list for a conversation
  if backend == nil or conversationId == 0:
    return false

  backend.pool.withDb:
    try:
      let conversations = db.filter(Conversation, it.id == conversationId)
      if conversations.len == 0:
        return false

      var conv = conversations[0]
      conv.planModeEnteredAt = fromUnix(0).utc()  # Set to epoch (indicates not in plan mode)
      conv.planModeCreatedFiles = ""  # Empty string indicates no created files
      conv.updated_at = now().utc()

      db.update(conv)
      debug(fmt"Plan mode created files cleared for conversation {conversationId}")
      return true
    except Exception as e:
      error(fmt"Failed to clear plan mode created files: {e.msg}")
      return false

proc setConversationCondensationInfo*(backend: DatabaseBackend, conversationId: int,
                                      parentConvId: int, messageCount: int,
                                      strategy: string, metadata: string): bool =
  ## Set condensation information for a conversation
  if backend == nil or conversationId == 0:
    return false

  backend.pool.withDb:
    try:
      let conversations = db.filter(Conversation, it.id == conversationId)
      if conversations.len == 0:
        debug(fmt"Conversation {conversationId} not found")
        return false

      var conv = conversations[0]
      conv.parentConversationId = some(parentConvId)
      conv.condensedFromMessageCount = messageCount
      conv.condensationStrategy = strategy
      conv.condensationMetadata = metadata
      conv.updated_at = now().utc()

      db.update(conv)
      debug(fmt"Condensation info set for conversation {conversationId}")
      return true
    except Exception as e:
      error(fmt"Failed to set condensation info: {e.msg}")
      return false

proc getPlanModeCreatedFiles*(backend: DatabaseBackend, conversationId: int): tuple[enabled: bool, createdFiles: seq[string]] =
  ## Get plan mode created files list for a conversation
  if backend == nil or conversationId == 0:
    return (false, @[])

  backend.pool.withDb:
    try:
      let conversations = db.filter(Conversation, it.id == conversationId)
      if conversations.len == 0:
        return (false, @[])

      let conv = conversations[0]

      # Check if planModeEnteredAt is a valid DateTime (not epoch)
      try:
        if conv.planModeEnteredAt > fromUnix(0).utc():
          # Parse created files list (empty list if no files created yet)
          let createdFiles = if conv.planModeCreatedFiles.len > 0:
            to(parseJson(conv.planModeCreatedFiles), seq[string])
          else:
            @[]
          return (true, createdFiles)
      except Exception:
        # If DateTime parsing fails, assume plan mode is not active
        debug(fmt"Invalid planModeEnteredAt value for conversation {conversationId}, plan mode not active")
      return (false, @[])
    except Exception as e:
      error(fmt"Failed to get plan mode created files: {e.msg}")
      return (false, @[])

proc addPlanModeCreatedFile*(backend: DatabaseBackend, conversationId: int, filePath: string): bool =
  ## Add a file to the plan mode created files list for a conversation
  if backend == nil or conversationId == 0:
    return false

  backend.pool.withDb:
    try:
      let conversations = db.filter(Conversation, it.id == conversationId)
      if conversations.len == 0:
        return false

      var conv = conversations[0]

      # Get current created files list
      let currentFiles = if conv.planModeCreatedFiles.len > 0:
        to(parseJson(conv.planModeCreatedFiles), seq[string])
      else:
        @[]

      # Add new file if not already in list
      var updatedFiles = currentFiles
      if filePath notin currentFiles:
        updatedFiles.add(filePath)
        conv.planModeCreatedFiles = $(%*updatedFiles)
        conv.updated_at = now().utc()

        db.update(conv)
        debug(fmt"Added file '{filePath}' to plan mode created files for conversation {conversationId}")

      return true
    except Exception as e:
      error(fmt"Failed to add plan mode created file: {e.msg}")
      return false

# Token correction factor database functions
proc recordTokenCorrectionToDB*(backend: DatabaseBackend, modelName: string, estimatedTokens: int, actualTokens: int) =
  ## Record a token correction sample in the database
  if backend == nil or estimatedTokens <= 0 or actualTokens <= 0:
    debug(fmt"Invalid parameters for recordTokenCorrectionToDB: model={modelName}, estimated={estimatedTokens}, actual={actualTokens}")
    return

  let ratio = actualTokens.float / estimatedTokens.float
  debug(fmt"🔍 CORRECTION FACTOR DEBUG: model={modelName}")
  debug(fmt"   📊 Estimated tokens: {estimatedTokens}")
  debug(fmt"   📊 Actual tokens: {actualTokens}")
  debug(fmt"   📊 Ratio (actual/estimated): {ratio:.6f}")
  let logicCheck = if ratio > 1.0: "Actual > Estimated (we underestimated)" else: "Actual < Estimated (we overestimated)"
  debug(fmt"   📊 Logic check: {logicCheck}")

  # Skip correction for models with fundamentally incompatible tokenizers
  if ratio > 5.0 or ratio < 0.2:
    debug(fmt"Skipping token correction for {modelName}: ratio {ratio:.3f} indicates incompatible tokenizer (estimated={estimatedTokens}, actual={actualTokens})")
    return  # Don't record corrections for incompatible tokenizers

  debug(fmt"Recording token correction for {modelName}: estimated={estimatedTokens}, actual={actualTokens}, ratio={ratio:.3f}")

  backend.pool.withDb:
    # Check if correction factor exists for this model
    let existingFactors = db.filter(TokenCorrectionFactor, it.modelName == modelName)

    if existingFactors.len > 0:
      # Update existing correction factor
      var factor = existingFactors[0]
      factor.totalSamples += 1
      factor.sumRatio += ratio
      factor.avgCorrection = factor.sumRatio / factor.totalSamples.float
      factor.updatedAt = now().utc()
      db.update(factor)

      debug(fmt"Updated correction for {modelName}: estimated={estimatedTokens}, actual={actualTokens}, ratio={ratio:.3f}, avg={factor.avgCorrection:.3f}")
    else:
      # Create new correction factor
      let factor = TokenCorrectionFactor(
        id: 0,
        modelName: modelName,
        totalSamples: 1,
        sumRatio: ratio,
        avgCorrection: ratio,
        createdAt: now().utc(),
        updatedAt: now().utc()
      )
      db.insert(factor)

      debug(fmt"Created new correction for {modelName}: estimated={estimatedTokens}, actual={actualTokens}, ratio={ratio:.3f}")

proc getCorrectionFactorFromDB*(backend: DatabaseBackend, modelName: string): Option[float] =
  ## Get the correction factor for a model from database
  if backend == nil:
    return none(float)

  backend.pool.withDb:
    try:
      let factors = db.filter(TokenCorrectionFactor, it.modelName == modelName)
      if factors.len > 0:
        let factor = factors[0]
        # Only apply correction if we have enough samples and it's not too extreme
        if factor.totalSamples >= 3 and factor.avgCorrection > 0.5 and factor.avgCorrection < 2.0:
          return some(factor.avgCorrection)
      return none(float)
    except Exception as e:
      error(fmt"Failed to get correction factor from database: {e.msg}")
      return none(float)

proc getAllCorrectionFactorsFromDB*(backend: DatabaseBackend): seq[TokenCorrectionFactor] =
  ## Get all correction factors from database
  if backend == nil:
    return @[]

  backend.pool.withDb:
    try:
      return db.filter(TokenCorrectionFactor)
    except Exception as e:
      error(fmt"Failed to get all correction factors from database: {e.msg}")
      return @[]

proc clearAllCorrectionFactorsFromDB*(backend: DatabaseBackend) =
  ## Clear all correction factors from database
  if backend == nil:
    return

  backend.pool.withDb:
    try:
      db.query("DELETE FROM token_correction_factor")
      debug("Cleared all token correction factors from database")
    except Exception as e:
      error(fmt"Failed to clear correction factors from database: {e.msg}")

proc getAssistantTokensForConversation*(backend: DatabaseBackend, conversationId: int): Table[string, int] =
  ## Get a table mapping assistant message content to actual output tokens for a conversation
  result = initTable[string, int]()

  if backend == nil or conversationId == 0:
    return

  backend.pool.withDb:
    try:
      let assistantMessages = db.filter(ConversationMessage,
        it.conversationId == conversationId and it.role == "assistant")
      for msg in assistantMessages:
        if msg.outputTokens > 0:
          result[msg.content] = msg.outputTokens
    except Exception as e:
      error(fmt"Failed to get assistant tokens for conversation: {e.msg}")