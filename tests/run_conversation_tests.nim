## Test Runner for Conversation Management Integration Tests
##
## This runner executes all conversation management tests and provides
## a summary of results with proper cleanup.

import std/[unittest, os, strformat]

# Import all test suites
include test_conversation_infrastructure
include test_conversation_e2e
include test_conversation_cli

proc main() =
  echo "=" & "=".repeat(60)
  echo "NIFFLER CONVERSATION MANAGEMENT INTEGRATION TESTS"
  echo "=" & "=".repeat(60)
  echo ""
  
  # Create a temporary directory for test databases
  let testDir = getTempDir() / "niffler_test_run"
  createDir(testDir)
  defer: 
    try:
      removeDir(testDir)
    except:
      echo fmt"Warning: Could not cleanup test directory {testDir}"
  
  echo "Starting comprehensive integration tests..."
  echo "Test directory: " & testDir
  echo ""
  
  # Run the test suites
  try:
    echo "Running test suites..."
    echo ""
    
    # The unittest framework will automatically run all tests
    # when this module is executed
    
  except Exception as e:
    echo fmt"Test execution failed: {e.msg}"
    quit(1)

when isMainModule:
  main()