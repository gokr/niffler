import std/[options, tables, strformat, os, times, strutils, algorithm, logging]
import ../types/config
import config
import debby/sqlite

type
  DatabaseBackendKind* = enum
    dbkSQLite
    dbkTiDB
  
  DatabaseBackend* = ref object
    config*: DatabaseConfig
    case kind*: DatabaseBackendKind
    of dbkSQLite, dbkTiDB:
      db: sqlite.Db
  
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

proc initializeDatabase*(db: DatabaseBackend) =
  ## This is where we create the tables if they are not already created.
  case db.kind:
  of dbkSQLite, dbkTiDB:
    # When running this for the first time, it will create the tables
    if not db.db.tableExists(TokenLogEntry):
      db.db.createTable(TokenLogEntry)
      # Create indexes for better performance
      db.db.createIndexIfNotExists(TokenLogEntry, "model")
      db.db.createIndexIfNotExists(TokenLogEntry, "created_at")
    
    if not db.db.tableExists(PromptHistoryEntry):
      db.db.createTable(PromptHistoryEntry)
      # Create indexes for better performance
      db.db.createIndexIfNotExists(PromptHistoryEntry, "created_at")
      db.db.createIndexIfNotExists(PromptHistoryEntry, "sessionId")
    
    # Create new conversation tracking tables
    if not db.db.tableExists(Conversation):
      db.db.createTable(Conversation)
      # Create indexes for better performance
      db.db.createIndexIfNotExists(Conversation, "sessionId")
      db.db.createIndexIfNotExists(Conversation, "isActive")
    
    if not db.db.tableExists(ConversationMessage):
      db.db.createTable(ConversationMessage)
      # Create indexes for better performance
      db.db.createIndexIfNotExists(ConversationMessage, "conversationId")
      db.db.createIndexIfNotExists(ConversationMessage, "model")
      db.db.createIndexIfNotExists(ConversationMessage, "created_at")
    
    if not db.db.tableExists(ModelTokenUsage):
      db.db.createTable(ModelTokenUsage)
      # Create indexes for better performance
      db.db.createIndexIfNotExists(ModelTokenUsage, "conversationId")
      db.db.createIndexIfNotExists(ModelTokenUsage, "model")
      db.db.createIndexIfNotExists(ModelTokenUsage, "created_at")
    
    # Create todo system tables
    if not db.db.tableExists(TodoList):
      db.db.createTable(TodoList)
      db.db.createIndexIfNotExists(TodoList, "conversationId")
      db.db.createIndexIfNotExists(TodoList, "isActive")
    
    if not db.db.tableExists(TodoItem):
      db.db.createTable(TodoItem)
      db.db.createIndexIfNotExists(TodoItem, "listId")
      db.db.createIndexIfNotExists(TodoItem, "state")
      db.db.createIndexIfNotExists(TodoItem, "orderIndex")

proc checkDatabase*(db: DatabaseBackend) =
  ## Verify structure of database against model definitions
  case db.kind:
  of dbkSQLite, dbkTiDB:
    db.db.checkTable(TokenLogEntry)
    db.db.checkTable(PromptHistoryEntry)
    db.db.checkTable(Conversation)
    db.db.checkTable(ConversationMessage)
    db.db.checkTable(ModelTokenUsage)
    db.db.checkTable(TodoList)
    db.db.checkTable(TodoItem)
  echo "Database checked"

proc init*(db: DatabaseBackend) =
  case db.kind:
  of dbkSQLite:
    let fullPath = db.config.path.get()
    
    try:
      # Create directory if it doesn't exist
      createDir(parentDir(fullPath))
      
      # Check if file is missing
      if not fileExists(fullPath):
        echo "Creating Sqlite3 database at: ", fullPath

      # Open database connection
      db.db = sqlite.openDatabase(fullPath)
      
      # Enable WAL mode for better concurrency
      if db.config.walMode:
        db.db.query("PRAGMA journal_mode=WAL")
        db.db.query("PRAGMA synchronous=NORMAL")
      
      # Set busy timeout
      db.db.query(fmt"PRAGMA busy_timeout = {db.config.busyTimeout}")
      
      # Create tables using debby's ORM
      db.initializeDatabase()
      
      echo "Database initialized successfully at: ", fullPath
    except Exception as e:
      error(fmt"Failed to initialize SQLite database: {e.msg}")
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

proc close*(db: DatabaseBackend) =
  case db.kind:
  of dbkSQLite, dbkTiDB:
    if cast[pointer](db.db) != nil:
      db.db.close()

proc logTokenUsage*(db: DatabaseBackend, entry: TokenLogEntry) =
  case db.kind:
  of dbkSQLite, dbkTiDB:
    # Insert using debby's ORM
    db.db.insert(entry)

proc getTokenStats*(db: DatabaseBackend, model: string, startDate, endDate: DateTime): tuple[totalInputTokens: int, totalOutputTokens: int, totalCost: float] =
  case db.kind:
  of dbkSQLite, dbkTiDB:
    let startDateStr = startDate.format("yyyy-MM-dd HH:mm:ss")
    let endDateStr = endDate.format("yyyy-MM-dd HH:mm:ss")
    
    # Query using debby's ORM
    let entries = if model.len > 0:
      db.db.filter(TokenLogEntry, it.model == model and it.created_at >= startDate and it.created_at <= endDate)
    else:
      db.db.filter(TokenLogEntry, it.created_at >= startDate and it.created_at <= endDate)
    
    # Calculate totals
    result = (0, 0, 0.0)
    for entry in entries:
      result.totalInputTokens += entry.inputTokens
      result.totalOutputTokens += entry.outputTokens
      result.totalCost += entry.totalCost

proc logPromptHistory*(db: DatabaseBackend, entry: PromptHistoryEntry) =
  case db.kind:
  of dbkSQLite, dbkTiDB:
    # Insert using debby's ORM
    db.db.insert(entry)



proc getPromptHistory*(db: DatabaseBackend, sessionId: string = "", maxEntries: int = 50): seq[PromptHistoryEntry] =
  case db.kind:
  of dbkSQLite, dbkTiDB:
    # Query using debby's ORM
    let entries = if sessionId.len > 0:
      db.db.filter(PromptHistoryEntry, it.sessionId == sessionId)
    else:
      # Get all entries by filtering with a condition that's always true
      db.db.filter(PromptHistoryEntry, it.id > 0)
    
    # Sort by created_at descending and limit results
    result = entries.sortedByIt(-it.created_at.toTime().toUnix())
    if result.len > maxEntries:
      result = result[0..<maxEntries]

proc getRecentPrompts*(db: DatabaseBackend, maxEntries: int = 20): seq[string] =
  case db.kind:
  of dbkSQLite, dbkTiDB:
    # Get recent user prompts only
    let entries = db.db.filter(PromptHistoryEntry, it.id > 0)
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
proc logTokenUsage*(db: DatabaseBackend, model: string, inputTokens, outputTokens: int, 
                   inputCost, outputCost: float, request: string = "", response: string = "") =
  if db == nil:
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
  
  db.logTokenUsage(entry)

proc getTokenStats*(db: DatabaseBackend, model: string = "", days: int = 30): tuple[totalInputTokens: int, totalOutputTokens: int, totalCost: float] =
  if db == nil:
    return (0, 0, 0.0)
  
  let endDate = now()
  let startDate = endDate - initDuration(days = days)
  
  return db.getTokenStats(model, startDate, endDate)

# Helper functions for prompt history
proc logPromptHistory*(db: DatabaseBackend, userPrompt: string, assistantResponse: string, 
                      model: string, sessionId: string = "") =
  if db == nil:
    return
  
  let entry = PromptHistoryEntry(
    id: 0,  # Will be set by database
    created_at: now(),
    userPrompt: userPrompt,
    assistantResponse: assistantResponse,
    model: model,
    sessionId: sessionId
  )
  
  db.logPromptHistory(entry)

# New conversation tracking functions
proc startConversation*(db: DatabaseBackend, sessionId: string, title: string): int =
  ## Start a new conversation and return its ID
  if db == nil:
    return 0
  
  case db.kind:
  of dbkSQLite, dbkTiDB:
    let conv = Conversation(
      id: 0,
      created_at: now(),
      updated_at: now(),
      sessionId: sessionId,
      title: title,
      isActive: true
    )
    db.db.insert(conv)
    return conv.id

proc logConversationMessage*(db: DatabaseBackend, conversationId: int, role: string,
                           content: string, model: string, toolCallId: Option[string] = none(string),
                           inputTokens: int = 0, outputTokens: int = 0,
                           inputCost: float = 0.0, outputCost: float = 0.0) =
  ## Log a message in a conversation
  if db == nil or conversationId == 0:
    return
  
  case db.kind:
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
    db.db.insert(msg)

proc logModelTokenUsage*(db: DatabaseBackend, conversationId: int, messageId: int,
                        model: string, inputTokens: int, outputTokens: int,
                        inputCostPerMToken: Option[float], outputCostPerMToken: Option[float]) =
  ## Log model-specific token usage for accurate cost calculation
  if db == nil or conversationId == 0:
    return
  
  let inputCost = if inputCostPerMToken.isSome():
    float(inputTokens) * (inputCostPerMToken.get() / 1_000_000.0)
  else: 0.0
  
  let outputCost = if outputCostPerMToken.isSome():
    float(outputTokens) * (outputCostPerMToken.get() / 1_000_000.0)
  else: 0.0
  
  let totalCost = inputCost + outputCost
  
  case db.kind:
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
    db.db.insert(usage)

proc getConversationCostBreakdown*(db: DatabaseBackend, conversationId: int): tuple[totalCost: float, breakdown: seq[string]] =
  ## Calculate accurate cost breakdown by model for a conversation
  if db == nil or conversationId == 0:
    return (0.0, @[])
  
  case db.kind:
  of dbkSQLite, dbkTiDB:
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
    
    let rows = db.db.query(query, conversationId)
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

# Wrapper functions removed - using direct method calls now

# Global database instance
var globalDatabase {.threadvar.}: DatabaseBackend

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
    try:
      # Check if all required tables exist
      if not database.db.tableExists(TokenLogEntry):
        warn("TokenLogEntry table missing")
        return false
      if not database.db.tableExists(PromptHistoryEntry):
        warn("PromptHistoryEntry table missing")
        return false
      if not database.db.tableExists(Conversation):
        warn("Conversation table missing")
        return false
      if not database.db.tableExists(ConversationMessage):
        warn("ConversationMessage table missing")
        return false
      if not database.db.tableExists(ModelTokenUsage):
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
proc createTodoList*(db: DatabaseBackend, conversationId: int, title: string, description: string = ""): int =
  ## Create a new todo list and return its ID
  if db == nil:
    return 0
  
  case db.kind:
  of dbkSQLite, dbkTiDB:
    let todoList = TodoList(
      id: 0,
      conversationId: conversationId,
      title: title,
      description: description,
      createdAt: now(),
      updatedAt: now(),
      isActive: true
    )
    db.db.insert(todoList)
    return todoList.id

proc addTodoItem*(db: DatabaseBackend, listId: int, content: string, priority: TodoPriority = tpMedium): int =
  ## Add a new todo item to a list
  if db == nil:
    return 0
  
  case db.kind:
  of dbkSQLite, dbkTiDB:
    # Get the next order index
    let existingItems = db.db.filter(TodoItem, it.listId == listId)
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
    db.db.insert(todoItem)
    return todoItem.id

proc updateTodoItem*(db: DatabaseBackend, itemId: int, newState: Option[TodoState] = none(TodoState),
                    newContent: Option[string] = none(string), newPriority: Option[TodoPriority] = none(TodoPriority)): bool =
  ## Update a todo item's state, content, or priority
  if db == nil:
    return false
  
  case db.kind:
  of dbkSQLite, dbkTiDB:
    try:
      let items = db.db.filter(TodoItem, it.id == itemId)
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
      
      db.db.update(item)
      return true
    except:
      return false

proc getTodoItems*(db: DatabaseBackend, listId: int): seq[TodoItem] =
  ## Get all todo items for a list, sorted by order index
  if db == nil:
    return @[]
  
  case db.kind:
  of dbkSQLite, dbkTiDB:
    let items = db.db.filter(TodoItem, it.listId == listId)
    return items.sortedByIt(it.orderIndex)

proc getActiveTodoList*(db: DatabaseBackend, conversationId: int): Option[TodoList] =
  ## Get the active todo list for a conversation
  if db == nil:
    return none(TodoList)
  
  case db.kind:
  of dbkSQLite, dbkTiDB:
    let lists = db.db.filter(TodoList, it.conversationId == conversationId and it.isActive == true)
    if lists.len > 0:
      return some(lists[0])
    else:
      return none(TodoList)