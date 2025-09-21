import std/[unittest, options, json, strutils]
import ../src/types/messages
import ../src/ui/tool_visualizer
import ../src/tools/common
import ../src/core/constants

suite "Continuous Streaming Tests":
  
  test "CompactToolRequestInfo creation and formatting":
    let args = %*{"path": "test.txt", "operation": "create"}
    let toolRequest = CompactToolRequestInfo(
      toolCallId: "call_123",
      toolName: "create",
      icon: "📁",
      args: args,
      status: "Executing..."
    )
    
    check toolRequest.toolCallId == "call_123"
    check toolRequest.toolName == "create"
    check toolRequest.icon == "📁"
    
    let formatted = formatCompactToolRequest(toolRequest)
    check formatted.contains("create")
    check formatted.find("test.txt") != -1
    check formatted.find("Executing...") != -1

  test "CompactToolResultInfo creation and formatting":
    let toolResult = CompactToolResultInfo(
      toolCallId: "call_123",
      toolName: "read",
      icon: "📖",
      success: true,
      resultSummary: "42 lines read",
      executionTime: 0.5
    )
    
    check toolResult.toolCallId == "call_123"
    check toolResult.toolName == "read"
    check toolResult.icon == "📖"
    check toolResult.success == true
    
    let formatted = formatCompactToolResult(toolResult)
    check formatted.find("read") != -1
    check formatted.find("42 lines read") != -1

  test "Tool result summary creation":
    # Test read tool
    let readResult = """{"content": "line1\nline2\nline3"}"""
    let readSummary = createToolResultSummary("read", readResult, true)
    check readSummary == "3 lines read"
    
    # Test edit tool with changes
    let editResult = """{"path": "test.txt", "changes_made": true, "size_change": 5}"""
    let editSummary = createToolResultSummary("edit", editResult, true)
    check editSummary.find("Updated") != -1
    check editSummary.find("(+5 chars)") != -1
    
    # Test bash tool success
    let bashResult = "Command output\nLine 2\nLine 3"
    let bashSummary = createToolResultSummary("bash", bashResult, true)
    check bashSummary.find("Command executed") != -1
    check bashSummary.find("3 lines output") != -1
    
    # Test tool failure
    let failSummary = createToolResultSummary("bash", "Error message", false)
    check failSummary == "Failed"

  test "Tool icon selection":
    check getToolIcon("read") != ""
    check getToolIcon("edit") != ""
    check getToolIcon("list") != ""
    check getToolIcon("bash") != ""
    check getToolIcon("fetch") != ""
    check getToolIcon("create") != ""
    check getToolIcon("unknown") != ""

  test "Tool args formatting":
    # Test read tool
    let readArgs = %*{"path": "/path/to/file.txt"}
    let readFormatted = formatToolArgs("read", readArgs)
    check readFormatted == "/path/to/file.txt"
    
    # Test bash tool
    let bashArgs = %*{"command": "echo hello world"}
    let bashFormatted = formatToolArgs("bash", bashArgs)
    check bashFormatted == "echo hello world"
    
    # Test long bash command truncation
    let longBashArgs = %*{"command": "echo " & "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}
    let longBashFormatted = formatToolArgs("bash", longBashArgs)
    check longBashFormatted.len == TOOL_ARGS_COMPACT_LENGTH + 3 # TOOL_ARGS_COMPACT_LENGTH chars + "..."
    check longBashFormatted[^3..^1] == "..."

  test "APIResponse with new tool call types":
    # Test tool request response
    let toolRequestResponse = APIResponse(
      requestId: "req_123",
      kind: arkToolCallRequest,
      toolRequestInfo: CompactToolRequestInfo(
        toolCallId: "call_123",
        toolName: "read",
        icon: "📖",
        args: %*{"path": "test.txt"},
        status: "Executing..."
      )
    )
    
    check toolRequestResponse.requestId == "req_123"
    check toolRequestResponse.kind == arkToolCallRequest
    check toolRequestResponse.toolRequestInfo.toolName == "read"
    
    # Test tool result response
    let toolResultResponse = APIResponse(
      requestId: "req_123",
      kind: arkToolCallResult,
      toolResultInfo: CompactToolResultInfo(
        toolCallId: "call_123",
        toolName: "read",
        icon: "📖",
        success: true,
        resultSummary: "42 lines read",
        executionTime: 0.5
      )
    )
    
    check toolResultResponse.requestId == "req_123"
    check toolResultResponse.kind == arkToolCallResult
    check toolResultResponse.toolResultInfo.toolName == "read"
    check toolResultResponse.toolResultInfo.success == true

when isMainModule:
  echo "Running Continuous Streaming Tests..."
  echo "All continuous streaming tests completed!"