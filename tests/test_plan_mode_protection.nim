## Plan Mode File Protection Tests
##
## This module tests the plan mode file protection system that prevents
## editing existing files while in plan mode, ensuring clear separation
## between planning and implementation phases.

import std/[unittest, os, tempfiles, json, options]
import ../src/core/[database, conversation_manager, app, mode_state]
import ../src/tools/[edit, create], ../src/types/[mode, tools, config as configTypes]
import test_utils

# Test database and conversation setup
var testDb: DatabaseBackend
var testConvId: int
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
  ## Setup test database and conversation in a temporary directory
  testDir = createTempDir("niffler_plan_protection_", "")
  setCurrentDir(testDir)

  # Create test database using test_utils
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
      discard  # Ignore errors during cleanup
    testDb = nil
  if testDir != "" and dirExists(testDir):
    removeDir(testDir)

proc createTestFiles() =
  ## Create test files that should be protected in plan mode
  writeFile("existing_file1.txt", "This file existed before plan mode")
  writeFile("existing_file2.nim", "echo \"Existing Nim code\"")
  createDir("subdir")
  writeFile("subdir/nested_file.txt", "Nested existing file")

proc switchToPlanMode() =
  ## Switch to plan mode and trigger file protection
  let testModel = createSimpleTestModelConfig()
  # Start conversation in code mode, not plan mode
  let conversation = createConversation(testDb, "Plan Mode Test", amCode, testModel.nickname)
  check conversation.isSome()
  testConvId = conversation.get().id
  
  # Switch to the conversation and initialize session
  check switchToConversation(testDb, testConvId) == true
  initSessionManager(testDb.pool)
  
  # Start in code mode to ensure we have a different previous mode
  setCurrentMode(amCode)
  updateConversationMode(testDb, testConvId, amCode)
  
  # Now switch to plan mode and manually initialize created files tracking
  setCurrentMode(amPlan)
  updateConversationMode(testDb, testConvId, amPlan)
  discard setPlanModeCreatedFiles(testDb, testConvId, @[])

proc switchToCodeMode() =
  ## Switch to code mode which should clear created files tracking
  setCurrentMode(amCode)
  updateConversationMode(testDb, testConvId, amCode)
  discard clearPlanModeCreatedFiles(testDb, testConvId)

suite "Plan Mode File Protection Tests":
  setup:
    setupTestEnvironment()
    createTestFiles()
    switchToPlanMode()
  
  teardown:
    cleanupTestEnvironment()
  
  test "Plan mode created files tracking is enabled after entering plan mode":
    # Verify created files tracking state is stored in database
    let createdFiles = getPlanModeCreatedFiles(testDb, testConvId)
    check createdFiles.enabled == true
    check createdFiles.createdFiles.len == 0  # Initially empty
    
    # Verify our existing test files are NOT in the created files list
    check "existing_file1.txt" notin createdFiles.createdFiles
    check "existing_file2.nim" notin createdFiles.createdFiles
    check "subdir/nested_file.txt" notin createdFiles.createdFiles
  
  test "checkPlanModeProtection correctly identifies editable files":
    # Existing files should be protected (not created in plan mode)
    check checkPlanModeProtection("existing_file1.txt") == true
    check checkPlanModeProtection("existing_file2.nim") == true
    check checkPlanModeProtection("subdir/nested_file.txt") == true
    
    # Files that don't exist should be allowed (new file creation)
    check checkPlanModeProtection("new_file.txt") == false
    check checkPlanModeProtection("nonexistent.nim") == false
  
  test "Edit tool blocks protected files in plan mode":
    # Try to edit an existing file - should fail
    let editArgs = %*{
      "path": "existing_file1.txt",
      "operation": "replace",
      "old_text": "This file existed",
      "new_text": "Modified content"
    }
    
    expect ToolValidationError:
      discard executeEdit(editArgs)
  
  test "Create tool allows creating new files in plan mode":
    # Create a new file during plan mode - should work
    let createArgs = %*{
      "path": "plan_mode_notes.md", 
      "content": "# Planning Notes\nThis file was created during plan mode"
    }
    
    # This should not raise an exception
    let result = executeCreate(createArgs)
    let resultJson = parseJson(result)
    check resultJson["created"].getBool() == true
    check fileExists("plan_mode_notes.md")
  
  test "Edit tool allows editing files created in plan mode":
    # First create a file using create tool (should be tracked automatically)
    let createArgs = %*{
      "path": "new_plan_file.txt",
      "content": "Initial content"
    }
    discard executeCreate(createArgs)
    
    # Verify the file was added to created files list
    let createdFiles = getPlanModeCreatedFiles(testDb, testConvId)
    check "new_plan_file.txt" in createdFiles.createdFiles
    
    # Then edit it - should work since it's in the created files list
    let editArgs = %*{
      "path": "new_plan_file.txt",
      "operation": "replace",
      "old_text": "Initial content",
      "new_text": "Modified content"
    }
    
    # This should not raise an exception
    let result = executeEdit(editArgs)
    let resultJson = parseJson(result)
    check resultJson["changes_made"].getBool() == true
  
  test "Created files tracking is cleared when switching to code mode":
    # Switch to code mode
    switchToCodeMode()
    
    # Verify created files tracking is cleared in database
    let createdFiles = getPlanModeCreatedFiles(testDb, testConvId)
    check createdFiles.enabled == false
    
    # Verify files are no longer protected
    check checkPlanModeProtection("existing_file1.txt") == false
    check checkPlanModeProtection("existing_file2.nim") == false
  
  test "Edit tool works normally in code mode":
    # Switch to code mode
    switchToCodeMode()
    
    # Now editing existing files should work
    let editArgs = %*{
      "path": "existing_file1.txt",
      "operation": "replace", 
      "old_text": "This file existed before plan mode",
      "new_text": "Modified in code mode"
    }
    
    # This should not raise an exception
    let result = executeEdit(editArgs)
    let resultJson = parseJson(result)
    check resultJson["changes_made"].getBool() == true
  
  test "Protection works with absolute paths":
    # Test with absolute path
    let absolutePath = testDir / "existing_file1.txt"
    check checkPlanModeProtection(absolutePath) == true
  
  test "Protection handles non-existent current session gracefully":
    # Clear current session to simulate no active conversation
    clearCurrentSession()
    initSessionManager()
    
    # Should return false (no protection) rather than crash
    check checkPlanModeProtection("existing_file1.txt") == false
  
  test "Protection fails open on database errors":
    # Close database to simulate error condition
    if testDb != nil:
      testDb.close()
      testDb = nil
    setGlobalDatabase(nil)
    
    # Should return false (allow operation) rather than crash
    check checkPlanModeProtection("existing_file1.txt") == false

when isMainModule:
  # Run tests when compiled directly
  discard