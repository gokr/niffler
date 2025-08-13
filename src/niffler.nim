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

proc list() = 
  ## List available models and configurations
  let config = loadConfig()
  echo "Available models:"
  for model in config.models:
    echo "  ", model.nickname, " (", model.baseUrl, ")"

proc prompt(text: string = "", model: string = "", debug: bool = false, info: bool = false) =
  ## Start interactive session or send single prompt
  var level = lvlNotice
  if debug:
    level = lvlDebug
    debug "Debug logging enabled"
  elif info:
    level = lvlInfo
    debug "Info logging enabled"
  setLogFilter(level)

  if text.len == 0:
    # Start interactive UI
    startInteractiveUI(model, level)
  else:
    # Send single prompt
    sendSinglePrompt(text, model, level)

when isMainModule:
  dispatchMulti([version], [init], [list], [prompt])