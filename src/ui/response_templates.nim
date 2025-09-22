## Response Processing Templates
##
## Templates for eliminating repetitive response processing patterns in CLI UI.
## These templates handle common streaming response patterns like thinking content
## display and tool call visualization.

import std/[tables, strformat]
import ../types/messages
import tool_visualizer
import theme

template processThinkingContent*(response: APIResponse, isInThinkingBlock: var bool): untyped =
  ## Template for consistent thinking content display across CLI modes
  ## Handles the repetitive pattern of thinking token processing in startCLIMode() and sendSinglePrompt()
  if response.thinkingContent.isSome():
    let thinkingContent = response.thinkingContent.get()
    let isEncrypted = response.isEncrypted.isSome() and response.isEncrypted.get()
    
    if not isInThinkingBlock:
      # Start of thinking block - show emoji prefix and set flag
      let emojiPrefix = if isEncrypted: "🔒 " else: "🤔 "
      let styledContent = formatWithStyle(thinkingContent, currentTheme.thinking)
      stdout.write(emojiPrefix & styledContent)
      isInThinkingBlock = true
    else:
      # Continuing thinking block - just show content without emoji
      let styledContent = formatWithStyle(thinkingContent, currentTheme.thinking)
      stdout.write(styledContent)
    stdout.flushFile()

template handleToolCallDisplay*(response: APIResponse, 
                               pendingToolCalls: var Table[string, CompactToolRequestInfo],
                               outputAfterToolCall: var bool): untyped =
  ## Template for consistent tool call display handling
  ## Covers both arkToolCallRequest and arkToolCallResult cases
  case response.kind:
  of arkToolCallRequest:
    # Display tool request immediately with hourglass indicator
    let toolRequest = response.toolRequestInfo
    pendingToolCalls[toolRequest.toolCallId] = toolRequest
    
    # Reset output tracking and display tool call with hourglass
    outputAfterToolCall = false
    let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
    stdout.write(formattedRequest & " ⏳\n")
    stdout.flushFile()
  
  of arkToolCallResult:
    # Handle progressive tool result display
    let toolResult = response.toolResultInfo
    if pendingToolCalls.hasKey(toolResult.toolCallId):
      let toolRequest = pendingToolCalls[toolResult.toolCallId]
      let formattedResult = formatCompactToolResultWithIndent(toolResult)
      
      if not outputAfterToolCall:
        # No output since tool call - move cursor up, clear hourglass, and add result
        stdout.write("\r\e[K")  # Clear current line
        stdout.write("\e[1A")   # Move cursor up one line
        stdout.write("\r\e[K")  # Clear the tool call line with hourglass
        
        # Re-write tool call without hourglass and add result
        let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
        stdout.write(formattedRequest & "\n" & formattedResult & "\n")
      else:
        # Output occurred since tool call - re-render both request and result
        let formattedRequest = formatCompactToolRequestWithIndent(toolRequest)
        stdout.write(formattedRequest & "\n" & formattedResult & "\n")
      
      # Remove from pending
      pendingToolCalls.del(toolResult.toolCallId)
    else:
      # Fallback if request wasn't tracked
      let formattedResult = formatCompactToolResult(toolResult)
      stdout.write(formattedResult & "\n")
    stdout.flushFile()
  else:
    discard

template resetThinkingBlockOnContent*(response: APIResponse, isInThinkingBlock: var bool): untyped =
  ## Template to reset thinking block flag when regular content arrives
  if response.content.len > 0:
    isInThinkingBlock = false

template resetThinkingBlockOnCompletion*(isInThinkingBlock: var bool): untyped =
  ## Template to reset thinking block flag when stream completes or errors
  isInThinkingBlock = false