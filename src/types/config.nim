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
    
    # OpenAI protocol parameters
    temperature*: Option[float]
    topP*: Option[float]
    topK*: Option[int]
    maxTokens*: Option[int]
    stop*: Option[seq[string]]
    presencePenalty*: Option[float]
    frequencyPenalty*: Option[float]
    logitBias*: Option[Table[int, float]]
    seed*: Option[int]
    
    # Cost tracking parameters
    inputCostPerToken*: Option[float]
    outputCostPerToken*: Option[float]

  SpecialModelConfig* = object
    baseUrl*: string
    apiEnvVar*: Option[string]
    apiKey*: Option[string]
    model*: string
    enabled*: bool

  McpServerConfig* = object
    command*: string
    args*: Option[seq[string]]

  DatabaseType* = enum
    dtSQLite = "sqlite"
    dtTiDB = "tidb"

  DatabaseConfig* = object
    `type`*: DatabaseType
    enabled*: bool
    # SQLite specific
    path*: Option[string]
    # TiDB specific
    host*: Option[string]
    port*: Option[int]
    database*: Option[string]
    username*: Option[string]
    password*: Option[string]
    # Common settings
    walMode*: bool
    busyTimeout*: int
    poolSize*: int

  Config* = object
    yourName*: string
    models*: seq[ModelConfig]
    diffApply*: Option[SpecialModelConfig]
    fixJson*: Option[SpecialModelConfig]
    defaultApiKeyOverrides*: Option[Table[string, string]]
    mcpServers*: Option[Table[string, McpServerConfig]]
    database*: Option[DatabaseConfig]

  KeyConfig* = Table[string, string]

  ConfigManager* = object
    config*: Config
    configPath*: string
    lock*: Lock

  CostTokenUsage* = object
    inputTokens*: int
    outputTokens*: int
    totalTokens*: int

  CostTracking* = object
    inputCostPerToken*: Option[float]
    outputCostPerToken*: Option[float]
    totalInputCost*: float
    totalOutputCost*: float
    totalCost*: float
    usage*: CostTokenUsage

# Remove unused global var - will be managed in config.nim