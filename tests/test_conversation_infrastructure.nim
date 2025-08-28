## Test Infrastructure for Conversation Management Integration Tests
##
## This module provides utilities for testing conversation management functionality
## with real database operations and full system integration.

import std/[unittest, options, strformat, times, os, tempfiles, strutils, algorithm]
import ../src/core/[database, conversation_manager, config, app]
import ../src/types/[config as configTypes, messages, mode]
import ../src/ui/commands
import debby/sqlite
import debby/pools

type
  TestDatabase* = object
    backend*: DatabaseBackend
    tempDir*: string
    dbPath*: string

  TestModelConfig* = object
    config*: configTypes.ModelConfig

proc createTestDatabase*(): TestDatabase =
  ## Create an in-memory SQLite database for testing
  let tempDir = createTempDir("niffler_test", "")
  let dbPath = tempDir / "test.db"
  
  let dbConfig = DatabaseConfig(
    `type`: dtSQLite,
    enabled: true,
    path: some(dbPath),
    walMode: false,  # Disable WAL for testing
    busyTimeout: 1000,
    poolSize: 1  # Single connection for tests
  )
  
  let backend = createDatabaseBackend(dbConfig)
  if backend == nil:
    doAssert false, "Failed to create test database backend"
  
  result = TestDatabase(
    backend: backend,
    tempDir: tempDir,
    dbPath: dbPath
  )

proc cleanupTestDatabase*(testDb: TestDatabase) =
  ## Clean up test database and temporary files
  if testDb.backend != nil:
    testDb.backend.close()
  
  try:
    removeDir(testDb.tempDir)
  except:
    discard  # Ignore cleanup errors

proc createTestModelConfig*(): configTypes.ModelConfig =
  ## Create a test model configuration
  result = configTypes.ModelConfig(
    nickname: "test-model",
    model: "test-gpt-4",
    baseUrl: "http://localhost:8080",
    context: 128000,
    inputCostPerMToken: some(10.0),
    outputCostPerMToken: some(30.0)
  )

proc verifyConversationInDatabase*(db: DatabaseBackend, expectedId: int, expectedTitle: string): bool =
  ## Verify that a conversation exists in the database with expected properties
  let convOpt = getConversationById(db, expectedId)
  if convOpt.isNone():
    return false
  
  let conv = convOpt.get()
  return conv.title == expectedTitle and conv.id == expectedId

proc verifyMessageCount*(db: DatabaseBackend, conversationId: int, expectedCount: int): bool =
  ## Verify that a conversation has the expected number of messages
  try:
    db.pool.withDb:
      let rows = db.query("SELECT COUNT(*) FROM conversation_message WHERE conversation_id = ?", conversationId)
      if rows.len > 0:
        let actualCount = parseInt(rows[0][0])
        return actualCount == expectedCount
      return false
  except:
    return false

proc getConversationMessages*(db: DatabaseBackend, conversationId: int): seq[ConversationMessage] =
  ## Get all messages for a conversation (for testing purposes)
  try:
    db.pool.withDb:
      let messages = db.filter(ConversationMessage, it.conversationId == conversationId)
      return messages.sortedByIt(it.id)
  except:
    return @[]

proc assertConversationExists*(db: DatabaseBackend, id: int, title: string) =
  ## Assert that a conversation exists with given properties
  let exists = verifyConversationInDatabase(db, id, title)
  check(exists)
  if not exists:
    doAssert false, fmt"Conversation {id} with title '{title}' not found in database"

proc assertMessageCount*(db: DatabaseBackend, conversationId: int, expectedCount: int) =
  ## Assert that a conversation has the expected number of messages
  let correct = verifyMessageCount(db, conversationId, expectedCount)
  check(correct)
  if not correct:
    doAssert false, fmt"Conversation {conversationId} has wrong message count (expected {expectedCount})"

proc simulateFullConversationWorkflow*(db: DatabaseBackend): tuple[convId: int, success: bool] =
  ## Simulate a complete conversation workflow for testing
  var testModel = createTestModelConfig()
  
  # Create conversation
  let convOpt = createConversation(db, "Test Conversation", amPlan, testModel.nickname)
  if convOpt.isNone():
    return (0, false)
  
  let conv = convOpt.get()
  let convId = conv.id
  
  # Switch to conversation
  if not switchToConversation(db, convId):
    return (convId, false)
  
  # Initialize session manager for this conversation
  initSessionManager(db.pool, convId)
  
  # Add some messages
  discard addUserMessage("Hello, this is a test message")
  discard addAssistantMessage("Hello! I'm responding to your test message.", none(seq[LLMToolCall]))
  discard addUserMessage("Can you help me with a task?")
  discard addAssistantMessage("Of course! I'd be happy to help you.", none(seq[LLMToolCall]))
  
  # Update conversation metadata
  updateConversationMessageCount(db, convId)
  updateConversationActivity(db, convId)
  
  return (convId, true)

template testConversationLifecycle*(name: string, body: untyped): untyped =
  ## Template for creating conversation lifecycle tests
  test name:
    let testDb = createTestDatabase()
    defer: cleanupTestDatabase(testDb)
    
    # Set global database for testing
    setGlobalDatabase(testDb.backend)
    
    # Initialize mode state for tests
    initializeModeState()
    
    body

proc verifyDatabasePersistence*(db1: DatabaseBackend, db2: DatabaseBackend, conversationId: int): bool =
  ## Verify that conversation data persists across database connections
  # Get conversation from first database
  let conv1Opt = getConversationById(db1, conversationId)
  if conv1Opt.isNone():
    return false
  
  let conv1 = conv1Opt.get()
  
  # Get same conversation from second database connection
  let conv2Opt = getConversationById(db2, conversationId)
  if conv2Opt.isNone():
    return false
  
  let conv2 = conv2Opt.get()
  
  # Verify they match
  return conv1.id == conv2.id and
         conv1.title == conv2.title and
         conv1.mode == conv2.mode and
         conv1.modelNickname == conv2.modelNickname

proc createTestConversationWithMessages*(db: DatabaseBackend, title: string, messageCount: int): int =
  ## Create a test conversation with a specified number of messages
  var testModel = createTestModelConfig()
  
  let convOpt = createConversation(db, title, amCode, testModel.nickname)
  if convOpt.isNone():
    return 0
  
  let conv = convOpt.get()
  let convId = conv.id
  
  # Switch to conversation and initialize session
  discard switchToConversation(db, convId)
  initSessionManager(db.pool, convId)
  
  # Add alternating user and assistant messages
  for i in 0..<messageCount:
    if i mod 2 == 0:
      discard addUserMessage(fmt"User message {i + 1}")
    else:
      discard addAssistantMessage(fmt"Assistant response {i + 1}", none(seq[LLMToolCall]))
  
  # Update conversation metadata
  updateConversationMessageCount(db, convId)
  updateConversationActivity(db, convId)
  
  return convId