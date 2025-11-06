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
import ../types/[config, messages, nats_messages]

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

proc parseDatabaseType(value: string): DatabaseType =
  case value.toLowerAscii()
  of "sqlite": dtSQLite
  of "tidb": dtTiDB
  else: dtSQLite

# This function doesn't work correctly for key lookup in YAML DOM
# We'll use a different approach

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

  let dbType = getYamlString("type", "sqlite")
  result.`type` = parseDatabaseType(dbType)

  let path = getYamlString("path")
  if path.len > 0:
    result.path = some(path)

  let host = getYamlString("host")
  if host.len > 0:
    result.host = some(host)

  let port = getYamlInt("port", 0)
  if port > 0:
    result.port = some(port)

  let database = getYamlString("database")
  if database.len > 0:
    result.database = some(database)

  let username = getYamlString("username")
  if username.len > 0:
    result.username = some(username)

  let password = getYamlString("password")
  if password.len > 0:
    result.password = some(password)

  result.walMode = getYamlBool("wal_mode", true)
  result.busyTimeout = getYamlInt("busy_timeout", 5000)
  result.poolSize = getYamlInt("pool_size", 10)

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

  let configPath = getRootString("config")
  if configPath.len > 0:
    result.config = some(configPath)

# Type to maintain compatibility with existing code
type YamlConfig* = Config

# Simple wrapper to maintain compatibility
proc yamlConfigToConfig*(yamlConfig: YamlConfig): Config =
  ## Identity conversion for compatibility
  result = yamlConfig