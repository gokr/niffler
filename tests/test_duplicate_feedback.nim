## Tests for Duplicate Feedback Prevention System
##
## This test suite validates the duplicate feedback prevention functionality
## that prevents infinite loops when LLMs repeatedly make the same tool call
## even after receiving duplicate feedback.
##
## The tests cover:
## - Tool call signature normalization
## - Duplicate feedback tracking per level and globally
## - Limit checking and enforcement
## - Error message generation
## - Recovery suggestion generation

import unittest
import ../src/types/[config, messages]
import ../src/api/api
import std/[tables, options, json, strutils]

suite "Tool Call Signature Creation":

  test "create normalized signature for simple tool call":
    let toolCall = LLMToolCall(
      id: "test-123",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: """{"path": "/tmp/test.txt"}"""
      )
    )

    let signature = createToolCallSignature(toolCall)
    check signature == "read(path='/tmp/test.txt')"

  test "create normalized signature for tool with multiple args":
    let toolCall = LLMToolCall(
      id: "test-456",
      `type`: "function",
      function: FunctionCall(
        name: "edit",
        arguments: """{"path": "file.txt", "content": "hello world", "position": 0}"""
      )
    )

    let signature = createToolCallSignature(toolCall)
    # Should be sorted by argument name
    check signature == "edit(content='hello world', path='file.txt', position=0)"

  test "create signature with integer arguments":
    let toolCall = LLMToolCall(
      id: "test-789",
      `type`: "function",
      function: FunctionCall(
        name: "bash",
        arguments: """{"command": "echo", "count": 3}"""
      )
    )

    let signature = createToolCallSignature(toolCall)
    check signature == "bash(command='echo', count=3)"

  test "create signature with boolean arguments":
    let toolCall = LLMToolCall(
      id: "test-boolean",
      `type`: "function",
      function: FunctionCall(
        name: "create",
        arguments: """{"path": "test.txt", "overwrite": true}"""
      )
    )

    let signature = createToolCallSignature(toolCall)
    check signature == "create(overwrite=true, path='test.txt')"

  test "handle invalid JSON gracefully":
    let toolCall = LLMToolCall(
      id: "test-invalid",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: "invalid json{"
      )
    )

    let signature = createToolCallSignature(toolCall)
    check signature == "read(invalid json{)"

suite "Duplicate Feedback Tracker Creation":

  test "create empty tracker":
    let tracker = createDuplicateFeedbackTracker()
    check tracker.attemptsPerLevel.len == 0
    check tracker.totalAttempts.len == 0

suite "Duplicate Feedback Limit Checking":

  test "check limits with enabled feature - first attempt":
    var tracker = createDuplicateFeedbackTracker()
    let config = DuplicateFeedbackConfig(
      enabled: true,
      maxAttemptsPerLevel: 2,
      maxTotalAttempts: 5,
      attemptRecovery: true
    )

    let toolCall = LLMToolCall(
      id: "test-123",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: """{"path": "/tmp/test.txt"}"""
      )
    )

    let reason = checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    check reason.result == dlAllowed
    check reason.currentCount == 0
    check reason.maxAllowed == 2

  test "check limits at same recursion level":
    var tracker = createDuplicateFeedbackTracker()
    let config = DuplicateFeedbackConfig(
      enabled: true,
      maxAttemptsPerLevel: 2,
      maxTotalAttempts: 5,
      attemptRecovery: true
    )

    let toolCall = LLMToolCall(
      id: "test-123",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: """{"path": "/tmp/test.txt"}"""
      )
    )

    # First attempt - should be allowed
    let reason1 = checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    check reason1.result == dlAllowed

    # Record the attempt
    recordDuplicateFeedbackAttempt(tracker, toolCall, 0)

    # Second attempt - should still be allowed
    let reason2 = checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    check reason2.result == dlAllowed
    check reason2.currentCount == 1

    # Record the attempt
    recordDuplicateFeedbackAttempt(tracker, toolCall, 0)

    # Third attempt at same level - should be blocked
    let reason3 = checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    check reason3.result == dlLevelExceeded
    check reason3.currentCount == 2
    check reason3.maxAllowed == 2
    check reason3.exceededLevel == 0

  test "check global total limit across different levels":
    var tracker = createDuplicateFeedbackTracker()
    let config = DuplicateFeedbackConfig(
      enabled: true,
      maxAttemptsPerLevel: 2,
      maxTotalAttempts: 3,
      attemptRecovery: true
    )

    let toolCall = LLMToolCall(
      id: "test-123",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: """{"path": "/tmp/test.txt"}"""
      )
    )

    # First attempt at level 0
    discard checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    recordDuplicateFeedbackAttempt(tracker, toolCall, 0)

    # Second attempt at level 0
    discard checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    recordDuplicateFeedbackAttempt(tracker, toolCall, 0)

    # Third attempt at level 1 (should be allowed, still within global limit)
    let reason3 = checkDuplicateFeedbackLimits(tracker, toolCall, 1, config)
    check reason3.result == dlAllowed
    recordDuplicateFeedbackAttempt(tracker, toolCall, 1)

    # Fourth attempt - should exceed global limit
    let reason4 = checkDuplicateFeedbackLimits(tracker, toolCall, 2, config)
    check reason4.result == dlTotalExceeded
    check reason4.currentCount == 3
    check reason4.maxAllowed == 3

  test "check limits with disabled feature":
    var tracker = createDuplicateFeedbackTracker()
    let config = DuplicateFeedbackConfig(
      enabled: false,
      maxAttemptsPerLevel: 2,
      maxTotalAttempts: 5,
      attemptRecovery: true
    )

    let toolCall = LLMToolCall(
      id: "test-123",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: """{"path": "/tmp/test.txt"}"""
      )
    )

    let reason = checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    check reason.result == dlDisabled

suite "Duplicate Feedback Attempt Recording":

  test "record attempts and verify counters":
    var tracker = createDuplicateFeedbackTracker()
    let toolCall = LLMToolCall(
      id: "test-123",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: """{"path": "/tmp/test.txt"}"""
      )
    )

    # Record first attempt at level 0
    recordDuplicateFeedbackAttempt(tracker, toolCall, 0)
    check tracker.attemptsPerLevel[0]["read(path='/tmp/test.txt')"] == 1
    check tracker.totalAttempts["read(path='/tmp/test.txt')"] == 1

    # Record second attempt at level 0
    recordDuplicateFeedbackAttempt(tracker, toolCall, 0)
    check tracker.attemptsPerLevel[0]["read(path='/tmp/test.txt')"] == 2
    check tracker.totalAttempts["read(path='/tmp/test.txt')"] == 2

    # Record attempt at level 1 (same tool call)
    recordDuplicateFeedbackAttempt(tracker, toolCall, 1)
    check tracker.attemptsPerLevel[1]["read(path='/tmp/test.txt')"] == 1
    check tracker.totalAttempts["read(path='/tmp/test.txt')"] == 3

suite "Error Message Generation":

  test "create error for level limit exceeded":
    let reason = DuplicateLimitReason(
      result: dlLevelExceeded,
      signature: "read(path='/tmp/test.txt')",
      currentCount: 3,
      maxAllowed: 2,
      exceededLevel: 1
    )

    let error = createDuplicateLimitError(reason)
    check error.contains("recursion depth 1")
    check error.contains("read(path='/tmp/test.txt')")
    check error.contains("3 times")
    check error.contains("limit: 2")
    check error.contains("stuck in a loop")

  test "create error for global limit exceeded":
    let reason = DuplicateLimitReason(
      result: dlTotalExceeded,
      signature: "bash(command='echo hello')",
      currentCount: 6,
      maxAllowed: 5,
      exceededLevel: -1
    )

    let error = createDuplicateLimitError(reason)
    check error.contains("Global duplicate feedback limit exceeded")
    check error.contains("bash(command='echo hello')")
    check error.contains("6 times total")
    check error.contains("limit: 5")
    check error.contains("infinite looping")

  test "create error for disabled feature":
    let reason = DuplicateLimitReason(
      result: dlDisabled,
      signature: "",
      currentCount: 0,
      maxAllowed: 0,
      exceededLevel: -1
    )

    let error = createDuplicateLimitError(reason)
    check error.contains("disabled")
    check error.contains("infinite loops")

suite "Alternative Approach Suggestions":

  test "suggest alternatives for read tool":
    let toolCall = LLMToolCall(
      id: "test-123",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: """{"path": "/tmp/test.txt"}"""
      )
    )

    let suggestions = suggestAlternativeApproaches(toolCall)
    check suggestions.contains("different file or directory")
    check suggestions.contains("previous result should still be available")

  test "suggest alternatives for edit tool":
    let toolCall = LLMToolCall(
      id: "test-456",
      `type`: "function",
      function: FunctionCall(
        name: "edit",
        arguments: """{"path": "test.txt"}"""
      )
    )

    let suggestions = suggestAlternativeApproaches(toolCall)
    check suggestions.contains("file already exists")
    check suggestions.contains("verify the current state")

  test "suggest alternatives for bash tool":
    let toolCall = LLMToolCall(
      id: "test-789",
      `type`: "function",
      function: FunctionCall(
        name: "bash",
        arguments: """{"command": "ls"}"""
      )
    )

    let suggestions = suggestAlternativeApproaches(toolCall)
    check suggestions.contains("different commands")
    check suggestions.contains("previous command failed")

  test "suggest alternatives for unknown tool":
    let toolCall = LLMToolCall(
      id: "test-unknown",
      `type`: "function",
      function: FunctionCall(
        name: "someTool",
        arguments: """{"param": "value"}"""
      )
    )

    let suggestions = suggestAlternativeApproaches(toolCall)
    check suggestions.contains("someTool")
    check suggestions.contains("different tool or approach")

suite "Integration Tests":

  test "Complete workflow demonstration":
    var tracker = createDuplicateFeedbackTracker()
    let config = DuplicateFeedbackConfig(
      enabled: true,
      maxAttemptsPerLevel: 2,
      maxTotalAttempts: 3,
      attemptRecovery: true
    )

    let toolCall = LLMToolCall(
      id: "integration-test",
      `type`: "function",
      function: FunctionCall(
        name: "read",
        arguments: """{"path": "/tmp/test.txt"}"""
      )
    )

    # First call - should be allowed
    let reason1 = checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    check reason1.result == dlAllowed
    recordDuplicateFeedbackAttempt(tracker, toolCall, 0)

    # Second call - should be allowed
    let reason2 = checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    check reason2.result == dlAllowed
    recordDuplicateFeedbackAttempt(tracker, toolCall, 0)

    # Third call - should be restricted
    let reason3 = checkDuplicateFeedbackLimits(tracker, toolCall, 0, config)
    check reason3.result == dlLevelExceeded

    # Test error message
    let error = createDuplicateLimitError(reason3)
    check error.contains("recursion depth 0")
    check error.contains("limit: 2")

    # Test alternative suggestions
    let suggestions = suggestAlternativeApproaches(toolCall)
    check suggestions.len > 0

echo "All duplicate feedback protection system tests passed!"