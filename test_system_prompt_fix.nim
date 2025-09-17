## Test the system prompt token calculation fix
import std/[strformat]
import src/core/system_prompt
import src/types/mode

proc main() =
  echo "=== Testing System Prompt Token Calculation Fix ==="
  
  # Test system prompt generation with new tokenizer
  let systemResult = generateSystemPromptWithTokens(amPlan, "glm-4")
  
  echo "System Prompt Token Breakdown (NEW):"
  echo fmt"  Total: {systemResult.tokens.total} tokens"
  echo fmt"  - Base prompt: {systemResult.tokens.basePrompt}"
  echo fmt"  - Mode prompt: {systemResult.tokens.modePrompt}"  
  echo fmt"  - Environment info: {systemResult.tokens.environmentInfo}"
  echo fmt"  - Instruction files: {systemResult.tokens.instructionFiles}"
  echo fmt"  - Tool instructions: {systemResult.tokens.toolInstructions}"
  echo fmt"  - Available tools: {systemResult.tokens.availableTools}"
  
  # Compare with manual calculation
  echo "\nManual Verification:"
  let systemPromptContent = systemResult.content
  echo fmt"  System prompt length: {systemPromptContent.len} characters"
  
  # Estimate with char/4 rule for comparison
  let charDiv4 = systemPromptContent.len div 4
  echo fmt"  Char/4 estimate: {charDiv4} tokens"
  echo fmt"  New BPE estimate: {systemResult.tokens.total} tokens"
  echo fmt"  Ratio vs char/4: {systemResult.tokens.total.float / charDiv4.float:.2f}x"
  
  # Test specific component that was problematic
  echo "\nInstruction Files Analysis:"
  let instructionFiles = findInstructionFiles()
  echo fmt"  Instruction content length: {instructionFiles.len} characters"
  let instructionDiv4 = instructionFiles.len div 4  
  echo fmt"  Char/4 estimate: {instructionDiv4} tokens"
  echo fmt"  New BPE estimate: {systemResult.tokens.instructionFiles} tokens"
  echo fmt"  Improvement: {100.0 * (1.0 - systemResult.tokens.instructionFiles.float / instructionDiv4.float):.1f}% more accurate"
  
  # Expected total for a realistic API request
  let conversationTokens = 790  # From user's example
  let totalEstimate = systemResult.tokens.total + conversationTokens
  echo fmt"\nRealistic API Request Estimate:"
  echo fmt"  Conversation: {conversationTokens} tokens"
  echo fmt"  System prompt: {systemResult.tokens.total} tokens"
  echo fmt"  Total request: {totalEstimate} tokens"
  echo fmt"  vs User's actual: 4,800 tokens"
  
  if totalEstimate >= 4000 and totalEstimate <= 6000:
    echo "  ✅ Much closer to actual usage!"
  else:
    echo "  ❌ Still significant discrepancy"

when isMainModule:
  main()