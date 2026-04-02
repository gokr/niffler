# Package
version       = "0.5.0"
author        = "Göran Krampe"
description   = "Niffler - Autonomous coding agent in Nim"
license       = "MIT"
srcDir        = "src"
bin           = @["niffler"]

# Dependencies

requires "nim >= 2.2.6"
requires "sunny"
requires "curly"
requires "htmlparser"
requires "https://github.com/gokr/debby"
requires "https://github.com/gokr/linecross"
requires "hldiff"
requires "unittest2 >= 0.2.4"
requires "nancy"
requires "yaml"
requires "dimscord"
requires "https://github.com/gokr/natswrapper"

# Test groups - organized by functionality
const TestCore = """
tests/test_basic.nim
tests/test_utils.nim
tests/test_command_parser.nim
tests/test_duplicate_feedback.nim
"""

const TestTools = """
tests/test_todolist.nim
tests/test_tool_integration.nim
tests/test_nedit.nim
tests/test_plan_mode.nim
"""

const TestConversation = """
tests/test_conversation_infrastructure.nim
tests/test_conversation_e2e.nim
tests/test_conversation_cli.nim
"""

const TestThinking = """
tests/test_thinking_tokens.nim
"""

const TestStreaming = """
tests/test_continuous_streaming.nim
tests/test_markdown_rendering.nim
"""

const TestIntegration = """
tests/test_integration_framework.nim
tests/test_real_llm_workflows.nim
tests/test_master_agent_scenario.nim
"""

const TestNats = """
tests/test_nats_messages.nim
tests/test_nats_integration.nim
"""

const TestOther = """
tests/test_diff_visualization.nim
"""

proc runTestGroup(groupName: string, testFiles: string) =
  echo "Running " & groupName & " tests..."
  for file in testFiles.splitWhitespace():
    if file.len > 0:
      echo "  " & file
      exec "testament pattern " & file & " || true"

task testament, "Run all tests using testament":
  exec "testament --colors:on pattern 'tests/test_*.nim'"

task test, "Run all tests organized by groups":
  runTestGroup("Core", TestCore)
  runTestGroup("Tools", TestTools)
  runTestGroup("Conversation", TestConversation)
  runTestGroup("Thinking", TestThinking)
  runTestGroup("Streaming", TestStreaming)

task testCore, "Run core functionality tests":
  runTestGroup("core", TestCore)

task testTools, "Run tool system tests":
  runTestGroup("tools", TestTools)

task testConversation, "Run conversation management tests":
  runTestGroup("conversation", TestConversation)

task testThinking, "Run thinking token tests":
  runTestGroup("thinking", TestThinking)

task testStreaming, "Run streaming and rendering tests":
  runTestGroup("streaming", TestStreaming)

task testIntegration, "Run integration tests (requires API keys)":
  runTestGroup("integration", TestIntegration)

task testNats, "Run NATS tests (requires NATS server)":
  runTestGroup("nats", TestNats)

task build, "Build optimized release":
  exec "nim c -d:release -o:bin/niffler src/niffler.nim"
