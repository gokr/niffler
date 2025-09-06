import std/[unittest, strutils, json]
import ../src/ui/tool_visualizer
import ../src/ui/diff_visualizer
import ../src/ui/theme

suite "Diff Visualization Tests":
  
  setup:
    # Initialize themes for testing
    initializeThemes()
  
  test "createInlineDiffFromEditResult handles simple text changes":
    let originalText = "Size = (15, 80, 0)"
    let modifiedText = "Size = (20, 120, 0)"
    
    let result = createInlineDiffFromEditResult("", originalText, modifiedText)
    check result.len > 0
    # The function should return some diff output (exact content depends on implementation)
  
  test "createInlineDiffFromEditResult handles code changes":
    let originalCode = """proc factorial*(n: int): int =
  if n <= 1:
    return 1
  else:
    return n * factorial(n - 1)"""
    
    let modifiedCode = """proc factorial*(n: int): int =
  if n <= 1:
    return 1
  var result = 1
  for i in 2..n:
    result = result * i
  return result"""
    
    let result = createInlineDiffFromEditResult("", originalCode, modifiedCode)
    check result.len > 0
  
  test "createInlineDiffFromEditResult handles import changes":
    let originalImports = """import std/[strutils, sequtils]
import json
import os"""
    
    let modifiedImports = """import std/[strutils, sequtils, math]
import std/json
import os, times"""
    
    let result = createInlineDiffFromEditResult("", originalImports, modifiedImports)
    check result.len > 0
  
  test "ToolDisplayInfo integration with diff visualization":
    # Test that we can create ToolDisplayInfo and format it
    let editArgs = %*{
      "path": "src/config.nim",
      "old_text": "Size = (15, 80, 0)",
      "new_text": "Size = (20, 120, 0)"
    }
    
    let editInfo = ToolDisplayInfo(
      name: "edit",
      args: editArgs,
      result: """{"path": "src/config.nim", "changes_made": true, "size_change": 5}""",
      success: true,
      executionTime: 0.15
    )
    
    let config = getDefaultToolConfig()
    let formatted = formatToolVisualization(editInfo, config)
    check formatted.len > 0

when isMainModule:
  echo "Running Diff Visualization Tests..."