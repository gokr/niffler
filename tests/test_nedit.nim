## Tests for nedit CLI tool
## 
## Run with: nim c -r tests/test_nedit.nim

import std/[unittest, os, strutils, strformat, osproc]

const
  NeditPath = "../nedit"
  TestDir = "test_nedit_temp"

proc runNedit(args: string): tuple[output: string, exitCode: int] =
  let cmd = &"{NeditPath} {args} 2>&1"
  let (output, exitCode) = execCmdEx(cmd)
  return (output.strip, exitCode)

proc setup() =
  if dirExists(TestDir):
    removeDir(TestDir)
  createDir(TestDir)
  
  writeFile(&"{TestDir}/test.txt", """Line 1
Line 2
Line 3
Line 4
Line 5
Line 6
Line 7
Line 8
Line 9
Line 10
""")
  
  writeFile(&"{TestDir}/sample.py", """def hello():
    print("Hello, World!")
    return 42

def goodbye():
    print("Goodbye!")
    return 0
""")

proc teardown() =
  if dirExists(TestDir):
    removeDir(TestDir)

suite "nedit help system":
  test "main help":
    let (output, code) = runNedit("--help")
    check code == 0
    check "nedit - File editor for LLM agents" in output
    check "read" in output
    check "write" in output
    check "edit" in output
    check "list" in output
    check "grep" in output
    check "stat" in output

  test "read help":
    let (output, code) = runNedit("read --help")
    check code == 0
    check "nedit read" in output
    check "--lines" in output

  test "write help":
    let (output, code) = runNedit("write --help")
    check code == 0
    check "nedit write" in output
    check "--mkdir" in output

  test "edit help":
    let (output, code) = runNedit("edit --help")
    check code == 0
    check "replace" in output
    check "insert" in output

  test "list help":
    let (output, code) = runNedit("list --help")
    check code == 0
    check "nedit list" in output

  test "grep help":
    let (output, code) = runNedit("grep --help")
    check code == 0
    check "nedit grep" in output

suite "nedit read command":
  setup:
    setup()
  
  teardown:
    teardown()

  test "read entire file":
    let (output, code) = runNedit(&"read {TestDir}/test.txt")
    check code == 0
    check "Line 1" in output
    check "Line 10" in output

  test "read with line range":
    let (output, code) = runNedit(&"read {TestDir}/test.txt --lines=3-5")
    check code == 0
    check "Line 3" in output
    check "Line 5" in output
    check "Line 2" notin output

  test "read with head":
    let (output, code) = runNedit(&"read {TestDir}/test.txt --head=3")
    check code == 0
    check "Line 1" in output
    check "Line 4" notin output

  test "read with tail":
    let (output, code) = runNedit(&"read {TestDir}/test.txt --tail=3")
    check code == 0
    check "Line 10" in output

  test "read with line numbers":
    let (output, code) = runNedit(&"read {TestDir}/test.txt --show-lines")
    check code == 0
    check "1 |" in output

  test "read non-existent file":
    let (output, code) = runNedit(&"read {TestDir}/nonexistent.txt")
    check code == 1
    check "not found" in output

suite "nedit write command":
  setup:
    setup()
  
  teardown:
    teardown()

  test "write new file":
    let (output, code) = runNedit(&"write {TestDir}/new.txt \"Hello World\"")
    check code == 0
    check "Wrote" in output
    check fileExists(&"{TestDir}/new.txt")

  test "write with mkdir":
    let (output, code) = runNedit(&"write {TestDir}/subdir/new.txt \"Test\" --mkdir")
    check code == 0
    check "Created directory" in output
    check fileExists(&"{TestDir}/subdir/new.txt")

  test "overwrite existing file":
    let (output, code) = runNedit(&"write {TestDir}/test.txt \"Replaced content\"")
    check code == 0
    check "Wrote" in output

  test "write with backup":
    let (output, code) = runNedit(&"write {TestDir}/test.txt \"New content\" --backup")
    check code == 0
    check "backup" in output
    check fileExists(&"{TestDir}/test.txt.bak")

suite "nedit edit command":
  setup:
    setup()
  
  teardown:
    teardown()

  test "replace text":
    let (output, code) = runNedit(&"edit {TestDir}/sample.py replace \"Hello\" \"Hi\"")
    check code == 0
    check "Replaced" in output
    let content = readFile(&"{TestDir}/sample.py")
    check "Hi, World!" in content

  test "replace all occurrences":
    writeFile(&"{TestDir}/multi.txt", "foo bar foo baz foo")
    discard runNedit(&"edit {TestDir}/multi.txt replace \"foo\" \"qux\" --all")
    let content = readFile(&"{TestDir}/multi.txt")
    check content.count("qux") == 3

  test "insert line":
    let (output, code) = runNedit(&"edit {TestDir}/test.txt insert 3 \"Inserted line\"")
    check code == 0
    check "Inserted" in output

  test "delete lines":
    let (output, code) = runNedit(&"edit {TestDir}/test.txt delete 3-5")
    check code == 0
    check "Deleted 3 lines" in output

  test "append text":
    let (output, code) = runNedit(&"edit {TestDir}/test.txt append \"Appended line\"")
    check code == 0
    let content = readFile(&"{TestDir}/test.txt")
    check "Appended line" in content

  test "prepend text":
    let (output, code) = runNedit(&"edit {TestDir}/test.txt prepend \"# Header\"")
    check code == 0
    let content = readFile(&"{TestDir}/test.txt")
    check "# Header" in content

  test "text not found error":
    let (output, code) = runNedit(&"edit {TestDir}/test.txt replace \"nonexistent\" \"replacement\"")
    check code == 1
    check "not found" in output

  test "invalid line number error":
    let (output, code) = runNedit(&"edit {TestDir}/test.txt insert 100 \"test\"")
    check code == 1
    check "Invalid line number" in output

suite "nedit list command":
  setup:
    setup()
  
  teardown:
    teardown()

  test "list directory":
    let (output, code) = runNedit(&"list {TestDir}")
    check code == 0
    check "test.txt" in output
    check "sample.py" in output

  test "list with long format":
    let (output, code) = runNedit(&"list {TestDir} --long")
    check code == 0
    check "test.txt" in output

  test "list non-existent directory":
    let (output, code) = runNedit("list nonexistent_dir")
    check code == 1
    check "not found" in output

suite "nedit grep command":
  setup:
    setup()
  
  teardown:
    teardown()

  test "grep in file":
    let (output, code) = runNedit(&"grep \"Line 5\" {TestDir}/test.txt")
    check code == 0
    check "Line 5" in output

  test "grep with recursive":
    let (output, code) = runNedit(&"grep \"print\" {TestDir}/ --recursive")
    check code == 0
    check "sample.py" in output

  test "grep with line numbers":
    let (output, code) = runNedit(&"grep \"Line\" {TestDir}/test.txt --line-number")
    check code == 0
    check ":" in output

  test "grep pattern not found":
    let (output, code) = runNedit(&"grep \"nonexistent_pattern\" {TestDir}/test.txt")
    check code == 0
    check "Found 0 matches" in output

  test "grep requires recursive for directory":
    let (output, code) = runNedit(&"grep \"test\" {TestDir}/")
    check code == 1
    check "recursive" in output

suite "nedit stat command":
  setup:
    setup()
  
  teardown:
    teardown()

  test "stat file":
    let (output, code) = runNedit(&"stat {TestDir}/test.txt")
    check code == 0
    check "Path:" in output
    check "Type: File" in output
    check "Size:" in output

  test "stat directory":
    let (output, code) = runNedit(&"stat {TestDir}")
    check code == 0
    check "Type: Directory" in output

  test "stat non-existent":
    let (output, code) = runNedit(&"stat {TestDir}/nonexistent")
    check code == 1
    check "not found" in output

suite "nedit error handling":
  test "unknown command":
    let (output, code) = runNedit("unknown")
    check code == 1
    check "Unknown command" in output

  test "missing file argument for read":
    let (output, code) = runNedit("read")
    check code == 1
    check "Missing" in output

  test "missing content argument for write":
    let (output, code) = runNedit("write test.txt")
    check code == 1
    check "Missing" in output

echo "\n✓ All tests completed!"
