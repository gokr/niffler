## Test File for Diff Visualization
##
## This test demonstrates the diff visualization functionality with sample output.

import std/[strutils, os]
import ../src/ui/diff_visualizer
import ../src/ui/theme

proc testDiffVisualization() =
  ## Test the diff visualization with sample content
  
  echo "=== Testing Diff Visualization ===\n"
  
  # Initialize themes
  initializeThemes()
  
  # Sample original content
  let originalContent = """
import std/[strutils, sequtils]

proc factorial*(n: int): int =
  ## Calculate factorial of n
  if n <= 1:
    return 1
  else:
    return n * factorial(n - 1)

proc fibonacci*(n: int): int =
  ## Calculate nth Fibonacci number
  if n <= 1:
    return n
  else:
    return fibonacci(n - 1) + fibonacci(n - 2)

echo "Hello, World!"
let result = factorial(5)
echo "Factorial of 5 is: ", result
""".strip()

  # Sample modified content
  let modifiedContent = """
import std/[strutils, sequtils, math]

proc factorial*(n: int): int =
  ## Calculate factorial of n iteratively
  if n <= 1:
    return 1
  var result = 1
  for i in 2..n:
    result = result * i
  return result

proc fibonacci*(n: int): int =
  ## Calculate nth Fibonacci number iteratively
  if n <= 1:
    return n
  var a, b = 0, 1
  for i in 2..n:
    let temp = a + b
    a = b
    b = temp
  return b

proc main() =
  echo "Hello, Nim World!"
  let result = factorial(5)
  echo "Factorial of 5 is: ", result
  let fib = fibonacci(10)
  echo "10th Fibonacci number is: ", fib

main()
""".strip()

  # Create diff config
  let config = getDefaultDiffConfig()
  
  # Compute diff
  let diffResult = computeDiff(originalContent, modifiedContent, config)
  diffResult.filePath = "example.nim"
  
  echo "Sample diff output:\n"
  echo "==================\n"
  
  # Display the diff
  displayDiff(diffResult, config)
  
  echo "\n==================\n"
  echo "Test completed!"

# Run the test
when isMainModule:
  testDiffVisualization()