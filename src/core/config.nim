## Configuration Management Module
##
## This module handles configuration-related functionality for Niffler:
## - Loading TOML configuration files (main entry point)
## - Managing API keys securely with file permissions
## - Platform-appropriate config directory detection
## - Model configuration with OpenAI protocol parameters
## - Database configuration (SQLite/TiDB)
## - Theme configuration and built-in themes
##
## Configuration Structure:
## - Main config: ~/.niffler/config.toml (Unix) or %APPDATA%/niffler/config.toml (Windows)
## - API keys: ~/.niffler/keys (with restricted permissions)
## - Database: ~/.niffler/niffler.db (SQLite)
## - System prompts: ~/.niffler/NIFFLER.md

import std/[os, appdirs, tables, options, locks, strformat, strutils, sugar]
import ../types/[config, messages, nats_messages]
import config_toml
import agent_defaults

const KEY_FILE_NAME = "keys"
const CONFIG_FILE_NAME = "config.toml"
const SQLITE_FILE_NAME = "niffler.db"
const AGENTS_DIR_NAME = "agents"

proc getConfigDir*(): string =
  ## Get platform-appropriate config directory for niffler
  when defined(windows):
    # Windows: Use %APPDATA%\niffler
    joinPath(appdirs.getConfigDir().string, "niffler")
  else:
    # Unix: Use ~/.niffler (traditional dot-prefix)
    joinPath(appdirs.getHomeDir().string, ".niffler")

proc getDefaultConfigPath*(): string =
  ## Get default path for main configuration file
  joinPath(getConfigDir(), CONFIG_FILE_NAME)

proc getDefaultSqlitePath*(): string =
  ## Get default path for SQLite database file
  joinPath(getConfigDir(), SQLITE_FILE_NAME)

proc getDefaultKeyPath*(): string =
  ## Get default path for API key storage file
  joinPath(getConfigDir(), KEY_FILE_NAME)

proc getAgentsDir*(): string =
  ## DEPRECATED: Get path for default agents directory (~/.niffler/agents)
  joinPath(getConfigDir(), AGENTS_DIR_NAME)

# Global configuration manager instance
var globalConfigManager: ConfigManager

proc initializeConfigManager*() =
  ## Initialize global config manager
  withLock(globalConfigManager.lock):
    if globalConfigManager.config.config.isNone():
      globalConfigManager.config.config = some(getDefaultConfigPath())
  initLock(globalConfigManager.lock)

proc readConfig*(path: string): Config =
  ## Read and parse TOML configuration file from specified path
  let tomlConfig = loadTomlConfig(path)
  return tomlConfigToConfig(tomlConfig)

proc loadConfigFromPath*(path: string): Config =
  ## Load configuration from an arbitrary path (for project-level configs)
  ## This is an exported version of readConfig for external use
  return readConfig(path)

proc readKeys*(): KeyConfig =
  ## Read API keys from secure key file (creates empty table if file doesn't exist)
  let keyPath = getDefaultKeyPath()
  if not fileExists(keyPath):
    return initTable[string, string]()

  # Simple key=value line format for now (can be migrated to TOML later)
  result = initTable[string, string]()
  for line in lines(keyPath):
    let parts = line.split('=', maxsplit=1)
    if parts.len == 2:
      result[parts[0].strip()] = parts[1].strip()

proc writeKeys*(keys: KeyConfig) =
  ## Write API keys to secure key file with restrictive permissions
  let keyPath = getDefaultKeyPath()
  let dir = parentDir(keyPath)
  createDir(dir)

  # Simple key=value line format for now (can be migrated to TOML later)
  var content = ""
  for key, val in keys:
    content &= key & "=" & val & "\n"

  writeFile(keyPath, content)
  # Set restrictive permissions (owner read/write only)
  setFilePermissions(keyPath, {fpUserRead, fpUserWrite})

# Cost calculation helpers
proc calculateCosts*(cost: var CostTracking, usage: TokenUsage) =
  ## Calculate and populate cost totals based on token usage and per-token rates
  cost.usage = usage
  if cost.inputCostPerMToken.isSome():
    let costPerToken = cost.inputCostPerMToken.get() / 1_000_000.0
    cost.totalInputCost = float(usage.inputTokens) * costPerToken
  else:
    cost.totalInputCost = 0.0

  if cost.outputCostPerMToken.isSome():
    let costPerToken = cost.outputCostPerMToken.get() / 1_000_000.0
    cost.totalOutputCost = float(usage.outputTokens) * costPerToken
  else:
    cost.totalOutputCost = 0.0

  cost.totalCost = cost.totalInputCost + cost.totalOutputCost

# Configuration access functions
proc getGlobalConfigManager*(): var ConfigManager =
  ## Get global configuration manager instance
  result = globalConfigManager

proc getGlobalConfig*(): Config =
  ## Get current configuration from global manager
  withLock(globalConfigManager.lock):
    result = globalConfigManager.config

proc setGlobalConfig*(config: Config) =
  ## Set configuration in global manager
  withLock(globalConfigManager.lock):
    globalConfigManager.config = config

proc reloadConfig*(): bool =
  ## Reload configuration from file
  try:
    let newConfig = readConfig(getDefaultConfigPath())
    setGlobalConfig(newConfig)
    return true
  except:
    return false

proc getModels*(): seq[ModelConfig] =
  ## Get all configured models, filtering enabled ones and applying defaults
  let globalConfig = getGlobalConfig()
  result = @[]
  for model in globalConfig.models:
    if model.enabled:
      result.add(model)

proc getModel*(nickname: string): Option[ModelConfig] =
  ## Get model configuration by nickname
  let models = getModels()
  for model in models:
    if model.nickname == nickname:
      return some(model)
  return none(ModelConfig)

proc getDefaultModel*(): ModelConfig =
  ## Get default model (first enabled model)
  let models = getModels()
  if models.len > 0:
    return models[0]

  # Fallback to default configuration if no models configured
  let fallbackModel = ModelConfig(
    nickname: "default",
    baseUrl: "https://api.openai.com/v1",
    model: "gpt-4",
    context: 4096,
    enabled: true
  )
  fallbackModel

proc getDatabaseConfig*(): DatabaseConfig =
  ## Get database configuration with defaults
  let globalConfig = getGlobalConfig()
  if globalConfig.database.isSome():
    return globalConfig.database.get()

  # Default SQLite configuration
  return DatabaseConfig(
    `type`: dtSQLite,
    enabled: true,
    path: some(getDefaultSqlitePath()),
    host: none(string),
    port: none(int),
    database: none(string),
    username: none(string),
    password: none(string),
    walMode: true,
    busyTimeout: 5000,
    poolSize: 10
  )

proc getCurrentTheme*(): string =
  ## Get current theme name with default
  let globalConfig = getGlobalConfig()
  if globalConfig.currentTheme.isSome():
    return globalConfig.currentTheme.get()
  return "default"

proc getThemes*(): Table[string, ThemeConfig] =
  ## Get all configured themes with minimal defaults
  let globalConfig = getGlobalConfig()
  result = initTable[string, ThemeConfig]()

  # Add basic default theme
  result["default"] = ThemeConfig(
    name: "default",
    header1: ThemeStyleConfig(color: "cyan", style: "bright"),
    header2: ThemeStyleConfig(color: "blue", style: "bright"),
    header3: ThemeStyleConfig(color: "magenta", style: "bright"),
    bold: ThemeStyleConfig(color: "white", style: "bright"),
    italic: ThemeStyleConfig(color: "white", style: "italic"),
    code: ThemeStyleConfig(color: "yellow", style: ""),
    link: ThemeStyleConfig(color: "blue", style: "underline"),
    listBullet: ThemeStyleConfig(color: "green", style: "bright"),
    codeBlock: ThemeStyleConfig(color: "yellow", style: ""),
    normal: ThemeStyleConfig(color: "white", style: "")
  )

  if globalConfig.themes.isSome():
    for name, themeConfig in globalConfig.themes.get():
      result[name] = themeConfig

# Configuration validation
proc validateConfig*(config: Config): seq[string] =
  ## Validate configuration and return list of issues
  result = @[]

  # Check required fields
  if config.yourName.len == 0:
    result.add("yourName is required")

  # Check models
  var enabledModels: seq[ModelConfig] = @[]
  for model in config.models:
    if model.enabled:
      enabledModels.add(model)
  if enabledModels.len == 0:
    result.add("At least one enabled model is required")

  for i, model in enabledModels:
    if model.nickname.len == 0:
      result.add(fmt"Model {i+1}: nickname is required")
    if model.baseUrl.len == 0:
      result.add(fmt"Model {i+1}: baseUrl is required")
    if model.model.len == 0:
      result.add(fmt"Model {i+1}: model name is required")
    if model.context <= 0:
      result.add(fmt"Model {i+1}: context must be positive")

    # Validate model-specific settings
    if model.temperature.isSome() and (model.temperature.get() < 0.0 or model.temperature.get() > 2.0):
      result.add(fmt"Model {i+1}: temperature must be between 0.0 and 2.0")

    if model.topP.isSome() and (model.topP.get() < 0.0 or model.topP.get() > 1.0):
      result.add(fmt"Model {i+1}: topP must be between 0.0 and 1.0")

    if model.topK.isSome() and model.topK.get() < 0:
      result.add(fmt"Model {i+1}: topK must be non-negative")

    if model.maxTokens.isSome() and model.maxTokens.get() <= 0:
      result.add(fmt"Model {i+1}: maxTokens must be positive")

  # Check database configuration
  if config.database.isSome():
    let dbConfig = config.database.get()
    if dbConfig.`type` == dtSqlite:
      if not dbConfig.path.isSome():
        result.add("SQLite mode requires database path")
    elif dbConfig.`type` == dtTiDB:
      if not dbConfig.host.isSome():
        result.add("TiDB mode requires host")
      if not dbConfig.port.isSome():
        result.add("TiDB mode requires port")
      if not dbConfig.database.isSome():
        result.add("TiDB mode requires database name")

# Create default configuration file if it doesn't exist
proc createDefaultConfigFile*(): void =
  let configPath = getDefaultConfigPath()
  if not fileExists(configPath):
    echo fmt"Creating default configuration at {configPath}"
    echo "Please edit the file to add your models and preferences"

# Load configuration with fallback to defaults
proc loadConfig*(): Config =
  ## Load configuration from file, falling back to defaults
  try:
    let configPath = getDefaultConfigPath()
    if fileExists(configPath):
      return readConfig(configPath)
    else:
      createDefaultConfigFile()
      return Config(
        yourName: "User",
        models: @[],
        themes: some(initTable[string, ThemeConfig]()),
        currentTheme: some("default"),
        markdownEnabled: some(true)
      )
  except:
    echo "Warning: Failed to load configuration, using defaults"
    return Config(
      yourName: "User",
      models: @[],
      themes: some(initTable[string, ThemeConfig]()),
      currentTheme: some("default"),
      markdownEnabled: some(true)
    )

# Configuration utilities
# Note: TOML writing functionality would be implemented here as needed
# For now, users can manually edit TOML files