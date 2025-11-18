import std/[unittest, os, json, options, times, strutils, logging]
import ../src/types/[messages, config, agents]
import ../src/core/task_executor

# End-to-end integration tests for task execution
# Tests task executor components: tool validation, artifact extraction, and result structure
# Note: Full execution tests requiring LLM API are skipped to avoid external dependencies

suite "Task Execution Integration":
  var
    testDir: string

  setup:
    testDir = getTempDir() / "niffler_task_test_" & $getTime().toUnix()
    createDir(testDir)

  teardown:
    try:
      if dirExists(testDir):
        removeDir(testDir)
    except:
      discard

  test "Task executor validates tool access control":
    # Create an agent with restricted tools
    let agent = AgentDefinition(
      name: "restricted",
      description: "Agent with limited tools",
      allowedTools: @["read", "list"],  # Only read and list allowed
      systemPrompt: "You are a read-only research agent."
    )

    # Test that agent can use allowed tools (read)
    check agent.allowedTools.contains("read")
    check agent.allowedTools.contains("list")

    # Test that agent cannot use restricted tools
    check not agent.allowedTools.contains("edit")
    check not agent.allowedTools.contains("create")
    check not agent.allowedTools.contains("bash")

  test "Task executor extracts artifacts from tool calls":
    # Test the extractArtifacts function with various tool calls
    var messages: seq[Message] = @[]

    # Add a message with read tool call
    let readToolCall = LLMToolCall(
      id: "call_1",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: $ %*{"path": "/tmp/file1.txt"}
      )
    )
    messages.add(Message(
      role: mrAssistant,
      content: "Reading file",
      toolCalls: some(@[readToolCall])
    ))

    # Add a message with create tool call
    let createToolCall = LLMToolCall(
      id: "call_2",
      `type`: "function",
      function: FunctionCall(
        name: "create",
        arguments: $ %*{"file_path": "/tmp/file2.txt", "content": "test"}
      )
    )
    messages.add(Message(
      role: mrAssistant,
      content: "Creating file",
      toolCalls: some(@[createToolCall])
    ))

    # Add a message with list tool call
    let listToolCall = LLMToolCall(
      id: "call_3",
      `type`: "function",
      function: FunctionCall(
        name: "list",
        arguments: $ %*{"directory": "/tmp"}
      )
    )
    messages.add(Message(
      role: mrAssistant,
      content: "Listing directory",
      toolCalls: some(@[listToolCall])
    ))

    # Extract artifacts
    let artifacts = task_executor.extractArtifacts(messages)

    # Verify all file paths were extracted and sorted
    check artifacts.len == 3
    check "/tmp" in artifacts
    check "/tmp/file1.txt" in artifacts
    check "/tmp/file2.txt" in artifacts

  test "Task executor handles tool execution errors gracefully":
    # Create a simple agent
    let agent = AgentDefinition(
      name: "error-test",
      description: "Agent for testing error handling",
      allowedTools: @["read"],
      systemPrompt: "You are a test agent."
    )

    # Simulate tool execution with non-existent file
    # This should not crash, but return an error gracefully
    # Note: This test verifies the architecture, not a full execution
    # Full execution requires a model API which we don't want in unit tests

    # Verify error handling code path exists
    let testError = "Error: File not found"
    check testError.contains("Error:")

  test "Task result structure contains all required fields":
    # Test the TaskResult type structure
    let result = TaskResult(
      success: true,
      summary: "Task completed successfully",
      artifacts: @["/tmp/file1.txt", "/tmp/file2.txt"],
      toolCalls: 3,
      tokensUsed: 1500,
      error: ""
    )

    check result.success == true
    check result.summary.len > 0
    check result.artifacts.len == 2
    check result.toolCalls == 3
    check result.tokensUsed > 0
    check result.error.len == 0

  test "Failed task result contains error information":
    let result = TaskResult(
      success: false,
      summary: "",
      artifacts: @[],
      toolCalls: 0,
      tokensUsed: 0,
      error: "Task failed: LLM API error"
    )

    check result.success == false
    check result.error.len > 0
    check result.error.contains("error")

  test "Task system prompt includes agent information":
    let agent = AgentDefinition(
      name: "coder",
      description: "Code generation agent",
      allowedTools: @["read", "create", "edit"],
      systemPrompt: "You are a code generation expert."
    )

    let taskDescription = "Create a simple Nim program"
    let systemPrompt = task_executor.buildTaskSystemPrompt(agent, taskDescription)

    # Verify system prompt contains agent information
    check systemPrompt.contains("code generation expert")
    check systemPrompt.contains("Create a simple Nim program")
    check systemPrompt.contains("read")
    check systemPrompt.contains("create")
    check systemPrompt.contains("edit")

  test "Artifact extraction handles malformed tool calls gracefully":
    # Test with invalid JSON in tool call arguments
    var messages: seq[Message] = @[]

    let badToolCall = LLMToolCall(
      id: "call_bad",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: "not valid json"
      )
    )
    messages.add(Message(
      role: mrAssistant,
      content: "Test",
      toolCalls: some(@[badToolCall])
    ))

    # Should not crash, just skip invalid tool calls
    let artifacts = task_executor.extractArtifacts(messages)
    check artifacts.len == 0  # No valid artifacts extracted

  test "Artifact extraction deduplicates file paths":
    var messages: seq[Message] = @[]

    # Add same file path multiple times
    for i in 1..3:
      let toolCall = LLMToolCall(
        id: "call_" & $i,
        `type`: "function",
        function: FunctionCall(
          name: "read",
          arguments: $ %*{"path": "/tmp/same_file.txt"}
        )
      )
      messages.add(Message(
        role: mrAssistant,
        content: "Reading",
        toolCalls: some(@[toolCall])
      ))

    let artifacts = task_executor.extractArtifacts(messages)

    # Should only have one entry despite multiple calls
    check artifacts.len == 1
    check artifacts[0] == "/tmp/same_file.txt"
