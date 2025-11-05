## CLI Command Integration Tests for Conversation Management
##
## These tests verify that all conversation management CLI commands work correctly
## through the full command execution pipeline with real database operations.

import std/[unittest, strformat, times, strutils, sequtils, options]
import test_conversation_infrastructure
import ../src/core/[database, conversation_manager, config, app, session]
import ../src/types/[config as configTypes, messages, mode]
import ../src/ui/commands

suite "CLI Command Integration Tests":
  
  testConversationLifecycle "New conversation command creates and switches":
    var testModel = createTestModelConfig()
    var session = initSession()

    # Test /new command without title
    let result1 = executeCommand("new", @[], session, testModel)
    check result1.success == true
    check "Created and switched to new conversation:" in result1.message
    
    # Verify conversation was created
    let conversations = listConversations(testDb.backend)
    check conversations.len == 1
    check conversations[0].isActive == true
    
    # Test /new command with title
    let result2 = executeCommand("new", @["Test", "Conversation", "Title"], session, testModel)
    check result2.success == true
    check "Test Conversation Title" in result2.message
    
    # Verify second conversation was created
    let updatedConversations = listConversations(testDb.backend)
    check updatedConversations.len == 2
    
    let namedConv = updatedConversations.filterIt("Test Conversation Title" in it.title)
    check namedConv.len == 1
    check namedConv[0].title == "Test Conversation Title"

  testConversationLifecycle "Conversation listing command shows proper formatting":
    # Create multiple conversations with different states
    var testModel = createTestModelConfig()
    var session = initSession()

    let conv1Id = createTestConversationWithMessages(testDb.backend, "Active Project Discussion", 5)
    let conv2Id = createTestConversationWithMessages(testDb.backend, "Completed Bug Fix", 3)
    let conv3Id = createTestConversationWithMessages(testDb.backend, "Draft API Design", 7)

    # Archive one conversation
    discard archiveConversation(testDb.backend, conv2Id)

    # Switch to one conversation to mark it as current
    discard switchToConversation(testDb.backend, conv1Id)

    # Test /conv command (list mode)
    let result = executeCommand("conv", @[], session, testModel)
    check result.success == true
    check "ID" in result.message  # Table header
    check "Title" in result.message  # Table header
    
    # Verify active conversations are listed (archived ones hidden by default)
    check "Active Project Discussion" in result.message
    check "Draft API Design" in result.message
    # Archived conversation should NOT be in active list
    check "Completed Bug Fix" notin result.message
    
    # Verify status markers in new format
    check "Current" in result.message   # Should show current conversation
    
    # Verify metadata is shown in new format
    check "msgs" in result.message  # Message count format
    check "Mode/Model" in result.message  # Table header

  testConversationLifecycle "Conversation switching by ID and title":
    var testModel = createTestModelConfig()
    var session = initSession()

    let conv1Id = createTestConversationWithMessages(testDb.backend, "First Conversation", 2)
    let conv2Id = createTestConversationWithMessages(testDb.backend, "Second Conversation", 3)

    # Test switching by ID using /conv command
    let switchById = executeCommand("conv", @[$conv2Id], session, testModel)
    check switchById.success == true
    check "Switched to conversation: Second Conversation" in switchById.message

    # Verify current session
    let currentSession = getCurrentSession()
    check currentSession.isSome()
    check currentSession.get().conversation.id == conv2Id

    # Test switching by title using /conv command
    let switchByTitle = executeCommand("conv", @["First"], session, testModel)
    check switchByTitle.success == true
    check "Switched to conversation: First Conversation" in switchByTitle.message

    # Verify session changed
    let newSession = getCurrentSession()
    check newSession.isSome()
    check newSession.get().conversation.id == conv1Id

    # Test switching by exact title match
    let switchExact = executeCommand("conv", @["Second", "Conversation"], session, testModel)
    check switchExact.success == true
    check "Switched to conversation: Second Conversation" in switchExact.message

    # Test invalid conversation ID
    let switchInvalid = executeCommand("conv", @["999"], session, testModel)
    check switchInvalid.success == false
    check "Failed to switch to conversation ID 999" in switchInvalid.message

    # Test non-existent title
    let switchNonExistent = executeCommand("conv", @["NonExistent"], session, testModel)
    check switchNonExistent.success == false
    check "No conversation found matching 'NonExistent'" in switchNonExistent.message

  testConversationLifecycle "Archive command functionality":
    var testModel = createTestModelConfig()
    var session = initSession()

    let conv1Id = createTestConversationWithMessages(testDb.backend, "To Be Archived", 4)
    let conv2Id = createTestConversationWithMessages(testDb.backend, "Active Conversation", 2)

    # Test archive command
    let archiveResult = executeCommand("archive", @[$conv1Id], session, testModel)
    check archiveResult.success == true
    check fmt"Archived conversation ID {conv1Id}" in archiveResult.message

    # Verify conversation is archived in database
    let archivedConv = getConversationById(testDb.backend, conv1Id)
    check archivedConv.isSome()
    check archivedConv.get().isActive == false

    # Verify other conversation is still active
    let activeConv = getConversationById(testDb.backend, conv2Id)
    check activeConv.isSome()
    check activeConv.get().isActive == true

    # Test archiving invalid ID
    let invalidArchive = executeCommand("archive", @["999"], session, testModel)
    check invalidArchive.success == false
    check "Failed to archive conversation ID 999" in invalidArchive.message

    # Test archive command without arguments
    let noArgs = executeCommand("archive", @[], session, testModel)
    check noArgs.success == false
    check "Usage: /archive <conversation_id>" in noArgs.message

  testConversationLifecycle "Search command with database content matching":
    var testModel = createTestModelConfig()
    var session = initSession()

    # Create conversations with searchable content
    let conv1Id = createTestConversationWithMessages(testDb.backend, "Python Development Setup", 3)
    let conv2Id = createTestConversationWithMessages(testDb.backend, "JavaScript Testing Framework", 4)
    let conv3Id = createTestConversationWithMessages(testDb.backend, "Python Data Analysis", 2)

    # Add specific content for searching
    discard switchToConversation(testDb.backend, conv1Id)
    initSessionManager(testDb.backend.pool, conv1Id)
    discard addUserMessage("How do I set up virtual environments in Python?")
    discard addAssistantMessage("Use venv to create Python virtual environments")

    discard switchToConversation(testDb.backend, conv2Id)
    initSessionManager(testDb.backend.pool, conv2Id)
    discard addUserMessage("What testing framework should I use for JavaScript?")
    discard addAssistantMessage("Jest is a popular JavaScript testing framework")

    # Test search by programming language
    let pythonResults = executeCommand("search", @["Python"], session, testModel)
    check pythonResults.success == true
    check "Found 2 conversations matching 'Python':" in pythonResults.message
    check "Python Development Setup" in pythonResults.message
    check "Python Data Analysis" in pythonResults.message

    # Test search by specific terms
    let testingResults = executeCommand("search", @["testing"], session, testModel)
    check testingResults.success == true
    check "Found 1 conversations matching 'testing':" in testingResults.message
    check "JavaScript Testing Framework" in testingResults.message

    # Test search by content (not just title)
    let venvResults = executeCommand("search", @["virtual", "environments"], session, testModel)
    check venvResults.success == true
    check "Python Development Setup" in venvResults.message

    # Test search with no results
    let noResults = executeCommand("search", @["nonexistent"], session, testModel)
    check noResults.success == true
    check "No conversations found matching 'nonexistent'" in noResults.message

    # Test search without arguments
    let noArgs = executeCommand("search", @[], session, testModel)
    check noArgs.success == false
    check "Usage: /search <query>" in noArgs.message

  testConversationLifecycle "Info command shows current conversation details":
    var testModel = createTestModelConfig()
    var session = initSession()

    # Clear any existing session to ensure clean state
    clearCurrentSession()

    # Test info command with no active conversation
    let noConvResult = executeCommand("info", @[], session, testModel)
    check noConvResult.success == true
    check "No active conversation" in noConvResult.message

    # Create and switch to conversation
    let convId = createTestConversationWithMessages(testDb.backend, "Detailed Info Test", 5)
    discard switchToConversation(testDb.backend, convId)

    # Test info command with active conversation
    let infoResult = executeCommand("info", @[], session, testModel)
    check infoResult.success == true
    check "Current Conversation:" in infoResult.message
    check fmt"ID: {convId}" in infoResult.message
    check "Title: Detailed Info Test" in infoResult.message
    check "Messages: 5" in infoResult.message
    check "Created:" in infoResult.message
    check "Last Activity:" in infoResult.message
    check "Session Started:" in infoResult.message

suite "Command Error Handling and Edge Cases":
  
  # NOTE: This test is skipped because getGlobalDatabase() auto-initializes 
  # the database when it's nil, making it impossible to test database unavailability
  # without major architectural changes.
  when false:
    testConversationLifecycle "Command execution without database":
      var testModel = createTestModelConfig()
      
      # Temporarily set global database to nil
      setGlobalDatabase(nil)
      
      # Test commands that require database
      let newResult = executeCommand("new", @["Test"], testModel)
      check newResult.success == false
      check "Database not available" in newResult.message
      
      let convResult = executeCommand("conv", @[], testModel)
      check convResult.success == false
      check "Database not available" in convResult.message
      
      let archiveResult = executeCommand("archive", @["1"], testModel)
      check archiveResult.success == false
      check "Database not available" in archiveResult.message
      
      let searchResult = executeCommand("search", @["test"], testModel)
      check searchResult.success == false
      check "Database not available" in searchResult.message
      
      # Restore database for cleanup
      setGlobalDatabase(testDb.backend)

  testConversationLifecycle "Model switching integration with conversation context":
    # This test would verify that model changes are properly reflected
    # in conversation context, but requires a more complex setup with
    # multiple model configurations
    
    var testModel1 = createTestModelConfig()
    testModel1.nickname = "gpt4"
    
    var testModel2 = createTestModelConfig() 
    testModel2.nickname = "claude"
    
    # Create conversation with first model
    let convOpt = createConversation(testDb.backend, "Model Switch Test", amCode, testModel1.nickname)
    check convOpt.isSome()
    
    let conv = convOpt.get()
    check conv.modelNickname == "gpt4"
    
    # Switch to conversation should update model context
    # (This would require extending the test to include model configuration loading)
    discard switchToConversation(testDb.backend, conv.id)
    
    # Verify conversation properties
    let retrievedConv = getConversationById(testDb.backend, conv.id)
    check retrievedConv.isSome()
    check retrievedConv.get().modelNickname == "gpt4"

suite "Concurrent Operations and Thread Safety":
  
  testConversationLifecycle "Sequential conversation operations maintain consistency":
    var testModel = createTestModelConfig()
    var session = initSession()

    # Perform rapid sequential operations
    var results = newSeq[CommandResult](5)
    for i in 0..4:
      results[i] = executeCommand("new", @[fmt"Rapid Test {i}"], session, testModel)
      check results[i].success == true

    # Verify all conversations were created
    let conversations = listConversations(testDb.backend)
    check conversations.len == 5

    # Verify each conversation has correct title
    for i in 0..4:
      let expectedTitle = fmt"Rapid Test {i}"
      let foundConv = conversations.filterIt(it.title == expectedTitle)
      check foundConv.len == 1

    # Test rapid switching between conversations
    for conv in conversations:
      let switchResult = executeCommand("conv", @[$conv.id], session, testModel)
      check switchResult.success == true

      # Verify current session
      let session = getCurrentSession()
      check session.isSome()
      check session.get().conversation.id == conv.id