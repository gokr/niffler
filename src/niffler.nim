## Main CLI Entry Point
##
## This is the primary entry point for Niffler, an AI-powered terminal assistant.
## It provides command-line interface handling using cligen for multi-dispatch commands.
##
## Design Decisions:
## - Uses cligen's dispatchMulti for clean subcommand handling
## - Default behavior (no subcommand) starts interactive mode
## - Single prompts can be sent via --prompt/-p option
## - Supports multiple logging levels (debug, info, notice)
## - Configuration management through init subcommand
## - Model listing through models subcommand
##
## Command Structure:
## - `niffler` - Interactive mode
## - `niffler --prompt "text"` - Send single prompt
## - `niffler init` - Initialize configuration
## - `niffler models` - List available models
## - `niffler version` - Show version

import std/[strutils, os]
import cligen

import core/config
import std/logging
import ui/cli

const VERSION* = staticExec("cd " & (currentSourcePath().parentDir().parentDir()) & " && nimble dump | grep '^version:' | cut -d'\"' -f2") 

proc version() =
  ## Show current version of Niffler
  echo "Niffler " & VERSION

proc init(configPath: string = "") =
  ## Initialize Niffler configuration
  let path = if configPath.len == 0: getDefaultConfigPath() else: configPath
  initializeConfig(path)
  echo "Configuration initialized at: ", path

proc models() = 
  ## List available models and configurations
  let config = loadConfig()
  echo "Available models:"
  for model in config.models:
    echo "  ", model.nickname, " (", model.baseUrl, ")"

proc niffler(prompt: string = "", p: string = "", model: string = "", debug: bool = false, info: bool = false, dump: bool = false, illwill: bool = false) =
  ## Start interactive session or send single prompt
  ## 
  ## Args:
  ##   prompt, p: Single prompt text to send (--prompt or -p)
  ##   model: Model to use for the session
  ##   debug: Enable debug logging
  ##   info: Enable info logging
  ##   dump: Enable HTTP request/response dumping
  var level = lvlNotice
  if debug:
    level = lvlDebug
    debug "Debug logging enabled"
  elif info:
    level = lvlInfo
    debug "Info logging enabled"
  setLogFilter(level)

  # Use either --prompt or -p for single prompt text
  let promptText = if prompt.len > 0: prompt elif p.len > 0: p else: ""
  
  if promptText.len == 0:
    # Start interactive UI
    startInteractiveUI(model, level, dump, illwill)
  else:
    # Send single prompt
    sendSinglePrompt(promptText, model, level, dump)

when isMainModule:
  # Check if any subcommands were provided
  var subcommandGiven = false
  for arg in commandLineParams():
    if not arg.startsWith("-") and arg in ["version", "init", "models"]:
      subcommandGiven = true
      break
  
  if subcommandGiven:
    # Use dispatchMulti for subcommands
    dispatchMulti([version], [init], [models], [niffler])
  else:
    # Use dispatch for main command (default behavior)
    dispatch(niffler)