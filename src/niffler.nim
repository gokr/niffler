## Main CLI Entry Point
##
## This is the primary entry point for Niffler, an AI-powered terminal assistant.
## It provides command-line interface handling using docopt for elegant subcommand parsing.
##
## Design Decisions:
## - Uses docopt for self-documenting command-line interface
## - Default behavior (no subcommand) starts interactive mode
## - Single prompts can be sent via --prompt/-p option
## - Supports multiple logging levels (debug, info, notice)
## - Configuration management through init subcommand
## - Model management through model subcommands
##
## Command Structure:
## - `niffler` - Interactive mode
## - `niffler --prompt "text"` - Send single prompt
## - `niffler init [<path>]` - Initialize configuration
## - `niffler model list` - List available models

import std/[os, tables, logging]
import docopt

import core/config
import ui/cli

const VERSION* = staticExec("cd " & (currentSourcePath().parentDir().parentDir()) & " && nimble dump | grep '^version:' | cut -d'\"' -f2") 

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

let doc = """
Niffler - your friendly magical AI buddy

Usage:
  niffler [--model=<nickname>] [--prompt=<text>] [options]
  niffler init [<path>] [options]
  niffler model list [options]
  niffler --version
  niffler --help

Options:
  -h --help              Show this help message
  -v --version           Show version of Niffler
  -m --model <nickname>  Select model by nickname
  -p --prompt "<text>"   Perform single prompt and exit
  -t --tui               Use TUI widget-style interface
  -i --info              Show info level logging
  -d --debug             Show debug level logging
  --dump                 Show HTTP requests & responses

Commands:
  init                   Initialize configuration
  model list             List available models
"""

when isMainModule:
  # Parse command line arguments using docopt
  let args = docopt(doc, version = "Niffler " & VERSION)
  
  # Handle subcommands
  if args["init"]:
    let configPath = if args["<path>"] and args["<path>"].kind != vkNone: $args["<path>"] else: ""
    init(configPath)
    quit(0)
  elif args["model"]:
    if args["list"]:
      showModels()
      quit(0)
    else:
      echo "Unknown model subcommand. Use 'niffler model list'"
      quit(1)
  
  # Set logging level based on options
  var level = lvlNotice
  if args["--debug"]:
    level = lvlDebug
    debug "Debug logging enabled"
  elif args["--info"]:
    level = lvlInfo
    debug "Info logging enabled"
  setLogFilter(level)
  
  # Extract options
  let model = if args["--model"] and args["--model"].kind != vkNone: $args["--model"] else: ""
  let prompt = if args["--prompt"] and args["--prompt"].kind != vkNone: $args["--prompt"] else: ""
  let dump = args["--dump"]
  let tui = args["--tui"]

  if prompt.len == 0:
    # Start interactive UI if no prompt given
    startInteractiveUI(model, level, dump, tui)
  else:
    # Send single prompt
    sendSinglePrompt(prompt, model, level, dump)

