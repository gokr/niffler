## Command Parser
##
## Shared parser for agent and master modes to parse user input commands.
## Handles commands like /plan, /task, /model <name>, etc.
##
## Used by:
## - Master mode: Parse user input to determine what to send to agent
## - Agent mode: Parse request input to determine mode switches and model changes
##
## Examples:
## - "/plan Create a feature" -> {mode: plan, prompt: "Create a feature"}
## - "/model haiku Write docs" -> {model: "haiku", prompt: "Write docs"}
## - "/plan /model sonnet Design schema" -> {mode: plan, model: "sonnet", prompt: "Design schema"}
## - "Create tests" -> {prompt: "Create tests"}

import std/[strutils, options]

type
  ExecutionMode* = enum
    ## Execution mode for the agent
    emCode = "code"      # Default code mode
    emPlan = "plan"      # Planning mode

  ConversationType* = enum
    ## Type of conversation
    ctAsk = "ask"        # Continue/create ask conversation (builds context)
    ctTask = "task"      # Create fresh task conversation (isolated)

  ParsedCommand* = object
    ## Result of parsing a command string
    mode*: Option[ExecutionMode]           # /plan or /code
    conversationType*: Option[ConversationType]  # /task (default is ask)
    model*: Option[string]                 # /model <name>
    prompt*: string                        # Remaining text after commands

proc parseCommand*(input: string): ParsedCommand =
  ## Parse command string and extract commands and prompt
  ## Commands are prefixed with / and can be combined
  ## Examples:
  ## - "/plan Create feature" -> mode=plan, prompt="Create feature"
  ## - "/task Research topic" -> type=task, prompt="Research topic"
  ## - "/model haiku Write" -> model="haiku", prompt="Write"
  ## - "/plan /model sonnet Design" -> mode=plan, model="sonnet", prompt="Design"

  result.mode = none(ExecutionMode)
  result.conversationType = none(ConversationType)
  result.model = none(string)
  result.prompt = ""

  var tokens = input.strip().split()
  # Filter out empty tokens from multiple spaces
  var filteredTokens: seq[string] = @[]
  for token in tokens:
    if token.len > 0:
      filteredTokens.add(token)

  var promptTokens: seq[string] = @[]
  var i = 0

  while i < filteredTokens.len:
    let token = filteredTokens[i]

    if token.startsWith("/"):
      let cmd = token[1..^1].toLower()

      case cmd:
      of "plan":
        result.mode = some(emPlan)
        i.inc()
      of "code":
        result.mode = some(emCode)
        i.inc()
      of "task":
        result.conversationType = some(ctTask)
        i.inc()
      of "ask":
        result.conversationType = some(ctAsk)
        i.inc()
      of "model":
        # Next token should be model name
        if i + 1 < filteredTokens.len:
          result.model = some(filteredTokens[i + 1])
          i.inc(2)
        else:
          # /model without argument, skip it
          i.inc()
      else:
        # Unknown command, treat as part of prompt
        promptTokens.add(token)
        i.inc()
    else:
      # Not a command, add to prompt
      promptTokens.add(token)
      i.inc()

  result.prompt = promptTokens.join(" ")

proc hasCommands*(parsed: ParsedCommand): bool =
  ## Check if any commands were parsed
  parsed.mode.isSome() or parsed.conversationType.isSome() or parsed.model.isSome()

proc `$`*(parsed: ParsedCommand): string =
  ## String representation for debugging
  result = "ParsedCommand("
  if parsed.mode.isSome():
    result.add("mode=" & $parsed.mode.get() & ", ")
  if parsed.conversationType.isSome():
    result.add("type=" & $parsed.conversationType.get() & ", ")
  if parsed.model.isSome():
    result.add("model=" & parsed.model.get() & ", ")
  result.add("prompt=\"" & parsed.prompt & "\")")
