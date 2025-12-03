## Conversation Mode Restore Tests
##
## This module tests that plan mode protection is properly initialized
## when loading conversations that are already in plan mode.

import std/[unittest, os, tempfiles, json, options]
import ../src/core/[database, conversation_manager, app, mode_state]
import ../src/tools/[edit, create], ../src/types/[mode, tools, config as configTypes]
import test_utils

# Test database and conversation setup
var testDb: DatabaseBackend
var testDir: string

proc createSimpleTestModelConfig(): configTypes.ModelConfig =
  ## Create a simple test model configuration
  result = configTypes.ModelConfig(
    nickname: "test-model",
    model: "test-gpt-4",
    baseUrl: "http://localhost:8080",
    context: 128000,
    inputCostPerMToken: some(10.0),
    outputCostPerMToken: some(30.0)
  )

proc setupTestEnvironment() =
  ## Setup test database and files in a temporary directory
  testDir = createTempDir("niffler_mode_restore_", "")
  setCurrentDir(testDir)

  # Create test database
  testDb = createTestDatabaseBackend()
  clearTestDatabase(testDb)
  setGlobalDatabase(testDb)

  # Initialize mode state
  initializeModeState()

proc cleanupTestEnvironment() =
  ## Cleanup test environment
  if testDb != nil:
    try:
      testDb.close()
    except:
      discard
    testDb = nil
  if testDir != "" and dirExists(testDir):
    removeDir(testDir)

proc createTestFiles() =
  ## Create test files that should be protected in plan mode
  writeFile("existing_file1.txt", "This file existed before plan mode")
  writeFile("existing_file2.nim", "echo \"Existing Nim code\"")
  createDir("subdir")
  writeFile("subdir/nested_file.txt", "Nested existing file")

proc createPlanModeConversation(): int =
  ## Create a conversation that's already in plan mode with protection
  let testModel = createSimpleTestModelConfig()
  
  # Create conversation in plan mode
  let conversation = createConversation(testDb, "Test Plan Mode Conversation", amPlan, testModel.nickname)
  check conversation.isSome()
  let convId = conversation.get().id
  
  # Switch to the conversation
  check switchToConversation(testDb, convId) == true
  initSessionManager(testDb.pool)
  
  # Set up plan mode created files tracking as if the user had previously entered plan mode
  setCurrentMode(amPlan)
  discard setPlanModeCreatedFiles(testDb, convId, @[])
  
  return convId

suite "Conversation Mode Restore Tests":
  setup:
    setupTestEnvironment()
    createTestFiles()
  
  teardown:
    cleanupTestEnvironment()
  
  test "restoreModeWithProtection initializes protection when restoring to plan mode":
    # Create a conversation already in plan mode
    let convId = createPlanModeConversation()
    
    # Simulate starting fresh (clear current mode and session)
    setCurrentMode(amCode)
    clearCurrentSession()
    
    # Now simulate loading the conversation (like startup or /conv command would)
    check switchToConversation(testDb, convId) == true
    initSessionManager(testDb.pool)
    
    # Get the conversation and restore its mode using our new function
    let conversationOpt = getConversationById(testDb, convId)
    check conversationOpt.isSome()
    let conversation = conversationOpt.get()
    
    # This is the key - use restoreModeWithProtection instead of setCurrentMode
    restoreModeWithProtection(conversation.mode)
    
    # Verify that we're in plan mode
    check getCurrentMode() == amPlan
    
    # Verify that created files tracking is active
    let createdFiles = getPlanModeCreatedFiles(testDb, convId)
    check createdFiles.enabled == true
    check createdFiles.createdFiles.len == 0  # Initially empty
    
    # Verify our test files are NOT in created files (so they're protected)
    check "existing_file1.txt" notin createdFiles.createdFiles
    check "existing_file2.nim" notin createdFiles.createdFiles
    check "subdir/nested_file.txt" notin createdFiles.createdFiles
    
    # Verify checkPlanModeProtection works
    check checkPlanModeProtection("existing_file1.txt") == true
    check checkPlanModeProtection("existing_file2.nim") == true
  
  test "restoreModeWithProtection allows editing when restoring to code mode":
    # Create a conversation in code mode
    let testModel = createSimpleTestModelConfig()
    let conversation = createConversation(testDb, "Test Code Mode Conversation", amCode, testModel.nickname)
    check conversation.isSome()
    let convId = conversation.get().id
    
    # Switch to the conversation and restore mode
    check switchToConversation(testDb, convId) == true
    initSessionManager(testDb.pool)
    
    # Start from plan mode (to test the transition)
    setCurrentMode(amPlan)
    discard setPlanModeCreatedFiles(testDb, convId, @[])  # Set up created files tracking first
    
    # Now restore to code mode
    restoreModeWithProtection(amCode)
    
    # Verify we're in code mode
    check getCurrentMode() == amCode
    
    # Verify created files tracking is cleared
    let createdFiles = getPlanModeCreatedFiles(testDb, convId)
    check createdFiles.enabled == false
    
    # Verify files are not protected
    check checkPlanModeProtection("existing_file1.txt") == false
    check checkPlanModeProtection("existing_file2.nim") == false
  
  test "Edit tool works correctly after mode restore":
    # Create conversation in plan mode with protection
    let convId = createPlanModeConversation()
    
    # Simulate conversation loading
    setCurrentMode(amCode)  # Start from different mode
    clearCurrentSession()
    check switchToConversation(testDb, convId) == true
    initSessionManager(testDb.pool)
    
    # Restore mode (this should enable protection)
    let conversationOpt = getConversationById(testDb, convId)
    check conversationOpt.isSome()
    restoreModeWithProtection(conversationOpt.get().mode)
    
    # Try to edit an existing file - should fail
    let editArgs = %*{
      "path": "existing_file1.txt",
      "operation": "replace",
      "old_text": "This file existed",
      "new_text": "Modified content"
    }
    
    expect ToolValidationError:
      discard executeEdit(editArgs)
    
    # But creating new files should work
    let createArgs = %*{
      "path": "new_plan_file.md",
      "content": "# New file created in plan mode"
    }
    
    let result = executeCreate(createArgs)
    let resultJson = parseJson(result)
    check resultJson["created"].getBool() == true
    check fileExists("new_plan_file.md")

when isMainModule:
  # Run tests when compiled directly
  discard