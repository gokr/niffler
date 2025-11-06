import std/strformat
import ../src/ui/diff_visualizer
import ../src/ui/external_renderer
import ../src/ui/theme
import ../src/types/config

proc demoBuiltinDiff() =
  echo "\n=== Demo: Built-in Diff Rendering ==="

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

  echo "\nOriginal code:"
  echo originalCode
  echo "\nModified code:"
  echo modifiedCode

  let diffResult = computeDiff(originalCode, modifiedCode)
  diffResult.filePath = "example.nim"

  echo "\n--- Built-in diff rendering ---"
  displayDiff(diffResult)

proc demoDeltaDiff() =
  echo "\n\n=== Demo: Delta External Rendering ==="

  let originalCode = """import std/[strutils, sequtils]
import json
import os

proc processFile(path: string): bool =
  let content = readFile(path)
  let lines = content.splitLines()
  return lines.len > 0"""

  let modifiedCode = """import std/[strutils, sequtils, math]
import std/json
import os, times

proc processFile(path: string): tuple[success: bool, lineCount: int] =
  let content = readFile(path)
  let lines = content.splitLines()
  let count = lines.len
  return (success: count > 0, lineCount: count)"""

  echo "\nOriginal code:"
  echo originalCode
  echo "\nModified code:"
  echo modifiedCode

  echo "\n--- Delta rendering (if available) ---"
  displayDiffWithExternal(originalCode, modifiedCode, "example.nim")

  echo "\n--- Checking delta availability ---"
  let hasDelta = isCommandAvailable("delta")
  if hasDelta:
    echo "✓ Delta is installed and available"
  else:
    echo "✗ Delta is not available (showing built-in rendering above)"

proc demoExternalConfig() =
  echo "\n\n=== Demo: External Rendering Configuration ==="

  let defaultConfig = getDefaultExternalRenderingConfig()
  echo fmt("Enabled: {defaultConfig.enabled}")
  echo fmt("Content renderer: {defaultConfig.contentRenderer}")
  echo fmt("Diff renderer: {defaultConfig.diffRenderer}")
  echo fmt("Fallback to builtin: {defaultConfig.fallbackToBuiltin}")

  echo "\nCommand availability:"
  echo fmt("  batcat: {isCommandAvailable(\"batcat\")}")
  echo fmt("  delta: {isCommandAvailable(\"delta\")}")

when isMainModule:
  initializeThemes()

  echo "================================================"
  echo "   Delta Integration Demonstration"
  echo "================================================"

  demoBuiltinDiff()
  demoDeltaDiff()
  demoExternalConfig()

  echo "\n\nTo use delta in Niffler, make sure:"
  echo "1. Delta is installed (cargo install git-delta)"
  echo "2. External rendering is enabled in config.yaml"
  echo "3. Edit tool operations will automatically use delta for diff visualization"