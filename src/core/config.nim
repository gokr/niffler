## Configuration Management Module
##
## This module handles all configuration-related functionality for Niffler:
## - Loading and saving JSON configuration files
## - Managing API keys securely with file permissions
## - Platform-appropriate config directory detection
## - Model configuration with OpenAI protocol parameters
## - Database configuration (SQLite/TiDB)
## - Theme configuration and built-in themes
## - Cost tracking and token usage calculation
##
## Configuration Structure:
## - Main config: ~/.niffler/config.json (Unix) or %APPDATA%/niffler/config.json (Windows)
## - API keys: ~/.niffler/keys (with restricted permissions)
## - Database: ~/.niffler/niffler.db (SQLite)
## - System prompts: ~/.niffler/NIFFLER.md

import std/[os, appdirs, json, tables, options, locks, strformat, strutils]
import ../types/[config, messages]

const KEY_FILE_NAME = "keys"
const CONFIG_FILE_NAME = "config.json"
const SQLITE_FILE_NAME = "niffler.db"

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

# Global config manager
var globalConfigManager: ConfigManager

proc initializeConfigManager() =
  globalConfigManager.configPath = getDefaultConfigPath()
  initLock(globalConfigManager.lock)

proc parseModelConfig(node: JsonNode): ModelConfig =
  ## Parse a model configuration from JSON node with OpenAI protocol parameters
  result.nickname = node["nickname"].getStr()
  result.baseUrl = node["baseUrl"].getStr()
  result.model = node["model"].getStr()
  result.context = node["context"].getInt()
  result.enabled = if node.hasKey("enabled"): node["enabled"].getBool() else: true
  
  if node.hasKey("type"):
    case node["type"].getStr():
    of "standard": result.`type` = some(mtStandard)
    of "openai-responses": result.`type` = some(mtOpenAIResponses)
    of "anthropic": result.`type` = some(mtAnthropic)
  
  if node.hasKey("apiEnvVar"):
    result.apiEnvVar = some(node["apiEnvVar"].getStr())
    
  if node.hasKey("apiKey"):
    result.apiKey = some(node["apiKey"].getStr())
    
  if node.hasKey("reasoning"):
    case node["reasoning"].getStr():
    of "low": result.reasoning = some(rlLow)
    of "medium": result.reasoning = some(rlMedium)
    of "high": result.reasoning = some(rlHigh)
    
  # OpenAI protocol parameters
  if node.hasKey("temperature"):
    result.temperature = some(node["temperature"].getFloat())
    
  if node.hasKey("topP"):
    result.topP = some(node["topP"].getFloat())
    
  if node.hasKey("topK"):
    result.topK = some(node["topK"].getInt())
    
  if node.hasKey("maxTokens"):
    result.maxTokens = some(node["maxTokens"].getInt())
    
  if node.hasKey("stop"):
    var stopSeq: seq[string] = @[]
    for stopItem in node["stop"]:
      stopSeq.add(stopItem.getStr())
    result.stop = some(stopSeq)
    
  if node.hasKey("presencePenalty"):
    result.presencePenalty = some(node["presencePenalty"].getFloat())
    
  if node.hasKey("frequencyPenalty"):
    result.frequencyPenalty = some(node["frequencyPenalty"].getFloat())
    
  if node.hasKey("logitBias"):
    var biasTable = initTable[int, float]()
    for key, val in node["logitBias"]:
      biasTable[parseInt(key)] = val.getFloat()
    result.logitBias = some(biasTable)
    
  if node.hasKey("seed"):
    result.seed = some(node["seed"].getInt())
    
  # Cost tracking parameters
  if node.hasKey("inputCostPerMToken"):
    result.inputCostPerMToken = some(node["inputCostPerMToken"].getFloat())
  elif node.hasKey("inputCostPerToken"):  # Backward compatibility
    result.inputCostPerMToken = some(node["inputCostPerToken"].getFloat() * 1_000_000.0)
    
  if node.hasKey("outputCostPerMToken"):
    result.outputCostPerMToken = some(node["outputCostPerMToken"].getFloat())
  elif node.hasKey("outputCostPerToken"):  # Backward compatibility
    result.outputCostPerMToken = some(node["outputCostPerToken"].getFloat() * 1_000_000.0)

proc parseSpecialModelConfig(node: JsonNode): SpecialModelConfig =
  result.baseUrl = node["baseUrl"].getStr()
  result.model = node["model"].getStr()
  result.enabled = if node.hasKey("enabled"): node["enabled"].getBool() else: true
  if node.hasKey("apiEnvVar"):
    result.apiEnvVar = some(node["apiEnvVar"].getStr())
  if node.hasKey("apiKey"):
    result.apiKey = some(node["apiKey"].getStr())

proc parseMcpServerConfig(node: JsonNode): McpServerConfig =
  result.command = node["command"].getStr()
  result.enabled = if node.hasKey("enabled"): node["enabled"].getBool() else: true
  result.name = if node.hasKey("name"): node["name"].getStr() else: ""

  if node.hasKey("args"):
    var args: seq[string] = @[]
    for arg in node["args"]:
      args.add(arg.getStr())
    result.args = some(args)

  if node.hasKey("env"):
    var envTable = initTable[string, string]()
    for key, val in node["env"]:
      envTable[key] = val.getStr()
    result.env = some(envTable)

  if node.hasKey("workingDir"):
    result.workingDir = some(node["workingDir"].getStr())

  if node.hasKey("timeout"):
    result.timeout = some(node["timeout"].getInt())

proc parseExternalRenderingConfig(node: JsonNode): ExternalRenderingConfig =
  result.enabled = node.getOrDefault("enabled").getBool(true)
  result.contentRenderer = node.getOrDefault("contentRenderer").getStr("batcat --color=always --style=numbers --theme=auto {file}")
  result.diffRenderer = node.getOrDefault("diffRenderer").getStr("delta --line-numbers --syntax-theme=auto")
  result.fallbackToBuiltin = node.getOrDefault("fallbackToBuiltin").getBool(true)

proc parseDatabaseConfig(node: JsonNode): DatabaseConfig =
  result.enabled = node.getOrDefault("enabled").getBool(true)
  
  # Parse database type
  if node.hasKey("type"):
    case node["type"].getStr():
    of "sqlite": result.`type` = dtSQLite
    of "tidb": result.`type` = dtTiDB
    else: result.`type` = dtSQLite  # Default to SQLite
  
  # SQLite specific settings
  if node.hasKey("path"):
    result.path = some(node["path"].getStr())
  else:
    result.path = some(getDefaultSqlitePath())

  # TiDB specific settings
  if node.hasKey("host"):
    result.host = some(node["host"].getStr())
  if node.hasKey("port"):
    result.port = some(node["port"].getInt())
  if node.hasKey("database"):
    result.database = some(node["database"].getStr())
  if node.hasKey("username"):
    result.username = some(node["username"].getStr())
  if node.hasKey("password"):
    result.password = some(node["password"].getStr())
  
  # Common settings
  result.walMode = node.getOrDefault("walMode").getBool(true)
  result.busyTimeout = node.getOrDefault("busyTimeout").getInt(5000)
  result.poolSize = node.getOrDefault("poolSize").getInt(10)

proc parseThemeStyleConfig(node: JsonNode): ThemeStyleConfig =
  result.color = node.getOrDefault("color").getStr("white")
  result.style = node.getOrDefault("style").getStr("bright")

proc parseThemeConfig(node: JsonNode): ThemeConfig =
  result.name = node.getOrDefault("name").getStr()
  result.header1 = parseThemeStyleConfig(node.getOrDefault("header1"))
  result.header2 = parseThemeStyleConfig(node.getOrDefault("header2"))
  result.header3 = parseThemeStyleConfig(node.getOrDefault("header3"))
  result.bold = parseThemeStyleConfig(node.getOrDefault("bold"))
  result.italic = parseThemeStyleConfig(node.getOrDefault("italic"))
  result.code = parseThemeStyleConfig(node.getOrDefault("code"))
  result.link = parseThemeStyleConfig(node.getOrDefault("link"))
  result.listBullet = parseThemeStyleConfig(node.getOrDefault("listBullet"))
  result.codeBlock = parseThemeStyleConfig(node.getOrDefault("codeBlock"))
  result.normal = parseThemeStyleConfig(node.getOrDefault("normal"))

proc parseConfig(configJson: JsonNode): Config =
  ## Parse complete configuration from JSON with all sections
  result.yourName = configJson["yourName"].getStr()
  
  for modelNode in configJson["models"]:
    let model = parseModelConfig(modelNode)
    if model.enabled:
      result.models.add(model)
  
  if configJson.hasKey("diffApply"):
    result.diffApply = some(parseSpecialModelConfig(configJson["diffApply"]))
    
  if configJson.hasKey("fixJson"):
    result.fixJson = some(parseSpecialModelConfig(configJson["fixJson"]))
    
  if configJson.hasKey("defaultApiKeyOverrides"):
    result.defaultApiKeyOverrides = some(initTable[string, string]())
    for key, val in configJson["defaultApiKeyOverrides"]:
      result.defaultApiKeyOverrides.get()[key] = val.getStr()
      
  if configJson.hasKey("mcpServers"):
    result.mcpServers = some(initTable[string, McpServerConfig]())
    for key, val in configJson["mcpServers"]:
      result.mcpServers.get()[key] = parseMcpServerConfig(val)
      
  if configJson.hasKey("database"):
    result.database = some(parseDatabaseConfig(configJson["database"]))
    
  if configJson.hasKey("themes"):
    result.themes = some(initTable[string, ThemeConfig]())
    for key, val in configJson["themes"]:
      result.themes.get()[key] = parseThemeConfig(val)
      
  if configJson.hasKey("currentTheme"):
    result.currentTheme = some(configJson["currentTheme"].getStr())
    
  if configJson.hasKey("markdownEnabled"):
    result.markdownEnabled = some(configJson["markdownEnabled"].getBool())
    
  if configJson.hasKey("instructionFiles"):
    var instructionFiles: seq[string] = @[]
    for fileNode in configJson["instructionFiles"]:
      instructionFiles.add(fileNode.getStr())
    result.instructionFiles = some(instructionFiles)
    
  if configJson.hasKey("externalRendering"):
    result.externalRendering = some(parseExternalRenderingConfig(configJson["externalRendering"]))

proc readConfig*(path: string): Config =
  ## Read and parse configuration file from specified path
  let content = readFile(path)
  let configJson = parseJson(content)
  return parseConfig(configJson)

proc writeConfig*(config: Config, path: string) =
  ## Write configuration to JSON file with proper formatting
  let dir = parentDir(path)
  createDir(dir)
  
  var configJson = newJObject()
  configJson["yourName"] = newJString(config.yourName)
  
  var modelsArray = newJArray()
  for model in config.models:
    var modelObj = newJObject()
    modelObj["nickname"] = newJString(model.nickname)
    modelObj["baseUrl"] = newJString(model.baseUrl)
    modelObj["model"] = newJString(model.model)
    modelObj["context"] = newJInt(model.context)
    modelObj["enabled"] = newJBool(model.enabled)
    
    if model.`type`.isSome():
      modelObj["type"] = newJString($model.`type`.get())
    if model.apiEnvVar.isSome():
      modelObj["apiEnvVar"] = newJString(model.apiEnvVar.get())
    if model.apiKey.isSome():
      modelObj["apiKey"] = newJString(model.apiKey.get())
    if model.reasoning.isSome():
      modelObj["reasoning"] = newJString($model.reasoning.get())
      
    # OpenAI protocol parameters
    if model.temperature.isSome():
      modelObj["temperature"] = newJFloat(model.temperature.get())
    if model.topP.isSome():
      modelObj["topP"] = newJFloat(model.topP.get())
    if model.topK.isSome():
      modelObj["topK"] = newJInt(model.topK.get())
    if model.maxTokens.isSome():
      modelObj["maxTokens"] = newJInt(model.maxTokens.get())
    if model.stop.isSome():
      var stopArray = newJArray()
      for stopItem in model.stop.get():
        stopArray.add(newJString(stopItem))
      modelObj["stop"] = stopArray
    if model.presencePenalty.isSome():
      modelObj["presencePenalty"] = newJFloat(model.presencePenalty.get())
    if model.frequencyPenalty.isSome():
      modelObj["frequencyPenalty"] = newJFloat(model.frequencyPenalty.get())
    if model.logitBias.isSome():
      var biasObj = newJObject()
      for key, val in model.logitBias.get():
        biasObj[$key] = newJFloat(val)
      modelObj["logitBias"] = biasObj
    if model.seed.isSome():
      modelObj["seed"] = newJInt(model.seed.get())
      
    # Cost tracking parameters
    if model.inputCostPerMToken.isSome():
      modelObj["inputCostPerMToken"] = newJFloat(model.inputCostPerMToken.get())
    if model.outputCostPerMToken.isSome():
      modelObj["outputCostPerMToken"] = newJFloat(model.outputCostPerMToken.get())
      
    modelsArray.add(modelObj)
  configJson["models"] = modelsArray
  
  # Add database configuration if present
  if config.database.isSome():
    var dbObj = newJObject()
    let dbConfig = config.database.get()
    dbObj["type"] = newJString($dbConfig.`type`)
    dbObj["enabled"] = newJBool(dbConfig.enabled)
    dbObj["walMode"] = newJBool(dbConfig.walMode)
    dbObj["busyTimeout"] = newJInt(dbConfig.busyTimeout)
    dbObj["poolSize"] = newJInt(dbConfig.poolSize)
    
    if dbConfig.path.isSome():
      dbObj["path"] = newJString(dbConfig.path.get())
    if dbConfig.host.isSome():
      dbObj["host"] = newJString(dbConfig.host.get())
    if dbConfig.port.isSome():
      dbObj["port"] = newJInt(dbConfig.port.get())
    if dbConfig.database.isSome():
      dbObj["database"] = newJString(dbConfig.database.get())
    if dbConfig.username.isSome():
      dbObj["username"] = newJString(dbConfig.username.get())
    if dbConfig.password.isSome():
      dbObj["password"] = newJString(dbConfig.password.get())
    
    configJson["database"] = dbObj
  
  # Add theme configurations if present
  if config.themes.isSome():
    var themesObj = newJObject()
    for themeName, themeConfig in config.themes.get():
      var themeObj = newJObject()
      themeObj["name"] = newJString(themeConfig.name)
      
      # Helper proc to create theme style JSON
      proc createThemeStyleJson(style: ThemeStyleConfig): JsonNode =
        var styleObj = newJObject()
        styleObj["color"] = newJString(style.color)
        styleObj["style"] = newJString(style.style)
        return styleObj
      
      themeObj["header1"] = createThemeStyleJson(themeConfig.header1)
      themeObj["header2"] = createThemeStyleJson(themeConfig.header2)
      themeObj["header3"] = createThemeStyleJson(themeConfig.header3)
      themeObj["bold"] = createThemeStyleJson(themeConfig.bold)
      themeObj["italic"] = createThemeStyleJson(themeConfig.italic)
      themeObj["code"] = createThemeStyleJson(themeConfig.code)
      themeObj["link"] = createThemeStyleJson(themeConfig.link)
      themeObj["listBullet"] = createThemeStyleJson(themeConfig.listBullet)
      themeObj["codeBlock"] = createThemeStyleJson(themeConfig.codeBlock)
      themeObj["normal"] = createThemeStyleJson(themeConfig.normal)
      
      themesObj[themeName] = themeObj
    configJson["themes"] = themesObj
  
  if config.currentTheme.isSome():
    configJson["currentTheme"] = newJString(config.currentTheme.get())
    
  if config.markdownEnabled.isSome():
    configJson["markdownEnabled"] = newJBool(config.markdownEnabled.get())
    
  if config.instructionFiles.isSome():
    var instructionFilesArray = newJArray()
    for filename in config.instructionFiles.get():
      instructionFilesArray.add(newJString(filename))
    configJson["instructionFiles"] = instructionFilesArray
  
  if config.externalRendering.isSome():
    var renderingObj = newJObject()
    let renderingConfig = config.externalRendering.get()
    renderingObj["enabled"] = newJBool(renderingConfig.enabled)
    renderingObj["contentRenderer"] = newJString(renderingConfig.contentRenderer)
    renderingObj["diffRenderer"] = newJString(renderingConfig.diffRenderer)
    renderingObj["fallbackToBuiltin"] = newJBool(renderingConfig.fallbackToBuiltin)
    configJson["externalRendering"] = renderingObj
  
  writeFile(path, pretty(configJson, 2))

proc readKeys*(): KeyConfig =
  ## Read API keys from secure key file (creates empty table if file doesn't exist)
  let keyPath = getDefaultKeyPath()
  if not fileExists(keyPath):
    return initTable[string, string]()
    
  let content = readFile(keyPath)
  let keysJson = parseJson(content)
  
  for key, val in keysJson:
    result[key] = val.getStr()

proc writeKeys*(keys: KeyConfig) =
  ## Write API keys to secure key file with restrictive permissions
  let keyPath = getDefaultKeyPath()
  let dir = parentDir(keyPath)
  createDir(dir)
  
  var keysJson = newJObject()
  for key, val in keys:
    keysJson[key] = newJString(val)
    
  writeFile(keyPath, $keysJson)
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

proc addUsage*(cost: var CostTracking, inputTokens: int, outputTokens: int) =
  ## Add token usage and update running totals and costs
  cost.usage.inputTokens = cost.usage.inputTokens + inputTokens
  cost.usage.outputTokens = cost.usage.outputTokens + outputTokens
  cost.usage.totalTokens = cost.usage.inputTokens + cost.usage.outputTokens
  calculateCosts(cost, cost.usage)

proc createDefaultThemes(): Table[string, ThemeConfig] =
  ## Create built-in themes (default, dark, light, minimal)
  result = initTable[string, ThemeConfig]()
  
  # Default theme with standard terminal colors
  result["default"] = ThemeConfig(
    name: "default",
    header1: ThemeStyleConfig(color: "yellow", style: "bright"),
    header2: ThemeStyleConfig(color: "yellow", style: "bright"),
    header3: ThemeStyleConfig(color: "yellow", style: "dim"),
    bold: ThemeStyleConfig(color: "white", style: "bright"),
    italic: ThemeStyleConfig(color: "cyan", style: "bright"),
    code: ThemeStyleConfig(color: "green", style: "dim"),
    link: ThemeStyleConfig(color: "blue", style: "bright"),
    listBullet: ThemeStyleConfig(color: "white", style: "bright"),
    codeBlock: ThemeStyleConfig(color: "cyan", style: "bright"),
    normal: ThemeStyleConfig(color: "white", style: "bright")
  )
  
  # Dark theme
  result["dark"] = ThemeConfig(
    name: "dark",
    header1: ThemeStyleConfig(color: "blue", style: "bright"),
    header2: ThemeStyleConfig(color: "cyan", style: "bright"),
    header3: ThemeStyleConfig(color: "cyan", style: "dim"),
    bold: ThemeStyleConfig(color: "white", style: "bright"),
    italic: ThemeStyleConfig(color: "yellow", style: "bright"),
    code: ThemeStyleConfig(color: "green", style: "bright"),
    link: ThemeStyleConfig(color: "magenta", style: "bright"),
    listBullet: ThemeStyleConfig(color: "cyan", style: "bright"),
    codeBlock: ThemeStyleConfig(color: "blue", style: "dim"),
    normal: ThemeStyleConfig(color: "white", style: "bright")
  )
  
  # Light theme
  result["light"] = ThemeConfig(
    name: "light",
    header1: ThemeStyleConfig(color: "blue", style: "bright"),
    header2: ThemeStyleConfig(color: "magenta", style: "bright"),
    header3: ThemeStyleConfig(color: "magenta", style: "dim"),
    bold: ThemeStyleConfig(color: "black", style: "bright"),
    italic: ThemeStyleConfig(color: "blue", style: "dim"),
    code: ThemeStyleConfig(color: "green", style: "dim"),
    link: ThemeStyleConfig(color: "blue", style: "bright"),
    listBullet: ThemeStyleConfig(color: "black", style: "bright"),
    codeBlock: ThemeStyleConfig(color: "magenta", style: "dim"),
    normal: ThemeStyleConfig(color: "black", style: "bright")
  )
  
  # Minimal theme
  result["minimal"] = ThemeConfig(
    name: "minimal",
    header1: ThemeStyleConfig(color: "white", style: "bright"),
    header2: ThemeStyleConfig(color: "white", style: "bright"),
    header3: ThemeStyleConfig(color: "white", style: "dim"),
    bold: ThemeStyleConfig(color: "white", style: "bright"),
    italic: ThemeStyleConfig(color: "white", style: "dim"),
    code: ThemeStyleConfig(color: "white", style: "dim"),
    link: ThemeStyleConfig(color: "white", style: "underscore"),
    listBullet: ThemeStyleConfig(color: "white", style: "bright"),
    codeBlock: ThemeStyleConfig(color: "white", style: "dim"),
    normal: ThemeStyleConfig(color: "white", style: "bright")
  )

proc createDefaultNifflerMd*(configDir: string) =
  ## Create default NIFFLER.md system prompt file if it doesn't exist
  let nifflerPath = configDir / "NIFFLER.md"
  
  if fileExists(nifflerPath):
    return
    
  let defaultNifflerContent = """# Common System Prompt

You are Niffler, an AI-powered terminal assistant built in Nim. You provide conversational assistance with software development tasks while supporting tool calling for file operations, command execution, and web fetching.

Available tools: {availableTools}

Current environment:
- Working directory: {currentDir}
- Current time: {currentTime}
- OS: {osInfo}
{gitInfo}
{projectInfo}

General guidelines:
- Be concise and direct in responses
- Use tools when needed to gather information or make changes
- Follow project conventions and coding standards
- Always validate information before making changes

# Plan Mode Prompt

**PLAN MODE ACTIVE**

You are in Plan mode - focus on analysis, research, and breaking down tasks into actionable steps.

Plan mode priorities:
1. **Research thoroughly** before suggesting implementation
2. **Break down complex tasks** into smaller, manageable steps
3. **Identify dependencies** and potential challenges
4. **Suggest approaches** and gather requirements
5. **Use read/list tools extensively** to understand the codebase
6. **Create detailed plans** before moving to implementation

In Plan mode:
- Read files to understand current implementation
- List directories to explore project structure
- Research existing patterns and conventions
- Ask clarifying questions when requirements are unclear
- Propose step-by-step implementation plans
- Avoid making changes until the plan is clear

# Code Mode Prompt

**CODE MODE ACTIVE**

You are in Code mode - focus on implementation and execution of planned tasks.

Code mode priorities:
1. **Execute plans efficiently** and make concrete changes
2. **Implement solutions** using edit/create/bash tools
3. **Test implementations** and verify functionality
4. **Fix issues** as they arise during implementation
5. **Complete tasks systematically** following established plans
6. **Document changes** when significant

In Code mode:
- Make file edits and create new files as needed
- Execute commands to test and verify changes
- Implement features following the established plan
- Address errors and edge cases proactively
- Focus on working, tested solutions
- Be decisive in implementation choices

# System-Wide Configuration

This NIFFLER.md file provides system-wide defaults for all projects, see the NIFFLER-FEATURES.md documentation.
"""
  
  try:
    writeFile(nifflerPath, defaultNifflerContent)
    echo "Default NIFFLER.md created at: ", nifflerPath
  except:
    echo "Warning: Could not create NIFFLER.md at: ", nifflerPath

proc initializeConfig*(path: string) =
  ## Initialize configuration with sensible defaults and create directory structure
  if fileExists(path):
    echo "Configuration file already exists: ", path
    # Even if config exists, create NIFFLER.md if it doesn't
    let configDir = path.parentDir()
    createDefaultNifflerMd(configDir)
    return
    
  let defaultConfig = Config(
    yourName: "User",
    models: @[
      ModelConfig(
        nickname: "qwen3coder",
        baseUrl: "https://router.requesty.ai/v1",
        model: "deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct",
        context: 262144,
        `type`: some(mtStandard),
        enabled: true,
        # OpenAI protocol parameters
        temperature: some(0.7),
        topP: some(0.8),
        topK: some(20),
        maxTokens: some(65536),
        presencePenalty: some(0.0),
        frequencyPenalty: some(1.05),
        # Cost tracking parameters (example rates for GPT-4o)
        inputCostPerMToken: some(0.4),  # $2.50 per million tokens
        outputCostPerMToken: some(1.6),   # $10.00 per million tokens
        apiEnvVar: some("REQUESTY_API_KEY")
      ),
      ModelConfig(
        nickname: "kimi",
        baseUrl: "https://openrouter.ai/api/v1",
        model: "moonshotai/kimi-k2:free",
        context: 128000,
        `type`: some(mtAnthropic),
        apiEnvVar: some("OPENROUTER_API_KEY"),
        enabled: true
      ),
      ModelConfig(
        nickname: "qwen3",
        baseUrl: "http://localhost:1234/v1",
        model: "qwen3:1.7b",
        context: 8192,
        `type`: some(mtStandard),
        enabled: true
      )
    ],
    database: some(DatabaseConfig(
      `type`: dtSQLite,
      enabled: true,
      path: some(getDefaultSqlitePath()),
      walMode: true,
      busyTimeout: 5000,
      poolSize: 10
    )),
    themes: some(createDefaultThemes()),
    currentTheme: some("default"),
    markdownEnabled: some(true),
    instructionFiles: some(@["NIFFLER.md", "CLAUDE.md", "OCTO.md", "AGENT.md"]),
    externalRendering: some(ExternalRenderingConfig(
      enabled: true,
      contentRenderer: "batcat --color=always --style=numbers --theme=auto {file}",
      diffRenderer: "delta --line-numbers --syntax-theme=auto",
      fallbackToBuiltin: true
    ))
  )
  
  writeConfig(defaultConfig, path)
  echo "Configuration initialized at: ", path
  
  # Also create default NIFFLER.md
  let configDir = path.parentDir()
  createDefaultNifflerMd(configDir)

proc loadConfig*(): Config =
  ## Load configuration from default path (thread-safe, creates if missing)
  if globalConfigManager.configPath.len == 0:
    initializeConfigManager()
    
  acquire(globalConfigManager.lock)
  try:
    if not fileExists(globalConfigManager.configPath):
      initializeConfig(globalConfigManager.configPath)
    globalConfigManager.config = readConfig(globalConfigManager.configPath)
    result = globalConfigManager.config
  finally:
    release(globalConfigManager.lock)

proc getModelFromConfig*(config: Config, modelOverride: string): ModelConfig =
  ## Select model from config by nickname or return first model as default
  if modelOverride.len == 0:
    return config.models[0]
    
  for model in config.models:
    if model.nickname == modelOverride:
      return model
      
  return config.models[0]

proc readKeyForModel*(model: ModelConfig): string =
  ## Get API key for model (checks env vars, model config, then key file)
  if model.apiEnvVar.isSome():
    let envKey = getEnv(model.apiEnvVar.get())
    if envKey.len > 0:
      return envKey
      
  if model.apiKey.isSome():
    return model.apiKey.get()
      
  let keys = readKeys()
  return keys.getOrDefault(model.baseUrl, "")

proc assertKeyForModel*(model: ModelConfig): string =
  ## Get API key for model or raise exception if not found
  let key = readKeyForModel(model)
  if key.len == 0:
    raise newException(ValueError, fmt"No API key defined for {model.baseUrl}")
  return key

proc writeKeyForModel*(model: ModelConfig, apiKey: string) =
  ## Store API key for a specific model's base URL
  var keys = readKeys()
  keys[model.baseUrl] = apiKey
  writeKeys(keys)
