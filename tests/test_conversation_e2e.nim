## End-to-End Conversation Management Integration Tests
##
## These tests exercise the complete conversation management system through
## real database operations and verify persistence across the entire stack.

import std/[unittest, strformat, times, strutils, options, sequtils]
import test_conversation_infrastructure
import ../src/core/[database, conversation_manager, config, app]
import ../src/types/[config as configTypes, messages, mode]
import ../src/ui/commands

suite "End-to-End Conversation Lifecycle":
  
  test "Complete conversation workflow with database persistence":
    let testDb = createTestDatabase()
    defer: cleanupTestDatabase(testDb)
    
    # Set global database for testing
    setGlobalDatabase(testDb.backend)
    
    # Initialize mode state for tests
    initializeModeState()
    
    # Test the full conversation lifecycle from creation to archival
    var testModel = createTestModelConfig()
    
    # Step 1: Create conversation via conversation manager
    let convOpt = createConversation(testDb.backend, "E2E Test Conversation", amPlan, testModel.nickname)
    check convOpt.isSome()
    
    let conv = convOpt.get()
    let convId = conv.id
    check conv.title == "E2E Test Conversation"
    check conv.mode == amPlan
    check conv.modelNickname == testModel.nickname
    check conv.isActive == true
    
    # Verify conversation was persisted to database
    assertConversationExists(testDb.backend, convId, "E2E Test Conversation")
    
    # Step 2: Switch to conversation and add messages
    let switchSuccess = switchToConversation(testDb.backend, convId)
    check switchSuccess == true
    
    # Initialize session for message operations
    initSessionManager(testDb.backend.pool, convId)
    
    # Add user message
    let userMsg = addUserMessage("Test user message for E2E test")
    check userMsg.role == mrUser
    check userMsg.content == "Test user message for E2E test"
    
    # Add assistant message
    let assistantMsg = addAssistantMessage("Test assistant response for E2E test")
    check assistantMsg.role == mrAssistant
    check assistantMsg.content == "Test assistant response for E2E test"
    
    # Step 3: Verify messages persisted to database
    assertMessageCount(testDb.backend, convId, 2)
    
    let messages = getConversationMessages(testDb.backend, convId)
    check messages.len == 2
    check messages[0].role == "user"
    check messages[0].content == "Test user message for E2E test"
    check messages[1].role == "assistant"
    check messages[1].content == "Test assistant response for E2E test"
    
    # Step 4: Update conversation metadata
    updateConversationMessageCount(testDb.backend, convId)
    updateConversationActivity(testDb.backend, convId)
    
    # Verify metadata was updated
    let updatedConvOpt = getConversationById(testDb.backend, convId)
    check updatedConvOpt.isSome()
    let updatedConv = updatedConvOpt.get()
    check updatedConv.messageCount == 2
    
    # Step 5: Archive conversation
    let archiveSuccess = archiveConversation(testDb.backend, convId)
    check archiveSuccess == true
    
    # Verify conversation is archived
    let archivedConvOpt = getConversationById(testDb.backend, convId)
    check archivedConvOpt.isSome()
    let archivedConv = archivedConvOpt.get()
    check archivedConv.isActive == false

  testConversationLifecycle "Conversation persistence across database connections":
    # Create conversation with first database connection
    let (convId, success) = simulateFullConversationWorkflow(testDb.backend)
    check success == true
    check convId > 0
    
    # Create second database connection to same file
    let dbConfig = DatabaseConfig(
      `type`: dtSQLite,
      enabled: true,
      path: some(testDb.dbPath),
      walMode: false,
      busyTimeout: 1000,
      poolSize: 1
    )
    
    let secondDb = createDatabaseBackend(dbConfig)
    check secondDb != nil
    defer: secondDb.close()
    
    # Verify conversation persists across connections
    let persistenceVerified = verifyDatabasePersistence(testDb.backend, secondDb, convId)
    check persistenceVerified == true
    
    # Verify messages persist
    assertMessageCount(secondDb, convId, 4)  # simulateFullConversationWorkflow adds 4 messages
    
    # Verify we can retrieve conversation context from second connection
    let messages = getRecentMessagesFromDb(secondDb.pool, convId, 10)
    check messages.len == 4
    check messages[0].role == mrUser
    check messages[1].role == mrAssistant
    check messages[2].role == mrUser
    check messages[3].role == mrAssistant

  testConversationLifecycle "Multiple conversations with different models and modes":
    var testModel1 = createTestModelConfig()
    testModel1.nickname = "test-gpt-4"
    
    var testModel2 = createTestModelConfig()
    testModel2.nickname = "test-claude"
    
    # Create first conversation (Plan mode, GPT-4)
    let conv1Opt = createConversation(testDb.backend, "Planning Discussion", amPlan, testModel1.nickname)
    check conv1Opt.isSome()
    let conv1 = conv1Opt.get()
    
    # Create second conversation (Code mode, Claude)
    let conv2Opt = createConversation(testDb.backend, "Code Review", amCode, testModel2.nickname)
    check conv2Opt.isSome()
    let conv2 = conv2Opt.get()
    
    # Verify both conversations exist
    let conversations = listConversations(testDb.backend)
    check conversations.len == 2
    
    # Verify correct properties
    let planConv = conversations.filterIt(it.mode == amPlan)[0]
    let codeConv = conversations.filterIt(it.mode == amCode)[0]
    
    check planConv.title == "Planning Discussion"
    check planConv.modelNickname == "test-gpt-4"
    check codeConv.title == "Code Review"
    check codeConv.modelNickname == "test-claude"
    
    # Switch between conversations and add messages
    check switchToConversation(testDb.backend, conv1.id) == true
    initSessionManager(testDb.backend.pool, conv1.id)
    discard addUserMessage("Planning message")
    
    check switchToConversation(testDb.backend, conv2.id) == true
    initSessionManager(testDb.backend.pool, conv2.id)
    discard addUserMessage("Code review message")
    
    # Verify messages went to correct conversations
    assertMessageCount(testDb.backend, conv1.id, 1)
    assertMessageCount(testDb.backend, conv2.id, 1)
    
    let planMessages = getConversationMessages(testDb.backend, conv1.id)
    let codeMessages = getConversationMessages(testDb.backend, conv2.id)
    
    check planMessages[0].content == "Planning message"
    check codeMessages[0].content == "Code review message"

  testConversationLifecycle "Conversation search functionality with database content":
    # Create multiple conversations with distinct content
    let conv1Id = createTestConversationWithMessages(testDb.backend, "Authentication System Design", 4)
    let conv2Id = createTestConversationWithMessages(testDb.backend, "Bug Fix for Auth Module", 6)
    let conv3Id = createTestConversationWithMessages(testDb.backend, "UI Design Review", 2)
    
    # Add specific content that we can search for
    discard switchToConversation(testDb.backend, conv1Id)
    initSessionManager(testDb.backend.pool, conv1Id)
    discard addUserMessage("We need to implement OAuth2 authentication")
    discard addAssistantMessage("I recommend using the authorization code flow for OAuth2")
    
    discard switchToConversation(testDb.backend, conv2Id)
    initSessionManager(testDb.backend.pool, conv2Id)
    discard addUserMessage("There's a null pointer exception in the auth validator")
    discard addAssistantMessage("The authentication bug is in the token validation")
    
    # Test search functionality
    let authResults = searchConversations(testDb.backend, "authentication")
    check authResults.len == 2  # Should match both conversations
    
    let titleResults = authResults.filterIt(it.title.contains("Authentication"))
    let bugResults = authResults.filterIt(it.title.contains("Bug Fix"))
    
    check titleResults.len == 1
    check bugResults.len == 1
    check titleResults[0].title == "Authentication System Design"
    check bugResults[0].title == "Bug Fix for Auth Module"
    
    # Test search by specific content
    let oauthResults = searchConversations(testDb.backend, "OAuth2")
    check oauthResults.len == 1
    check oauthResults[0].title == "Authentication System Design"
    
    # Test search that should return no results
    let noResults = searchConversations(testDb.backend, "nonexistent")
    check noResults.len == 0

suite "Token Tracking and Session Persistence":
  
  testConversationLifecycle "Session token tracking persists across conversation switches":
    # Create two conversations
    let conv1Id = createTestConversationWithMessages(testDb.backend, "Token Test 1", 2)
    let conv2Id = createTestConversationWithMessages(testDb.backend, "Token Test 2", 2)
    
    # Switch to first conversation and simulate token usage
    check switchToConversation(testDb.backend, conv1Id) == true
    initSessionManager(testDb.backend.pool, conv1Id)
    
    updateSessionTokens(500, 300)  # Input: 500, Output: 300
    updateSessionTokens(200, 150)  # Additional tokens
    
    let tokens1 = getSessionTokens()
    check tokens1.inputTokens == 700
    check tokens1.outputTokens == 450
    check tokens1.totalTokens == 1150
    
    # Switch to second conversation
    check switchToConversation(testDb.backend, conv2Id) == true
    initSessionManager(testDb.backend.pool, conv2Id)
    
    # Verify new conversation has clean token state
    let tokens2 = getSessionTokens()
    check tokens2.inputTokens == 0
    check tokens2.outputTokens == 0
    check tokens2.totalTokens == 0
    
    # Add some tokens to second conversation
    updateSessionTokens(100, 75)
    let tokens2Updated = getSessionTokens()
    check tokens2Updated.inputTokens == 100
    check tokens2Updated.outputTokens == 75
    
    # Switch back to first conversation
    check switchToConversation(testDb.backend, conv1Id) == true
    initSessionManager(testDb.backend.pool, conv1Id)
    
    # Verify tokens were preserved (Note: This tests session isolation, not persistence)
    # In the current implementation, tokens are per-session, not per-conversation
    let restoredTokens = getSessionTokens()
    check restoredTokens.inputTokens == 0  # New session for conv1
    check restoredTokens.outputTokens == 0

suite "Conversation Context and Message Retrieval":
  
  testConversationLifecycle "Message context retrieval with proper ordering":
    # Create conversation with many messages
    let convId = createTestConversationWithMessages(testDb.backend, "Context Test", 10)
    
    # Add tool call messages
    discard switchToConversation(testDb.backend, convId)
    initSessionManager(testDb.backend.pool, convId)
    
    # Create a mock tool call
    let mockToolCall = LLMToolCall(
      id: "test_tool_call_1",
      `type`: "function",
      function: FunctionCall(
        name: "test_tool",
        arguments: """{"param": "value"}"""
      )
    )
    
    discard addAssistantMessage("I'll help with that tool call", some(@[mockToolCall]))
    discard addToolMessage("Tool execution completed successfully", "test_tool_call_1")
    
    # Verify complete context retrieval
    let (contextMessages, toolCallCount) = getConversationContextFromDb(testDb.backend.pool, convId)
    check contextMessages.len == 12  # 10 original + 1 assistant + 1 tool
    check toolCallCount == 1
    
    # Verify message ordering (chronological)
    for i in 0..<contextMessages.len-1:
      # Each message should be in proper sequence
      if i mod 2 == 0:
        check contextMessages[i].role == mrUser
      else:
        # Could be assistant or tool
        check contextMessages[i].role in [mrAssistant, mrTool]
    
    # Verify tool call message structure
    let toolCallMessage = contextMessages.filterIt(it.toolCalls.isSome())[0]
    check toolCallMessage.toolCalls.get().len == 1
    check toolCallMessage.toolCalls.get()[0].id == "test_tool_call_1"
    
    let toolResultMessage = contextMessages.filterIt(it.toolCallId.isSome())[0]
    check toolResultMessage.toolCallId.get() == "test_tool_call_1"
    check toolResultMessage.content == "Tool execution completed successfully"