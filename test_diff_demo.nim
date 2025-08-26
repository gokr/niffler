## Enhanced diff visualization demo showcasing Claude Code-style inline highlighting

import std/strutils
import src/ui/tool_visualizer
import src/ui/diff_visualizer
import src/ui/theme

# Initialize themes first
initializeThemes()

# Set theme to see background colors
discard setCurrentTheme("default")

echo "=== Enhanced Inline Diff Visualization Demo ===\n"

# Example 1: Simple text changes (like Claude Code's config file example)
echo "Example 1: Configuration File Changes"
let originalConfig = """Size = (15, 80, 0)
Color = (255, 255, 255)
Texture = paddle.png
Pivot = center
[BallGraphic]
Texture = ball.png
Size = (12, 12, 0)"""

let modifiedConfig = """Size = (20, 120, 0)
Color = (255, 255, 255)
Texture = orx:texture:pixel
Pivot = center
[BallGraphic]
Texture = ball.png
Size = (8, 8, 0)"""

echo createInlineDiffFromEditResult("", originalConfig, modifiedConfig)
echo ""

# Example 2: Code changes with more complex differences
echo "Example 2: Code Refactoring"
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

echo createInlineDiffFromEditResult("", originalCode, modifiedCode)
echo ""

# Example 3: Import statement changes
echo "Example 3: Import Changes"
let originalImports = """import std/[strutils, sequtils]
import json
import os"""

let modifiedImports = """import std/[strutils, sequtils, math]
import std/json
import os, times"""

echo createInlineDiffFromEditResult("", originalImports, modifiedImports)
echo ""

echo "=== Tool Visualization Integration Example ===\n"

# Example of how this integrates with tool calls
import std/json

# Simulate an edit tool call result
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

echo "Tool Call Visualization:"
echo formatToolVisualization(editInfo, getDefaultToolConfig())

echo "\n=== End of Enhanced Demo ==="