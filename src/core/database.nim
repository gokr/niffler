import std/[options, tables, strformat, os, times, strutils, algorithm]
import ../types/config
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

proc checkDatabase*(db: DatabaseBackend) =
  ## Verify structure of database against model definitions
  case db.kind:
  of dbkSQLite, dbkTiDB:
    db.db.checkTable(TokenLogEntry)
    db.db.checkTable(PromptHistoryEntry)
  echo "Database checked"

proc init*(db: DatabaseBackend) =
  case db.kind:
  of dbkSQLite:
    let fullPath = db.config.path.get()
    
    # Create directory if it doesn't exist
    createDir(parentDir(fullPath))
    
    # Check if file is missing
    if not fileExists(fullPath):
      echo "Creating Sqlite3 database ..."

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
  
  of dbkTiDB:
    let host = db.config.host.get("localhost")
    let port = db.config.port.get(4000)
    let database = db.config.database.get("niffler")
    let username = db.config.username.get("root")
    let password = db.config.password.get("")
    
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

# Wrapper functions removed - using direct method calls now