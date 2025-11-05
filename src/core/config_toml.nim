## TOML Configuration Management Module
##
## Handles TOML configuration parsing for Niffler multi-agent architecture.
## Parses:
## - Model configurations
## - Agent definitions (new for multi-agent support)
## - NATS messaging configuration (new)
## - Database, theme, and UI settings

import std/[os, tables, options, strformat, strutils]
import parsetoml
import ../types/[config, messages]

type
  NatsConfig* = object
    server*: string
    timeoutMs*: int
    reconnectAttempts*: int
    reconnectDelayMs*: int

  MasterConfig* = object
    enabled*: bool
    defaultAgent*: string
    autoStartAgents*: bool
    heartbeatCheckInterval*: int

  AgentConfig* = object
    id*: string
    name*: string
    description*: string
    model*: string
    capabilities*: seq[string]
    toolPermissions*: seq[string]
    autoStart*: bool
    persistent*: bool
    maxIdleSeconds*: Option[int]

  TomlConfig* = object
    yourName*: string
    models*: seq[ModelConfig]
    nats*: Option[NatsConfig]
    master*: Option[MasterConfig]
    agents*: seq[AgentConfig]
    database*: Option[DatabaseConfig]
    themes*: Option[Table[string, ThemeConfig]]
    currentTheme*: Option[string]
    markdownEnabled*: Option[bool]
    instructionFiles*: Option[seq[string]]
    externalRendering*: Option[ExternalRenderingConfig]
    textExtraction*: Option[TextExtractionConfig]
    config*: Option[string]
    mcpServers*: Option[Table[string, McpServerConfig]]

proc parseModelType(value: string): Option[ModelType] =
  case value
  of "standard": some(mtStandard)
  of "openai-responses": some(mtOpenAIResponses)
  of "anthropic": some(mtAnthropic)
  else: none(ModelType)

proc parseReasoningLevel(value: string): Option[ReasoningLevel] =
  case value
  of "low": some(rlLow)
  of "medium": some(rlMedium)
  of "high": some(rlHigh)
  of "none": some(rlNone)
  else: none(ReasoningLevel)

proc parseModelConfig(node: TomlValueRef): ModelConfig =
  result.nickname = node["nickname"].getStr()
  result.baseUrl = node["base_url"].getStr()
  result.model = node["model"].getStr()
  result.context = node["context"].getInt()
  result.enabled = node.getOrDefault("enabled").getBool(true)

  if node.hasKey("type"):
    result.`type` = parseModelType(node["type"].getStr())

  if node.hasKey("api_env_var"):
    result.apiEnvVar = some(node["api_env_var"].getStr())

  if node.hasKey("api_key"):
    result.apiKey = some(node["api_key"].getStr())

  if node.hasKey("reasoning"):
    result.reasoning = parseReasoningLevel(node["reasoning"].getStr())

  if node.hasKey("temperature"):
    result.temperature = some(node["temperature"].getFloat())

  if node.hasKey("top_p"):
    result.topP = some(node["top_p"].getFloat())

  if node.hasKey("top_k"):
    result.topK = some(node["top_k"].getInt())

  if node.hasKey("max_tokens"):
    result.maxTokens = some(node["max_tokens"].getInt())

  if node.hasKey("stop"):
    var stopSeq: seq[string] = @[]
    for item in node["stop"].getElems():
      stopSeq.add(item.getStr())
    result.stop = some(stopSeq)

  if node.hasKey("presence_penalty"):
    result.presencePenalty = some(node["presence_penalty"].getFloat())

  if node.hasKey("frequency_penalty"):
    result.frequencyPenalty = some(node["frequency_penalty"].getFloat())

  if node.hasKey("seed"):
    result.seed = some(node["seed"].getInt())

  if node.hasKey("input_cost_per_mtoken"):
    result.inputCostPerMToken = some(node["input_cost_per_mtoken"].getFloat())

  if node.hasKey("output_cost_per_mtoken"):
    result.outputCostPerMToken = some(node["output_cost_per_mtoken"].getFloat())

  if node.hasKey("reasoning_cost_per_mtoken"):
    result.reasoningCostPerMToken = some(node["reasoning_cost_per_mtoken"].getFloat())

proc parseNatsConfig(node: TomlValueRef): NatsConfig =
  result.server = node["server"].getStr()
  result.timeoutMs = node.getOrDefault("timeout_ms").getInt(30000)
  result.reconnectAttempts = node.getOrDefault("reconnect_attempts").getInt(5)
  result.reconnectDelayMs = node.getOrDefault("reconnect_delay_ms").getInt(1000)

proc parseMasterConfig(node: TomlValueRef): MasterConfig =
  result.enabled = node.getOrDefault("enabled").getBool(false)
  result.defaultAgent = node.getOrDefault("default_agent").getStr("general")
  result.autoStartAgents = node.getOrDefault("auto_start_agents").getBool(true)
  result.heartbeatCheckInterval = node.getOrDefault("heartbeat_check_interval").getInt(30)

proc parseAgentConfig(node: TomlValueRef): AgentConfig =
  result.id = node["id"].getStr()
  result.name = node.getOrDefault("name").getStr(result.id)
  result.description = node.getOrDefault("description").getStr("")
  result.model = node["model"].getStr()

  result.capabilities = @[]
  if node.hasKey("capabilities"):
    for item in node["capabilities"].getElems():
      result.capabilities.add(item.getStr())

  result.toolPermissions = @[]
  if node.hasKey("tool_permissions"):
    for item in node["tool_permissions"].getElems():
      result.toolPermissions.add(item.getStr())

  result.autoStart = node.getOrDefault("auto_start").getBool(false)
  result.persistent = node.getOrDefault("persistent").getBool(true)

  if node.hasKey("max_idle_seconds"):
    result.maxIdleSeconds = some(node["max_idle_seconds"].getInt())

proc parseDatabaseType(value: string): DatabaseType =
  case value
  of "sqlite": dtSQLite
  of "tidb": dtTiDB
  else: dtSQLite

proc parseDatabaseConfig(node: TomlValueRef): DatabaseConfig =
  result.enabled = node.getOrDefault("enabled").getBool(true)

  if node.hasKey("type"):
    result.`type` = parseDatabaseType(node["type"].getStr())
  else:
    result.`type` = dtSQLite

  if node.hasKey("path"):
    result.path = some(node["path"].getStr())

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

  result.walMode = node.getOrDefault("wal_mode").getBool(true)
  result.busyTimeout = node.getOrDefault("busy_timeout").getInt(5000)
  result.poolSize = node.getOrDefault("pool_size").getInt(10)

proc parseThemeStyleConfig(node: TomlValueRef): ThemeStyleConfig =
  result.color = node.getOrDefault("color").getStr("white")
  result.style = node.getOrDefault("style").getStr("bright")

proc parseThemeConfig(node: TomlValueRef): ThemeConfig =
  result.name = node.getOrDefault("name").getStr()
  result.header1 = parseThemeStyleConfig(node.getOrDefault("header1"))
  result.header2 = parseThemeStyleConfig(node.getOrDefault("header2"))
  result.header3 = parseThemeStyleConfig(node.getOrDefault("header3"))
  result.bold = parseThemeStyleConfig(node.getOrDefault("bold"))
  result.italic = parseThemeStyleConfig(node.getOrDefault("italic"))
  result.code = parseThemeStyleConfig(node.getOrDefault("code"))
  result.link = parseThemeStyleConfig(node.getOrDefault("link"))
  result.listBullet = parseThemeStyleConfig(node.getOrDefault("list_bullet"))
  result.codeBlock = parseThemeStyleConfig(node.getOrDefault("code_block"))
  result.normal = parseThemeStyleConfig(node.getOrDefault("normal"))
  if node.hasKey("diff_added"):
    result.diffAdded = parseThemeStyleConfig(node["diff_added"])
  if node.hasKey("diff_removed"):
    result.diffRemoved = parseThemeStyleConfig(node["diff_removed"])
  if node.hasKey("diff_context"):
    result.diffContext = parseThemeStyleConfig(node["diff_context"])

proc parseExternalRenderingConfig(node: TomlValueRef): ExternalRenderingConfig =
  result.enabled = node.getOrDefault("enabled").getBool(true)
  result.contentRenderer = node.getOrDefault("content_renderer").getStr("batcat --color=always --style=numbers --theme=auto {file}")
  result.diffRenderer = node.getOrDefault("diff_renderer").getStr("delta --line-numbers --syntax-theme=auto")
  result.fallbackToBuiltin = node.getOrDefault("fallback_to_builtin").getBool(true)

proc parseTextExtractionMode(value: string): TextExtractionMode =
  case value
  of "url": temUrl
  of "stdin": temStdin
  else: temUrl

proc parseTextExtractionConfig(node: TomlValueRef): TextExtractionConfig =
  result.enabled = node.getOrDefault("enabled").getBool(false)
  result.command = node.getOrDefault("command").getStr("trafilatura -u {url}")
  result.fallbackToBuiltin = node.getOrDefault("fallback_to_builtin").getBool(true)

  if node.hasKey("mode"):
    result.mode = parseTextExtractionMode(node["mode"].getStr())
  else:
    result.mode = temUrl

proc parseMcpServerConfig(node: TomlValueRef): McpServerConfig =
  result.command = node["command"].getStr()
  result.enabled = node.getOrDefault("enabled").getBool(true)
  result.name = node.getOrDefault("name").getStr("")

  if node.hasKey("args"):
    var args: seq[string] = @[]
    for item in node["args"].getElems():
      args.add(item.getStr())
    result.args = some(args)

  if node.hasKey("env"):
    var envTable = initTable[string, string]()
    for key, val in node["env"].getTable():
      envTable[key] = val.getStr()
    result.env = some(envTable)

  if node.hasKey("working_dir"):
    result.workingDir = some(node["working_dir"].getStr())

  if node.hasKey("timeout"):
    result.timeout = some(node["timeout"].getInt())

proc loadTomlConfig*(path: string): TomlConfig =
  ## Load and parse TOML configuration file
  if not fileExists(path):
    raise newException(IOError, fmt"Configuration file not found: {path}")

  let tomlContent = readFile(path)
  let parsed = parsetoml.parseString(tomlContent)

  # Parse yourName
  result.yourName = parsed["your_name"].getStr()

  # Parse models array
  result.models = @[]
  if parsed.hasKey("models"):
    for modelNode in parsed["models"].getElems():
      result.models.add(parseModelConfig(modelNode))

  # Parse NATS configuration
  if parsed.hasKey("nats"):
    result.nats = some(parseNatsConfig(parsed["nats"]))

  # Parse master configuration
  if parsed.hasKey("master"):
    result.master = some(parseMasterConfig(parsed["master"]))

  # Parse agents array
  result.agents = @[]
  if parsed.hasKey("agents"):
    for agentNode in parsed["agents"].getElems():
      result.agents.add(parseAgentConfig(agentNode))

  # Parse database configuration
  if parsed.hasKey("database"):
    result.database = some(parseDatabaseConfig(parsed["database"]))

  # Parse themes
  if parsed.hasKey("themes"):
    result.themes = some(initTable[string, ThemeConfig]())
    for key, val in parsed["themes"].getTable():
      result.themes.get()[key] = parseThemeConfig(val)

  # Parse optional fields
  if parsed.hasKey("current_theme"):
    result.currentTheme = some(parsed["current_theme"].getStr())

  if parsed.hasKey("markdown_enabled"):
    result.markdownEnabled = some(parsed["markdown_enabled"].getBool())

  if parsed.hasKey("instruction_files"):
    var files: seq[string] = @[]
    for item in parsed["instruction_files"].getElems():
      files.add(item.getStr())
    result.instructionFiles = some(files)

  if parsed.hasKey("external_rendering"):
    result.externalRendering = some(parseExternalRenderingConfig(parsed["external_rendering"]))

  if parsed.hasKey("text_extraction"):
    result.textExtraction = some(parseTextExtractionConfig(parsed["text_extraction"]))

  if parsed.hasKey("config"):
    result.config = some(parsed["config"].getStr())

  # Parse MCP servers
  if parsed.hasKey("mcp_servers"):
    result.mcpServers = some(initTable[string, McpServerConfig]())
    for key, val in parsed["mcp_servers"].getTable():
      result.mcpServers.get()[key] = parseMcpServerConfig(val)

proc tomlConfigToConfig*(tomlConfig: TomlConfig): Config =
  ## Convert TomlConfig to Config type (for compatibility with existing code)
  result.yourName = tomlConfig.yourName
  result.models = tomlConfig.models
  result.database = tomlConfig.database
  result.themes = tomlConfig.themes
  result.currentTheme = tomlConfig.currentTheme
  result.markdownEnabled = tomlConfig.markdownEnabled
  result.instructionFiles = tomlConfig.instructionFiles
  result.externalRendering = tomlConfig.externalRendering
  result.textExtraction = tomlConfig.textExtraction
  result.config = tomlConfig.config
  result.mcpServers = tomlConfig.mcpServers
