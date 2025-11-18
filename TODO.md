# Niffler TODO

Niffler is an AI-powered terminal assistant written in Nim with Plan/Code workflow.

## Recently Completed ✅

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

- [ ] **1.1 Resolve circular import issues** (`src/core/task_executor.nim`)
      - Problem: task_executor.nim cannot import tool execution logic (circular dependency)
      - Solution: Extract tool execution interface to `src/tools/execution_interface.nim`
      - Define ToolExecutor trait/interface with execute() method
      - Use dependency injection pattern: pass tool executor callback to executeTask()
      - Update lines 27-35 (placeholder implementations) with actual interface

- [ ] **1.2 Integrate tool execution into task conversation loop** (`src/core/task_executor.nim:244-258`)
      - When LLM returns tool calls in response, collect them
      - For each tool call: validate against agent.allowedTools whitelist
      - Execute allowed tools via tool worker (reuse existing worker)
      - Reject unauthorized tools with clear error message
      - Format tool results as messages (role: tool, content: result JSON)
      - Append tool result messages to conversation history
      - Continue conversation loop with tool results until task completes
      - Handle tool execution errors gracefully (don't crash task)

- [ ] **1.3 Extract artifacts from task conversations**
      - Parse tool calls for file operations (read, create, edit, list)
      - Extract file paths from tool call arguments
      - Track unique file paths in TaskResult.artifacts seq[string]
      - Include artifact list in task summary for main agent
      - Display artifacts in UI when showing task results

- [ ] **1.4 Task result visualization** (`src/ui/cli.nim`)
      - Display task approval prompt: agent name, description, tools allowed, estimated complexity
      - Show task progress indicator during execution (spinner or dots)
      - Render task results with formatting (success/failure, summary, artifacts, metrics)
      - Display artifacts as file paths (with click support if terminal supports it)
      - Show error details if task failed

- [ ] **1.5 Test end-to-end task execution**
      - Unit test: tool call parsing and validation against whitelist
      - Unit test: artifact extraction from various tool calls
      - Integration test: multi-turn task with 3+ tool calls
      - Integration test: tool access control enforcement (reject unauthorized)
      - Integration test: error handling (tool execution failure, LLM error)
      - Stress test: concurrent task execution (multiple tasks simultaneously)
      - Verify result condensation works correctly (summary generation)

**Estimated Effort:** 3-5 days
**Complexity:** Medium-High (circular import = architectural change)
**Success Criteria:** Task can execute tool calls, receive results, continue conversation, and complete successfully with summary

### **2. User Message Queue & Always-There Input** *(HIGH PRIORITY)*

**Message Queueing System:**
- [ ] Implement user message queue for background processing
- [ ] Queue multiple user inputs while model is responding
- [ ] Handle queue priority and ordering
- [ ] Support message cancellation and reordering
- [ ] Prevent message loss during streaming

**Always-There Input Prompt:**
- [ ] Visual indicator for queued messages

**Input State Management:**
- [ ] Track input state across conversation turns
- [ ] Preserve partial input during interruptions
- [ ] Auto-save draft messages

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
- [ ] Implement a /condense command that takes a <strategy> parameter that controls how a new conversation is created from the current (and linked to parent)
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
- [ ] Switch model (rotate within current mode)
- [ ] Switch plan/code mode (currently requires `/plan` and `/code` commands)
- [ ] Switch config (rotate among full configs)
- [ ] Switch reasoning level

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
- [ ] Add connection status indicators

**History Navigation:**
- ⚠️ Basic history exists via linecross
- [ ] Add search functionality in command history
- [ ] Persist command history across sessions

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

#### **Phase 3.1: NATS Communication Layer** *(1 week)*

**Using:** https://github.com/gokr/natswrapper (NOT nim-nats)

- [ ] **3.1.1 NATS Client Integration** (`src/core/nats_client.nim`)
      - Replace nim-nats references with gokr/natswrapper
      - Implement NatsConnection type wrapping natswrapper
      - Connection management with auto-reconnect
      - Publish/subscribe primitives
      - Request/reply pattern support
      - Subject-based routing helpers (`niffler.agent.<name>.*`)
      - Error handling and timeouts
      - Connection pooling if needed

- [ ] **3.1.2 Message Type Definitions** (`src/types/nats_messages.nim`)
      - Complete JSON serialization for all message types (already started)
      - Add deserialization functions (currently missing): fromJson() for each type
      - Implement message validation helpers
      - Define TaskRequest message (requestId, agentName, prompt, metadata)
      - Define AskRequest message (requestId, agentName, prompt, conversationId, metadata)
      - Define StatusUpdate message (status, data, timestamp)
      - Define Response message (requestId, success, summary, artifacts, toolCalls, tokensUsed, error)
      - Define Heartbeat message (status, uptime, requestsProcessed, currentRequestId)
      - Add error handling for malformed messages

- [ ] **3.1.3 NATS Integration Tests**
      - Test publish/subscribe between processes
      - Verify JSON message integrity (serialize → deserialize → compare)
      - Test reconnection scenarios (kill NATS server, restart)
      - Performance baseline (latency, throughput)
      - Require NATS server running for tests (`nats-server`)

**Deliverable:** Working NATS communication layer with natswrapper

#### **Phase 3.2: Agent Mode (Sub-Niffler)** *(1 week)*

**Goal:** Long-running agent processes that display work transparently

- [ ] **3.2.1 Agent Mode CLI** (`src/ui/agent_cli.nim` - new file)
      - Add `--agent <name>` flag to niffler.nim entry point
      - Load agent definition from ~/.niffler/agents/<name>.md
      - Validate agent exists and is properly configured
      - Initialize NATS connection to configured server
      - Subscribe to `niffler.agent.<name>.request` subject
      - Display agent info on startup (model, tools, status)

- [ ] **3.2.2 Request Processing** (`src/ui/agent_cli.nim`)
      - Parse incoming TaskRequest and AskRequest messages from NATS
      - Validate message structure (reject malformed)
      - Display: `[RECEIVED:TASK @agent] prompt` or `[RECEIVED:ASK @agent] prompt`
      - **Task handling**: Create new conversation (fresh context, no history loaded)
      - **Ask handling**: Load/continue conversation (conversationId or current ask conversation)
      - Track current conversation ID in agent state
      - Route to task/conversation executor
      - Stream LLM output to stdout (user sees live in agent terminal)
      - Display tool calls: `[TOOL: edit] file.nim`
      - Display tool results: `[TOOL RESULT] Success`
      - **Task completion**: Restore previous conversation context
      - **Ask completion**: Remain in current conversation

- [ ] **3.2.3 Status and Response Publishing** (`src/ui/agent_cli.nim`)
      - Publish status updates to `niffler.agent.<name>.status`
      - Status: processing, tool_call, streaming, completed, error
      - Include tool name and args in tool_call status
      - Publish final result to `niffler.agent.<name>.response`
      - Include requestId for correlation
      - Include token usage statistics
      - Include tool execution results and artifacts (files created/read)
      - Display completion: `[COMPLETED ✓]` or `[ERROR ✗]`

- [ ] **3.2.4 Heartbeat Publishing** (`src/ui/agent_cli.nim`)
      - Publish heartbeat every 30 seconds to `niffler.agent.<name>.heartbeat`
      - Include status: idle (waiting) or busy (processing)
      - Include uptime in seconds
      - Include requests processed count
      - Include current requestId if busy

- [ ] **3.2.5 Tool Permission Enforcement** (integrate with existing tool worker)
      - Before executing tool, check against agent.allowedTools
      - Reject unauthorized tools with clear error message
      - Report permission violations via status message
      - Continue conversation with error result (don't crash)

**Deliverable:** Agent processes that receive NATS requests and display work

#### **Phase 3.3: Master Mode** *(1-2 weeks)*

**Goal:** Coordinator that routes requests to agents and manages lifecycle

- [ ] **3.3.1 Master Mode CLI** (`src/ui/master_cli.nim` - new file)
      - Detect master mode: no `--agent` flag specified
      - Simplified input loop: read stdin, parse, route (no streaming output)
      - Initialize NATS connection
      - Load agent configurations from config
      - Display startup: "Master mode initialized"

- [ ] **3.3.2 Input Parsing and Routing** (`src/ui/master_cli.nim`)
      - Parse `@agent /task prompt` syntax (task request)
      - Parse `@agent prompt` syntax (ask request - default)
      - Fallback to default_agent if no `@agent` specified (from config)
      - Tab completion for agent names (from config)
      - Validate agent exists before routing

- [ ] **3.3.3 NATS Request/Reply** (`src/ui/master_cli.nim`)
      - Build TaskRequest or AskRequest message based on input syntax
      - Generate unique requestId (UUID)
      - For AskRequest: include conversationId if tracking agent conversations
      - Publish to `niffler.agent.<name>.request`
      - Subscribe to `niffler.agent.<name>.response` (with timeout)
      - Display routing confirmation: "→ Sent to @coder (task)" or "→ Sent to @coder (ask)"
      - Wait for response with 30s timeout (or configured timeout)
      - Display completion: "✓ @coder completed" or "✗ @coder failed/timeout"
      - Show condensed result summary with artifacts

- [ ] **3.3.4 Agent Auto-Start** (`src/core/agent_manager.nim` - new file)
      - Read agents with `auto_start: true` from config on master startup
      - Spawn agent processes: `niffler --agent <name>` (fork/exec)
      - Track PIDs of spawned agents in AgentProcess table
      - Wait for heartbeats to confirm agents ready (max 10s)
      - Report startup: "✓ @coder started (pid: 12345)"
      - Report failures: "✗ @coder failed to start"

- [ ] **3.3.5 Agent Management Commands** (`src/ui/master_cli.nim`)
      - `/agents list` - Query active agents via NATS heartbeats
      - `/agents start <name>` - Spawn agent process manually
      - `/agents stop <name>` - Publish graceful shutdown message
      - `/agents restart <name>` - Stop and start sequence
      - `/agents health` - Show health status table (nancy)
      - Tab completion for agent names

**Deliverable:** Master coordinates agent processes via NATS

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
