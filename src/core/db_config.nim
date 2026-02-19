## Database-Based Configuration Module
##
## This module replaces the YAML-based configuration with a database-based system.
## Only minimal database connection configuration is read from a local config file
## (or environment variables), everything else is stored in the database.

import std/[os, json, strformat, strutils, options, tables, sequtils, logging, times]
import ../types/config
import ../core/database
import debby/pools
import debby/mysql

# Minimal config file location - only contains database connection
const MinimalConfigPath* = getConfigDir() / "niffler" / "db_config.yaml"
const MinimalConfigEnvPrefix* = "NIFFLER_DB_"

type
  MinimalDbConfig* = object
    ## Minimal configuration required to connect to the database
    ## Everything else is stored in the database itself
    host*: string
    port*: int
    database*: string
    username*: string
    password*: string

proc loadMinimalDbConfig*(): MinimalDbConfig =
  ## Load minimal database configuration from file or environment
  ## Priority: Environment variables > Config file > Defaults
  
  result = MinimalDbConfig(
    host: "127.0.0.1",
    port: 4000,
    database: "niffler",
    username: "root",
    password: ""
  )
  
  # Try to load from config file if it exists
  if fileExists(MinimalConfigPath):
    try:
      let content = readFile(MinimalConfigPath)
      let jsonNode = parseJson(content)
      
      if jsonNode.hasKey("host"):
        result.host = jsonNode["host"].getStr()
      if jsonNode.hasKey("port"):
        result.port = jsonNode["port"].getInt()
      if jsonNode.hasKey("database"):
        result.database = jsonNode["database"].getStr()
      if jsonNode.hasKey("username"):
        result.username = jsonNode["username"].getStr()
      if jsonNode.hasKey("password"):
        result.password = jsonNode["password"].getStr()
    except Exception as e:
      warn(fmt("Failed to load minimal config from {MinimalConfigPath}: {e.msg}"))
  
  # Environment variables override file config
  if existsEnv("NIFFLER_DB_HOST"):
    result.host = getEnv("NIFFLER_DB_HOST")
  if existsEnv("NIFFLER_DB_PORT"):
    result.port = parseInt(getEnv("NIFFLER_DB_PORT"))
  if existsEnv("NIFFLER_DB_DATABASE"):
    result.database = getEnv("NIFFLER_DB_DATABASE")
  if existsEnv("NIFFLER_DB_USERNAME"):
    result.username = getEnv("NIFFLER_DB_USERNAME")
  if existsEnv("NIFFLER_DB_PASSWORD"):
    result.password = getEnv("NIFFLER_DB_PASSWORD")

proc saveMinimalDbConfig*(config: MinimalDbConfig) =
  ## Save minimal database configuration to file
  let configDir = getConfigDir() / "niffler"
  if not dirExists(configDir):
    createDir(configDir)
  
  let jsonNode = %*{
    "host": config.host,
    "port": config.port,
    "database": config.database,
    "username": config.username,
    "password": config.password
  }
  
  writeFile(MinimalConfigPath, $jsonNode)

proc toDatabaseConfig*(minimal: MinimalDbConfig): DatabaseConfig =
  ## Convert minimal config to full DatabaseConfig
  result = DatabaseConfig(
    enabled: true,
    host: minimal.host,
    port: minimal.port,
    database: minimal.database,
    username: minimal.username,
    password: minimal.password,
    poolSize: 10
  )

# ============================================================================
# Database Configuration Storage
# ============================================================================

proc getConfigValue*(db: DatabaseBackend, configKey: string): Option[JsonNode] =
  ## Get a configuration value from the database
  if db == nil:
    return none(JsonNode)
  
  db.pool.withDb:
    let rows = db.query("SELECT value FROM agent_config WHERE `key` = ?", configKey)
    if rows.len > 0:
      try:
        return some(parseJson(rows[0][0]))
      except:
        return none(JsonNode)
  
  return none(JsonNode)

proc setConfigValue*(db: DatabaseBackend, configKey: string, value: JsonNode) =
  ## Set a configuration value in the database
  if db == nil:
    return
  
  let valueStr = $value
  
  db.pool.withDb:
    # Check if key exists
    let existing = db.query("SELECT id FROM agent_config WHERE `key` = ?", configKey)
    if existing.len > 0:
      # Update existing
      db.query("UPDATE agent_config SET value = ?, updated_at = NOW() WHERE `key` = ?", valueStr, configKey)
    else:
      # Insert new
      db.query("INSERT INTO agent_config (`key`, value, updated_at) VALUES (?, ?, NOW())", configKey, valueStr)

proc deleteConfigValue*(db: DatabaseBackend, configKey: string) =
  ## Delete a configuration value from the database
  if db == nil:
    return
  
  db.pool.withDb:
    db.query("DELETE FROM agent_config WHERE `key` = ?", configKey)

proc listConfigKeys*(db: DatabaseBackend): seq[string] =
  ## List all configuration keys in the database
  if db == nil:
    return @[]
  
  db.pool.withDb:
    let rows = db.query("SELECT `key` FROM agent_config")
    result = rows.mapIt(it[0])

# ============================================================================
# Configuration Sections
# ============================================================================

proc loadModelsFromDb*(db: DatabaseBackend): seq[ModelConfig] =
  ## Load model configurations from the database
  let modelsJson = getConfigValue(db, "models")
  if modelsJson.isSome:
    try:
      let jsonArr = modelsJson.get()
      if jsonArr.kind == JArray:
        for item in jsonArr:
          var model: ModelConfig
          # Parse model config from JSON
          if item.hasKey("nickname"):
            model.nickname = item["nickname"].getStr()
          if item.hasKey("baseUrl"):
            model.baseUrl = item["baseUrl"].getStr()
          if item.hasKey("apiKey"):
            model.apiKey = some(item["apiKey"].getStr())
          if item.hasKey("model"):
            model.model = item["model"].getStr()
          if item.hasKey("context"):
            model.context = item["context"].getInt()
          # ... parse other fields
          result.add(model)
    except Exception as e:
      error(fmt("Failed to load models from database: {e.msg}"))

proc saveModelsToDb*(db: DatabaseBackend, models: seq[ModelConfig]) =
  ## Save model configurations to the database
  var jsonArr = newJArray()
  for model in models:
    var obj = newJObject()
    obj["nickname"] = %model.nickname
    obj["baseUrl"] = %model.baseUrl
    if model.apiKey.isSome:
      obj["apiKey"] = %model.apiKey.get()
    obj["model"] = %model.model
    obj["context"] = %model.context
    # ... add other fields
    jsonArr.add(obj)
  setConfigValue(db, "models", jsonArr)

proc loadPersonasFromDb*(db: DatabaseBackend): Table[string, JsonNode] =
  ## Load persona definitions from the database
  let personasJson = getConfigValue(db, "personas")
  if personasJson.isSome:
    try:
      let jsonObj = personasJson.get()
      if jsonObj.kind == JObject:
        for key, value in jsonObj:
          result[key] = value
    except Exception as e:
      error(fmt("Failed to load personas from database: {e.msg}"))

proc savePersonasToDb*(db: DatabaseBackend, personas: Table[string, JsonNode]) =
  ## Save persona definitions to the database
  var jsonObj = newJObject()
  for key, value in personas:
    jsonObj[key] = value
  setConfigValue(db, "personas", jsonObj)

proc loadDiscordConfigFromDb*(db: DatabaseBackend): Option[JsonNode] =
  ## Load Discord configuration from the database
  return getConfigValue(db, "discord")

proc saveDiscordConfigToDb*(db: DatabaseBackend, config: JsonNode) =
  ## Save Discord configuration to the database
  setConfigValue(db, "discord", config)

proc loadWebhookConfigFromDb*(db: DatabaseBackend): Option[JsonNode] =
  ## Load webhook configuration from the database
  return getConfigValue(db, "webhooks")

proc saveWebhookConfigToDb*(db: DatabaseBackend, config: JsonNode) =
  ## Save webhook configuration to the database
  setConfigValue(db, "webhooks", config)

proc loadScheduledJobsFromDb*(db: DatabaseBackend): seq[JsonNode] =
  ## Load scheduled jobs from the database
  let jobsJson = getConfigValue(db, "scheduled_jobs")
  if jobsJson.isSome:
    try:
      let jsonArr = jobsJson.get()
      if jsonArr.kind == JArray:
        for item in jsonArr:
          result.add(item)
    except Exception as e:
      error(fmt("Failed to load scheduled jobs from database: {e.msg}"))

proc saveScheduledJobsToDb*(db: DatabaseBackend, jobs: seq[JsonNode]) =
  ## Save scheduled jobs to the database
  var jsonArr = newJArray()
  for job in jobs:
    jsonArr.add(job)
  setConfigValue(db, "scheduled_jobs", jsonArr)

proc loadFileWatchersFromDb*(db: DatabaseBackend): seq[JsonNode] =
  ## Load file watchers from the database
  let watchersJson = getConfigValue(db, "file_watchers")
  if watchersJson.isSome:
    try:
      let jsonArr = watchersJson.get()
      if jsonArr.kind == JArray:
        for item in jsonArr:
          result.add(item)
    except Exception as e:
      error(fmt("Failed to load file watchers from database: {e.msg}"))

proc saveFileWatchersToDb*(db: DatabaseBackend, watchers: seq[JsonNode]) =
  ## Save file watchers to the database
  var jsonArr = newJArray()
  for watcher in watchers:
    jsonArr.add(watcher)
  setConfigValue(db, "file_watchers", jsonArr)

# ============================================================================
# Migration from YAML Config
# ============================================================================

proc migrateYamlConfigToDb*(db: DatabaseBackend, yamlConfig: Config) =
  ## Migrate existing YAML configuration to the database
  if db == nil:
    error("Cannot migrate config: database not available")
    return
  
  info("Migrating YAML configuration to database...")
  
  # Migrate models
  if yamlConfig.models.len > 0:
    saveModelsToDb(db, yamlConfig.models)
    info(fmt("Migrated {yamlConfig.models.len} models"))
  
  # Migrate MCP servers
  if yamlConfig.mcpServers.isSome:
    var mcpObj = newJObject()
    for key, value in yamlConfig.mcpServers.get():
      var serverObj = newJObject()
      serverObj["command"] = %value.command
      if value.args.isSome:
        serverObj["args"] = %value.args.get()
      serverObj["enabled"] = %value.enabled
      serverObj["name"] = %value.name
      mcpObj[key] = serverObj
    setConfigValue(db, "mcp_servers", mcpObj)
    info("Migrated MCP server configuration")
  
  # Migrate themes
  if yamlConfig.themes.isSome:
    var themesObj = newJObject()
    for key, value in yamlConfig.themes.get():
      var themeObj = newJObject()
      themeObj["name"] = %value.name
      # ... add other theme fields
      themesObj[key] = themeObj
    setConfigValue(db, "themes", themesObj)
    info("Migrated themes")
  
  # Migrate other settings
  var settingsObj = newJObject()
  settingsObj["yourName"] = %yamlConfig.yourName
  if yamlConfig.markdownEnabled.isSome:
    settingsObj["markdownEnabled"] = %yamlConfig.markdownEnabled.get()
  if yamlConfig.thinkingTokensEnabled.isSome:
    settingsObj["thinkingTokensEnabled"] = %yamlConfig.thinkingTokensEnabled.get()
  setConfigValue(db, "settings", settingsObj)
  
  info("Configuration migration complete")
