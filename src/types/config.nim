## Configuration Type Definitions
##
## This module defines all configuration-related types for Niffler:
## - Model configurations with OpenAI protocol parameters
## - Database configuration for TiDB backend
## - Theme and UI configuration settings
## - Cost tracking and token usage types
##
## Key Type Categories:
## - ModelConfig: LLM model settings and API parameters
## - DatabaseConfig: Database backend configuration
## - ThemeConfig: UI theming and styling settings
## - CostTracking: Token usage and cost calculation
##
## Design Decisions:
## - Uses Option[T] for optional configuration fields
## - Separate enums for different configuration categories
## - Cost tracking built-in for all model configurations
## - TiDB (MySQL-compatible) database backend

import std/[tables, options, locks]
import messages

type
  ModelType* = enum
    mtStandard = "standard"
    mtOpenAIResponses = "openai-responses" 
    mtAnthropic = "anthropic"

  ReasoningLevel* = enum
    rlLow = "low"
    rlMedium = "medium"
    rlHigh = "high"
    rlNone = "none"
    
  ReasoningContentType* = enum
    rctVisible = "visible"
    rctHidden = "hidden"
    rctEncrypted = "encrypted"

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
    reasoningContent*: Option[ReasoningContentType]  # New: thinking token visibility
    
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
    
    # Cost tracking parameters (per million tokens)
    inputCostPerMToken*: Option[float]
    outputCostPerMToken*: Option[float]
    reasoningCostPerMToken*: Option[float]  # Cost for reasoning/thinking tokens

  SpecialModelConfig* = object
    baseUrl*: string
    apiEnvVar*: Option[string]
    apiKey*: Option[string]
    model*: string
    enabled*: bool

  McpServerConfig* = object
    command*: string                    # Command to start the server
    args*: Option[seq[string]]         # Command arguments
    env*: Option[Table[string, string]] # Environment variables
    workingDir*: Option[string]        # Working directory
    timeout*: Option[int]             # Timeout in seconds
    enabled*: bool                    # Enable/disable specific servers
    name*: string                     # Human-readable name

  DatabaseConfig* = object
    enabled*: bool
    host*: string
    port*: int
    database*: string
    username*: string
    password*: string
    poolSize*: int

  ThemeStyleConfig* = object
    color*: string
    style*: string

  ThemeConfig* = object
    name*: string
    header1*: ThemeStyleConfig
    header2*: ThemeStyleConfig
    header3*: ThemeStyleConfig
    bold*: ThemeStyleConfig
    italic*: ThemeStyleConfig
    code*: ThemeStyleConfig
    link*: ThemeStyleConfig
    listBullet*: ThemeStyleConfig
    codeBlock*: ThemeStyleConfig
    normal*: ThemeStyleConfig
    diffAdded*: ThemeStyleConfig
    diffRemoved*: ThemeStyleConfig
    diffContext*: ThemeStyleConfig

  ExternalRenderingConfig* = object
    enabled*: bool
    contentRenderer*: string  # Command template for file content (e.g., "batcat --color=always --style=numbers {file}")
    diffRenderer*: string     # Command template for diffs (e.g., "delta --line-numbers --syntax-theme=auto")
    fallbackToBuiltin*: bool  # Use built-in rendering if external command fails

  TextExtractionMode* = enum
    temUrl = "url"        # Pass URL as argument to external command
    temStdin = "stdin"    # Pipe HTML content via stdin to external command

  TextExtractionConfig* = object
    enabled*: bool              # Enable external text extraction tool
    command*: string            # Command template (e.g., "trafilatura -u {url}" or "trafilatura")
    mode*: TextExtractionMode   # How to pass content: url argument or stdin
    fallbackToBuiltin*: bool    # Use built-in htmlToText if external command fails

  Config* = object
    yourName*: string
    models*: seq[ModelConfig]
    diffApply*: Option[SpecialModelConfig]
    fixJson*: Option[SpecialModelConfig]
    defaultApiKeyOverrides*: Option[Table[string, string]]
    mcpServers*: Option[Table[string, McpServerConfig]]
    database*: Option[DatabaseConfig]
    themes*: Option[Table[string, ThemeConfig]]
    currentTheme*: Option[string]
    markdownEnabled*: Option[bool]
    instructionFiles*: Option[seq[string]]
    # Thinking token global configuration
    thinkingTokensEnabled*: Option[bool]
    defaultReasoningLevel*: Option[ReasoningLevel]
    defaultReasoningContentType*: Option[ReasoningContentType]
    # External rendering configuration
    externalRendering*: Option[ExternalRenderingConfig]
    # Text extraction configuration for web fetch tool
    textExtraction*: Option[TextExtractionConfig]
    # Agent configuration
    agentTimeoutSeconds*: Option[int]
    defaultMaxTurns*: Option[int]
    # Duplicate feedback prevention configuration
    duplicateFeedback*: Option[DuplicateFeedbackConfig]
    # Active config directory selection
    config*: Option[string]
    # Master and agent configuration
    master*: Option[MasterConfig]
    agents*: seq[AgentConfig]

  KeyConfig* = Table[string, string]

  # ---------------------------------------------------------------------------
  # Duplicate Feedback Prevention Configuration
  # ---------------------------------------------------------------------------

  ## Configuration for preventing infinite loops from duplicate tool call feedback
  ##
  ## This configuration addresses the issue where LLMs get stuck making the same
  ## tool call repeatedly even after receiving duplicate feedback. By tracking
  ## attempts per recursion level and globally, we can prevent infinite loops
  ## while providing helpful recovery options.
  ##
  ## The system works by:
  ## 1. Recording each duplicate feedback attempt with recursion depth
  ## 2. Checking limits before providing feedback to prevent loops
  ## 3. Attempting recovery (alternative suggestions) when limits exceeded
  ## 4. Gracefully terminating with clear error messages if recovery fails
  ##
  ## Typical Usage:
  ## ```nim
  ## # In config.yaml:
  ## duplicate_feedback:
  ##   enabled: true
  ##   max_attempts_per_level: 2
  ##   max_total_attempts: 6
  ##   attempt_recovery: true
  ## ```
  DuplicateFeedbackConfig* = object
    ## Enable/disable duplicate feedback tracking and limits
    ## When false, the system behaves as before (no duplicate limits)
    enabled*: bool

    ## Maximum duplicate feedback attempts per recursion level
    ## Prevents infinite loops at the same depth. Recommended: 2-3
    ## Lower values provide faster failure detection but may be too restrictive
    maxAttemptsPerLevel*: int

    ## Maximum total duplicate feedback attempts across all recursion levels
    ## Global safety limit to prevent runaway loops. Recommended: 6-10
    ## Should be higher than maxAttemptsPerLevel * typical depth
    maxTotalAttempts*: int

    ## Attempt automatic recovery when limits exceeded
    ## When true, suggests alternative tools/approaches before terminating
    ## When false, terminates immediately with error message
    attemptRecovery*: bool

  # ---------------------------------------------------------------------------
  # Master and Agent Configuration Types
  # ---------------------------------------------------------------------------

  MasterConfig* = object
    enabled*: bool
    defaultAgent*: string
    autoStartAgents*: bool
    heartbeatCheckInterval*: int
    # Future: Could add natsUrl, timeoutSec, etc.

  AgentConfig* = object
    id*: string
    name*: string
    description*: string
    model*: string
    capabilities*: seq[string]
    toolPermissions*: seq[string]
    autoStart*: bool
    persistent*: bool
    # Future: Could add maxIdleSeconds, workingDir, etc.

  ConfigManager* = object
    config*: Config
    configPath*: string
    lock*: Lock

  # CostTokenUsage removed - using TokenUsage from messages.nim instead
  
  CostTracking* = object
    inputCostPerMToken*: Option[float]
    outputCostPerMToken*: Option[float]
    totalInputCost*: float
    totalOutputCost*: float
    totalCost*: float
    usage*: TokenUsage

# Remove unused global var - will be managed in config.nim