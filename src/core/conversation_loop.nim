## Conversation Loop Module
##
## This module provides reusable conversation orchestration logic that can be used
## by both the main API worker and task execution. It handles the mechanics of
## multi-turn conversations with tool calling.
##
## Key Features:
## - Single-turn conversation execution
## - Tool call collection and execution
## - Message history management
## - Token usage tracking
##
## Design:
## - Breaks circular dependency between api.nim and task_executor.nim
## - Provides clean primitives for conversation orchestration
## - Handles both interactive (main) and autonomous (task) conversations

## This module is deprecated - task execution logic moved directly to task_executor.nim
## to avoid circular dependencies. Kept for reference only.

import std/[options]
import ../types/[messages, config, agents]

type
  ConversationTurn* = object
    ## Result of a single conversation turn
    assistantContent*: string
    toolCalls*: seq[LLMToolCall]
    tokensUsed*: int
    success*: bool
    error*: string

  ConversationResult* = object
    ## Final result of a multi-turn conversation
    messages*: seq[Message]  ## Full conversation history
    totalTokens*: int
    totalToolCalls*: int
    success*: bool
    error*: string
