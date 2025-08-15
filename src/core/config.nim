import std/[os, appdirs, json, tables, options, locks, strformat]
import ../types/config

const DEFAULT_CONFIG_DIR = "niffler"
const KEY_FILE_NAME = "keys"
const CONFIG_FILE_NAME = "config.json"

proc getDefaultConfigPath*(): string =
  joinPath(appdirs.getConfigDir().string, DEFAULT_CONFIG_DIR, CONFIG_FILE_NAME)

proc getDefaultKeyPath*(): string = 
  joinPath(appdirs.getConfigDir().string, DEFAULT_CONFIG_DIR, KEY_FILE_NAME)

# Global config manager
var globalConfigManager: ConfigManager

proc initializeConfigManager() =
  globalConfigManager.configPath = getDefaultConfigPath()
  initLock(globalConfigManager.lock)

proc parseModelConfig(node: JsonNode): ModelConfig =
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
  if node.hasKey("args"):
    var args: seq[string] = @[]
    for arg in node["args"]:
      args.add(arg.getStr())
    result.args = some(args)

proc parseConfig(configJson: JsonNode): Config =
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

proc readConfig*(path: string): Config =
  let content = readFile(path)
  let configJson = parseJson(content)
  return parseConfig(configJson)

proc writeConfig*(config: Config, path: string) =
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
      
    modelsArray.add(modelObj)
  configJson["models"] = modelsArray
  
  writeFile(path, pretty(configJson, 2))

proc readKeys*(): KeyConfig =
  let keyPath = getDefaultKeyPath()
  if not fileExists(keyPath):
    return initTable[string, string]()
    
  let content = readFile(keyPath)
  let keysJson = parseJson(content)
  
  for key, val in keysJson:
    result[key] = val.getStr()

proc writeKeys*(keys: KeyConfig) =
  let keyPath = getDefaultKeyPath()
  let dir = parentDir(keyPath)
  createDir(dir)
  
  var keysJson = newJObject()
  for key, val in keys:
    keysJson[key] = newJString(val)
    
  writeFile(keyPath, $keysJson)
  # Set restrictive permissions (owner read/write only)
  setFilePermissions(keyPath, {fpUserRead, fpUserWrite})

proc initializeConfig*(path: string) =
  if fileExists(path):
    echo "Configuration file already exists: ", path
    return
    
  let defaultConfig = Config(
    yourName: "User",
    models: @[
      ModelConfig(
        nickname: "gpt-4o",
        baseUrl: "https://api.openai.com/v1",
        model: "gpt-4o",
        context: 128000,
        `type`: some(mtStandard),
        enabled: true
      ),
      ModelConfig(
        nickname: "claude-3.5-sonnet",
        baseUrl: "https://api.anthropic.com/v1",
        model: "claude-3-5-sonnet-20241022",
        context: 200000,
        `type`: some(mtAnthropic),
        enabled: false
      ),
      ModelConfig(
        nickname: "local-llm",
        baseUrl: "http://localhost:1234/v1",
        model: "llama-3.2-3b-instruct",
        context: 8000,
        `type`: some(mtStandard),
        enabled: false
      )
    ]
  )
  
  writeConfig(defaultConfig, path)
  echo "Default configuration created at: ", path

proc loadConfig*(): Config =
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
  if modelOverride.len == 0:
    return config.models[0]
    
  for model in config.models:
    if model.nickname == modelOverride:
      return model
      
  return config.models[0]

proc readKeyForModel*(model: ModelConfig): string =
  if model.apiEnvVar.isSome():
    let envKey = getEnv(model.apiEnvVar.get())
    if envKey.len > 0:
      return envKey
      
  if model.apiKey.isSome():
    return model.apiKey.get()
      
  let keys = readKeys()
  return keys.getOrDefault(model.baseUrl, "")

proc assertKeyForModel*(model: ModelConfig): string =
  let key = readKeyForModel(model)
  if key.len == 0:
    raise newException(ValueError, fmt"No API key defined for {model.baseUrl}")
  return key

proc writeKeyForModel*(model: ModelConfig, apiKey: string) =
  var keys = readKeys()
  keys[model.baseUrl] = apiKey
  writeKeys(keys)
