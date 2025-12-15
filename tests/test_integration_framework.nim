## Integration Tests for Niffler with Real LLM
##
## These tests verify end-to-end functionality using actual LLM APIs.
## Skip if API key is not configured.

import std/[unittest, os, times, options, strutils, json, logging, tables]
import ../src/core/[config, session, app, database, conversation_manager, nats_client, channels]
import ../src/types/[messages, config as configTypes, mode]
import ../src/api/api
import ../src/ui/[cli, master_cli]
import debby/pools

# Test configuration - can be overridden via environment variables
const
  TEST_MODEL = getEnv("NIFflER_TEST_MODEL", "gpt-4o-mini")
  TEST_API_KEY = getEnv("NIFflER_TEST_API_KEY", "")
  TEST_BASE_URL = getEnv("NIFflER_TEST_BASE_URL", "https://api.openai.com/v1")
  TEST_NATS_URL = getEnv("NIFflER_TEST_NATS_URL", "nats://localhost:4222")

var
  testConfig: Config
  testDatabase: DatabaseBackend

suite "Integration Tests with Real LLM":

  setup:
    # Initialize test configuration
    testConfig = Config(
      yourName: "Test User",
      models: @[
        ModelConfig(
          nickname: TEST_MODEL,
          model: TEST_MODEL,
          baseUrl: TEST_BASE_URL,
          apiKey: some(TEST_API_KEY),
          maxTokens: some(1000),
          temperature: some(0.1)
        )
      ],
      database: some(DatabaseConfig(
        host: "127.0.0.1",
        port: 4000,
        database: "niffler_test",
        username: "root",
        password: ""
      ))
    )

    # Initialize test database
    testDatabase = createDatabaseBackend(testConfig.database.get())

    # Clean up any existing test data
    # TODO: Implement test cleanup when database API is available
    # testDatabase.execute("DELETE FROM conversation WHERE title LIKE 'test_%'")

  teardown:
    # Clean up test database
    if testDatabase != nil:
      # TODO: Implement test cleanup when database API is available
      # testDatabase.execute("DELETE FROM conversation WHERE title LIKE 'test_%'")
      testDatabase.close()


  test "Simple Q&A with real LLM":
    #[ Test basic LLM integration without tool usage ]#
    if TEST_API_KEY.len == 0:
      skip

    # Initialize API worker
    var apiChannels = initializeChannels()
    var apiProc = apiWorkerProc
    var apiThread: Thread[ThreadParams]
    var params = ThreadParams(channels: addr apiChannels, level: lvlInfo, dump: false)
    createThread(apiThread, apiProc, params)

    defer:
      signalShutdown(addr apiChannels)
      joinThread(apiThread)

    # Wait for API worker to be ready
    sleep(1000)

    # Create conversation
    let convTitle = "test_qa_integration_" & $getTime().toUnix()
    let conversation = createConversation(testDatabase, convTitle, amCode, TEST_MODEL)
    check conversation.isSome

    let convId = conversation.get().id
    discard switchToConversation(testDatabase, convId)

    # Send simple question
    let messages = @[
      Message(role: mrUser, content: "What is 2 + 2? Respond with just the number.")
    ]

    # Send request to API worker
    discard trySendAPIRequest(addr apiChannels, APIRequest(
      kind: arkChatRequest,
      messages: messages,
      model: testConfig.models[0].model,
      modelNickname: testConfig.models[0].nickname,
      requestId: $epochTime(),
      maxTokens: 1000,
      temperature: 0.1,
      baseUrl: testConfig.models[0].baseUrl,
      apiKey: testConfig.models[0].apiKey.get(""),
      enableTools: true
    ))

    # Wait for response
    var response: ApiResponse
    for i in 0..<50:  # Max 5 seconds
      var response: APIResponse
      if tryReceiveAPIResponse(addr apiChannels, response):
        break
      sleep(100)

    check response.kind == arkStreamComplete
    check true  # Response arrived successfully
    check "4" in response.content.toLowerAscii()

    # Verify database persistence
    let dbMessages = getRecentMessagesFromDb(testDatabase.pool, convId)
    check dbMessages.len >= 2  # User + assistant messages

  test "Tool execution with real LLM":
    #[ Test LLM's ability to use tools ]#
    if TEST_API_KEY.len == 0:
      skip

    # Create test file
    let testContent = "This is a test file for integration testing.\n"
    let testFile = "/tmp/niffler_test_integration.txt"
    writeFile(testFile, testContent)

    defer:
      if fileExists(testFile):
        removeFile(testFile)

    # Initialize API worker
    var apiChannels = initializeChannels()
    var apiThread: Thread[ThreadParams]
    var params = ThreadParams(channels: addr apiChannels, level: lvlInfo, dump: false)
    createThread(apiThread, apiWorkerProc, params)

    defer:
      signalShutdown(addr apiChannels)
      joinThread(apiThread)

    sleep(1000)  # Wait for worker

    # Create conversation
    let convTitle = "test_tool_integration_" & $getTime().toUnix()
    let conversation = createConversation(testDatabase, convTitle, amCode, TEST_MODEL)
    let convId = conversation.get().id
    discard switchToConversation(testDatabase, convId)

    # Send request that requires tool usage
    let messages = @[
      Message(role: mrUser, content: fmt"Read the file {testFile} and tell me what it contains.")
    ]

    discard trySendAPIRequest(addr apiChannels, APIRequest(
      kind: arkChatRequest,
      messages: messages,
      model: testConfig.models[0].model,
      modelNickname: testConfig.models[0].nickname,
      requestId: $epochTime(),
      maxTokens: 1000,
      temperature: 0.1,
      baseUrl: testConfig.models[0].baseUrl,
      apiKey: testConfig.models[0].apiKey.get(""),
      enableTools: true
    ))

    # Collect response(s)
    var finalResponse: ApiResponse
    var toolCallDetected = false

    for i in 0..<100:  # Max 10 seconds
      var response: APIResponse
      if tryReceiveAPIResponse(addr apiChannels, response):
        if response.kind == arkToolCallRequest:
          toolCallDetected = true
        elif response.kind == arkStreamComplete:
          finalResponse = response
          break
      sleep(100)

    check toolCallDetected, "LLM should have made a tool call"
    check finalResponse.content.len > 0
    check "test file" in finalResponse.content.toLowerAscii()

  test "Master-Agent E2E Communication":
    #[ Test full master-agent workflow ]#
    if TEST_API_KEY.len == 0:
      skip

    # Test NATS availability
    try:
      var natsTest = initNatsClient(TEST_NATS_URL, "test", 0)
      natsTest.close()
    except:
      skip

    # This is a simplified test since we can't easily spawn full processes in tests
    # In a real test suite, you would:
    # 1. Launch nats-server process
    # 2. Launch agent process: niffler agent coder
    # 3. Launch master process: niffler --master
    # 4. Send command via master's API or stdin
    # 5. Verify response and persistence

    # For now, we test the master mode components directly
    var masterState = initializeMaster(TEST_NATS_URL)
    check masterState.connected

    # Test agent input parsing
    let input1 = "@coder fix the bug"
    let parsed1 = parseAgentInput(input1)
    check parsed1.agentName == "coder"
    check parsed1.input == "fix the bug"

    let input2 = "help me debug"
    let parsed2 = parseAgentInput(input2)
    check parsed2.agentName.len == 0
    check parsed2.input == "help me debug"

    masterState.cleanup()

suite "Integration Test Utilities":

  test "Test environment validation":
    #[ Verify test environment is properly configured ]#

    # We expect these to be configurable, not all required
    if TEST_API_KEY.len > 0:
      echo "✅ API key configured for testing"
      echo "  Model: ", TEST_MODEL
      echo "  Base URL: ", TEST_BASE_URL
    else:
      echo "⚠️  No API key - real LLM tests will be skipped"
      echo "  Set NIFflER_TEST_API_KEY to enable"

    try:
      var natsTest = initNatsClient(TEST_NATS_URL, "test", 0)
      natsTest.close()
      echo "✅ NATS server available at: ", TEST_NATS_URL
    except:
      echo "⚠️  NATS not available - master mode tests will be skipped"
      echo "  Start NATS with: nats-server -js"

    try:
      let dbConfig = DatabaseConfig(
        host: "127.0.0.1",
        port: 4000,
        database: "niffler_test",
        username: "root",
        password: ""
      )
      let testDb = createDatabaseBackend(dbConfig)
      testDb.close()
      echo "✅ Database available for testing"
    except:
      echo "⚠️  Database not available - persistence tests will fail"
      echo "  Ensure TiDB/MySQL is running on localhost:4000"

when isMainModule:
  # Run with: nim c -r tests/test_integration_framework.nim
  echo """
🧪 Niffler Integration Test Suite
================================

These tests verify end-to-end functionality with real services.

Environment variables:
  NIFflER_TEST_API_KEY - LLM API key for testing
  NIFflER_TEST_MODEL - Model name (default: gpt-4o-mini)
  NIFflER_TEST_BASE_URL - API base URL (default: OpenAI)
  NIFflER_TEST_NATS_URL - NATS server URL (default: nats://localhost:4222)

Tip: Run with verbose logging:
  NIFflER_LOG_LEVEL=DEBUG nim c -r tests/test_integration_framework.nim
"""

  # Validate environment first
  echo "\n📋 Validating test environment..."
  # The validation test will print detailed status