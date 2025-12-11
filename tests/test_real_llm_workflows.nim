## Real LLM Workflow Tests
##
## These tests verify Niffler can handle realistic workflows with real LLMs

import std/[unittest, os, times, options, strutils, json, chronicles, re]
import ../src/core/[config, session, app, database, channels, conversation_manager]
import ../src/types/[messages, config as configTypes]
import ../src/api/[api, http_client]
import ../src/tools/[registry, worker]
import debby/pools

# Test configuration
const
  TEST_MODEL = getEnv("NIFflER_TEST_MODEL", "gpt-4o-mini")
  TEST_API_KEY = getEnv("NIFflER_TEST_API_KEY", "")
  TEST_BASE_URL = getEnv("NIFflER_TEST_BASE_URL", "https://api.openai.com/v1")

suite "Real LLM Workflow Tests":

  test "Code analysis workflow":
    #[ Test LLM's ability to read and analyze code ]#
    if TEST_API_KEY.len == 0:
      skip("No API key configured")

    # Create a simple Python file for analysis
    let testCode = """
def calculate_fibonacci(n):
    \"\"\"Calculate the nth Fibonacci number.\"\"\"
    if n <= 1:
        return n
    return calculate_fibonacci(n-1) + calculate_fibonacci(n-2)

# Test the function
for i in range(10):
    print(f"F({i}) = {calculate_fibonacci(i)}")
"""
    let testFile = "/tmp/test_fibonacci.py"
    writeFile(testFile, testCode)
    defer:
      if fileExists(testFile):
        removeFile(testFile)

    # Initialize API worker
    var apiChannels = initThreadChannels()
    var toolChannels = initThreadChannels()

    # Start API worker thread
    var apiThread: Thread[ThreadParams]
    var apiParams = ThreadParams(channels: addr apiChannels, level: lvlInfo, dump: false)
    createThread(apiThread, apiWorkerProc, apiParams)

    # Start tool worker thread
    var toolThread: Thread[ThreadParams]
    var toolParams = ThreadParams(channels: addr toolChannels, level: lvlInfo, dump: false)
    createThread(toolThread, toolWorkerProc, toolParams)

    defer:
      apiChannels.signalShutdown()
      joinThread(apiThread)
      toolChannels.signalShutdown()
      joinThread(toolThread)

    sleep(1000)  # Wait for workers

    # Create conversation
    let testDB = getGlobalDatabase()
    let convTitle = "test_code_analysis_" & $getTime().toUnix()
    let conversation = testDB.createConversation(convTitle, cmCode, TEST_MODEL)
    let convId = conversation.get().id
    setCurrentConversationId(convId)

    # Send code analysis request
    let messages = @[
      Message(role: mrUser, content: fmt"Analyze the Python file {testFile}. What is the time complexity of this algorithm? Please suggest optimizations.")
    ]

    apiChannels.sendApi(ApiRequest(
      kind: arkChat,
      conversationId: convId,
      messages: messages,
      model: ModelConfig(
        nickname: TEST_MODEL,
        model: TEST_MODEL,
        baseUrl: TEST_BASE_URL,
        apiKey: some(TEST_API_KEY),
        maxTokens: 1000,
        temperature: 0.1
      )
    ))

    # Collect responses (tool calls and final answer)
    var toolCallsMade = 0
    var finalResponse = ""
    var timeout = getTime() + initDuration(seconds = 15)

    while getTime() < timeout:
      # Check for tool calls
      let maybeToolRequest = toolChannels.tryReceiveTool()
      if maybeToolRequest.isSome:
        let toolReq = maybeToolRequest.get()
        toolCallsMade += 1

        # Execute the tool
        if toolReq.toolName == "read":
          if toolReq.args.hasKey("path") and toolReq.args["path"].getStr() == testFile:
            let toolResult = ToolResult(
              success: true,
              output: testCode
            )
            apiChannels.sendToolResult(toolResult)

      # Check for API response
      let maybeApi = apiChannels.tryReceiveApi()
      if maybeApi.isSome:
        let apiResp = maybeApi.get()
        if apiResp.kind == arkChat and apiResp.success:
          finalResponse = apiResp.content
          break

      sleep(100)

    check toolCallsMade > 0, "LLM should have called the read tool"
    check finalResponse.len > 0, "Should have received a response"
    check "O(2^n)" in finalResponse or "exponential" in finalResponse.toLowerAscii(),
           "Response should identify exponential time complexity"

  test "Multi-step file editing workflow":
    #[ Test LLM's ability to perform multiple file operations ]#
    if TEST_API_KEY.len == 0:
      skip("No API key configured")

    # Create initial file
    let initialContent = "# TODO List\n\n- [ ] Task 1\n- [ ] Task 2\n"
    let todoFile = "/tmp/test_todo.md"
    writeFile(todoFile, initialContent)
    defer:
      if fileExists(todoFile):
        removeFile(todoFile)

    # Initialize workers
    var apiChannels = initThreadChannels()
    var toolChannels = initThreadChannels()

    var apiThread: Thread[ThreadParams]
    createThread(apiThread, apiWorkerProc,
      ThreadParams(channels: addr apiChannels, level: lvlInfo, dump: false))

    var toolThread: Thread[ThreadParams]
    createThread(toolThread, toolWorkerProc,
      ThreadParams(channels: addr toolChannels, level: lvlInfo, dump: false))

    defer:
      apiChannels.signalShutdown()
      joinThread(apiThread)
      toolChannels.signalShutdown()
      joinThread(toolThread)

    sleep(1000)

    # Create conversation
    let testDB = getGlobalDatabase()
    let convTitle = "test_file_editing_" & $getTime().toUnix()
    let conversation = testDB.createConversation(convTitle, cmCode, TEST_MODEL)
    let convId = conversation.get().id
    setCurrentConversationId(convId)

    # Send editing request
    let messages = @[
      Message(role: mrUser, content: fmt"""
Read the todo file at {todoFile}, then:
1. Add a new task "Task 3" marked as completed
2. Mark "Task 1" as completed
3. Save the file

Make minimal changes to preserve the format.
""")
    ]

    apiChannels.sendApi(ApiRequest(
      kind: arkChat,
      conversationId: convId,
      messages: messages,
      model: ModelConfig(
        nickname: TEST_MODEL,
        model: TEST_MODEL,
        baseUrl: TEST_BASE_URL,
        apiKey: some(TEST_API_KEY),
        maxTokens: 1000,
        temperature: 0.1
      )
    ))

    # Track tool executions
    var toolSequence: seq[string] = @[]
    var finalResponse = ""
    var timeout = getTime() + initDuration(seconds = 20)

    while getTime() < timeout:
      # Check for tool calls
      let maybeToolRequest = toolChannels.tryReceiveTool()
      if maybeToolRequest.isSome:
        let toolReq = maybeToolRequest.get()
        toolSequence.add(toolReq.toolName)

        # Mock tool execution
        case toolReq.toolName:
        of "read":
          if toolReq.args.hasKey("path"):
            let path = toolReq.args["path"].getStr()
            let content = if path == todoFile: readFile(path) else: "File not found"
            apiChannels.sendToolResult(ToolResult(success: true, output: content))
        of "edit":
          if toolReq.args.hasKey("path") and toolReq.args.hasKey("content"):
            writeFile(todoFile, toolReq.args["content"].getStr())
            apiChannels.sendToolResult(ToolResult(success: true, output: "File edited"))
        else:
          apiChannels.sendToolResult(ToolResult(success: false, output: "Unknown tool"))

      # Check for final response
      let maybeApi = apiChannels.tryReceiveApi()
      if maybeApi.isSome:
        let apiResp = maybeApi.get()
        if apiResp.kind == arkChat:
          finalResponse = apiResp.content
          if apiResp.success: break

      sleep(100)

    # Verify workflow
    check "read" in toolSequence, "Should have read the file first"
    check "edit" in toolSequence, "Should have edited the file"

    # Verify final file content
    let finalContent = readFile(todoFile)
    check "Task 3" in finalContent
    check "[x] Task 1" in finalContent or "[X] Task 1" in finalContent

  test "Error handling and recovery":
    #[ Test LLM's response to tool failures ]#
    if TEST_API_KEY.len == 0:
      skip("No API key configured")

    # Initialize workers
    var apiChannels = initThreadChannels()
    var toolChannels = initThreadChannels()

    var apiThread: Thread[ThreadParams]
    createThread(apiThread, apiWorkerProc,
      ThreadParams(channels: addr apiChannels, level: lvlInfo, dump: false))

    var toolThread: Thread[ThreadParams]
    createThread(toolThread, toolWorkerProc,
      ThreadParams(channels: addr toolChannels, level: lvlInfo, dump: false))

    defer:
      apiChannels.signalShutdown()
      joinThread(apiThread)
      toolChannels.signalShutdown()
      joinThread(toolThread)

    sleep(1000)

    # Create conversation
    let testDB = getGlobalDatabase()
    let convTitle = "test_error_handling_" & $getTime().toUnix()
    let conversation = testDB.createConversation(convTitle, cmCode, TEST_MODEL)
    let convId = conversation.get().id
    setCurrentConversationId(convId)

    # Send request that will trigger an error
    let messages = @[
      Message(role: mrUser, content: "Try to read the file /nonexistent/file.md and tell me what you find.")
    ]

    apiChannels.sendApi(ApiRequest(
      kind: arkChat,
      conversationId: convId,
      messages: messages,
      model: ModelConfig(
        nickname: TEST_MODEL,
        model: TEST_MODEL,
        baseUrl: TEST_BASE_URL,
        apiKey: some(TEST_API_KEY),
        maxTokens: 1000,
        temperature: 0.1
      )
    ))

    # Track error handling
    var errorDetected = false
    var finalResponse = ""
    var timeout = getTime() + initDuration(seconds = 10)

    while getTime() < timeout:
      # Check for tool calls
      let maybeToolRequest = toolChannels.tryReceiveTool()
      if maybeToolRequest.isSome:
        let toolReq = maybeToolRequest.get()

        # Simulate file not found error
        if toolReq.toolName == "read":
          apiChannels.sendToolResult(ToolResult(
            success: false,
            output: "File not found: /nonexistent/file.md",
            error: "File does not exist"
          ))
          errorDetected = true

      # Check for final response
      let maybeApi = apiChannels.tryReceiveApi()
      if maybeApi.isSome:
        let apiResp = maybeApi.get()
        if apiResp.kind == arkChat:
          finalResponse = apiResp.content
          if apiResp.success: break

      sleep(100)

    check errorDetected, "Should have encountered a file read error"
    check finalResponse.len > 0, "Should still provide a response despite the error"
    check "not found" in finalResponse.toLowerAscii() or
          "doesn't exist" in finalResponse.toLowerAscii(),
          "Should acknowledge the error in the response"

suite "Workflow Test Helpers":

  test "Test data cleanup":
    #[ Clean up any leftover test files ]#
    let testFiles = @[
      "/tmp/test_fibonacci.py",
      "/tmp/test_todo.md",
      "/tmp/test_nonexistent.md"
    ]

    for file in testFiles:
      if fileExists(file):
        removeFile(file)
        echo fmt"🗑️  Cleaned up: {file}"

when isMainModule:
  echo """
🔄 Real LLM Workflow Tests
==========================

These tests verify Niffler can handle realistic workflows:

Test Scenarios:
- Code analysis with file reading
- Multi-step file editing operations
- Error handling and graceful recovery

Environment:
  NIFflER_TEST_API_KEY - Required for real LLM tests
  NIFflER_TEST_MODEL - Model to test (default: gpt-4o-mini)
  NIFflER_TEST_BASE_URL - API endpoint (default: OpenAI)

What gets tested:
- LLM tool calling ability
- Multi-turn conversations
- Error handling
- File operation workflows
- Response parsing and validation

Note: These tests use real APIs and may consume tokens.
"""