import std/[tables, options, locks]

type
  ModelType* = enum
    mtStandard = "standard"
    mtOpenAIResponses = "openai-responses" 
    mtAnthropic = "anthropic"

  ReasoningLevel* = enum
    rlLow = "low"
    rlMedium = "medium"
    rlHigh = "high"

  ModelConfig* = object
    `type`*: Option[ModelType]
    nickname*: string
    baseUrl*: string
    apiEnvVar*: Option[string]
    apiKey*: Option[string]
    model*: string
    context*: int
    reasoning*: Option[ReasoningLevel]
    enabled*: bool

  SpecialModelConfig* = object
    baseUrl*: string
    apiEnvVar*: Option[string]
    apiKey*: Option[string]
    model*: string
    enabled*: bool

  McpServerConfig* = object
    command*: string
    args*: Option[seq[string]]

  Config* = object
    yourName*: string
    models*: seq[ModelConfig]
    diffApply*: Option[SpecialModelConfig]
    fixJson*: Option[SpecialModelConfig]
    defaultApiKeyOverrides*: Option[Table[string, string]]
    mcpServers*: Option[Table[string, McpServerConfig]]

  KeyConfig* = Table[string, string]

  ConfigManager* = object
    config*: Config
    configPath*: string
    lock*: Lock

# Remove unused global var - will be managed in config.nim