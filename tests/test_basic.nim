import std/[unittest, options]
import ../src/types/messages
import ../src/tools/registry

# Very basic test suite that works with current codebase

suite "Basic Functionality Tests":
  
  test "Tool schema generation":
    let bashSchema = getToolSchema("bash")
    check bashSchema.isSome()
    check bashSchema.get().`type` == "function"
    check bashSchema.get().function.name == "bash"
    check bashSchema.get().function.description == "Execute shell commands"

  test "Message type creation":
    let message = Message(
      role: mrUser,
      content: "Hello, world!"
    )
    check message.role == mrUser
    check message.content == "Hello, world!"

  test "Tool definition access":
    let allSchemas = getAllToolSchemas()
    check allSchemas.len == 7
    
    let toolNames = ["bash", "read", "list", "edit", "create", "fetch", "todolist"]
    for toolName in toolNames:
      let schema = getToolSchema(toolName)
      check schema.isSome()
      check schema.get().function.name == toolName

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