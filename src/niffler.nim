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
import clim

import core/config
import std/logging
import ui/cli

const VERSION* = staticExec("cd " & (currentSourcePath().parentDir().parentDir()) & " && nimble dump | grep '^version:' | cut -d'\"' -f2") 

proc showVersion() =
  ## Show current version of Niffler
  echo "Niffler " & VERSION

proc init(configPath: string = "") =
  ## Initialize Niffler configuration
  let path = if configPath.len == 0: getDefaultConfigPath() else: configPath
  initializeConfig(path)
  echo "Configuration initialized at: ", path

proc showModels() = 
  ## List available models and configurations
  let config = loadConfig()
  echo "Available models:"
  for model in config.models:
    echo "  ", model.nickname, " (", model.baseUrl, ")"

proc showHelp() =
  echo """
This is Niffler, your cuddly friendly coder pal.

  niffler [options]

Options:
  --help, -h               Show this help message
  --version, -v            Show version of Niffler

  --model, -m:<nickname>   Select model
  --prompt, -p:<text>      Perform single prompt and exit
  --models                 List available models
  --init                   Initialize a default config at ~/.config/niffler/config.json
  --init:<filepath>        Initialize a default configuration in given filepath

  --simple, -s             Use a simpler terminal UI
  --info, -i               Show info level logging
  --debug, -d              Show debug level logging
  --dump                   Show HTTP requests & responses
"""

when isMainModule:
  # Command line options using clim
  proc undefinedOptionHook(name, part: string) =
    echo "Undefined option: " & part
    quit(0)
  template parseErrorHook(name, value: string, typ: typedesc) =
    echo "Parse error: " & name & " " & value
    quit(0)  
  opt(help, bool, ["--help", "-h"])
  opt(version, bool, ["--version", "-v"])
  opt(model, string, ["--model", "-m"])
  opt(prompt, string, ["--prompt", "-p"], "")
  opt(models, bool, ["--models"])
  opt(initConfig, string, ["--init"], "false")
  opt(simple, bool, ["--simple", "-s"])
  opt(info, bool, ["--info", "-i"])
  opt(debug, bool, ["--debug", "-d"])
  opt(dump, bool, ["--dump"])
  getOpt(commandLineParams())

  if help:
    showHelp()
    quit(0)
  elif version:
    showVersion()
    quit(0)
  elif models:
    showModels()
    quit(0)
  elif initConfig != "false":
    init(if initConfig == "true": "" else: initConfig)
    quit(0)
  
  var level = lvlNotice
  if debug:
    level = lvlDebug
    debug "Debug logging enabled"
  elif info:
    level = lvlInfo
    debug "Info logging enabled"
  setLogFilter(level)

  if prompt.len == 0:
    # Start interactive UI if no prompt given
    startInteractiveUI(model, level, dump, simple)
  else:
    # Send single prompt
    sendSinglePrompt(prompt, model, level, dump)

