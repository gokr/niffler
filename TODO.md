# Niffler TODO

Niffler is an AI-powered terminal assistant written in Nim with Plan/Code workflow.

## Recently Completed ✅

### **Master Mode (Phase 3.3)**
- ✅ Master mode CLI with NATS connection (`src/ui/master_cli.nim`)
- ✅ `@agent` routing syntax for directing requests to agents
- ✅ NATS request/reply with status updates and responses
- ✅ `/agents` command to list running agents via presence tracking
- ✅ Integrated into main CLI input loop

### **Conversation Condensation**
- ✅ `/condense` command for LLM-based conversation summarization
- ✅ Database schema with parent conversation linking
- ✅ Condensation module (`src/core/condense.nim`)
- ✅ Strategy framework (LLM summary implemented, truncate/smart_window planned)

### **MCP Integration**
- ✅ Model Context Protocol client implementation
- ✅ MCP worker thread with dedicated message processing
- ✅ Dynamic external tool loading from MCP servers
- ✅ Service discovery and configuration (src/mcp/*)
- ✅ Cross-thread accessibility with caching
- ✅ `/mcp status` command for monitoring

### **Task & Agent System**
- ✅ Soft agent type system with markdown-based definitions (src/types/agents.nim)
- ✅ Default agents: general-purpose, code-focused (src/core/agent_defaults.nim)
- ✅ Tool access control for agent-based restrictions
- ✅ Task tool for autonomous agent execution (src/tools/task.nim)
- ✅ Task executor with isolated execution context (src/core/task_executor.nim)
- ⚠️ Basic conversation loop (tool execution integration still pending)

### **Todolist Tool**
- ✅ Database-backed todo persistence (src/tools/todolist.nim)
- ✅ Markdown checklist parsing and generation
- ✅ State tracking (pending, in_progress, completed, cancelled)
- ✅ Priority support (low, medium, high)
- ✅ Bulk update operations

### **CLI & Output Improvements**
- ✅ Buffered streaming output with user input display
- ✅ Tool visualization with progress indicators
- ✅ Thinking token display and storage
- ✅ Enhanced markdown rendering

### **Database & Persistence**
- ✅ Conversation tracking with metadata
- ✅ Message persistence with basic tool call support
- ✅ Token usage logging and cost tracking
- ✅ Thinking token storage (conversation_thinking_token table)
- ✅ Todo system database schema

## Remaining Tasks

### **1. Complete Task Tool Integration (Phase 0)** *(CRITICAL PRIORITY - BLOCKS ALL MULTI-AGENT)*

**Current Status:** Framework exists, tool execution blocked by circular imports. This is a prerequisite for all multi-agent work.

**Documented in:** doc/TASK.md (comprehensive implementation guide)

**Tasks:**

- [x] **1.1 Resolve circular import issues** (`src/core/task_executor.nim`)
      - ✅ COMPLETED: Tool execution via channels (lines 329-383)
      - ✅ Uses existing tool worker with thread-safe communication
      - ✅ No circular dependency - clean architecture

- [x] **1.2 Integrate tool execution into task conversation loop** (`src/core/task_executor.nim:308-386`)
      - ✅ COMPLETED: Full tool execution loop implemented
      - ✅ Tool call collection from LLM responses (lines 262-266)
      - ✅ Tool access validation against agent.allowedTools (lines 318-327)
      - ✅ Tool execution via tool worker (lines 329-383)
      - ✅ Tool result formatting and conversation continuation (lines 358-385)
      - ✅ Graceful error handling for tool failures

- [x] **1.3 Extract artifacts from task conversations**
      - ✅ COMPLETED: `extractArtifacts()` function implemented (lines 25-62)
      - ✅ Parses file operations (read, create, edit, list)
      - ✅ Extracts file paths from tool arguments
      - ✅ Returns sorted unique file paths
      - ✅ Called during task completion (line 402)

- [ ] **1.4 Task result visualization** (`src/ui/cli.nim`)
      - Render task results with formatting (success/failure, summary, artifacts, metrics)
      - Display artifacts as file paths
      - Show error details if failed
      - Note: Skip approval prompt and progress indicator (not needed for multi-process architecture)

- [x] **1.5 Test end-to-end task execution**
      - ✅ Unit test: tool call parsing and validation against whitelist
      - ✅ Unit test: artifact extraction from various tool calls
      - ✅ Unit test: tool access control enforcement (reject unauthorized)
      - ✅ Unit test: error handling (graceful failure, malformed data)
      - ✅ Unit test: TaskResult structure validation
      - ✅ Unit test: System prompt generation
      - ✅ All 8 tests passing in tests/test_task_execution.nim
      - Note: Full multi-turn execution tests with live LLM require manual testing

**Status:** ✅ PHASE 0 COMPLETE
**Complexity:** Medium-High (circular import resolved, architecture clean)
**Success Criteria:** ✅ Task can execute tool calls, receive results, continue conversation, and complete successfully with summary

### **2. User Message Queue**

**Message Queueing System:**
- [ ] Implement user message queue, we get queueing via NATS jetstream so we just need to visualize the ACK from the agent to know that it accepted the message
- [ ] Support message cancellation perhaps, at least until the agent has accepted the message?

**Current Status:** Not implemented.

### **3. Enhanced Message Persistence** *(MEDIUM PRIORITY)*

**Rich Metadata (Partially Implemented):**
- ⚠️ Extend tool call metadata tracking (basic schema exists in conversation_message.toolCalls)
- [ ] Track tool execution time, success/failure rates
- [ ] Add summary flags to mark condensed messages
- [ ] Support multiple content blocks per message

**Current Status:** Basic tool call storage exists but lacks rich metadata and summarization.

### **4. Advanced Context Management** *(MEDIUM PRIORITY)*

**User-Controlled Condensing:**
- [x] Implement a /condense command that takes a <strategy> parameter that controls how a new conversation is created from the current (and linked to parent)
      - ✅ COMPLETED: `/condense [strategy]` command in `src/ui/commands.nim`
      - ✅ LLM summary strategy implemented (`csLlmSummary` - default)
      - ✅ Database schema extended with condensation support columns (`src/core/database.nim`)
      - ✅ Parent conversation linking and metadata tracking
      - ⚠️ `truncate` and `smart_window` strategies not yet implemented
- [ ] Create a /summarize tool that takes a <filename> parameter into which the conversation is summarized
- [ ] Provide context size warning

**Advanced @ Referencing:**
- ⚠️ Extend @ syntax for folder references (@folder/)
- ⚠️ Support glob patterns in @ references (@*.py, @src/*)
- [ ] Improve file completion search intelligence

**Current Status:** Basic file completion exists (src/ui/file_completion.nim) but no folder/glob pattern support.

### **5. Multi-Config System** *(MEDIUM PRIORITY)*

**Three-Model Configs:**
- [ ] Plan model with default reasoning level
- [ ] Code model optimized for implementation
- [ ] Fast tool model for quick operations

**Hotkey Support:**
- [ ] Switch config (rotate among full configs)

**Dynamic System Prompt Selection:**
- [ ] Analyze prompt using fast model
- [ ] Select appropriate system prompt based on context
- [ ] Multiple specialized system prompts available

**Current Status:** Basic model switching exists via `/model` command but no hotkey support or multi-config profiles.

### **6. UI/UX Polish** *(MEDIUM PRIORITY)*

**Enhanced Help System:**
- [ ] Update `/help` command for Plan/Code workflow
- [ ] Add contextual help for current mode
- [ ] Document plan mode file protection behavior

**Status Indicators:**
- ⚠️ Show current model in prompt (partially implemented)
- [ ] Display token count and context window usage

**Custom Slash Commands:**
- [ ] Support user-defined slash commands
- [ ] Command registration and dispatch system
- [ ] Parameterized command support

**Current Status:** Basic commands exist (src/ui/commands.nim) but no user-defined command support.

### **7. Advanced Features** *(LOW PRIORITY)*

**Content Visualization:**
- [ ] Use delta for git-style diff visualization
- [ ] Use batcat for enhanced content display
- [ ] Configurable external renderers

**Context Squashing:**
- [ ] `/squash` command for context compression
- [ ] Start new chat after heavy plan building
- [ ] Preserve important context during squash

**Sub-Task Spawning:**
- ⚠️ Task tool provides delegation (src/tools/task.nim)
- [ ] Support recursive task spawning with depth limits
- [ ] Automatic context inheritance from parent task

### **8. Provider Support** *(LOW PRIORITY)*

**Anthropic Integration:**
- ⚠️ Thinking token support exists via OpenAI-compatible API
- [ ] Add dedicated Claude API client
- [ ] Create unified provider interface
- [ ] Add provider-specific optimizations

### **9. Thread Channel Communication Optimization** *(MEDIUM PRIORITY)*

**Background:** Currently uses polling with artificial delays (doc/THREADS.md)

**Missing:**
- [ ] Replace `tryReceive` + `sleep(10)` in API worker (src/api/worker.nim:80)
- [ ] Replace `tryReceive` + `sleep(10)` in tool worker (src/tools/worker.nim:60)
- [ ] Replace `sleep(5)` in CLI response polling (src/ui/cli.nim:314)
- [ ] Use blocking `receive` or timeout-based blocking instead
- [ ] Maintain graceful shutdown capabilities

**Expected Impact:** 20-50ms latency reduction per multi-turn conversation

**Current Status:** Documented analysis complete (doc/THREADS.md), implementation pending

### **10. Advanced File Features** *(LOW PRIORITY)*

- [ ] Advanced change detection with timestamps
- [ ] Enhanced git integration for repository awareness
- [ ] Session save/restore functionality
- [ ] Export capabilities for conversations (current: SQLite database access)

### **11. Multi-Process Agent Architecture (Phase 3)** *(HIGH PRIORITY)*

**Prerequisites:** Phase 0 (Task Tool Integration) must be complete

**Goal:** Enable process-per-agent architecture with NATS messaging for true isolation, per-agent visibility, and distributed potential

**Documented in:** doc/TASK.md (unified multi-agent architecture)

**Architecture:**
- **Master Niffler**: Coordinator CLI with `@agent` routing syntax (no `--agent` flag)
- **Agent Niffler**: Dedicated process per agent (started with `--agent <name>` flag)
- **NATS Message Bus**: Inter-process communication via **gokr/natswrapper**
- **Task vs Ask Model**: Ask (default) = `@agent prompt`; Task = `@agent /task prompt`
- **Visibility**: Each agent displays work in own terminal window

**Design Principles:**
- **No single-process mode**: Only multi-process architecture
- **Task and Ask semantics**: Task for isolation, Ask for conversation
- **Minimal viable**: One master + one agent is the baseline

#### **Phase 3.1: NATS Communication Layer** ✅ **COMPLETE**

**Using:** https://github.com/gokr/natswrapper (NOT nim-nats)

- [x] **3.1.1 NATS Client Integration** (`src/core/nats_client.nim` - 229 lines)
      - ✅ Wraps natswrapper for Niffler's multi-agent communication
      - ✅ Connection management (initNatsClient, close)
      - ✅ Publish/subscribe primitives (publish, subscribe, nextMsg)
      - ✅ Request/reply pattern support (request)
      - ✅ JetStream KV presence tracking (sendHeartbeat, isPresent, listPresent, removePresence)
      - ✅ 15-second TTL for auto-expiring heartbeats
      - ✅ Synchronous subscriptions with timeout support
      - ✅ Path configured in config.nims for natswrapper import

- [x] **3.1.2 Message Type Definitions** (`src/types/nats_messages.nim` - ~60 lines)
      - ✅ **Simplified protocol** with single generic Request type (agent parses commands)
      - ✅ **Automatic JSON serialization** via Sunny `{.json:}` pragmas (no manual toJson/fromJson)
      - ✅ NatsRequest (requestId, agentName, input) - agent parses /plan, /task, /model from input
      - ✅ NatsResponse (requestId, content, done flag for streaming)
      - ✅ NatsStatusUpdate (requestId, agentName, status)
      - ✅ NatsHeartbeat (agentName, timestamp)
      - ✅ Convenience creation functions (createRequest, createResponse, etc.)
      - ✅ String conversion operators for debugging

- [x] **3.1.3 NATS Integration Tests** (20 tests passing)
      - ✅ Message serialization tests (`tests/test_nats_messages.nim` - 10 tests)
        - Round-trip serialization for all message types
        - Special character handling
        - Empty content preservation
      - ✅ Client integration tests (`tests/test_nats_integration.nim` - 10 tests)
        - Publish/subscribe between clients
        - Subscription timeout handling
        - Presence tracking with JetStream KV
        - NatsRequest/NatsResponse serialization over NATS
        - Multi-client communication
      - ✅ Graceful skip if NATS server not running

**Deliverable:** ✅ Working NATS communication layer with natswrapper and comprehensive test coverage

#### **Phase 3.2: Agent Mode (Sub-Niffler)** ✅ **COMPLETE**

**Goal:** Long-running agent processes that display work transparently

- [x] **3.2.0 Shared Command Parser** (`src/core/command_parser.nim` - 106 lines)
      - ✅ Parses `/plan`, `/code`, `/task`, `/ask`, `/model <name>` commands
      - ✅ Handles combined commands: `/plan /model haiku Create tests`
      - ✅ Extracts prompt text after commands
      - ✅ Returns structured ParsedCommand type
      - ✅ Shared by both agent and master modes
      - ✅ 17 tests passing (`tests/test_command_parser.nim`)

- [x] **3.2.1 Agent Mode CLI** (`src/ui/agent_cli.nim` - 278 lines)
      - ✅ Added `--agent <name>` and `--nats <url>` flags to niffler.nim
      - ✅ Load agent definition from ~/.niffler/agents/<name>.md
      - ✅ Initialize NATS connection with presence tracking
      - ✅ Subscribe to `niffler.agent.<name>.request` subject
      - ✅ Display agent info on startup (name, model, tools, listening subject)
      - ✅ Database and channel initialization

- [x] **3.2.2 Request Processing** (`src/ui/agent_cli.nim`)
      - ✅ Parse incoming NatsRequest messages from NATS
      - ✅ Use shared command parser to extract commands from input
      - ✅ Display: `[REQUEST] prompt` when received
      - ✅ **Task handling**: Execute via task_executor with fresh context
      - ✅ **Ask handling**: TODO - continue conversation (placeholder implemented)
      - ✅ Route to task executor with agent definition and tool schemas
      - ✅ Handle mode switches (/plan, /code) via command parser
      - ✅ Handle model switches (/model <name>) via command parser
      - ✅ Comprehensive error handling

- [x] **3.2.3 Status and Response Publishing** (`src/ui/agent_cli.nim`)
      - ✅ Publish status updates to `niffler.master.status`
      - ✅ sendStatusUpdate() for state changes
      - ✅ Publish responses to `niffler.master.response`
      - ✅ sendResponse() with streaming support (done flag)
      - ✅ Include requestId for correlation
      - ✅ Send task results with summary and artifacts
      - ✅ Display "Waiting for requests..." status

- [x] **3.2.4 Heartbeat Publishing** (`src/ui/agent_cli.nim`)
      - ✅ Publish heartbeat every 5 seconds to JetStream KV presence store
      - ✅ Uses sendHeartbeat() from nats_client
      - ✅ 15-second TTL for auto-expiration on crash
      - ✅ publishHeartbeat() proc integrated in main loop
      - ✅ Graceful removal on shutdown via removePresence()

- [x] **3.2.5 Tool Permission Enforcement** (task_executor integration)
      - ✅ Tool access validation via AgentContext and isToolAllowed()
      - ✅ Rejects unauthorized tools with error message
      - ✅ Uses agent.allowedTools from definition
      - ✅ Integrated with existing task_executor

- [x] **3.2.6 Sample Agent Definitions**
      - ✅ `~/.niffler/agents/coder.md` - Full access (read, create, edit, bash, list, fetch)
      - ✅ `~/.niffler/agents/researcher.md` - Read-only (read, list, fetch)

**Deliverable:** ✅ Agent processes ready to receive NATS requests and display work

**Usage:**
```bash
./src/niffler --agent coder              # Start coder agent
./src/niffler --agent researcher --model haiku  # Research agent with specific model
```

#### **Phase 3.3: Master Mode** ✅ **CORE COMPLETE**

**Goal:** Coordinator that routes requests to agents and manages lifecycle

**Current Status:** Core master mode implemented! Master can route requests to agents via NATS.

**What's Working:**
- ✅ Agents can start and listen: `./src/niffler --agent coder`
- ✅ Agents can receive NatsRequest messages via NATS
- ✅ Agents parse commands and execute tasks
- ✅ Agents send NatsResponse messages back
- ✅ Agents publish heartbeats for presence tracking
- ✅ **Master mode integrated into CLI with @agent routing**
- ✅ **Master mode discovers agents via NATS presence**
- ✅ **Master mode sends requests and receives responses**
- ✅ **`/agents` command to list running agents**

**Minimal Viable Goal:** ✅ Agent in one terminal, master in another, communicate via NATS

- [x] **3.3.1 Master Mode CLI** (`src/ui/master_cli.nim` - 301 lines)
      - ✅ Detect master mode: no `--agent` flag specified
      - ✅ Initialize NATS connection in CLI startup
      - ✅ Display agent discovery on startup
      - ✅ MasterState object with NATS client, pending requests tracking

- [x] **3.3.2 Input Parsing and Routing** (`src/ui/master_cli.nim`)
      - ✅ Parse `@agent prompt` syntax via `parseAgentInput()`
      - ✅ Parse `@agent /task prompt` for task requests
      - ✅ Validate agent exists before routing via `isAgentAvailable()`
      - ⚠️ Default agent fallback not yet implemented
      - ⚠️ Tab completion for agent names not yet implemented

- [x] **3.3.3 NATS Request/Reply** (`src/ui/master_cli.nim`)
      - ✅ Build NatsRequest with generated requestId
      - ✅ Publish to `niffler.agent.<name>.request`
      - ✅ Subscribe to `niffler.master.response` for responses
      - ✅ Subscribe to `niffler.master.status` for status updates
      - ✅ Display routing confirmation: "→ Sending to @agent..."
      - ✅ Wait for response with 30s timeout
      - ✅ Display completion: "✓ @agent completed" or "✗ @agent failed"
      - ✅ Show agent response content

- [ ] **3.3.4 Agent Auto-Start** (`src/core/agent_manager.nim` - new file)
      - Read agents with `auto_start: true` from config on master startup
      - Spawn agent processes: `niffler --agent <name>` (fork/exec)
      - Track PIDs of spawned agents in AgentProcess table
      - Wait for heartbeats to confirm agents ready (max 10s)
      - Report startup: "✓ @coder started (pid: 12345)"
      - Report failures: "✗ @coder failed to start"

- [x] **3.3.5 Agent Management Commands** (`src/ui/commands.nim`)
      - ✅ `/agents` - Query active agents via NATS heartbeats
      - ⚠️ `/agents start <name>` - Not yet implemented
      - ⚠️ `/agents stop <name>` - Not yet implemented
      - ⚠️ `/agents restart <name>` - Not yet implemented
      - ⚠️ Tab completion for agent names - Not yet implemented

**Deliverable:** ✅ Master coordinates agent processes via NATS

**Usage:**
```bash
# Terminal 1: Start an agent
./src/niffler --agent coder

# Terminal 2: Start master mode (default)
./src/niffler

# In master mode, route to agents:
@coder fix the bug in main.nim
@coder /task refactor the database module

# Check available agents:
/agents
```

#### **Phase 3.4: Process Management** *(1 week)*

**Goal:** Robust agent lifecycle with health monitoring

- [ ] **3.4.1 Process Spawning** (`src/core/agent_manager.nim`)
      - AgentProcess type (config, pid, startTime, lastHeartbeat, status)
      - AgentStatus enum (asStarting, asRunning, asIdle, asBusy, asUnhealthy, asStopped)
      - startAgent() proc: fork/exec `niffler --agent <name>`
      - Track PID and start time
      - Set initial status: asStarting
      - Handle fork/exec failures gracefully

- [ ] **3.4.2 Heartbeat Monitoring** (`src/core/agent_manager.nim`)
      - Subscribe to `niffler.agent.*.heartbeat` wildcard subject
      - Track last heartbeat time per agent in AgentProcess table
      - Update status based on heartbeat content (idle → asIdle, busy → asBusy)
      - Detect stale agents: no heartbeat > 90s threshold
      - Mark stale agents as asUnhealthy
      - Display warnings in `/agents health` command

- [ ] **3.4.3 Auto-Restart** (`src/core/agent_manager.nim`)
      - Detect agent crashes: process exit via waitpid
      - Detect agent hangs: heartbeat timeout (>90s)
      - Auto-restart if agent config has `persistent: true`
      - Don't restart if agent config has `persistent: false` (ephemeral)
      - Report restart to user: "⚠ @coder crashed, restarting..."
      - Limit restart attempts: max 3 retries within 5 minutes

- [ ] **3.4.4 Graceful Shutdown** (`src/core/agent_manager.nim` and `src/ui/agent_cli.nim`)
      - Master: publish shutdown message to `niffler.agent.<name>.shutdown`
      - Agent: subscribe to shutdown subject
      - Agent: finish current request if busy (don't interrupt mid-request)
      - Agent: clean up resources (close database, close NATS)
      - Agent: exit with status code 0
      - Master: wait for process exit (max 10s)
      - Master: SIGKILL if timeout exceeded

- [ ] **3.4.5 Ephemeral vs Persistent Lifecycle** (`src/core/agent_manager.nim`)
      - Persistent agents (`persistent: true`): stay running when idle
      - Ephemeral agents (`persistent: false`): track idle time since last request
      - Ephemeral: shutdown after `max_idle_seconds` config value
      - Master can respawn ephemeral agents on demand
      - Master displays agent lifecycle policy in `/agents list`

**Deliverable:** Robust process lifecycle management

#### **Phase 3.5: Configuration and Database** *(1 week)*

- [ ] **3.5.1 YAML Config Extension** (`src/core/config_yaml.nim`)
      - Parse `nats:` section (server URL, timeout_ms, reconnect_attempts, reconnect_delay_ms)
      - Parse `master:` section (default_agent, auto_start_agents, heartbeat_check_interval)
      - Parse `agents:` array with full AgentConfig
      - AgentConfig: id, name, description, model, capabilities, toolPermissions, autoStart, persistent, maxIdleSeconds
      - Validate NATS server URL format
      - Note: Always multi-process mode, no single-process fallback

- [ ] **3.5.2 Database Schema Extensions** (`src/core/database.nim`)
      - Add `agent_id` TEXT field to conversations table (which agent owns conversation)
      - Add `type` TEXT field to conversations table ('task' or 'ask')
      - Add `status` TEXT field to conversations table ('active', 'completed')
      - Add `request_id` TEXT field to link to NATS request
      - Add indexes: idx_conversations_agent, idx_conversations_type, idx_conversations_status
      - Update conversation creation to include agent_id and type
      - Add queries: createTaskConversation(agentId, requestId), loadAskConversation(agentId, conversationId)

- [ ] **3.5.3 Conversation Context Management** (`src/core/task_executor.nim` and agent state)
      - **Task requests**: Create new conversation (type='task', fresh context, no history loaded)
      - **Ask requests**: Load/continue conversation (type='ask', with history)
        - If conversationId provided: load that specific conversation
        - If no conversationId: load/create agent's current ask conversation
      - Agent tracks currentConversationId in memory
      - Store conversation with agent_id, type, and request_id
      - Store all messages in conversation for audit/debugging
      - Mark conversation as 'completed' when finished
      - Task completion restores previous conversation context

- [ ] **3.5.4 Migration Utilities** (`src/core/config.nim`)
      - `niffler --migrate-config` command to convert existing configs
      - Add NATS and master sections with sensible defaults
      - Preserve existing model configurations
      - Create example agent configurations in ~/.niffler/agents/
      - Document migration process in README

**Deliverable:** Full configuration and persistence support

#### **Phase 3.6: Integration and Testing** *(1 week)*

- [ ] **3.6.1 End-to-End Multi-Process Tests**
      - Test: Master starts, spawns agents, agents become ready
      - Test: Master routes task request, agent processes, returns result
      - Test: Multiple sequential tasks to same agent (fresh context each time)
      - Test: Agent crash, master detects and restarts
      - Test: Agent heartbeat timeout, master marks unhealthy
      - Test: Graceful shutdown, all agents cleanup correctly
      - Test: Tool access control across process boundary
      - Test: Multiple concurrent requests to different agents

- [ ] **3.6.2 Documentation**
      - Update TASK.md with multi-process usage examples
      - Create NATS_SETUP.md with server installation guide
      - Document master/agent CLI usage
      - Document agent configuration format
      - Add troubleshooting guide (NATS connection, agent crashes, etc.)
      - Update main README with multi-process mode

- [ ] **3.6.3 Example Configuration**
      - Create example config.yaml with NATS settings
      - Example: 3 agents (coder, researcher, bash_helper)
      - Different models per agent (optimize costs)
      - Different tool permissions per agent
      - Mix of auto-start and manual agents
      - Mix of persistent and ephemeral agents

**Estimated Total Effort:** 4-6 weeks
**Complexity:** High (IPC, process management, lifecycle, failure handling)
**Success Criteria:** Master spawns agents, routes via NATS, monitors health, agents display work in separate terminals

## Documentation Cleanup *(LOW PRIORITY)*

- [ ] Expand doc/MODELS.md into full model configuration guide (currently just JSON snippet)
- [ ] Update doc/CCPROMPTS.md with context about Niffler's cc config usage
- [ ] Audit doc/CONFIG.md for path consistency (verify no intermediate `config/` paths)
- [ ] Move doc/OCTO-THINKING.md to doc/research/ with context note (analyzes Octofriend, not Niffler)
- [ ] Add header to doc/STREAM-BPE.md clarifying it's background education
- [ ] Update or archive doc/MULTIAGENT.md as "future vision" vs current implementation

## Fun Easter Eggs *(LOW PRIORITY)*

- [ ] `/niffler` - ASCII art niffler creature
- [ ] `/coffee` - Coffee break messages
