import std/[unittest, os, tempfiles, json, options]
import ../src/core/[database, conversation_manager, app, mode_state]
import ../src/tools/[edit, create]
import ../src/types/[mode, tools, config as configTypes]
import test_utils

var testDb: DatabaseBackend
var testConvId: int
var testDir: string

proc createTestModelConfig(): configTypes.ModelConfig =
  result = configTypes.ModelConfig(
    nickname: "test-model",
    model: "test-gpt-4",
    baseUrl: "http://localhost:8080",
    context: 128000,
    inputCostPerMToken: some(10.0),
    outputCostPerMToken: some(30.0)
  )

proc setupTestEnvironment() =
  testDir = createTempDir("niffler_plan_mode_", "")
  setCurrentDir(testDir)
  testDb = createTestDatabaseBackend()
  clearTestDatabase(testDb)
  setGlobalDatabase(testDb)
  initializeModeState()

proc cleanupTestEnvironment() =
  if testDb != nil:
    try:
      testDb.close()
    except:
      discard
    testDb = nil
  if testDir != "" and dirExists(testDir):
    removeDir(testDir)

proc createTestFiles() =
  writeFile("existing_file1.txt", "This file existed before plan mode")
  writeFile("existing_file2.nim", "echo \"Existing Nim code\"")
  createDir("subdir")
  writeFile("subdir/nested_file.txt", "Nested existing file")

proc switchToPlanMode() =
  let testModel = createTestModelConfig()
  let conversation = createConversation(testDb, "Plan Mode Test", amCode, testModel.nickname)
  check conversation.isSome()
  testConvId = conversation.get().id
  
  check switchToConversation(testDb, testConvId) == true
  initSessionManager(testDb.pool)
  
  setCurrentMode(amCode)
  updateConversationMode(testDb, testConvId, amCode)
  
  setCurrentMode(amPlan)
  updateConversationMode(testDb, testConvId, amPlan)
  discard setPlanModeCreatedFiles(testDb, testConvId, @[])

proc switchToCodeMode() =
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
  
  test "Created files tracking enabled in plan mode":
    let createdFiles = getPlanModeCreatedFiles(testDb, testConvId)
    check createdFiles.enabled == true
    check createdFiles.createdFiles.len == 0
    
    check "existing_file1.txt" notin createdFiles.createdFiles
    check "existing_file2.nim" notin createdFiles.createdFiles
  
  test "checkPlanModeProtection identifies editable files":
    check checkPlanModeProtection("existing_file1.txt") == true
    check checkPlanModeProtection("existing_file2.nim") == true
    check checkPlanModeProtection("subdir/nested_file.txt") == true
    
    check checkPlanModeProtection("new_file.txt") == false
    check checkPlanModeProtection("nonexistent.nim") == false
  
  test "Edit tool blocks protected files in plan mode":
    let editArgs = %*{
      "path": "existing_file1.txt",
      "operation": "replace",
      "old_text": "This file existed",
      "new_text": "Modified content"
    }
    
    expect ToolValidationError:
      discard executeEdit(editArgs)
  
  test "Create tool allows new files in plan mode":
    let createArgs = %*{
      "path": "plan_mode_notes.md",
      "content": "# Planning Notes\nCreated during plan mode"
    }
    
    let result = executeCreate(createArgs)
    let resultJson = parseJson(result)
    check resultJson["created"].getBool() == true
    check fileExists("plan_mode_notes.md")
  
  test "Edit tool allows editing files created in plan mode":
    let createArgs = %*{
      "path": "new_plan_file.txt",
      "content": "Initial content"
    }
    discard executeCreate(createArgs)
    
    let createdFiles = getPlanModeCreatedFiles(testDb, testConvId)
    check "new_plan_file.txt" in createdFiles.createdFiles
    
    let editArgs = %*{
      "path": "new_plan_file.txt",
      "operation": "replace",
      "old_text": "Initial content",
      "new_text": "Modified content"
    }
    
    let result = executeEdit(editArgs)
    let resultJson = parseJson(result)
    check resultJson["changes_made"].getBool() == true
  
  test "Created files tracking cleared when switching to code mode":
    switchToCodeMode()
    
    let createdFiles = getPlanModeCreatedFiles(testDb, testConvId)
    check createdFiles.enabled == false
    
    check checkPlanModeProtection("existing_file1.txt") == false
    check checkPlanModeProtection("existing_file2.nim") == false

  test "Code mode mutations require todolist":
    switchToCodeMode()
    discard ensurePlanFile(testDb, testConvId, "Mutation Requirement Plan")

    let createArgs = %*{
      "path": "blocked_without_todo.txt",
      "content": "Should not be created"
    }

    expect ToolValidationError:
      discard executeCreate(createArgs)

    let editArgs = %*{
      "path": "existing_file1.txt",
      "operation": "replace",
      "old_text": "This file existed before plan mode",
      "new_text": "Blocked without todo"
    }

    expect ToolValidationError:
      discard executeEdit(editArgs)

  test "Code mode mutations allowed with plan and todolist":
    switchToCodeMode()
    let planPath = ensurePlanFile(testDb, testConvId, "Implementation Plan")
    check planPath.isSome()
    check hasActivePlan(testDb, testConvId) == true
    let listId = createTodoList(testDb, testConvId, "Implementation Tasks")
    discard addTodoItem(testDb, listId, "Make code change", tpHigh)

    let createArgs = %*{
      "path": "allowed_with_todo.txt",
      "content": "Created with todo"
    }

    let createResult = parseJson(executeCreate(createArgs))
    check createResult["created"].getBool() == true

    let editArgs = %*{
      "path": "existing_file1.txt",
      "operation": "replace",
      "old_text": "This file existed before plan mode",
      "new_text": "Allowed with todo"
    }

    let editResult = parseJson(executeEdit(editArgs))
    check editResult["changes_made"].getBool() == true
  
  test "Edit tool works normally in code mode":
    switchToCodeMode()
    let planPath = ensurePlanFile(testDb, testConvId, "Code Mode Edit Plan")
    check planPath.isSome()
    check hasActivePlan(testDb, testConvId) == true
    let listId = createTodoList(testDb, testConvId, "Edit Tasks")
    discard addTodoItem(testDb, listId, "Edit existing file", tpHigh)
    
    let editArgs = %*{
      "path": "existing_file1.txt",
      "operation": "replace",
      "old_text": "This file existed before plan mode",
      "new_text": "Modified in code mode"
    }
    
    let result = executeEdit(editArgs)
    let resultJson = parseJson(result)
    check resultJson["changes_made"].getBool() == true
  
  test "Protection works with absolute paths":
    let absolutePath = testDir / "existing_file1.txt"
    check checkPlanModeProtection(absolutePath) == true
  
  test "Protection handles non-existent current session":
    clearCurrentSession()
    initSessionManager()
    
    check checkPlanModeProtection("existing_file1.txt") == false
  
  test "Protection fails open on database errors":
    if testDb != nil:
      testDb.close()
      testDb = nil
    setGlobalDatabase(nil)
    
    check checkPlanModeProtection("existing_file1.txt") == false

suite "Mode Restore Tests":
  setup:
    setupTestEnvironment()
    createTestFiles()
  
  teardown:
    cleanupTestEnvironment()
  
  proc createPlanModeConversation(): int =
    let testModel = createTestModelConfig()
    let conversation = createConversation(testDb, "Test Plan Mode", amPlan, testModel.nickname)
    check conversation.isSome()
    let convId = conversation.get().id
    
    check switchToConversation(testDb, convId) == true
    initSessionManager(testDb.pool)
    
    setCurrentMode(amPlan)
    discard setPlanModeCreatedFiles(testDb, convId, @[])
    
    return convId
  
  test "restoreModeWithProtection initializes protection for plan mode":
    let convId = createPlanModeConversation()
    
    setCurrentMode(amCode)
    clearCurrentSession()
    
    check switchToConversation(testDb, convId) == true
    initSessionManager(testDb.pool)
    
    let conversationOpt = getConversationById(testDb, convId)
    check conversationOpt.isSome()
    
    restoreModeWithProtection(conversationOpt.get().mode)
    
    check getCurrentMode() == amPlan
    
    let createdFiles = getPlanModeCreatedFiles(testDb, convId)
    check createdFiles.enabled == true
    check createdFiles.createdFiles.len == 0
    
    check "existing_file1.txt" notin createdFiles.createdFiles
    
    check checkPlanModeProtection("existing_file1.txt") == true
    check checkPlanModeProtection("existing_file2.nim") == true
  
  test "restoreModeWithProtection allows editing in code mode":
    let testModel = createTestModelConfig()
    let conversation = createConversation(testDb, "Test Code Mode", amCode, testModel.nickname)
    check conversation.isSome()
    let convId = conversation.get().id
    
    check switchToConversation(testDb, convId) == true
    initSessionManager(testDb.pool)
    
    setCurrentMode(amPlan)
    discard setPlanModeCreatedFiles(testDb, convId, @[])
    
    restoreModeWithProtection(amCode)
    
    check getCurrentMode() == amCode
    
    let createdFiles = getPlanModeCreatedFiles(testDb, convId)
    check createdFiles.enabled == false
    
    check checkPlanModeProtection("existing_file1.txt") == false
  
  test "Edit tool works correctly after mode restore":
    let convId = createPlanModeConversation()
    
    setCurrentMode(amCode)
    clearCurrentSession()
    check switchToConversation(testDb, convId) == true
    initSessionManager(testDb.pool)
    
    let conversationOpt = getConversationById(testDb, convId)
    check conversationOpt.isSome()
    restoreModeWithProtection(conversationOpt.get().mode)
    
    let editArgs = %*{
      "path": "existing_file1.txt",
      "operation": "replace",
      "old_text": "This file existed",
      "new_text": "Modified content"
    }
    
    expect ToolValidationError:
      discard executeEdit(editArgs)
    
    let createArgs = %*{
      "path": "new_plan_file.md",
      "content": "# New file"
    }
    
    let result = executeCreate(createArgs)
    let resultJson = parseJson(result)
    check resultJson["created"].getBool() == true
    check fileExists("new_plan_file.md")

echo "All plan mode tests completed"
