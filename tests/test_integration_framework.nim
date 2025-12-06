## Integration Tests for Niffler with Real LLM
##
## These tests verify end-to-end functionality using actual LLM APIs.
## Skip if API key is not configured.

import std/[unittest, os, times, options, strutils, json, chronicles, asyncdispatch]
import ../src/core/[config, session, app, database, nats_client]
import ../src/types/[messages, config as configTypes]
import ../src/api/[api, http_client]
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
  testPool: Pool

suite "Integration Tests with Real LLM":

  setup:
    # Initialize test configuration
    testConfig = Config(
      models: {
        TEST_MODEL: ModelConfig(
          nickname: TEST_MODEL,
          model: TEST_MODEL,
          baseUrl: TEST_BASE_URL,
          apiKey: some(TEST_API_KEY),
          maxTokens: 1000,
          temperature: 0.1
        )
      }.toTable(),
      defaultModel: TEST_MODEL,
      database: DatabaseConfig(
        host: "127.0.0.1",
        port: 4000,
        database: "niffler_test",
        username: "root",
        password: ""
      ),
      natsUrl: TEST_NATS_URL
    )

    # Initialize test database
    testPool = newPool(5)
    testDatabase = initMysqlBackend(testConfig.database, testPool)

    # Clean up any existing test data
    testDatabase.execute("DELETE FROM conversation WHERE title LIKE 'test_%'")

  teardown:
    # Clean up test database
    if testDatabase != nil:
      testDatabase.execute("DELETE FROM conversation WHERE title LIKE 'test_%'")
      testDatabase.close()

    if testPool != nil:
      testPool.close()

  test "Simple Q&A with real LLM":
    #[ Test basic LLM integration without tool usage ]#
    if TEST_API_KEY.len == 0:
      skip("No API key configured - set NIFflER_TEST_API_KEY")

    # Initialize API worker
    var apiChannels = initThreadChannels()
    var apiProc = apiWorkerProc
    var apiThread: Thread[ThreadParams]
    var params = ThreadParams(channels: addr apiChannels, level: lvlInfo, dump: false)
    createThread(apiThread, apiProc, params)

    defer:
      apiChannels.signalShutdown()
      joinThread(apiThread)

    # Wait for API worker to be ready
    sleep(1000)

    # Create conversation
    let convTitle = "test_qa_integration_" & $getTime().toUnix()
    let conversation = testDatabase.createConversation(convTitle, cmCode, TEST_MODEL)
    check conversation.isSome

    let convId = conversation.get().id
    setCurrentConversationId(convId)

    # Send simple question
    let messages = @[
      Message(role: mrUser, content: "What is 2 + 2? Respond with just the number.")
    ]

    # Send request to API worker
    apiChannels.sendApi(ApiRequest(
      kind: arkChat,
      conversationId: convId,
      messages: messages,
      model: testConfig.models[TEST_MODEL]
    ))

    # Wait for response
    var response: ApiResponse
    for i in 0..<50:  # Max 5 seconds
      let maybeResponse = apiChannels.tryReceiveApi()
      if maybeResponse.isSome:
        response = maybeResponse.get()
        break
      sleep(100)

    check response.kind == arkChat
    check response.success
    check "4" in response.content.toLowerAscii()

    # Verify database persistence
    let dbMessages = testDatabase.getConversationMessages(convId)
    check dbMessages.len >= 2  # User + assistant messages

  test "Tool execution with real LLM":
    #[ Test LLM's ability to use tools ]#
    if TEST_API_KEY.len == 0:
      skip("No API key configured")

    # Create test file
    let testContent = "This is a test file for integration testing.\n"
    let testFile = "/tmp/niffler_test_integration.txt"
    writeFile(testFile, testContent)

    defer:
      if fileExists(testFile):
        removeFile(testFile)

    # Initialize API worker
    var apiChannels = initThreadChannels()
    var apiThread: Thread[ThreadParams]
    var params = ThreadParams(channels: addr apiChannels, level: lvlInfo, dump: false)
    createThread(apiThread, apiWorkerProc, params)

    defer:
      apiChannels.signalShutdown()
      joinThread(apiThread)

    sleep(1000)  # Wait for worker

    # Create conversation
    let convTitle = "test_tool_integration_" & $getTime().toUnix()
    let conversation = testDatabase.createConversation(convTitle, cmCode, TEST_MODEL)
    let convId = conversation.get().id
    setCurrentConversationId(convId)

    # Send request that requires tool usage
    let messages = @[
      Message(role: mrUser, content: fmt"Read the file {testFile} and tell me what it contains.")
    ]

    apiChannels.sendApi(ApiRequest(
      kind: arkChat,
      conversationId: convId,
      messages: messages,
      model: testConfig.models[TEST_MODEL]
    ))

    # Collect response(s)
    var finalResponse: ApiResponse
    var toolCallDetected = false

    for i in 0..<100:  # Max 10 seconds
      let maybeResponse = apiChannels.tryReceiveApi()
      if maybeResponse.isSome:
        response = maybeResponse.get()
        if response.kind == arkToolCall:
          toolCallDetected = true
        elif response.kind == arkChat:
          finalResponse = response
          break
      sleep(100)

    check toolCallDetected, "LLM should have made a tool call"
    check finalResponse.success
    check "test file" in finalResponse.content.toLowerAscii()

  test "Master-Agent E2E Communication":
    #[ Test full master-agent workflow ]#
    if TEST_API_KEY.len == 0:
      skip("No API key configured")

    # Test NATS availability
    try:
      var natsTest = initNatsClient(TEST_NATS_URL, "test", 0)
      natsTest.close()
    except:
      skip("NATS server not available - start with: nats-server -js")

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
      let testPool = newPool(1)
      let testDb = initMysqlBackend(dbConfig, testPool)
      testDb.close()
      testPool.close()
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