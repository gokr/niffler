import std/[strutils, os]
import cligen

import core/config
import std/logging
import ui/cli

const VERSION* = staticExec("cd " & (currentSourcePath().parentDir().parentDir()) & " && nimble dump | grep '^version:' | cut -d'\"' -f2")

proc version() =
  echo "Niffler " & VERSION & " - AI-powered terminal assistant"

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

proc prompt(text: string = "", model: string = "", debug: bool = false) =
  ## Start interactive session or send single prompt
  if debug:
    setLogFilter(lvlDebug)
    echo "Debug logging enabled"
  
  if text.len == 0:
    # Start interactive UI
    startInteractiveUI(model, debug)
  else:
    # Send single prompt
    sendSinglePrompt(text, model, debug)

when isMainModule:
  dispatchMulti([version], [init], [list], [prompt])