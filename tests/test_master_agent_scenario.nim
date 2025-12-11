## Master-Agent System Integration Tests
##
## These tests simulate realistic multi-agent scenarios

import std/[unittest, os, times, options, strutils, json, logging, osproc, streams]
import ../src/core/[config, session, database, nats_client]
import ../src/ui/[master_cli, agent_cli]
import ../src/types/[nats_messages, config as configTypes]

# Test scenario configuration
const
  TEST_TIMEOUT = 30_000  # 30 seconds
  TEST_NATS_URL = getEnv("NIFflER_TEST_NATS_URL", "nats://localhost:4222")
  TEST_AGENTS_DIR = "tests/test_agents"

suite "Master-Agent Multi-Agent Scenarios":

  test "Agent definition loading and validation":
    #[ Test that agent definitions are properly loaded ]#
    if not dirExists(TEST_AGENTS_DIR):
      skip("Test agents directory not found")

    let agents = loadAgentDefinitions(TEST_AGENTS_DIR)
    check agents.len > 0, "Should have at least one test agent definition"

    # Check for required fields in each agent
    for agent in agents:
      check agent.name.len > 0
      check agent.description.len > 0
      check agent.allowedTools.len > 0
      check agent.systemPrompt.len > 0

    # Verify we can find specific agents
    let coder = findAgent(agents, "test-coder")
    check coder.name == "test-coder"

  test "Master mode without NATS fallback":
    #[ Test master mode behavior when NATS is unavailable ]#

    # Use invalid NATS URL to force fallback
    var masterState = initializeMaster("nats://invalid:4222", "")
    check not masterState.connected, "Should detect NATS unavailability"

    # Test agent request handling in fallback mode
    let result = masterState.handleAgentRequest("@coder help")
    check result.handled
    check "Not connected to NATS" in result.output

    masterState.cleanup()

  test "Agent input parsing edge cases":
    #[ Test various @agent syntax patterns ]#

    # Basic cases
    let test1 = parseAgentInput("@agent command")
    check test1.agentName == "agent"
    check test1.input == "command"

    # With subcommands
    let test2 = parseAgentInput("@coder /task refactor code")
    check test2.agentName == "coder"
    check test2.input == "/task refactor code"

    # Multiple spaces
    let test3 = parseAgentInput("@  agent    command")
    check test3.agentName == "agent"
    check test3.input == "command"

    # Empty input after agent
    let test4 = parseAgentInput("@agent ")
    check test4.agentName == "agent"
    check test4.input == ""

    # No @ syntax
    let test5 = parseAgentInput("normal command")
    check test5.agentName.len == 0
    check test5.input == "normal command"

  test "NATS message serialization/deserialization":
    #[ Test NATS message format consistency ]#

    let testMessage = createRequest("test-123", "test-agent", "test input")
    let messageJson = parseJson($testMessage)

    check messageJson["requestId"].getStr() == "test-123"
    check messageJson["agentName"].getStr() == "test-agent"
    check messageJson["input"].getStr() == "test input"
    check messageJson["timestamp"].getStr().len > 0

    # Verify we can deserialize
    let deserialized = toRequest(messageJson)
    check deserialized.requestId == testMessage.requestId
    check deserialized.agentName == testMessage.agentName
    check deserialized.input == testMessage.input

suite "Integration Test Helpers":

  test "Process spawning utilities":
    #[ Test utilities for spawning and managing test processes ]#

    # Test that we can detect running processes
    let processes = @[
      ("nats-server", "Check for NATS server"),
      ("mysqld", "Check for MySQL/TiDB"),
      ("nim", "Check for Nim compiler")
    ]

    for (procName, description) in processes:
      try:
        let result = execCmd(fmt"pgrep {procName} > /dev/null 2>&1 || echo 'not found'")
        if result == 0:
          echo fmt"✅ {description}: running"
        else:
          echo fmt"⚠️  {description}: not running"
      except:
        echo fmt"⚠️  {description}: could not check"

when isMainModule:
  echo """
🤖 Master-Agent System Tests
============================

These tests verify the multi-agent architecture:

Test Requirements:
- Optional: NATS server (nats-server -js)
- Test agent definitions in tests/test_agents/

Environment variables:
  NIFflER_TEST_NATS_URL - NATS server URL

Supported Scenarios:
- Agent definition loading
- Master mode routing
- @agent syntax parsing
- NATS message serialization
- Process management utilities

Tip: Create test agents in tests/test_agents/ with .md extension:

  ## Description
  Test agent for integration testing

  ## Allowed Tools
  - read
  - bash

  ## System Prompt
  You are a test agent...
"""

  # Create test agents directory if it doesn't exist
  if not dirExists(TEST_AGENTS_DIR):
    createDir(TEST_AGENTS_DIR)

    # Create a sample test agent
    let sampleAgent = """## Description
Test coder agent for integration testing. Specializes in simple file operations.

## Allowed Tools
- read
- create
- edit
- bash

## System Prompt
You are a test coder agent focused on simple file operations.
Always respond with "TEST_AGENT: " prefix to clearly identify your responses.
"""

    writeFile(TEST_AGENTS_DIR / "test-coder.md", sampleAgent)
    echo "📁 Created sample test agent: ", TEST_AGENTS_DIR / "test-coder.md"