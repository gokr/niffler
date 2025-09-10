## Thinking Token Visualizer
##
## This module provides specialized rendering for thinking token content in the CLI,
## offering distinct visual formatting for reasoning content, encrypted reasoning,
## and thinking section headers. Integrates with the existing theme system.

import std/[strformat]
import theme
import ../core/constants

# Simple display styles for thinking tokens
proc renderThinkingContent*(content: string, isEncrypted = false): string =
  ## Render thinking content with appropriate emoji prefix and styling based on encryption
  ## Render thinking content with appropriate styling
  if isEncrypted:
    return formatWithStyle("🔒 [Encrypted reasoning]", currentTheme.encryptedThinking)
  
  # Use cursive/italic formatting for thinking content with emoji prefix
  let styledContent = formatWithStyle(content, currentTheme.thinking)
  return "🤔 " & styledContent

proc renderThinkingSummary*(tokenCount: int): string =
  ## Render a summary line showing thinking token usage count
  ## Render thinking token usage summary
  if tokenCount <= 0:
    return ""
  return fmt"[{tokenCount} reasoning tokens]"

# Configuration for thinking display
var
  thinkingDisplayEnabled*: bool = true
  thinkingTokenBudget*: int = THINKING_TOKEN_DEFAULT_BUDGET

proc configureThinkingDisplay*(enabled: bool, budget: int = THINKING_TOKEN_DEFAULT_BUDGET) =
  ## Configure thinking token display settings including budget limits
  thinkingDisplayEnabled = enabled
  thinkingTokenBudget = budget

proc isThinkingDisplayEnabled*(): bool =
  ## Check if thinking token display is currently enabled
  thinkingDisplayEnabled