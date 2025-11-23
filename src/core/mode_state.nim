## Mode State Management
##
## This module provides thread-safe mode state management for Niffler.
## Separated from app.nim to avoid circular dependencies.

import std/[strformat, logging]
import ../types/mode

type
  RuntimeMode* = enum
    rmMaster = "master"   ## Running as master coordinator
    rmAgent = "agent"     ## Running as an agent

# Thread-safe mode state management
var currentMode {.threadvar.}: AgentMode
var modeInitialized {.threadvar.}: bool

# Runtime mode state (master vs agent)
var runtimeMode {.threadvar.}: RuntimeMode
var runtimeModeInitialized {.threadvar.}: bool
var currentAgentForPrompt {.threadvar.}: string  # For master mode prompt display

proc initializeModeState*() =
  ## Initialize the mode state (thread-safe)
  if not modeInitialized:
    currentMode = getDefaultMode()
    modeInitialized = true
    debug(fmt"Mode state initialized to: {currentMode}")

proc getCurrentMode*(): AgentMode =
  ## Get the current agent mode (thread-safe)
  if not modeInitialized:
    initializeModeState()
  return currentMode

proc setCurrentMode*(mode: AgentMode) =
  ## Set the current agent mode (thread-safe)
  let previousMode = getCurrentMode()
  currentMode = mode
  modeInitialized = true
  debug(fmt"Mode changed from {previousMode} to: {mode}")

proc toggleMode*(): AgentMode =
  ## Toggle between Plan and Code modes, returns new mode
  let newMode = getNextMode(getCurrentMode())
  setCurrentMode(newMode)
  return newMode

# Runtime mode functions (master vs agent)
proc initializeRuntimeMode*(mode: RuntimeMode) =
  ## Initialize the runtime mode (master or agent)
  runtimeMode = mode
  runtimeModeInitialized = true
  debug(fmt("Runtime mode initialized to: {mode}"))

proc getRuntimeMode*(): RuntimeMode =
  ## Get the current runtime mode
  if not runtimeModeInitialized:
    runtimeMode = rmMaster  # Default to master
    runtimeModeInitialized = true
  return runtimeMode

proc isMasterMode*(): bool =
  ## Check if running in master mode
  result = getRuntimeMode() == rmMaster

proc isAgentMode*(): bool =
  ## Check if running in agent mode
  result = getRuntimeMode() == rmAgent

proc setCurrentAgentForPrompt*(agentName: string) =
  ## Set the current agent name for prompt display (master mode only)
  currentAgentForPrompt = agentName

proc getCurrentAgentForPrompt*(): string =
  ## Get the current agent name for prompt display
  result = currentAgentForPrompt

