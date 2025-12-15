## YAML Configuration Loading Module
##
## This module handles loading and parsing YAML configuration files for Niffler.
## It provides conversion between YAML structures and internal Config type.
##
## Dependencies:
## - yaml package for YAML parsing
## - Core configuration types defined in types/config.nim

import std/[options, tables, strutils, streams, os]
import yaml
import ../types/config

proc parseModelType(value: string): Option[ModelType] =
  case value.toLowerAscii()
  of "standard": some(mtStandard)
  of "openai-responses": some(mtOpenAIResponses)
  of "anthropic": some(mtAnthropic)
  else: none(ModelType)

proc parseReasoningLevel(value: string): Option[ReasoningLevel] =
  case value.toLowerAscii()
  of "low": some(rlLow)
  of "medium": some(rlMedium)
  of "high": some(rlHigh)
  of "none": some(rlNone)
  else: none(ReasoningLevel)

proc parseModelFromYaml(yamlNode: YamlNode): ModelConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Expected mapping for model config")

  let fields = yamlNode.fields

  # Helper function to get string value from YamlNode
  proc getYamlString(key: string, default: string = ""): string =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return v.content
    return default

  # Helper function to get int value from YamlNode
  proc getYamlInt(key: string, default: int): int =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return parseInt(v.content)
    return default

  # Helper function to get bool value from YamlNode
  proc getYamlBool(key: string, default: bool): bool =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          let content = v.content.toLowerAscii()
          return content == "true" or content == "yes" or content == "1"
    return default

  result.nickname = getYamlString("nickname")
  result.baseUrl = getYamlString("base_url")
  result.model = getYamlString("model")
  result.context = getYamlInt("context", 4096)
  result.enabled = getYamlBool("enabled", true)

  # Optional fields
  let modelType = getYamlString("type")
  if modelType.len > 0:
    result.`type` = parseModelType(modelType)

  let apiEnvVar = getYamlString("api_env_var")
  if apiEnvVar.len > 0:
    result.apiEnvVar = some(apiEnvVar)

  let apiKey = getYamlString("api_key")
  if apiKey.len > 0:
    result.apiKey = some(apiKey)

  let reasoning = getYamlString("reasoning")
  if reasoning.len > 0:
    result.reasoning = parseReasoningLevel(reasoning)

  let tempStr = getYamlString("temperature")
  if tempStr.len > 0:
    result.temperature = some(parseFloat(tempStr))

  let topPStr = getYamlString("top_p")
  if topPStr.len > 0:
    result.topP = some(parseFloat(topPStr))

  let maxTokensStr = getYamlString("max_tokens")
  if maxTokensStr.len > 0:
    result.maxTokens = some(parseInt(maxTokensStr))

  let inputCostStr = getYamlString("input_cost_per_mtoken")
  if inputCostStr.len > 0:
    result.inputCostPerMToken = some(parseFloat(inputCostStr))

  let outputCostStr = getYamlString("output_cost_per_mtoken")
  if outputCostStr.len > 0:
    result.outputCostPerMToken = some(parseFloat(outputCostStr))

  # Thinking token configuration (optional)
  let includeThinking = getYamlString("include_reasoning_in_context")
  if includeThinking.len > 0:
    result.includeReasoningInContext = some(getYamlBool("include_reasoning_in_context", false))

  let thinkingFormat = getYamlString("thinking_format")
  if thinkingFormat.len > 0:
    result.thinkingFormat = some(thinkingFormat)

  let maxThinkingTokensStr = getYamlString("max_thinking_tokens")
  if maxThinkingTokensStr.len > 0:
    result.maxThinkingTokens = some(parseInt(maxThinkingTokensStr))

proc parseDatabaseFromYaml(yamlNode: YamlNode): DatabaseConfig =
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Expected mapping for database config")

  let fields = yamlNode.fields

  proc getYamlString(key: string, default: string = ""): string =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return v.content
    return default

  proc getYamlBool(key: string, default: bool): bool =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          let content = v.content.toLowerAscii()
          return content == "true" or content == "yes" or content == "1"
    return default

  proc getYamlInt(key: string, default: int): int =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return parseInt(v.content)
    return default

  result.enabled = getYamlBool("enabled", true)
  result.host = getYamlString("host", "127.0.0.1")
  result.port = getYamlInt("port", 4000)
  result.database = getYamlString("database", "niffler")
  result.username = getYamlString("username", "root")
  result.password = getYamlString("password", "")
  result.poolSize = getYamlInt("pool_size", 10)

proc parseMasterFromYaml(yamlNode: YamlNode): MasterConfig =
  ## Parse master configuration from YAML node
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Expected mapping for master config")

  let fields = yamlNode.fields

  proc getYamlBool(key: string, default: bool): bool =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          let content = v.content.toLowerAscii()
          return content == "true" or content == "yes" or content == "1"
    return default

  proc getYamlString(key: string, default: string = ""): string =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return v.content
    return default

  proc getYamlInt(key: string, default: int): int =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return parseInt(v.content)
    return default

  result.enabled = getYamlBool("enabled", false)
  result.defaultAgent = getYamlString("default_agent", "coder")
  result.autoStartAgents = getYamlBool("auto_start_agents", true)
  result.heartbeatCheckInterval = getYamlInt("heartbeat_check_interval", 30)

proc parseAgentFromYaml(yamlNode: YamlNode): AgentConfig =
  ## Parse agent configuration from YAML node
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Expected mapping for agent config")

  let fields = yamlNode.fields

  proc getYamlString(key: string, default: string = ""): string =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return v.content
    return default

  proc getYamlBool(key: string, default: bool): bool =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          let content = v.content.toLowerAscii()
          return content == "true" or content == "yes" or content == "1"
    return default

  proc getYamlStringSeq(key: string): seq[string] =
    result = @[]
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == ySequence:
          for item in v.elems:
            if item.kind == yScalar:
              result.add(item.content)
        break

  result.id = getYamlString("id")
  result.name = getYamlString("name", result.id)
  result.description = getYamlString("description", "")
  result.model = getYamlString("model", "")
  result.capabilities = getYamlStringSeq("capabilities")
  result.toolPermissions = getYamlStringSeq("tool_permissions")
  result.autoStart = getYamlBool("auto_start", false)
  result.persistent = getYamlBool("persistent", true)

proc parseMcpServerFromYaml(yamlNode: YamlNode, serverName: string): McpServerConfig =
  ## Parse a single MCP server configuration from YAML
  if yamlNode.kind != yMapping:
    raise newException(ValueError, "Expected mapping for MCP server config")

  let fields = yamlNode.fields

  proc getYamlString(key: string, default: string = ""): string =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return v.content
    return default

  proc getYamlBool(key: string, default: bool): bool =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          let content = v.content.toLowerAscii()
          return content == "true" or content == "yes" or content == "1"
    return default

  proc getYamlInt(key: string, default: int): int =
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return parseInt(v.content)
    return default

  proc getYamlStringSeq(key: string): seq[string] =
    result = @[]
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == ySequence:
          for item in v.elems:
            if item.kind == yScalar:
              result.add(item.content)
        break

  proc getYamlStringTable(key: string): Table[string, string] =
    result = initTable[string, string]()
    for k, v in fields.pairs:
      if k.content == key:
        if v.kind == yMapping:
          for envKey, envValue in v.fields.pairs:
            if envValue.kind == yScalar:
              result[envKey.content] = envValue.content
        break

  result.command = getYamlString("command")
  if result.command.len == 0:
    raise newException(ValueError, "MCP server '" & serverName & "' missing required 'command' field")

  let args = getYamlStringSeq("args")
  if args.len > 0:
    result.args = some(args)

  let env = getYamlStringTable("env")
  if env.len > 0:
    result.env = some(env)

  let workingDir = getYamlString("working_dir")
  if workingDir.len > 0:
    result.workingDir = some(workingDir)

  let timeout = getYamlInt("timeout", 0)
  if timeout > 0:
    result.timeout = some(timeout)

  result.enabled = getYamlBool("enabled", true)
  result.name = getYamlString("name", serverName)

proc loadYamlConfig*(path: string): Config =
  ## Load and parse YAML configuration file using proper YAML parsing
  if not fileExists(path):
    raise newException(IOError, "Configuration file not found: " & path)

  var yamlStream = newFileStream(path, fmRead)
  var yamlRoot: YamlNode
  load(yamlStream, yamlRoot)
  yamlStream.close()

  if yamlRoot.kind != yMapping:
    raise newException(ValueError, "Expected root mapping in YAML file")

  let root = yamlRoot.fields

  # Helper function to get string value from root mapping
  proc getRootString(key: string, default: string = ""): string =
    for k, v in root.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return v.content
    return default

  # Helper function to get bool value from root mapping
  proc getRootBool(key: string, default: bool): bool =
    for k, v in root.pairs:
      if k.content == key:
        if v.kind == yScalar:
          let content = v.content.toLowerAscii()
          return content == "true" or content == "yes" or content == "1"
    return default

  # Helper function to get int value from root mapping
  proc getRootInt(key: string, default: int): int =
    for k, v in root.pairs:
      if k.content == key:
        if v.kind == yScalar:
          return parseInt(v.content)
    return default

  # Parse basic fields
  result.yourName = getRootString("your_name", "User")

  # Parse models
  result.models = @[]
  for k, v in root.pairs:
    if k.content == "models":
      if v.kind == ySequence:
        for modelNode in v.elems:
          if modelNode.kind == yMapping:
            result.models.add(parseModelFromYaml(modelNode))
      break

  # Parse database
  for k, v in root.pairs:
    if k.content == "database":
      if v.kind == yMapping:
        result.database = some(parseDatabaseFromYaml(v))
      break

  # Parse optional fields
  let currentTheme = getRootString("current_theme")
  if currentTheme.len > 0:
    result.currentTheme = some(currentTheme)

  for k, v in root.pairs:
    if k.content == "markdown_enabled":
      if v.kind == yScalar:
        result.markdownEnabled = some(getRootBool("markdown_enabled", true))
      break

  # Parse agent timeout
  let agentTimeout = getRootInt("agent_timeout_seconds", 0)
  if agentTimeout > 0:
    result.agentTimeoutSeconds = some(agentTimeout)

  # Parse default max turns
  let defaultMaxTurns = getRootInt("default_max_turns", 0)
  if defaultMaxTurns > 0:
    result.defaultMaxTurns = some(defaultMaxTurns)

  let configPath = getRootString("config")
  if configPath.len > 0:
    result.config = some(configPath)

  # Parse master configuration
  for k, v in root.pairs:
    if k.content == "master":
      if v.kind == yMapping:
        result.master = some(parseMasterFromYaml(v))
      break

  # Parse agents configuration
  result.agents = @[]
  for k, v in root.pairs:
    if k.content == "agents":
      if v.kind == ySequence:
        for agentNode in v.elems:
          if agentNode.kind == yMapping:
            result.agents.add(parseAgentFromYaml(agentNode))
      break

  # Parse MCP servers configuration
  for k, v in root.pairs:
    if k.content == "mcp_servers":
      if v.kind == yMapping:
        var mcpTable = initTable[string, McpServerConfig]()
        for serverKey, serverValue in v.fields.pairs:
          if serverValue.kind == yMapping:
            mcpTable[serverKey.content] = parseMcpServerFromYaml(serverValue, serverKey.content)
        if mcpTable.len > 0:
          result.mcpServers = some(mcpTable)
      break

# Type to maintain compatibility with existing code
type YamlConfig* = Config

# Simple wrapper to maintain compatibility
proc yamlConfigToConfig*(yamlConfig: YamlConfig): Config =
  ## Identity conversion for compatibility
  result = yamlConfig