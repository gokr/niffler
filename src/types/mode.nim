## Mode Type Definitions
##
## This module defines the operation mode types for Niffler's agentic behavior.
## Inspired by Claude Code's Plan/Code workflow.
##
## Mode Types:
## - Plan: Analysis, research, planning (no editing allowed)
## - Code: Implementation, execution, and completing todos
##
## In multi-agent architecture, mode is set via /plan command prefix
## sent to agents (e.g., "@coder /plan Design the architecture")

import std/strutils

type
  AgentMode* = enum
    ## Niffler's operation modes for agentic workflow
    amPlan = "plan"   ## Planning mode: analysis, research, todo generation
    amCode = "code"   ## Implementation mode: execution, completing todos

proc parseMode*(modeStr: string): AgentMode =
  ## Parse string to AgentMode (case insensitive)
  case modeStr.toLower():
  of "plan": amPlan
  of "code": amCode
  else:
    raise newException(ValueError, "Invalid mode: " & modeStr)

proc getDefaultMode*(): AgentMode =
  ## Get the default starting mode
  amPlan  # Start in planning mode by default

proc getModeDescription*(mode: AgentMode): string =
  ## Get human-readable description of the mode
  case mode:
  of amPlan: "Planning & Analysis - Focus on research, planning, and breaking down tasks into actionable todos"
  of amCode: "Implementation & Execution - Focus on writing code, executing todos, and making changes"

proc getNextMode*(mode: AgentMode): AgentMode =
  ## Get the next mode for toggling (Plan ↔ Code)
  case mode:
  of amPlan: amCode
  of amCode: amPlan