## Session State Management
##
## This module manages runtime session state including the active configuration
## selection. The session holds transient state that changes during execution
## but is not persisted to disk.
##
## Key Features:
## - Tracks current active config (default, cc, custom)
## - Initialized from config.json files (project or user level)
## - Can be switched dynamically via /config command (in-memory only)
## - Provides config directory resolution for prompts and agents

import std/[options, os, strformat, json, appdirs]

type
  Session* = object
    currentConfig*: string  ## Currently active config name (e.g., "default", "cc")

  ConfigDiagnostics* = object
    configExists*: bool
    configSource*: string  # "global" or "project"
    nifflerMdExists*: bool
    nifflerMdPath*: string
    agentCount*: int
    agentsDir*: string
    warnings*: seq[string]
    errors*: seq[string]

proc getConfigDir(): string =
  ## Get platform-appropriate config directory for niffler (duplicated to avoid circular import)
  when defined(windows):
    joinPath(appdirs.getConfigDir().string, "niffler")
  else:
    joinPath(appdirs.getHomeDir().string, ".niffler")

proc getDefaultConfigPath(): string =
  ## Get default path for main configuration file (duplicated to avoid circular import)
  joinPath(getConfigDir(), "config.json")

proc readConfigField(path: string): Option[string] =
  ## Read just the "config" field from a config.json file
  ## Returns None if file doesn't exist or doesn't have the field
  if not fileExists(path):
    return none(string)

  try:
    let content = readFile(path)
    let configJson = parseJson(content)
    if configJson.hasKey("config"):
      return some(configJson["config"].getStr())
  except:
    discard

  return none(string)

proc loadActiveConfig*(): string =
  ## Determine which config to use at startup with layered resolution
  ## Priority: .niffler/config.json (project) > ~/.niffler/config.json (user)

  # Check for project-level config override
  let projectConfigField = readConfigField(".niffler/config.json")
  if projectConfigField.isSome():
    return projectConfigField.get()

  # Fallback to user-level config
  let userConfigField = readConfigField(getDefaultConfigPath())
  if userConfigField.isSome():
    return userConfigField.get()

  # Default fallback
  return "default"

proc initSession*(): Session =
  ## Initialize a new session with config loaded from config.json files
  result.currentConfig = loadActiveConfig()

proc getActiveConfigDir*(session: Session): string =
  ## Get the directory path for the currently active config
  ## Priority: .niffler/{name}/ before ~/.niffler/{name}/
  let configName = session.currentConfig

  # Check project-local config first
  if dirExists(".niffler"):
    let localConfigDir = ".niffler" / configName
    if dirExists(localConfigDir):
      return localConfigDir

  # Fall back to global config (use local getDefaultConfigPath to avoid circular import)
  let nifflerHome = getDefaultConfigPath().parentDir()
  return nifflerHome / configName

proc getAgentsDir*(session: Session): string =
  ## Get the agents directory for the currently active config
  return getActiveConfigDir(session) / "agents"

proc getAgentsDir*(): string =
  ## Get the agents directory using current active config (convenience wrapper)
  ## Creates a temporary session to determine the active config
  let sess = initSession()
  return getAgentsDir(sess)

proc switchConfig*(session: var Session, configName: string): tuple[success: bool, reloaded: bool] =
  ## Switch to a different config or reload current (in-memory only, does not persist)
  ## Returns (success: bool, reloaded: bool)
  let isReload = (configName == session.currentConfig)
  let nifflerHome = getDefaultConfigPath().parentDir()

  # Check if config exists in either location
  let projectLocal = dirExists(".niffler" / configName)
  let globalExists = dirExists(nifflerHome / configName)

  if not (projectLocal or globalExists):
    return (false, false)

  session.currentConfig = configName
  return (true, isReload)

proc listAvailableConfigs*(session: Session): tuple[global: seq[string], project: seq[string]] =
  ## List all available config directories in both global and project locations
  result.global = @[]
  result.project = @[]

  # Scan global configs
  let nifflerHome = getDefaultConfigPath().parentDir()
  if dirExists(nifflerHome):
    for kind, path in walkDir(nifflerHome):
      if kind == pcDir:
        let name = path.lastPathPart()
        # Skip special directories
        if name notin ["agents", "config"]:
          result.global.add(name)

  # Scan project-local configs
  if dirExists(".niffler"):
    for kind, path in walkDir(".niffler"):
      if kind == pcDir:
        let name = path.lastPathPart()
        # Skip special directories
        if name notin ["agents", "config"]:
          result.project.add(name)

proc getConfigSource*(): string =
  ## Determine where the current config selection comes from
  ## Returns "project" if .niffler/config.json exists, otherwise "user"
  if fileExists(".niffler/config.json"):
    return "project"
  else:
    return "user"

proc diagnoseConfig*(session: Session): ConfigDiagnostics =
  ## Diagnose the current config and return detailed status
  result.warnings = @[]
  result.errors = @[]

  let configName = session.currentConfig
  let nifflerHome = getDefaultConfigPath().parentDir()

  # Determine config source and existence
  let projectConfigDir = ".niffler" / configName
  let globalConfigDir = nifflerHome / configName

  if dirExists(projectConfigDir):
    result.configExists = true
    result.configSource = "project"
    let configDir = projectConfigDir

    # Check NIFFLER.md
    let nifflerMdPath = configDir / "NIFFLER.md"
    result.nifflerMdPath = nifflerMdPath
    result.nifflerMdExists = fileExists(nifflerMdPath)

    # Check agents directory
    let agentsDir = configDir / "agents"
    result.agentsDir = agentsDir
    if dirExists(agentsDir):
      result.agentCount = 0
      for kind, _ in walkDir(agentsDir):
        if kind == pcFile:
          inc result.agentCount
    else:
      result.warnings.add(fmt"Agents directory not found: {agentsDir}")

  elif dirExists(globalConfigDir):
    result.configExists = true
    result.configSource = "global"
    let configDir = globalConfigDir

    # Check NIFFLER.md
    let nifflerMdPath = configDir / "NIFFLER.md"
    result.nifflerMdPath = nifflerMdPath
    result.nifflerMdExists = fileExists(nifflerMdPath)

    # Check agents directory
    let agentsDir = configDir / "agents"
    result.agentsDir = agentsDir
    if dirExists(agentsDir):
      result.agentCount = 0
      for kind, _ in walkDir(agentsDir):
        if kind == pcFile:
          inc result.agentCount
    else:
      result.warnings.add(fmt"Agents directory not found: {agentsDir}")

  else:
    result.configExists = false
    result.configSource = "none"
    result.errors.add(fmt"Config '{configName}' not found in project or global directories")

  # Check for NIFFLER.md warnings
  if not result.nifflerMdExists and result.configExists:
    result.warnings.add(fmt"NIFFLER.md not found: {result.nifflerMdPath}")

  # Check for conflicting project NIFFLER.md that might shadow config
  if result.configSource == "global" and fileExists("./NIFFLER.md"):
    result.warnings.add("Project ./NIFFLER.md found (may shadow global config prompts)")

  return result

proc displayConfigInfo*(session: Session) =
  ## Display current config status with diagnostics
  let diag = diagnoseConfig(session)
  let source = getConfigSource()

  echo fmt"Loaded config: {session.currentConfig} (from {source} config.json)"

  if not diag.configExists:
    for err in diag.errors:
      echo fmt"  ✗ {err}"
    return

  # Show config source
  echo fmt"  Source: {diag.configSource}"

  # Show NIFFLER.md status
  if diag.nifflerMdExists:
    echo fmt"  ✓ System prompts: {diag.nifflerMdPath}"
  else:
    echo fmt"  ✗ System prompts: {diag.nifflerMdPath} (not found)"

  # Show agents status
  if diag.agentCount > 0:
    echo fmt"  ✓ Agents: {diag.agentCount} found in {diag.agentsDir}"
  else:
    echo fmt"  ⚠ Agents: 0 found in {diag.agentsDir}"

  # Show warnings
  for warning in diag.warnings:
    echo fmt"  ⚠ {warning}"
