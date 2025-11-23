## UI State Management
##
## This module manages shared UI state and provides functions to update
## token counts, status line, and prompt text. This avoids circular imports
## between cli.nim and output_handler.nim.

import std/[strformat, strutils, options, math, terminal]
import ../../../linecross/linecross
import ../core/[config, session, conversation_manager, mode_state, app]
import ../types/[config as configTypes]
import theme

# UI state variables
var inputTokens*: int = 0
var outputTokens*: int = 0
var currentModelName*: string = ""
var isProcessing*: bool = false

proc formatTokenAmount*(tokens: int): string =
  ## Format token amounts with appropriate units (0-1000, 1.0k-20.0k, 20k-999k, 1.0M+)
  if tokens < 1000:
    return $tokens
  elif tokens < 20000:
    let k = tokens.float / 1000.0
    return fmt"{k:.1f}k"
  elif tokens < 1000000:
    let k = tokens div 1000
    return fmt"{k}k"
  else:
    let m = tokens.float / 1000000.0
    return fmt"{m:.1f}M"

proc formatCostRounded*(cost: float): string =
  ## Format cost rounded to 3 decimals with no trailing zeros
  let rounded = round(cost, 3)
  if rounded == 0.0:
    return "$0"

  let formatted = fmt"${rounded:.3f}"
  # Remove trailing zeros after decimal point
  var finalResult = formatted
  if '.' in finalResult:
    while finalResult.endsWith("0"):
      finalResult = finalResult[0..^2]
    if finalResult.endsWith("."):
      finalResult = finalResult[0..^2]
  return finalResult

proc updateStatusLine*() =
  ## Update status line with token counts, context info, and cost
  let sessionTotal = inputTokens + outputTokens

  if sessionTotal > 0:
    # Get model config from current session or load from config
    let config = loadConfig()
    let modelConfig = if currentModelName.len > 0:
      selectModelFromConfig(config, currentModelName)
    else:
      config.models[0]

    let contextMessages = conversation_manager.getConversationContext()
    let contextSize = app.estimateTokenCount(contextMessages)
    let maxContext = if modelConfig.context > 0: modelConfig.context else: 128000
    let statusIndicator = if isProcessing: "⚡" else: ""

    # Calculate context percentage and format max context
    let contextPercent = if maxContext > 0: min(100, (contextSize * 100) div maxContext) else: 0
    let contextInfo = fmt"{contextPercent}% of {formatTokenAmount(maxContext)}"

    # Format token amounts with new formatting
    let formattedInputTokens = formatTokenAmount(inputTokens)
    let formattedOutputTokens = formatTokenAmount(outputTokens)

    # Calculate session cost if available using real token data
    let sessionTokens = getSessionTokens()
    var sessionCost = 0.0

    if modelConfig.inputCostPerMToken.isSome() and sessionTokens.inputTokens > 0:
      let inputCostPerToken = modelConfig.inputCostPerMToken.get() / 1_000_000.0
      sessionCost += sessionTokens.inputTokens.float * inputCostPerToken

    if modelConfig.outputCostPerMToken.isSome() and sessionTokens.outputTokens > 0:
      let outputCostPerToken = modelConfig.outputCostPerMToken.get() / 1_000_000.0
      sessionCost += sessionTokens.outputTokens.float * outputCostPerToken

    let costInfo = if sessionCost > 0: fmt" {formatCostRounded(sessionCost)}" else: ""
    let statusLine = fmt"{statusIndicator}↑{formattedInputTokens} ↓{formattedOutputTokens} {contextInfo}{costInfo}"
    setStatus(@[statusLine])
  else:
    # Clear status line when no tokens yet
    clearStatus()

proc generatePrompt*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()): string =
  ## Generate prompt based on runtime mode:
  ## - Master mode: shows focused agent or just "niffler"
  ## - Agent mode: shows model, plan/code mode, and conversation ID
  if isMasterMode():
    # Master mode - show focused agent
    let agent = getCurrentAgentForPrompt()
    if agent.len > 0:
      return fmt("@{agent} > ")
    else:
      return "niffler > "
  else:
    # Agent mode - show detailed context
    let currentSession = getCurrentSession()
    let modelNameWithContext = if currentSession.isSome():
      let conv = currentSession.get().conversation
      let agentMode = getCurrentMode()
      fmt("{currentModelName}({agentMode}, {conv.id})")
    else:
      currentModelName

    return fmt("{modelNameWithContext} > ")

proc updatePromptState*(modelConfig: configTypes.ModelConfig = configTypes.ModelConfig()) =
  ## Update prompt color and text based on current mode and model
  setPromptColor(getModePromptColor(), {styleBright})

proc updateTokenCounts*(newInputTokens: int, newOutputTokens: int) =
  ## Update token counts in central history storage
  ## Note: This is safe to call from any thread as it only updates simple variables
  ## UI updates (status line, prompt) happen in readInputWithPrompt() on the main thread
  updateSessionTokens(newInputTokens, newOutputTokens)
  inputTokens = newInputTokens
  outputTokens = newOutputTokens

proc resetUIState*() =
  ## Reset UI-specific state (tokens, pending tool calls)
  inputTokens = 0
  outputTokens = 0

  # Sync currentModelName with the current session's model
  let currentSession = getCurrentSession()
  if currentSession.isSome():
    let conv = currentSession.get().conversation
    currentModelName = conv.modelNickname

  # Update prompt color to reflect current mode
  updatePromptState()

proc resetUIState*(modelName: string) =
  ## Reset UI-specific state and set specific model name
  inputTokens = 0
  outputTokens = 0
  currentModelName = modelName

  # Update prompt color to reflect current mode
  updatePromptState()
