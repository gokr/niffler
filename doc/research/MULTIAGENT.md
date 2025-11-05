# Multi-Agent Niffler Architecture

**Future Vision Document**: This describes a future multi-agent architecture with process-per-agent IPC system. Niffler currently uses single-process task execution (see [TASK.md](TASK.md)), which provides similar benefits without inter-process communication complexity.

This document outlines the design for implementing a multi-agent system using niffler, where multiple specialized AI agents run as persistent processes and are coordinated through a master interface using NATS messaging.

## Concept Overview

The multi-agent system consists of:
1. **Master Niffler** - Main interface for entering prompts with agent routing via `@agent:` syntax
2. **Sub-Niffler Instances** - Long-running specialized agents, each displaying their own work in separate terminals
3. **NATS Message Bus** - Inter-process communication using JSON messages over NATS subjects
4. **Task vs Ask Semantics** - Clear distinction between isolated tasks and conversational asks

### Core Design Principle

**One agent = One persistent process**. Unlike most agentic tools that coordinate multiple agents within a single process, Niffler uses separate operating system processes for true isolation, visibility, and fault tolerance.

### Task vs Ask Model

**Task** (`@agent:task: prompt`)
- Creates fresh context for isolated execution
- Agent processes request independently
- Returns result (context is persisted but not continued)
- Use case: One-off operations, isolated problems
- Example: `@researcher:task: Find Nim NATS libraries`

**Ask** (`@agent:ask: prompt`)
- Continues existing conversation context
- Agent builds on previous interactions
- Maintains context for iterative work
- Use case: Multi-step problems, refinement, learning
- Example: `@coder:ask: Now add error handling to that function`

Both task and ask conversations are **always persisted** in the database for history and analysis.

## Current Architecture Analysis

### Core Strengths for Multi-Agent Extension

**Thread-based Architecture**: Niffler uses dedicated worker threads (API worker, Tool worker) with thread-safe channel communication via `src/core/channels.nim`. This architecture remains **unchanged within each agent process** - NATS is used only for inter-process communication, not replacing internal threading.

**Configuration System**: The configuration in `src/core/config.nim` will be migrated from JSON to TOML for better readability, structure, and commenting. This supports multiple AI providers and enables rich agent definitions.

**Message Types**: Well-defined message protocols in `src/types/messages.nim` for API requests/responses and tool execution will be extended with NATS message types for inter-agent communication.

**CLI Framework**: Uses cligen for command parsing - will be extended with `--master` and `--agent-mode` flags for different process modes.

### Current Components Relevant to Multi-Agent

- **Main Entry Point** (`src/niffler.nim`): CLI parsing - will add master and agent mode switches
- **CLI Interface** (`src/ui/cli.nim`): Interactive terminal UI - master mode simplified, agent mode displays work
- **Threading System** (`src/core/channels.nim`): Internal thread communication - preserved as-is
- **API Worker** (`src/api/api.nim`): LLM communication - each agent has its own instance
- **Configuration** (`src/core/config.nim`): Will be extended with TOML support and agent definitions

## Multi-Agent Implementation Strategy

### 1. Master Niffler: Simplified Coordinator

**Role**: Classic CLI that reads user input and routes to agents, without streaming output complexity.

**Workflow**:
1. Read line from stdin
2. Parse for `@agent:task:` or `@agent:ask:` prefix
3. Publish request to NATS subject `niffler.agent.<name>.request`
4. Display routing confirmation: "→ Sent to @coder"
5. Wait for completion notification
6. Display result: "✓ @coder completed"

**No Streaming Output**: Master doesn't handle streaming - users see that in agent's terminal window. This eliminates the complex multiplexing problem that plagues other tools.

**Agent Management Commands**:
```bash
/agents list          # Query active agents via NATS heartbeats
/agents start <name>  # Spawn new agent process
/agents stop <name>   # Send graceful shutdown message
/agents restart <name> # Stop and restart agent
/agents health        # Show health status of all agents
```

**Backward Compatibility**: Input without `@agent:` prefix can:
- Process locally in single-agent mode (for backward compatibility)
- Or route to `default_agent` from config

### 2. Sub-Niffler: Visible Agent Workers

**Role**: Long-running specialist processes that display their work transparently.

**Process Architecture** (per agent):
```
┌─────────────────────────────────────┐
│ Sub-Niffler Process: "coder"       │
├─────────────────────────────────────┤
│ Main Thread:                        │
│  - NATS subscriber                  │
│  - Display incoming prompts         │
│  - Display streaming output         │
│  - Publish status updates           │
├─────────────────────────────────────┤
│ API Worker Thread: (unchanged)      │
│  - LLM communication                │
│  - Tool call orchestration          │
│  - Channel communication            │
├─────────────────────────────────────┤
│ Tool Worker Thread: (unchanged)     │
│  - Execute tools                    │
│  - Validation and security          │
└─────────────────────────────────────┘
```

**NATS Integration**:
- Subscribe to `niffler.agent.<name>.request`
- Receive task/ask requests
- Display prompts received to stdout
- Process via existing API worker (unchanged)
- Stream LLM output to stdout (user sees live)
- Publish status updates to `niffler.agent.<name>.status`
- Publish final result to `niffler.agent.<name>.response`
- Publish heartbeat to `niffler.agent.<name>.heartbeat`

**Display Format**:
```
[RECEIVED:TASK @coder] Create a simple HTTP server
[PROCESSING...]
I'll create an HTTP server using Nim's asynchttpserver...
[TOOL: create] src/server.nim
[TOOL RESULT] File created successfully
The HTTP server has been created with...
[COMPLETED ✓]

[RECEIVED:ASK @coder] Add logging to the server
[PROCESSING...] (continuing conversation)
I'll add logging to the server we just created...
[TOOL: edit] src/server.nim
[TOOL RESULT] File edited successfully
Added logging using Nim's logging module...
[COMPLETED ✓]
```

**Lifecycle**:
- Started once (manually or auto-started by master)
- Handles multiple requests over lifetime
- Each task creates new context
- Each ask continues existing context
- Persistent agents stay alive when idle
- Ephemeral agents shutdown after `max_idle_seconds`

### 3. NATS Message Bus

**Why NATS**:
- Battle-tested message bus with proven reliability
- Built-in request/reply and pub/sub patterns
- Subject-based routing eliminates discovery protocol
- Easy monitoring and observability (subscribe to `niffler.>`)
- Scalable to distributed deployment later
- Low latency (~1-2ms local)

**Message Protocol**: All messages use JSON serialization.

**Task Request Message**:
```json
{
  "type": "task_request",
  "requestId": "uuid-1234-5678",
  "agentName": "coder",
  "prompt": "Create a simple HTTP server",
  "context": null,
  "metadata": {
    "sender": "master",
    "timestamp": "2025-01-15T10:30:00Z"
  }
}
```
**Subject**: `niffler.agent.coder.request`

**Ask Request Message**:
```json
{
  "type": "ask_request",
  "requestId": "uuid-1234-5678",
  "agentName": "coder",
  "prompt": "Add logging to the server",
  "conversationId": "conv-abc-123",
  "context": [
    {"role": "user", "content": "Create a simple HTTP server"},
    {"role": "assistant", "content": "I'll create an HTTP server..."}
  ],
  "metadata": {
    "sender": "master",
    "timestamp": "2025-01-15T10:31:00Z",
    "conversationMessageCount": 4
  }
}
```
**Subject**: `niffler.agent.coder.request`

**Status Update Message**:
```json
{
  "type": "status",
  "requestId": "uuid-1234-5678",
  "agentName": "coder",
  "status": "processing|tool_call|streaming|completed|error",
  "data": {
    "toolName": "create",
    "toolArgs": {"file": "src/server.nim"},
    "message": "Creating file..."
  },
  "timestamp": "2025-01-15T10:30:05Z"
}
```
**Subject**: `niffler.agent.coder.status`

**Response Message**:
```json
{
  "type": "response",
  "requestId": "uuid-1234-5678",
  "agentName": "coder",
  "result": {
    "content": "I've created an HTTP server with...",
    "conversationId": "conv-abc-123",
    "toolCalls": [
      {"tool": "create", "file": "src/server.nim", "success": true}
    ],
    "tokensUsed": {"input": 1200, "output": 450}
  },
  "status": "completed",
  "timestamp": "2025-01-15T10:30:30Z"
}
```
**Subject**: `niffler.agent.coder.response`

**Heartbeat Message**:
```json
{
  "type": "heartbeat",
  "agentName": "coder",
  "status": "idle|busy",
  "uptime": 3600,
  "requestsProcessed": 42,
  "currentConversationId": "conv-abc-123",
  "timestamp": "2025-01-15T10:30:00Z"
}
```
**Subject**: `niffler.agent.coder.heartbeat` (published every 30 seconds)

### 4. Configuration: TOML Format

Niffler will migrate from JSON to TOML configuration for better readability, structure, and commenting.

**Location**: `~/.config/niffler/config.toml`

**Example Configuration**:
```toml
# Niffler Multi-Agent Configuration
# See https://docs.niffler.dev/config for complete documentation

[nats]
# NATS server connection settings
server = "nats://localhost:4222"
timeout_ms = 30000
reconnect_attempts = 5
reconnect_delay_ms = 1000

[master]
# Master mode settings (when running with --master flag)
enabled = false
default_agent = "coder"  # Agent to use when no @agent: specified
auto_start_agents = true  # Auto-start agents with auto_start=true
heartbeat_check_interval = 30  # Seconds between health checks

# Agent Definitions
# Each agent is a specialized worker with its own model and permissions

[[agents]]
id = "coder"
name = "Code Expert"
description = "Specialized in code analysis, debugging, and implementation"

# Model configuration
model = "claude-3.5-sonnet"

# Capabilities (used for smart routing and UI hints)
capabilities = ["coding", "debugging", "architecture", "refactoring", "testing"]

# Tool permissions (enforced by agent - only these tools can execute)
tool_permissions = ["read", "edit", "create", "bash", "list", "fetch"]

# Lifecycle settings
auto_start = true  # Master will start this agent automatically
persistent = true  # Keep running when idle (don't shutdown)

[[agents]]
id = "researcher"
name = "Research Assistant"
description = "Fast research, documentation lookup, and web search"

model = "claude-3-haiku"  # Cheaper model for simple research tasks
capabilities = ["research", "documentation", "web_search", "analysis"]
tool_permissions = ["read", "list", "fetch"]  # Read-only, no modifications

auto_start = false  # Start manually when needed
persistent = false  # Ephemeral - shutdown after idle timeout
max_idle_seconds = 600  # Shutdown after 10 minutes idle

[[agents]]
id = "bash_helper"
name = "Bash Helper"
description = "System commands, testing, and DevOps operations"

model = "gpt-4o"
capabilities = ["system", "commands", "testing", "devops", "monitoring"]
tool_permissions = ["bash", "read", "list"]  # Bash + read-only files

auto_start = true
persistent = true

[[agents]]
id = "reviewer"
name = "Code Reviewer"
description = "Code review, security analysis, and best practices"

model = "claude-opus-4"  # Most powerful model for thorough reviews
capabilities = ["review", "security", "quality", "best_practices"]
tool_permissions = ["read", "list"]  # Read-only for reviews

auto_start = false
persistent = false
max_idle_seconds = 1800  # 30 minutes

# Model definitions (shared across agents)
[[models]]
id = "claude-3.5-sonnet"
nickname = "sonnet"
base_url = "https://api.anthropic.com/v1"
api_key_env = "ANTHROPIC_API_KEY"

[[models]]
id = "claude-opus-4"
nickname = "opus"
base_url = "https://api.anthropic.com/v1"
api_key_env = "ANTHROPIC_API_KEY"

[[models]]
id = "claude-3-haiku"
nickname = "haiku"
base_url = "https://api.anthropic.com/v1"
api_key_env = "ANTHROPIC_API_KEY"

[[models]]
id = "gpt-4o"
nickname = "gpt4o"
base_url = "https://api.openai.com/v1"
api_key_env = "OPENAI_API_KEY"
```

### 5. Database Context Management

**All conversations are persisted** regardless of task or ask type, enabling full history and analysis.

**Conversation Types**:

**Task Conversations**:
- Create new conversation: `task_<agentId>_<timestamp>`
- Record all messages during execution
- Mark as `type = 'task'` in database
- Not loaded into future contexts (isolated)
- Available for history review and learning

**Ask Conversations**:
- Load or create conversation: `ask_<agentId>_<conversationId>`
- Append new messages to existing conversation
- Mark as `type = 'ask'` in database
- Loaded into subsequent ask requests (continued)
- Builds context over multiple interactions

**Schema Extension**:
```sql
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL,  -- Which agent owns this conversation
  type TEXT NOT NULL,      -- 'task' or 'ask'
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  status TEXT NOT NULL,    -- 'active', 'completed'
  metadata TEXT            -- JSON metadata
);

CREATE INDEX idx_conversations_agent ON conversations(agent_id);
CREATE INDEX idx_conversations_type ON conversations(type);
CREATE INDEX idx_conversations_status ON conversations(status);

-- Existing conversation_message table unchanged
-- Links to conversations via conversation_id foreign key
```

**Context Loading Rules**:
- **Task request**: Create new conversation, load no previous context
- **Ask request**: Load active 'ask' conversation for this agent, or create if first ask
- **All messages persisted**: Both task and ask messages stored for history

## Implementation Phases

### Phase 0: Configuration Migration (3-5 days)

**Goal**: Migrate from JSON to TOML configuration with backward compatibility.

1. **Add TOML Parser**
   - Evaluate Nim TOML libraries (`parsetoml`, `toml-serialization`)
   - Add dependency to nimble file
   - Create `src/core/config_toml.nim`

2. **Configuration Loader**
   - Check for `config.toml` first, then `config.json`
   - Parse TOML with agent definitions
   - Map to existing Config types
   - Validation and error reporting

3. **Migration Utility**
   - Add `niffler --migrate-config` command
   - Read existing JSON config
   - Generate TOML with comments
   - Backup JSON before migration

4. **Documentation**
   - Document TOML format
   - Provide migration guide
   - Update example configs

### Phase 1: NATS Foundation (1-2 weeks)

**Goal**: Establish NATS communication infrastructure.

1. **NATS Client Library**
   - Evaluate Nim NATS libraries (`nats.nim` if available)
   - Consider simple TCP implementation (NATS protocol is text-based)
   - Or FFI to nats.c native library
   - Decision: Start simple, can upgrade later

2. **Create `src/core/nats_client.nim`**
   - Connection management with auto-reconnect
   - Publish/subscribe primitives
   - Subject-based routing helpers
   - Error handling and timeouts
   - Connection pooling if needed

3. **Message Type Definitions**
   - Create `src/types/nats_messages.nim`
   - Define: TaskRequest, AskRequest, Response, Status, Heartbeat
   - JSON serialization/deserialization
   - Validation helpers

4. **Integration Tests**
   - Test publish/subscribe between processes
   - Verify JSON message integrity
   - Test reconnection scenarios
   - Performance baseline

### Phase 2: Agent Mode (2 weeks)

**Goal**: Sub-niffler can receive and process task/ask requests.

1. **Agent Mode CLI**
   - Add `--agent-mode --agent-name <name>` flags
   - Read agent config from TOML
   - Validate agent exists and is properly configured
   - Initialize NATS connection

2. **NATS Subscription**
   - Subscribe to `niffler.agent.<name>.request`
   - Parse incoming task/ask messages
   - Validate message structure
   - Handle malformed messages gracefully

3. **Request Routing to API Worker**
   - Task request → create new conversation
   - Ask request → load existing conversation
   - Route through existing channel to API worker thread
   - API worker processes as normal (unchanged)

4. **Output Display**
   - Format: `[RECEIVED:TASK @agent] prompt` or `[RECEIVED:ASK @agent] prompt`
   - Stream API worker output to stdout
   - Show tool calls: `[TOOL: edit] file.nim`
   - Show results: `[TOOL RESULT] Success`
   - Completion: `[COMPLETED ✓]` or `[ERROR ✗]`

5. **Status Publishing**
   - Publish status updates during processing
   - Tool call notifications
   - Streaming chunk updates (optional)
   - Final completion/error status

6. **Response Publishing**
   - Publish final result to `niffler.agent.<name>.response`
   - Include conversation ID for ask requests
   - Include token usage statistics
   - Include tool execution results

7. **Tool Permission Enforcement**
   - Read `tool_permissions` from config
   - Before executing tool, check if allowed
   - Reject unauthorized tools with clear error
   - Report permission violations via status

8. **Heartbeat Publishing**
   - Publish heartbeat every 30 seconds
   - Include current status (idle/busy)
   - Include uptime and request count
   - Include current conversation ID if busy

### Phase 3: Master Mode (2 weeks)

**Goal**: Master can route requests to agents and manage their lifecycle.

1. **Master Mode CLI**
   - Add `--master` flag
   - Simplified input loop: read stdin, parse, route
   - No streaming output handling
   - Display routing confirmations and completions

2. **Input Parsing**
   - Parse `@agent:task: prompt` syntax
   - Parse `@agent:ask: prompt` syntax
   - Parse `@agent: prompt` (default to 'ask')
   - Fallback to default_agent or local processing

3. **Agent Routing** (`src/core/router.nim`)
   - Validate agent exists in config
   - Check if agent is running (via heartbeat)
   - Auto-start if needed and `auto_start = true`
   - Build appropriate task/ask message

4. **NATS Request/Reply**
   - Publish to `niffler.agent.<name>.request`
   - Subscribe to `niffler.agent.<name>.response`
   - Display: "→ Sent task to @coder"
   - Wait for response with timeout
   - Display: "✓ @coder completed" or "✗ @coder failed"

5. **Agent Management Commands**
   - `/agents list` - Query via NATS heartbeats
   - `/agents start <name>` - Spawn agent process
   - `/agents stop <name>` - Publish shutdown message
   - `/agents restart <name>` - Stop and start
   - `/agents health` - Show health status table

6. **Process Management** (`src/core/agent_manager.nim`)
   - Spawn agent processes: `niffler --agent-mode --agent-name <name>`
   - Track PIDs of spawned agents
   - Monitor agent health via heartbeats
   - Handle agent crashes and restarts

7. **Backward Compatibility**
   - Input without `@` → route to default_agent
   - Or process locally if no agents configured
   - Single-agent mode still works

### Phase 4: Agent Lifecycle (1-2 weeks)

**Goal**: Robust agent lifecycle management and health monitoring.

1. **Auto-Start Agents**
   - Master reads agents with `auto_start = true`
   - Spawn agents during master startup
   - Wait for heartbeats to confirm ready
   - Report startup failures

2. **Heartbeat Monitoring**
   - Subscribe to `niffler.agent.*.heartbeat` in master
   - Track last heartbeat time per agent
   - Detect stale agents (no heartbeat > threshold)
   - Mark agents as unhealthy

3. **Auto-Restart**
   - Detect agent crashes (process exit)
   - Detect agent hangs (heartbeat timeout)
   - Auto-restart if persistent agent
   - Report restart to user

4. **Graceful Shutdown**
   - Master publishes shutdown message to agent
   - Agent finishes current request
   - Agent cleans up: close DB, close NATS
   - Agent exits with status code 0

5. **Ephemeral vs Persistent Lifecycle**
   - Persistent: Stay running when idle
   - Ephemeral: Track idle time since last request
   - Ephemeral: Shutdown after `max_idle_seconds`
   - Master can respawn ephemeral agents on demand

6. **Conversation Context Management**
   - Task: Create new conversation each time
   - Ask: Load or create single active 'ask' conversation
   - Master can query agent's active conversation
   - Agent can reset conversation on `/reset` command

### Phase 5: Advanced Features (2-3 weeks)

**Goal**: Polish and unique multi-agent capabilities.

1. **Smart Routing**
   - Analyze prompt content
   - Match against agent capabilities
   - Suggest agent if no @ specified
   - "This looks like code review. Use @reviewer? (y/n)"

2. **Conversation Management**
   - Master can list active ask conversations per agent
   - Master can switch agent to new ask conversation
   - Master can view task history
   - Agent can summarize current context

3. **Multi-Agent Workflows**
   - Broadcast to multiple agents
   - Collect responses from all
   - Display aggregated results
   - Example: "@researcher,@coder: Find and implement feature X"

4. **Agent Chaining**
   - Sequential agent execution
   - Pass output from one to next
   - Example: "@researcher → @coder → @bash_helper: pipeline"
   - Master coordinates the chain

5. **Context Sharing**
   - Agent can request context from another agent
   - Published via NATS: `niffler.agent.<name>.context.request`
   - Use case: Coder reads researcher's findings
   - Permission-based access

6. **Observability and Monitoring**
   - NATS monitoring tool: subscribe to `niffler.>`
   - Log all agent traffic for debugging
   - Performance metrics dashboard
   - Token usage aggregation across agents

7. **Agent Specialization Templates**
   - System prompt templates per agent type
   - Loaded from config or separate files
   - Examples: "You are a code reviewer expert..."
   - Personality customization

8. **Tool Execution via NATS (Future)**
   - Optional: Dedicated tool executor process
   - Agents publish tool requests to NATS
   - Single executor handles all tool calls
   - Ultimate isolation and centralized control

## Implementation Components

### New Modules

**NATS Communication** (`src/core/nats_client.nim`):
```nim
type
  NatsConnection* = object
    socket: Socket
    subscriptions: Table[string, Channel[string]]
    connected: bool

  NatsMessage* = object
    subject*: string
    payload*: string
    replyTo*: Option[string]

proc connect*(url: string): NatsConnection {.gcsafe.}
proc publish*(conn: var NatsConnection, subject: string, payload: string) {.gcsafe.}
proc subscribe*(conn: var NatsConnection, subject: string): Channel[string] {.gcsafe.}
proc request*(conn: var NatsConnection, subject: string, payload: string, timeout: int): Option[string] {.gcsafe.}
proc close*(conn: var NatsConnection) {.gcsafe.}
```

**Agent Router** (`src/core/router.nim`):
```nim
type
  AgentRouter* = object
    natsConn: NatsConnection
    agents: Table[string, AgentConfig]
    activeAgents: HashSet[string]

  RouteRequest* = object
    agentName*: string
    requestType*: RequestType  # Task or Ask
    prompt*: string
    conversationId*: Option[string]

proc parseRouting*(input: string): Option[RouteRequest]
proc routeRequest*(router: var AgentRouter, req: RouteRequest): Future[string]
proc checkAgentHealth*(router: var AgentRouter, agentName: string): bool
proc autoStartAgent*(router: var AgentRouter, agentName: string): bool
```

**Agent Manager** (`src/core/agent_manager.nim`):
```nim
type
  AgentProcess* = object
    config*: AgentConfig
    pid*: int
    startTime*: DateTime
    lastHeartbeat*: DateTime
    status*: AgentStatus

  AgentStatus* = enum
    asStarting, asRunning, asIdle, asBusy, asUnhealthy, asStopped

proc startAgent*(config: AgentConfig): AgentProcess {.gcsafe.}
proc stopAgent*(agent: var AgentProcess) {.gcsafe.}
proc healthCheck*(agent: AgentProcess): bool {.gcsafe.}
proc restartAgent*(agent: var AgentProcess) {.gcsafe.}
proc monitorAgents*(manager: var AgentManager) {.gcsafe.}
```

**NATS Message Types** (`src/types/nats_messages.nim`):
```nim
type
  RequestType* = enum
    rtTask, rtAsk

  AgentRequest* = object
    requestType*: RequestType
    requestId*: string
    agentName*: string
    prompt*: string
    conversationId*: Option[string]
    context*: seq[Message]
    metadata*: Table[string, string]

  AgentResponse* = object
    requestId*: string
    agentName*: string
    content*: string
    conversationId*: string
    toolCalls*: seq[ToolCallResult]
    tokensUsed*: TokenUsage
    status*: ResponseStatus

  AgentStatus* = object
    requestId*: string
    agentName*: string
    status*: string
    data*: JsonNode
    timestamp*: DateTime

proc toJson*(req: AgentRequest): string
proc fromJson*(json: string): AgentRequest
```

**TOML Configuration** (`src/core/config_toml.nim`):
```nim
type
  TomlConfig* = object
    nats*: NatsConfig
    master*: MasterConfig
    agents*: seq[AgentConfig]
    models*: seq[ModelConfig]

  NatsConfig* = object
    server*: string
    timeoutMs*: int
    reconnectAttempts*: int

  MasterConfig* = object
    enabled*: bool
    defaultAgent*: string
    autoStartAgents*: bool

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

proc loadTomlConfig*(path: string): TomlConfig
proc migrateFromJson*(jsonPath: string, tomlPath: string)
proc validateConfig*(config: TomlConfig): bool
```

### Extensions to Existing Modules

**CLI Interface** - Master Mode (`src/ui/master_cli.nim`):
- Simplified input loop without streaming complexity
- Parse `@agent:task:` and `@agent:ask:` syntax
- Display routing confirmations
- Agent management commands
- Connection status display

**CLI Interface** - Agent Mode (`src/ui/agent_cli.nim`):
- Display incoming prompts with formatting
- Stream output from API worker to stdout
- Show tool executions clearly
- Completion status indicators
- Error reporting

**Database Schema** (`src/database/database.nim`):
- Add `agent_id` field to conversations
- Add `type` field (task/ask) to conversations
- Add `status` field to conversations
- Indexes for agent-based queries
- Queries for context loading by agent

**Main Entry** (`src/niffler.nim`):
- Add `--master` flag
- Add `--agent-mode --agent-name <name>` flags
- Add `--migrate-config` utility flag
- Route to appropriate mode (master/agent/single)

## Usage Examples

### Basic Setup

**Terminal 1: Start Master**
```bash
$ niffler --master
Master mode initialized
Auto-starting agents: coder, bash_helper
✓ @coder started (pid: 12345)
✓ @bash_helper started (pid: 12346)
Ready for commands (type /help for help)
>
```

**Terminal 2: Agent 'coder' Output**
```bash
$ niffler --agent-mode --agent-name coder
Agent 'coder' initialized (model: claude-3.5-sonnet)
Subscribed to: niffler.agent.coder.request
Ready for requests...
```

**Terminal 3: Agent 'bash_helper' Output**
```bash
$ niffler --agent-mode --agent-name bash_helper
Agent 'bash_helper' initialized (model: gpt-4o)
Subscribed to: niffler.agent.bash_helper.request
Ready for requests...
```

### Task vs Ask Examples

**Using Tasks (Isolated Context)**
```bash
# Terminal 1 (Master):
> @researcher:task: Find Nim async HTTP libraries

# Terminal 2 (@researcher):
[RECEIVED:TASK @researcher] Find Nim async HTTP libraries
[PROCESSING...]
I'll search for Nim async HTTP libraries...
Found several options:
1. std/asynchttpserver - Standard library async HTTP server
2. httpbeast - High-performance HTTP server
3. jester - Sinatra-like web framework
[COMPLETED ✓]

# New task - fresh context
> @researcher:task: What is NATS messaging?

# Terminal 2 (@researcher):
[RECEIVED:TASK @researcher] What is NATS messaging?
[PROCESSING...]
NATS is a lightweight, high-performance messaging system...
(No knowledge of previous HTTP library task - fresh context)
[COMPLETED ✓]
```

**Using Asks (Conversational Context)**
```bash
# Terminal 1 (Master):
> @coder:ask: Create a simple HTTP server in Nim

# Terminal 3 (@coder):
[RECEIVED:ASK @coder] Create a simple HTTP server in Nim
[PROCESSING...]
I'll create a simple async HTTP server using Nim's standard library...
[TOOL: create] src/server.nim
[TOOL RESULT] File created successfully
I've created an HTTP server that listens on port 8080...
[COMPLETED ✓]

# Follow-up ask - continues context
> @coder:ask: Add logging to the server

# Terminal 3 (@coder):
[RECEIVED:ASK @coder] Add logging to the server
[PROCESSING...] (continuing conversation)
I'll add logging to the HTTP server we just created...
[TOOL: edit] src/server.nim
[TOOL RESULT] File edited successfully
Added logging using Nim's logging module, logging requests...
[COMPLETED ✓]

# Another follow-up - still same context
> @coder:ask: Now add error handling for port already in use

# Terminal 3 (@coder):
[RECEIVED:ASK @coder] Now add error handling for port already in use
[PROCESSING...] (continuing conversation)
I'll add error handling to our server for the port binding...
[TOOL: edit] src/server.nim
[TOOL RESULT] File edited successfully
Added try-catch around port binding with helpful error message...
[COMPLETED ✓]
```

### Multi-Agent Workflow

**Research → Design → Implement → Test Pipeline**
```bash
# Terminal 1 (Master):
> @researcher:task: Find best practices for HTTP streaming in Nim

# Terminal 2 (@researcher) - displays findings...
[RECEIVED:TASK] ...
[COMPLETED ✓]

> @coder:ask: Based on the researcher's findings, implement HTTP streaming

# Terminal 3 (@coder) - implements based on research...
[RECEIVED:ASK] ...
[TOOL: create] src/streaming.nim
[COMPLETED ✓]

> @bash_helper:task: Test the HTTP streaming implementation

# Terminal 4 (@bash_helper) - runs tests...
[RECEIVED:TASK] ...
[TOOL: bash] nim c -r tests/test_streaming.nim
[TOOL RESULT] All tests passed
[COMPLETED ✓]
```

### Agent Management

**Managing Agents**
```bash
> /agents list
┌─────────────┬────────────┬───────────┬───────────────┬──────────┐
│ Agent       │ Status     │ Model     │ Uptime        │ Requests │
├─────────────┼────────────┼───────────┼───────────────┼──────────┤
│ coder       │ idle       │ sonnet    │ 1h 23m        │ 15       │
│ bash_helper │ busy       │ gpt-4o    │ 1h 23m        │ 8        │
│ researcher  │ stopped    │ haiku     │ -             │ -        │
└─────────────┴────────────┴───────────┴───────────────┴──────────┘

> /agents start researcher
Starting agent 'researcher'...
✓ Started (pid: 12347)

> /agents stop bash_helper
Stopping agent 'bash_helper'...
✓ Stopped gracefully

> /agents health
All agents healthy (2/3 running)
```

**Resetting Conversation Context**
```bash
# Master can reset an agent's ask conversation
> @coder:reset
✓ @coder conversation context reset

# Next ask will start fresh
> @coder:ask: Create a new project
[Fresh context - no memory of previous conversation]
```

## Technical Considerations

### Nim-Specific Advantages

**Memory Safety**: Nim's deterministic memory management is ideal for long-running agent processes - no garbage collection pauses affecting responsiveness.

**Threading Model**: Current threading architecture with channels easily extends to NATS - same patterns, different transport.

**Compilation Speed**: Fast compilation enables quick agent deployment, updates, and restarts during development.

**Low Resource Usage**: Nim's efficiency means multiple agents can run simultaneously without excessive resource consumption.

**Type Safety**: Compile-time type checking helps prevent IPC protocol errors.

### Performance Considerations

**NATS Latency**: Local NATS adds ~1-2ms latency vs direct channels, negligible compared to LLM API calls (100-1000ms).

**Message Overhead**: JSON serialization adds minimal overhead for LLM-scale payloads.

**Connection Pooling**: NATS client maintains persistent connections, no per-message setup cost.

**Heartbeat Overhead**: 30-second heartbeat interval is lightweight (tiny message every 30s per agent).

**Process Isolation**: Each agent in separate process means no GC contention, better CPU cache utilization.

### Security Considerations

**Process Isolation**: Each agent runs in separate process space - OS-level security boundary.

**Tool Permissions**: Fine-grained control per agent - researcher can't run bash, bash_helper can't edit files.

**NATS Security**: Can add NATS authentication/authorization later for distributed deployments.

**Input Validation**: All NATS messages validated before processing, malformed messages rejected.

**Conversation Isolation**: Database queries scoped by agent_id, agents can't access each other's data.

### Scalability Considerations

**Horizontal Scaling**: NATS supports clustering - can distribute agents across machines later.

**Load Balancing**: Can run multiple instances of same agent type, master load-balances.

**Resource Limits**: Can apply cgroups limits per agent process for resource control.

**Database Scaling**: SQLite sufficient for single-machine, can migrate to PostgreSQL for multi-machine.

## Migration Path

### Phase 0: Configuration
1. TOML support added alongside JSON
2. `niffler --migrate-config` utility provided
3. Both formats work during transition
4. Documentation guides migration

### Phase 1-2: Agent Mode
1. Add agent mode to niffler binary
2. Agents can run standalone
3. No impact on existing single-agent usage
4. Users can experiment with agents

### Phase 3-4: Master Mode
1. Add master mode
2. Full multi-agent orchestration available
3. Single-agent mode still default
4. Users opt-in to multi-agent

### Backward Compatibility

**Single-Agent Mode Preserved**: Running `niffler` without flags continues to work exactly as before - no breaking changes.

**Gradual Adoption**: Users can start with master + one agent, expand as needed.

**Configuration Evolution**: JSON configs continue to work, TOML optional but recommended.

## Future Extensions

### Advanced Agent Capabilities

**Agent Learning**: Agents can analyze their past task/ask conversations to identify patterns and improve.

**Context Summarization**: Long ask conversations can be summarized periodically to reduce token usage.

**Agent Specialization**: Agents develop expertise by accumulating domain-specific knowledge in their conversation history.

**Multi-Model Agents**: Single agent can switch models based on task complexity (Haiku for simple, Opus for complex).

### Distributed Deployment

**Network NATS**: NATS server on network, agents on different machines.

**Cloud Agents**: Some agents running in cloud for GPU access or API proximity.

**Agent Pools**: Multiple instances of same agent for load balancing.

**Failover**: Automatic failover to backup agents on failure.

### Advanced Orchestration

**Workflow Engine**: Define complex multi-agent workflows in config.

**Conditional Routing**: Route to agents based on prompt analysis and availability.

**Result Aggregation**: Combine results from multiple agents into coherent response.

**Agent Collaboration**: Agents can communicate directly without master mediation.

### Observability and Monitoring

**Metrics Dashboard**: Web UI showing agent health, throughput, token usage.

**Distributed Tracing**: Trace request flow across multiple agents.

**Performance Profiling**: Identify bottlenecks in agent processing.

**Cost Tracking**: Aggregate token usage and costs across all agents.

## Conclusion

This multi-agent architecture transforms Niffler from a single-agent CLI tool into a powerful multi-process agentic system with unique advantages:

1. **True Process Isolation**: OS-level separation for reliability and security
2. **Visible Workstreams**: Each agent's work displayed in own terminal for transparency
3. **Simplified Master**: Classic CLI without streaming complexity
4. **Task vs Ask**: Clear semantics for context management
5. **NATS Messaging**: Battle-tested infrastructure for IPC
6. **TOML Configuration**: Readable, structured agent definitions
7. **Persistent Specialization**: Agents build expertise over time
8. **Mix-and-Match Economics**: Optimize costs with different models per agent

The architecture leverages Niffler's existing strengths (threading, tool system, database) while providing a powerful, flexible multi-agent framework that maintains simplicity and reliability.
