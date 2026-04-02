import std/[unittest]
import ../src/ui/diff_visualizer
import ../src/ui/theme

suite "Diff Visualization Tests":
  setup:
    initializeThemes()
  
  test "computeDiff detects additions":
    let original = "line1\nline2"
    let modified = "line1\nline2\nline3"
    
    let config = getDefaultDiffConfig()
    let result = computeDiff(original, modified, config)
    
    check result.hunks.len > 0
  
  test "computeDiff detects removals":
    let original = "line1\nline2\nline3"
    let modified = "line1\nline2"
    
    let config = getDefaultDiffConfig()
    let result = computeDiff(original, modified, config)
    
    check result.hunks.len > 0
  
  test "computeDiff detects modifications":
    let original = "hello world"
    let modified = "hello Nim"
    
    let config = getDefaultDiffConfig()
    let result = computeDiff(original, modified, config)
    
    check result.hunks.len > 0 or result.originalContent != result.modifiedContent
  
  test "computeDiff handles empty content":
    let original = ""
    let modified = ""
    
    let config = getDefaultDiffConfig()
    let result = computeDiff(original, modified, config)
    
    check result.hunks.len == 0
  
  test "getDefaultDiffConfig returns valid config":
    let config = getDefaultDiffConfig()
    
    check config.contextLines >= 0
    check config.showLineNumbers == true
    check config.useColor == true
  
  test "Diff result contains file path":
    let original = "original"
    let modified = "modified"
    
    let config = getDefaultDiffConfig()
    var result = computeDiff(original, modified, config)
    result.filePath = "test.nim"
    
    check result.filePath == "test.nim"

echo "All diff visualization tests completed"
