import std/[unittest, options, strutils, os, tempfiles]
import ../src/types/messages
import ../src/types/agents
import ../src/tools/registry
import ../src/core/[session, system_prompt]

# Very basic test suite that works with current codebase

suite "Basic Functionality Tests":
  
  test "Tool schema generation":
    let bashSchema = getToolSchema("bash")
    check bashSchema.isSome()
    check bashSchema.get().`type` == "function"
    check bashSchema.get().function.name == "bash"
    check bashSchema.get().function.description.startsWith("Execute shell commands")

  test "Message type creation":
    let message = Message(
      role: mrUser,
      content: "Hello, world!"
    )
    check message.role == mrUser
    check message.content == "Hello, world!"

  test "Tool definition access":
    let allSchemas = getAllToolSchemas()
    check allSchemas.len >= 8

    let toolNames = ["bash", "read", "list", "edit", "create", "fetch", "todolist", "task"]
    for toolName in toolNames:
      let schema = getToolSchema(toolName)
      check schema.isSome()
      check schema.get().function.name == toolName

  test "Agent markdown frontmatter parsing":
    let content = """---
model: synthetic-glm5
allowed_tools:
  - read
  - bash
capabilities:
  - coding
  - debugging
auto_start: true
max_turns: 12
description: Frontmatter description
---

# Test Agent

## System Prompt

Do useful work.
"""

    let agent = parseAgentDefinition(content, "/tmp/coder.md")
    check agent.name == "coder"
    check agent.description == "Frontmatter description"
    check agent.allowedTools == @["read", "bash"]
    check agent.capabilities == @["coding", "debugging"]
    check agent.model.isSome()
    check agent.model.get() == "synthetic-glm5"
    check agent.autoStart == true
    check agent.maxTurns.isSome()
    check agent.maxTurns.get() == 12
    check agent.systemPrompt == "Do useful work."

  test "System prompt only uses NIFFLER.md in parent chain":
    let originalDir = getCurrentDir()
    let rootDir = createTempDir("niffler_prompt_", "")
    let nestedDir = rootDir / "a" / "b"

    createDir(rootDir / "a")
    createDir(nestedDir)
    writeFile(rootDir / "NIFFLER.md", "# Common System Prompt\n\nProject prompt\n\n# Notes\n\nUse project notes.")
    writeFile(nestedDir / "CLAUDE.md", "This should be ignored")

    setCurrentDir(nestedDir)
    defer:
      setCurrentDir(originalDir)
      removeDir(rootDir)

    let sess = initSession()
    let (common, _, _) = extractSystemPromptsFromNiffler(sess)
    let instructions = findInstructionFiles(sess)

    check common == "Project prompt"
    check "Use project notes." in instructions
    check "CLAUDE.md" notin instructions

  test "Tool confirmation requirements":
    check not requiresConfirmation("read")
    check not requiresConfirmation("list") 
    check not requiresConfirmation("fetch")
    check requiresConfirmation("bash")
    check requiresConfirmation("edit")
    check requiresConfirmation("create")

  test "LLMToolCall creation":
    let toolCall = LLMToolCall(
      id: "call_123",
      `type`: "function",
      function: FunctionCall(
        name: "bash",
        arguments: """{"cmd": "echo hello"}"""
      )
    )
    check toolCall.id == "call_123"
    check toolCall.function.name == "bash"

  test "ToolResult creation":
    let result = ToolResult(
      id: "call_456",
      output: "Success!",
      error: none(string)
    )
    check result.id == "call_456"
    check result.output == "Success!"
    check result.error.isNone()

when isMainModule:
  echo "Running Basic Tests..."
  echo "All basic tests completed!"
