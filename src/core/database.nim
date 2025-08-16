import std/[options, tables, strformat, os, times, strutils, sequtils, algorithm]
import ../types/config
import debby/sqlite

type
  DatabaseBackend* = ref object of RootObj
    config: DatabaseConfig
  
  SQLiteBackend* = ref object of DatabaseBackend
    db: sqlite.Db
  
  TiDBBackend* = ref object of DatabaseBackend
    db: sqlite.Db  # Using SQLite for now, will be replaced with MySQL later
  
  TokenLogEntry* = ref object of RootObj
    id*: int
    timestamp*: DateTime
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
    timestamp*: DateTime
    userPrompt*: string
    assistantResponse*: string
    model*: string
    sessionId*: string

proc init*(db: DatabaseBackend) =
  raise newException(CatchableError, "Database backend not implemented")

proc close*(db: DatabaseBackend) =
  raise newException(CatchableError, "Database backend not implemented")

proc logTokenUsage*(db: DatabaseBackend, entry: TokenLogEntry) =
  raise newException(CatchableError, "Database backend not implemented")

proc getTokenStats*(db: DatabaseBackend, model: string, startDate, endDate: DateTime): tuple[totalInputTokens: int, totalOutputTokens: int, totalCost: float] =
  raise newException(CatchableError, "Database backend not implemented")

proc createTables*(db: DatabaseBackend) =
  raise newException(CatchableError, "Database backend not implemented")

proc logPromptHistory*(db: DatabaseBackend, entry: PromptHistoryEntry) =
  raise newException(CatchableError, "Database backend not implemented")



# SQLite Backend Implementation
proc init*(db: SQLiteBackend) =
  let fullPath = db.config.path.get()
  
  # Create directory if it doesn't exist
  createDir(parentDir(fullPath))
  
  # Open database connection
  db.db = sqlite.openDatabase(fullPath)
  
  # Enable WAL mode for better concurrency
  if db.config.walMode:
    db.db.query("PRAGMA journal_mode=WAL")
    db.db.query("PRAGMA synchronous=NORMAL")
  
  # Set busy timeout
  db.db.query(fmt"PRAGMA busy_timeout = {db.config.busyTimeout}")
  
  # Create tables using debby's ORM
  db.createTables()

proc close*(db: SQLiteBackend) =
  if cast[pointer](db.db) != nil:
    db.db.close()

proc createTables*(db: SQLiteBackend) =
  # Create token_logs table using debby's ORM
  db.db.checkTable(TokenLogEntry)
  
  # Create prompt_history table using debby's ORM
  db.db.checkTable(PromptHistoryEntry)
  
  # Create indexes for better performance
  db.db.createIndexIfNotExists(TokenLogEntry, "model")
  db.db.createIndexIfNotExists(TokenLogEntry, "timestamp")
  db.db.createIndexIfNotExists(PromptHistoryEntry, "timestamp")
  db.db.createIndexIfNotExists(PromptHistoryEntry, "sessionId")

proc logTokenUsage*(db: SQLiteBackend, entry: TokenLogEntry) =
  # Insert using debby's ORM
  db.db.insert(entry)

proc getTokenStats*(db: SQLiteBackend, model: string, startDate, endDate: DateTime): tuple[totalInputTokens: int, totalOutputTokens: int, totalCost: float] =
  let startDateStr = startDate.format("yyyy-MM-dd HH:mm:ss")
  let endDateStr = endDate.format("yyyy-MM-dd HH:mm:ss")
  
  # Query using debby's ORM
  let entries = if model.len > 0:
    db.db.filter(TokenLogEntry, it.model == model and it.timestamp >= startDate and it.timestamp <= endDate)
  else:
    db.db.filter(TokenLogEntry, it.timestamp >= startDate and it.timestamp <= endDate)
  
  # Calculate totals
  result = (0, 0, 0.0)
  for entry in entries:
    result.totalInputTokens += entry.inputTokens
    result.totalOutputTokens += entry.outputTokens
    result.totalCost += entry.totalCost

proc logPromptHistory*(db: SQLiteBackend, entry: PromptHistoryEntry) =
  # Insert using debby's ORM
  db.db.insert(entry)

proc getPromptHistory*(db: SQLiteBackend, sessionId: string = "", maxEntries: int = 50): seq[PromptHistoryEntry] =
  # Query using debby's ORM
  let entries = if sessionId.len > 0:
    db.db.filter(PromptHistoryEntry, it.sessionId == sessionId)
  else:
    # Get all entries by filtering with a condition that's always true
    db.db.filter(PromptHistoryEntry, it.id > 0)
  
  # Sort by timestamp descending and limit results
  result = entries.sortedByIt(-it.timestamp.toTime().toUnix())
  if result.len > maxEntries:
    result = result[0..<maxEntries]

proc getRecentPrompts*(db: SQLiteBackend, maxEntries: int = 20): seq[string] =
  # Get recent user prompts only
  let entries = db.db.filter(PromptHistoryEntry, it.id > 0)
  let sortedEntries = entries.sortedByIt(-it.timestamp.toTime().toUnix())
  
  result = @[]
  for entry in sortedEntries:
    if entry.userPrompt.len > 0:
      result.add(entry.userPrompt)
      if result.len >= maxEntries:
        break

# TiDB Backend Implementation (placeholder for now)
proc init*(db: TiDBBackend) =
  let host = db.config.host.get("localhost")
  let port = db.config.port.get(4000)
  let database = db.config.database.get("niffler")
  let username = db.config.username.get("root")
  let password = db.config.password.get("")
  
  # For now, use SQLite as a placeholder
  # In a real implementation, this would connect to TiDB using MySQL driver
  let dbPath = "tidb_placeholder.db"
  let fullPath = joinPath(getConfigDir(), "niffler", dbPath)
  createDir(parentDir(fullPath))
  db.db = sqlite.openDatabase(fullPath)
  db.createTables()

proc close*(db: TiDBBackend) =
  if cast[pointer](db.db) != nil:
    db.db.close()

proc createTables*(db: TiDBBackend) =
  # Same as SQLite for now
  db.db.checkTable(TokenLogEntry)
  db.db.checkTable(PromptHistoryEntry)
  db.db.createIndexIfNotExists(TokenLogEntry, "model")
  db.db.createIndexIfNotExists(TokenLogEntry, "timestamp")
  db.db.createIndexIfNotExists(PromptHistoryEntry, "timestamp")
  db.db.createIndexIfNotExists(PromptHistoryEntry, "sessionId")

proc logTokenUsage*(db: TiDBBackend, entry: TokenLogEntry) =
  # Same as SQLite for now
  db.db.insert(entry)

proc getTokenStats*(db: TiDBBackend, model: string, startDate, endDate: DateTime): tuple[totalInputTokens: int, totalOutputTokens: int, totalCost: float] =
  # Same as SQLite for now
  let startDateStr = startDate.format("yyyy-MM-dd HH:mm:ss")
  let endDateStr = endDate.format("yyyy-MM-dd HH:mm:ss")
  
  let entries = if model.len > 0:
    db.db.filter(TokenLogEntry, it.model == model and it.timestamp >= startDate and it.timestamp <= endDate)
  else:
    db.db.filter(TokenLogEntry, it.timestamp >= startDate and it.timestamp <= endDate)
  
  result = (0, 0, 0.0)
  for entry in entries:
    result.totalInputTokens += entry.inputTokens
    result.totalOutputTokens += entry.outputTokens
    result.totalCost += entry.totalCost

proc logPromptHistory*(db: TiDBBackend, entry: PromptHistoryEntry) =
  # Same as SQLite for now
  db.db.insert(entry)

proc getPromptHistory*(db: TiDBBackend, sessionId: string = "", maxEntries: int = 50): seq[PromptHistoryEntry] =
  # Same as SQLite for now
  let entries = if sessionId.len > 0:
    db.db.filter(PromptHistoryEntry, it.sessionId == sessionId)
  else:
    db.db.filter(PromptHistoryEntry, it.id > 0)
  
  result = entries.sortedByIt(-it.timestamp.toTime().toUnix())
  if result.len > maxEntries:
    result = result[0..<maxEntries]

proc getRecentPrompts*(db: TiDBBackend, maxEntries: int = 20): seq[string] =
  # Same as SQLite for now
  let entries = db.db.filter(PromptHistoryEntry, it.id > 0)
  let sortedEntries = entries.sortedByIt(-it.timestamp.toTime().toUnix())
  
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
    let backend = SQLiteBackend(config: config)
    backend.init()
    return backend
  of dtTiDB:
    let backend = TiDBBackend(config: config)
    backend.init()
    return backend

# Helper functions
proc logTokenUsage*(db: DatabaseBackend, model: string, inputTokens, outputTokens: int, 
                   inputCost, outputCost: float, request: string = "", response: string = "") =
  if db == nil:
    return
  
  let entry = TokenLogEntry(
    id: 0,  # Will be set by database
    timestamp: now(),
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
    timestamp: now(),
    userPrompt: userPrompt,
    assistantResponse: assistantResponse,
    model: model,
    sessionId: sessionId
  )
  
  db.logPromptHistory(entry)

proc getRecentPrompts*(db: DatabaseBackend, maxEntries: int = 20): seq[string] =
  if db == nil:
    return @[]
  
  return db.getRecentPrompts(maxEntries)

proc getPromptHistory*(db: DatabaseBackend, sessionId: string = "", maxEntries: int = 50): seq[PromptHistoryEntry] =
  if db == nil:
    return @[]
  
  return db.getPromptHistory(sessionId, maxEntries)