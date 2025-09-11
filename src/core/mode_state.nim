## Mode State Management
##
## This module provides thread-safe mode state management for Niffler.
## Separated from app.nim to avoid circular dependencies.

import std/[strformat, logging]
import ../types/mode

# Thread-safe mode state management
var currentMode {.threadvar.}: AgentMode
var modeInitialized {.threadvar.}: bool

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