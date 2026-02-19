# Niffler Architectural Map

## Executive Summary

Niffler is an AI-powered terminal assistant written in Nim that provides a conversational interface to interact with LLM models while supporting tool calling for file operations, command execution, and web fetching. It features a multi-threaded architecture with dedicated workers for API communication, tool execution, and MCP server management.

---

## 1. Directory Structure

```
src/
├── api/              # LLM API integration layer
│   ├── api.nim           # API worker thread, streaming, tool orchestration
│   ├── curlyStreaming.nim # HTTP/SSE streaming client (libcurl)
│   ├── tool_call_parser.nim # Flexible tool call format detection
│   └── thinking_token_parser.nim # Reasoning token extraction
│
├── core/              # Core application logic
│   ├── app.nim           # Application lifecycle, prompt preparation
│   ├── channels.nim      # Thread-safe channel communication
│   ├── config.nim        # Configuration loading and management
│   ├── database.nim      # TiDB/MySQL database operations
│   ├── conversation_manager.nim # Conversation persistence
│   ├── session.nim       # Session state management
│   ├── system_prompt.nim # Dynamic system prompt generation
│   ├── nats_client.nim   # NATS messaging wrapper
│   ├── agent_manager.nim # Agent process lifecycle
│   ├── task_executor.nim # Autonomous task execution
│   ├── mode_state.nim    # Plan/Code mode management
│   └── command_parser.nim # CLI command parsing
│
├── mcp/               # Model Context Protocol integration
│   ├── protocol.nim      # MCP JSON-RPC protocol
│   ├── manager.nim       # MCP server lifecycle management
│   ├── mcp.nim           # MCP worker thread
│   └── tools.nim         # MCP tool integration
│
├── tools/             # Tool execution system
│   ├── registry.nim      # Central tool registry with schemas
│   ├── worker.nim        # Tool execution worker thread
│   ├── common.nim        # Shared tool utilities
│   ├── bash.nim          # Shell command execution
│   ├── read.nim          # File reading
│   ├── list.nim          # Directory listing
│   ├── edit.nim          # File editing with diff
│   ├── create.nim        # File creation
│   ├── fetch.nim         # HTTP/Web fetching
│   ├── todolist.nim      # Task tracking
│   └── task.nim          # Agent delegation
│
├── types/             # Type definitions
│   ├── messages.nim      # LLM message types, API responses
│   ├── config.nim        # Configuration types
│   ├── agents.nim        # Agent definitions and contexts
│   ├── mode.nim          # Plan/Code mode enum
│   ├── tools.nim         # Tool types
│   ├── nats_messages.nim # NATS protocol messages
│   └── thinking_tokens.nim # Reasoning token types
│
├── ui/                # User interface layer
│   ├── cli.nim           # Interactive CLI with linecross
│   ├── agent_cli.nim     # Agent mode CLI (NATS listener)
│   ├── master_cli.nim    # Master mode for agent routing
│   ├── commands.nim      # Command handlers (/help, /model, etc.)
│   ├── output_handler.nim # API response display worker
│   ├── tool_visualizer.nim # Tool call UI display
│   ├── theme.nim         # UI theming
│   └── nats_listener.nim # Async NATS response handler
│
├── tokenization/      # Token counting system
│   ├── tokenizer.nim     # Public API with caching
│   ├── core.nim          # minbpe tokenizer port
│   └── estimation.nim    # Heuristic token estimation
│
└── niffler.nim        # CLI entry point
```

---

## 2. Core Components

### 2.1 Entry Point and CLI (`src/niffler.nim`)

**Purpose**: Main entry point with parseopt-based command dispatch

**Key Responsibilities**:
- Parse command-line arguments
- Dispatch to appropriate mode (master, agent, model list, init)
- Handle logging configuration

**Command Structure**:
```
niffler [options]                      # Interactive master mode
niffler agent <name> [options]         # Start specialized agent
niffler model list                     # List available models
niffler init [path]                    # Initialize config
niffler nats-monitor [options]         # Monitor NATS traffic
```

### 2.2 Core Application Logic (`src/core/app.nim`)

**Purpose**: Application orchestration and prompt preparation

**Key Functions**:
- `prepareConversationMessagesWithTokens()`: Build LLM messages with system prompt
- `processFileReferencesInText()`: Handle @file references
- `truncateContextIfNeeded()`: Context window management
- `toggleModeWithProtection()`: Plan/Code mode switching

### 2.3 Thread Communication (`src/core/channels.nim`)

**Purpose**: Thread-safe message passing between workers

**Channel Types**:
| Channel | Direction | Purpose |
|---------|-----------|---------|
| `apiRequestChan` | Main → API Worker | LLM requests |
| `apiResponseChan` | API Worker → Main | Streaming responses |
| `toolRequestChan` | API Worker → Tool Worker | Tool execution |
| `toolResponseChan` | Tool Worker → API Worker | Tool results |
| `mcpRequestChan` | Main → MCP Worker | MCP operations |
| `mcpResponseChan` | MCP Worker → Main | MCP results |
| `uiUpdateChan` | Workers → Main | UI notifications |

**Key Types**:
```nim
ThreadChannels = object
  apiRequestChan: ThreadSafeQueue[APIRequest]
  apiResponseChan: ThreadSafeQueue[APIResponse]
  toolRequestChan: ThreadSafeQueue[ToolRequest]
  toolResponseChan: ThreadSafeQueue[ToolResponse]
  mcpRequestChan: ThreadSafeQueue[McpRequest]
  mcpResponseChan: ThreadSafeQueue[McpResponse]
  uiUpdateChan: ThreadSafeQueue[UIUpdate]
  shutdownSignal: Atomic[bool]
  threadsActive: Atomic[int]
```

### 2.4 API Worker (`src/api/api.nim`)

**Purpose**: LLM communication and tool calling orchestration

**Key Features**:
- Streaming response handling with libcurl
- Tool call buffering during streaming
- Multi-turn conversation with tool results
- Duplicate feedback prevention
- Agentic loop execution (`executeAgenticLoop`)

**Tool Calling Flow**:
1. Send request with tool schemas to LLM
2. Detect tool calls in streaming chunks
3. Buffer partial tool call fragments
4. Execute completed tool calls via tool worker
5. Integrate results and continue conversation

**Key Data Structures**:
```nim
ToolCallBuffer = object
  id: string
  name: string
  arguments: string
  format: Option[ToolFormat]

DuplicateFeedbackTracker = object
  attemptsPerLevel: Table[int, Table[string, int]]
  totalAttempts: Table[string, int]
```

### 2.5 Tool Worker (`src/tools/worker.nim`)

**Purpose**: Execute tools in isolated thread with validation

**Execution Flow**:
1. Receive tool request from API worker
2. Validate agent context and permissions
3. Execute tool via registry
4. Handle MCP tools if not built-in
5. Send result back to API worker

### 2.6 Tool Registry (`src/tools/registry.nim`)

**Purpose**: Central tool registration with object variants

**Built-in Tools**:
| Tool | Purpose | Requires Confirmation |
|------|---------|----------------------|
| `bash` | Shell commands | Yes |
| `read` | File reading | No |
| `list` | Directory listing | No |
| `edit` | File editing | Yes |
| `create` | File creation | Yes |
| `fetch` | HTTP fetching | No |
| `todolist` | Task tracking | No |
| `task` | Agent delegation | No |

**Design Pattern**:
```nim
Tool = object
  requiresConfirmation: bool
  schema: ToolDefinition
  case kind: ToolKind
  of tkBash: bashExecute: proc(args: JsonNode): string
  of tkRead: readExecute: proc(args: JsonNode): string
  # ... etc
```

### 2.7 Database Layer (`src/core/database.nim`)

**Purpose**: TiDB (MySQL-compatible) persistence with connection pooling

**Tables**:
| Table | Purpose |
|-------|---------|
| `conversation` | Conversation metadata and settings |
| `conversation_message` | Individual messages with tool calls |
| `model_token_usage` | Token and cost tracking per API call |
| `message_thinking_blocks` | Interleaved reasoning tokens |
| `todo_list` / `todo_item` | Todo system persistence |
| `system_prompt_token_usage` | System prompt overhead tracking |
| `token_correction_factor` | Dynamic token estimation correction |

**Key Functions**:
- `startConversation()` / `switchToConversation()`
- `addUserMessage()` / `addAssistantMessage()` / `addToolMessage()`
- `getConversationContext()` - Load messages for LLM
- `logTokenUsageFromRequest()` - Track token usage

### 2.8 MCP Integration (`src/mcp/`)

**Purpose**: Model Context Protocol server integration

**Protocol Flow**:
1. Start MCP server process
2. Initialize with capabilities negotiation
3. Discover available tools
4. Execute tools on demand
5. Shutdown on application exit

**Key Types**:
```nim
McpClient = ref object
  process: Process
  inputStream: Stream
  outputStream: Stream
  serverName: string
  connected: bool
  capabilities: JsonNode
```

### 2.9 Agent System (`src/types/agents.nim`, `src/core/agent_manager.nim`)

**Purpose**: Specialized agent definitions and lifecycle management

**Agent Definition Format** (Markdown):
```markdown
## Description
Agent for general coding tasks

## Model
kimi

## Allowed Tools
- read
- write
- bash

## System Prompt
You are a specialized coding agent...
```

**Agent Context**:
```nim
AgentContext = object
  agent: AgentDefinition
  isMainAgent: bool  # Full access if true
```

### 2.10 Task Executor (`src/core/task_executor.nim`)

**Purpose**: Isolated task execution for autonomous agents

**Features**:
- Creates isolated conversation per task
- Filters tools to agent's allowed set
- Generates summary after completion
- Extracts artifacts (created/modified files)

**Task Result**:
```nim
TaskResult = object
  success: bool
  summary: string
  artifacts: seq[string]
  tempArtifacts: seq[string]
  toolCalls: int
  tokensUsed: int
  messages: int
  durationMs: int
  error: string
```

### 2.11 NATS Messaging (`src/core/nats_client.nim`)

**Purpose**: Multi-agent communication via NATS

**Features**:
- Pub/sub messaging
- Request/reply pattern
- Presence tracking via JetStream KV
- Auto-reconnect support

**Subject Patterns**:
- `niffler.agent.<name>.request` - Request channel
- `niffler.master.response` - Response channel
- `niffler_presence` KV bucket - Heartbeats

---

## 3. Data Flow

### 3.1 User Input → Processing → Response

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           MAIN THREAD                                    │
├─────────────────────────────────────────────────────────────────────────┤
│  1. User Input (linecross)                                              │
│     └── parseCommand() / classifyCommand()                              │
│                                                                         │
│  2. Prepare Request                                                      │
│     └── prepareConversationMessagesWithTokens()                         │
│     └── processFileReferencesInText()                                   │
│     └── createSystemMessage()                                           │
│                                                                         │
│  3. Send to API Worker                                                   │
│     └── trySendAPIRequest(apiRequestChan)                               │
└───────────────────────────┬─────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           API WORKER THREAD                             │
├─────────────────────────────────────────────────────────────────────────┤
│  4. Receive Request                                                      │
│     └── tryReceiveAPIRequest()                                          │
│                                                                         │
│  5. Send to LLM                                                          │
│     └── sendStreamingChatRequest()                                      │
│                                                                         │
│  6. Process Streaming Response                                           │
│     └── Buffer tool call fragments                                      │
│     └── Send chunks to main: apiResponseChan                            │
│                                                                         │
│  7. If Tool Calls Detected                                               │
│     └── executeToolCallsBatch() → toolRequestChan                       │
│     └── Wait for results ← toolResponseChan                             │
│     └── executeAgenticLoop() (recursive)                                │
└───────────────────────────┬─────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                          TOOL WORKER THREAD                             │
├─────────────────────────────────────────────────────────────────────────┤
│  8. Receive Tool Request                                                 │
│     └── Validate agent context                                          │
│     └── Check tool permissions                                          │
│                                                                         │
│  9. Execute Tool                                                         │
│     └── executeTool() via registry                                      │
│     └── Or executeMcpTool() for MCP                                     │
│                                                                         │
│  10. Return Result                                                       │
│      └── sendToolResponse(toolResponseChan)                             │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Thread Communication Patterns

```
┌────────────┐    apiRequestChan    ┌────────────┐
│    MAIN    │ ──────────────────▶ │    API     │
│   THREAD   │                      │   WORKER   │
│            │ ◀────────────────── │            │
└────────────┘   apiResponseChan   └─────┬──────┘
                                          │
                        toolRequestChan   │   toolResponseChan
                                     ┌────┴────┐
                                     │  TOOL   │
                                     │ WORKER  │
                                     └─────────┘

┌────────────┐    mcpRequestChan    ┌────────────┐
│    MAIN    │ ──────────────────▶ │    MCP     │
│   THREAD   │                      │   WORKER   │
│            │ ◀────────────────── │            │
└────────────┘   mcpResponseChan   └────────────┘
```

---

## 4. Key Types

### 4.1 Message Types (`src/types/messages.nim`)

```nim
# Core message for LLM communication
Message = object
  id: int                    # Database ID
  role: MessageRole          # user/assistant/system/tool
  content: string
  toolCalls: Option[seq[LLMToolCall]]
  toolCallId: Option[string]
  toolResults: Option[seq[ToolResult]]
  thinkingContent: Option[ThinkingContent]

# OpenAI-compatible tool call
LLMToolCall = object
  id: string
  `type`: string  # Always "function"
  function: FunctionCall

# API Request for thread communication
APIRequest = object
  case kind: APIRequestKind
  of arkChatRequest:
    requestId: string
    messages: seq[Message]
    model: string
    baseUrl: string
    apiKey: string
    enableTools: bool
    tools: Option[seq[ToolDefinition]]
    agentName: string

# API Response variants
APIResponse = object
  requestId: string
  case kind: APIResponseKind
  of arkStreamChunk:
    content: string
    toolCalls: Option[seq[LLMToolCall]]
    thinkingContent: Option[string]
  of arkStreamComplete:
    usage: TokenUsage
  of arkStreamError:
    error: string
  # ...
```

### 4.2 Configuration Types (`src/types/config.nim`)

```nim
ModelConfig = object
  nickname: string
  baseUrl: string
  model: string
  context: int
  reasoning: Option[ReasoningLevel]
  maxTokens: Option[int]
  temperature: Option[float]
  inputCostPerMToken: Option[float]
  outputCostPerMToken: Option[float]
  reasoningCostPerMToken: Option[float]

Config = object
  models: seq[ModelConfig]
  mcpServers: Option[Table[string, McpServerConfig]]
  database: Option[DatabaseConfig]
  themes: Option[Table[string, ThemeConfig]]
  master: Option[MasterConfig]
  agents: seq[AgentConfig]
```

### 4.3 Agent Types (`src/types/agents.nim`)

```nim
AgentDefinition = object
  name: string
  description: string
  allowedTools: seq[string]
  systemPrompt: string
  filePath: string
  model: Option[string]

AgentContext = object
  agent: AgentDefinition
  isMainAgent: bool

TaskResult = object
  success: bool
  summary: string
  artifacts: seq[string]
  toolCalls: int
  tokensUsed: int
```

---

## 5. External Dependencies

### 5.1 LLM APIs

- **OpenAI-compatible APIs**: Chat completions with streaming
- **Anthropic**: Extended thinking support
- **Custom endpoints**: Local servers (localhost/127.0.0.1) skip API key validation

**Protocol**: HTTP/SSE with JSON payloads

### 5.2 Database (TiDB/MySQL)

- **Host**: Default `127.0.0.1:4000`
- **Database**: `niffler`
- **Connection Pool**: 10 connections (configurable)

### 5.3 NATS Server

- **URL**: Default `nats://localhost:4222`
- **Features Used**:
  - Pub/sub messaging
  - JetStream KV for presence tracking
  - Request/reply pattern

### 5.4 MCP Servers

- **Protocol**: JSON-RPC 2.0 over stdio
- **Discovery**: Tool listing via `tools/list`
- **Execution**: Tool calls via `tools/call`

---

## 6. Design Decisions

### 6.1 Thread-Based Architecture (No Async)

- Uses Nim's native threads instead of asyncdispatch
- Deterministic behavior with proper isolation
- Thread-safe channels for communication
- Each worker has dedicated responsibility

### 6.2 Streaming-First API Design

- Real-time chunk processing
- Tool call buffering during streaming
- Progressive rendering of responses

### 6.3 Tool Registry Pattern

- Object variants for type-safe dispatch
- Schema co-located with execution
- Centralized registration at module init

### 6.4 Agent Permission Model

- Agent definitions in Markdown files
- Tool whitelist per agent
- Main agent has full access

### 6.5 Conversation Persistence

- All messages stored in database
- Thinking tokens tracked separately
- Token usage per API call with cost calculation

---

## 7. Extension Points

1. **New Tools**: Add to registry with schema and executor
2. **MCP Servers**: Configure in `config.yaml`
3. **Agent Types**: Create `.md` files in agents directory
4. **Themes**: Define in `config.yaml`
5. **Models**: Configure multiple API endpoints

---

## 8. Mode System

Niffler supports two primary modes:

### Plan Mode
- Focused on analysis and planning
- Protects files from accidental modification
- Read-only operations preferred

### Code Mode
- Full write access to files
- Implementation and execution
- Default mode for most work

Mode switching via `/plan` and `/code` commands with state persistence.

---

## 9. Multi-Agent Architecture

### Master Mode
- Routes requests to specialized agents
- NATS-based communication
- Presence tracking for agent discovery
- `@agent` syntax for direct routing

### Agent Mode
- Specialized agent instances
- Tool access restrictions
- Isolated conversation context
- Heartbeat publishing for presence

### Task Delegation
- `task` tool for spawning sub-agents
- Isolated execution context
- Result summarization
- Artifact extraction
