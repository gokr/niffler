# Niffler Multi-Agent Architecture

## Overview

This document outlines Niffler's multi-agent architecture using process-per-agent isolation with NATS messaging. The system uses a **soft agent type system** where agents are defined via markdown files in `~/.niffler/agents/`, making it user-extensible without code changes.

### Core Design Principles

1. **Process Isolation**: One agent = one persistent process for true fault isolation and visibility
2. **Markdown-Based Agents**: User-extensible agent definitions without code changes
3. **NATS Messaging**: Inter-process communication via **gokr/natswrapper**
4. **Minimal Viable**: One master + one agent is the baseline

### Task vs Ask Model

**Ask** (`@agent prompt`) - Default behavior
- Continues agent's current conversation context
- Agent builds on previous interactions within the same conversation
- Maintains context across multiple asks
- Agent stays in the conversation after responding
- Use case: Multi-step problems, refinement, iterative development
- Example: `@coder Build a simple HTTP server`

**Task** (`@agent /task prompt`)
- Creates fresh context for isolated execution
- Agent processes request independently without previous conversation history
- Returns result via NATS and restores previous conversation context
- Use case: One-off operations, isolated problems, research tasks
- Example: `@coder /task Research NATS libraries and tell me the best option`

**Key Points:**
- All conversations (both task and ask) are fully persisted to the database
- Any conversation can be resumed and continued
- Agents track their current conversation ID
- Task requests create isolated contexts but preserve conversation history for audit

### Architecture Components

```
┌─────────────────────────────────────────────────────────────┐
│                    Master Niffler Process                   │
│  - User interaction (stdin/stdout)                          │
│  - @agent routing syntax                                    │
│  - Agent lifecycle management                               │
│  - NATS client for request/reply                            │
└─────────────────────────────────────────────────────────────┘
                           │
                    NATS Message Bus
                (gokr/natswrapper)
                           │
         ┌─────────────────┴─────────────────┐
         │                                   │
┌────────▼────────┐             ┌───────────▼────────┐
│ Agent Process 1  │             │ Agent Process 2    │
│  (coder)         │             │  (researcher)      │
│                  │             │                    │
│ - Own terminal   │             │ - Own terminal     │
│ - NATS subscriber│             │ - NATS subscriber  │
│ - Task executor  │             │ - Task executor    │
│ - Tool worker    │             │ - Tool worker      │
└──────────────────┘             └────────────────────┘
```

## Current State Analysis

### What Exists ✅

**Task Framework (Partially Complete)**:
- ✅ Agent definitions: markdown-based soft types (`src/types/agents.nim`)
- ✅ Tool access control: whitelist enforcement ready
- ✅ Task executor: isolated context framework (`src/core/task_executor.nim`)
- ✅ Default agents: general-purpose, code-focused (`src/core/agent_defaults.nim`)
- ✅ Task tool: delegation mechanism (`src/tools/task.nim`)
- ✅ Database schema: conversation and message tracking

**NATS Infrastructure (Started)**:
- ⚠️ NATS client: basic wrapper exists, needs gokr/natswrapper integration (`src/core/nats_client.nim`)
- ⚠️ NATS messages: type definitions exist, we should use sunny for JSON serialization/deserialization (`src/types/nats_messages.nim`)
- ✅ YAML config: NATS server configuration support (`src/core/config_yaml.nim`)

### What's Missing ❌

**Phase 0 (Critical Blocker)**:
- ❌ Tool execution integration in task executor (line 244: "integration pending")
- ❌ Circular import resolution blocking tool calls from tasks
- ❌ Artifact extraction from task conversations
- ❌ Task result visualization in main conversation

**Phase 1 (Multi-Process)**:
- ❌ Master mode CLI: agent routing with `/<agent>` syntax
- ❌ Agent mode CLI: dedicated process per agent
- ❌ Process management: spawning, monitoring, health checks
- ❌ NATS communication: actual message passing via gokr/natswrapper
- ❌ Database schema: agent_id and request_id fields
- ❌ Agent lifecycle: auto-start, heartbeats, graceful shutdown

## Soft Agent Type System

### Agent Definition Format

Agents are defined via markdown files in `~/.niffler/agents/`. Each file must have three sections:

**Example: `~/.niffler/agents/general-purpose.md`**

```markdown
# General Purpose Agent

## Description
Safe research and analysis agent for gathering information without modifying the system.

## Allowed Tools
- read
- list
- fetch
- grep
- glob

## System Prompt

You are a research and analysis agent. Your role is to gather information, analyze code,
and provide comprehensive findings without making any modifications to the system.

### Your Capabilities
- Read and analyze files
- Search through codebases
- Fetch web content for research
- Explore directory structures

### Your Constraints
- You CANNOT edit or create files
- You CANNOT execute bash commands
- You CANNOT modify the system in any way
- You MUST return a concise summary of your findings

### Task Execution
When assigned a task, work autonomously to gather all relevant information, then provide
a clear summary with:
1. Key findings
2. Files/resources examined
3. Specific recommendations or answers
4. Any blockers or limitations encountered
```

### Default Agents Provided

**`general-purpose.md`**
- **Tools**: read, list, fetch, grep, glob
- **Purpose**: Research, analysis, information gathering
- **Constraints**: Cannot edit, create, or execute commands

**`code-focused.md`**
- **Tools**: read, list, fetch, grep, glob, create
- **Purpose**: Code generation, analysis, safe file creation
- **Constraints**: Cannot edit existing files or execute commands

### User-Defined Agents

Users can create custom agents by adding new markdown files to `~/.niffler/agents/`:
- `security-scanner.md` - Read-only security analysis with bash for safe scans
- `documentation-writer.md` - Read and create for documentation generation
- `test-runner.md` - Read and bash for test execution and reporting
- `api-tester.md` - Fetch and bash for API endpoint testing

### Agent Validation

**Validation checks**:
- ✓ Has `## Description` section
- ✓ Has `## Allowed Tools` section with at least one tool
- ✓ Has `## System Prompt` section
- ⚠ Warning if tools are not in registry (may be future tools)

**Status indicators** (in `/agent` command):
- ✓ (green) - Valid definition
- ✗ (red) - Parse error or missing required section
- ⚠ (yellow) - Valid but references unknown tools

### Agent Management Commands

**`/agent`** - Show table of all agents with status
```
┌────────────────────┬──────────────────────────────────┬───────┬────────┐
│ Name               │ Description                      │ Tools │ Status │
├────────────────────┼──────────────────────────────────┼───────┼────────┤
│ general-purpose    │ Research and analysis agent      │ 5     │ ✓      │
│ code-focused       │ Code generation and analysis     │ 6     │ ✓      │
│ my-custom-agent    │ Custom testing agent             │ 4     │ ✓      │
└────────────────────┴──────────────────────────────────┴───────┴────────┘
```

**`/agent <name>`** - Show detailed agent view
```
┌─ general-purpose ───────────────────────────────────────────────────────┐
│ Description: Research and analysis agent for gathering information      │
│              without modifying the system                               │
│                                                                          │
│ Allowed Tools: read, list, fetch, grep, glob                           │
│                                                                          │
│ Status: ✓ Valid                                                         │
│                                                                          │
│ File: ~/.niffler/agents/general-purpose.md                             │
└─────────────────────────────────────────────────────────────────────────┘
```

## Multi-Process Architecture

### Master Niffler: Coordinator Process

**Role**: Simplified CLI that routes user input to agents without streaming complexity.

**Startup**:
```bash
$ niffler  # No --agent flag = master mode
Master mode initialized
Auto-starting agents: coder, researcher
✓ @coder started (pid: 12345)
✓ @researcher started (pid: 12346)
Ready for commands (type /help for help)
>
```

**Workflow**:
1. Parse input for agent routing syntax:
   - `@coder prompt` - Ask request (default, continue conversation)
   - `@coder /task prompt` - Task request (fresh context)
2. Publish TaskRequest or AskRequest to NATS subject `niffler.agent.<name>.request`
3. Display routing confirmation: "→ Sent to @coder (task)" or "→ Sent to @coder (ask)"
4. Display result summary: "✓ @coder completed"

**No Streaming Output**: Master doesn't handle agent streaming - users see that in agent's terminal window.

**Agent Management Commands**:
```bash
/agent list          # Query active agents via NATS heartbeats
/agent start <name>  # Spawn new agent process
/agent stop <name>   # Send graceful shutdown message
/agent restart <name> # Stop and restart agent
```

**Default agent**: Input without `/agent` command routes to `default_agent` from config.

### Agent Niffler: Worker Processes

**Role**: Long-running specialist processes that display their work transparently.

**Startup**:
```bash
$ niffler --agent coder
Agent 'coder' initialized (model: claude-3.5-sonnet)
Subscribed to: niffler.agent.coder.request
Tools: read, list, create, edit, bash
Ready for requests...
```

**Process Architecture** (per agent):
```
┌─────────────────────────────────────┐
│ Agent Process: "coder"              │
├─────────────────────────────────────┤
│ Main Thread:                        │
│  - NATS subscriber                  │
│  - Display incoming prompts         │
│  - Display streaming output         │
│  - Publish status updates           │
├─────────────────────────────────────┤
│ API Worker Thread:                  │
│  - LLM communication                │
│  - Tool call orchestration          │
│  - Channel communication            │
├─────────────────────────────────────┤
│ Tool Worker Thread:                 │
│  - Execute tools                    │
│  - Validation and security          │
└─────────────────────────────────────┘
```

**NATS Integration**:
- Subscribe to `niffler.agent.<name>.request`
- Receive task requests
- Display prompts received to stdout
- Process via task executor (fresh context)
- Stream LLM output to stdout (user sees live)
- Publish status updates to `niffler.agent.<name>.status`
- Publish final result to `niffler.agent.<name>.response`
- Publish heartbeat to `niffler.agent.<name>.heartbeat` by integrating the presence example code from natswrapper (that implements heartbeat)

**Display Format**:
The output in an agent stdout will render much like it renders now in Niffler, but with the difference that:
1. The prompt coming from the master (or another agent) needs to be rendered in one color and prefixed with the name of the sender. Use "master:" for the master Niffler.
2. When a result has been reached we should also show that we are replying back to the agent that prompted us (or master). Like "Sent result to master" (or "Sent result to researcher" etc).

**Lifecycle**:
- Started once (manually or auto-started by master)
- Handles multiple requests over lifetime
- Tracks current conversation ID in memory
- **Task request handling**:
  - Creates new conversation (fresh context, type='task')
  - Executes task in isolation
  - Sends result via NATS
  - Restores previous conversation context
- **Ask request handling**:
  - Continues current conversation (type='ask')
  - If conversationId specified: loads that conversation
  - If no conversationId: uses/creates default ask conversation
  - Agent remains in this conversation after responding
- Persistent agents stay alive when idle
- Ephemeral agents shutdown after `max_idle_seconds`

### NATS Message Bus

**Why gokr/natswrapper**:
- Nim wrapper around C NATS library
- Proven reliability and performance
- Subject-based routing eliminates discovery protocol
- Easy monitoring (subscribe to `niffler.>`)
- Scalable to distributed deployment later
- Low latency (~1-2ms local)

**Message Protocol**: All messages use JSON serialization via sunny.

**Task Request Message**:
```json
{
  "type": "task_request",
  "id": "uuid-1234-5678",
  "to": "coder",
  "from": "master",
  "prompt": "Create a simple HTTP server",
  "timestamp": "2025-01-15T10:30:00Z"
}
```
**Subject**: `niffler.agent.coder.request`

**Ask Request Message**:
```json
{
  "type": "ask_request",
  "id": "uuid-1234-5678",
  "to": "coder",
  "from": "master",
  "prompt": "Add logging to the server",
  "conversationId": "conv-abc-123",
  "timestamp": "2025-01-15T10:31:00Z"
}
```
**Subject**: `niffler.agent.coder.request`
**Note**: If `conversationId` is null/empty, agent creates or continues default ask conversation for this agent.

**Task Status Message**:
```json
{
  "type": "task_status",
  "id": "uuid-1234-5678",
  "to": "master",
  "from": "coder",
  "status": "processing",
  "timestamp": "2025-01-15T10:30:05Z"
}
```
**Subject**: `niffler.agent.coder.status`

**Task Response Message**:
```json
{
  "type": "task_response",
  "id": "uuid-1234-5678",
  "to": "master",
  "from": "coder",
  "success": true,
  "result": {
    "summary":  "I've created an HTTP server with..."
  },
  "timestamp": "2025-01-15T10:30:30Z"
}
```
**Subject**: `niffler.agent.coder.response`

**Heartbeat Message**:
```json
{
  "type": "heartbeat",
  "from": "coder",
  "status": "idle|busy",
  "uptime": 3600,
  "requestsProcessed": 42,
  "currentRequestId": "uuid-1234-5678",
  "timestamp": "2025-01-15T10:30:00Z"
}
```
**Subject**: `niffler.agent.coder.heartbeat` (published every 30 seconds)

### Configuration: YAML Format

**Location**: `~/.niffler/config.yaml`

**Example Configuration**:
```yaml
# Niffler Multi-Agent Configuration

# NATS server connection settings
nats:
  server: "nats://localhost:4222"
  timeout_ms: 30000
  reconnect_attempts: 5
  reconnect_delay_ms: 1000

# Master mode settings
master:
  default_agent: "coder"  # Agent to use when no @agent specified
  auto_start_agents: true  # Auto-start agents with auto_start=true
  heartbeat_check_interval: 30  # Seconds between health checks

# Agent Definitions
agents:
  - id: "coder"
    name: "Code Expert"
    description: "Specialized in code analysis, debugging, and implementation"

    # Model configuration
    model: "claude-3.5-sonnet"

    # Capabilities (used for smart routing and UI hints)
    capabilities:
      - "coding"
      - "debugging"
      - "architecture"
      - "refactoring"
      - "testing"

    # Tool permissions (enforced by agent - only these tools can execute)
    tool_permissions:
      - "read"
      - "edit"
      - "create"
      - "bash"
      - "list"
      - "fetch"

    # Lifecycle settings
    auto_start: true  # Master will start this agent automatically
    persistent: true  # Keep running when idle (don't shutdown)

  - id: "researcher"
    name: "Research Assistant"
    description: "Fast research, documentation lookup, and web search"

    model: "claude-3-haiku"  # Cheaper model for simple research tasks
    capabilities:
      - "research"
      - "documentation"
      - "web_search"
      - "analysis"
    tool_permissions:  # Read-only, no modifications
      - "read"
      - "list"
      - "fetch"

    auto_start: false  # Start manually when needed
    persistent: false  # Ephemeral - shutdown after idle timeout
    max_idle_seconds: 600  # Shutdown after 10 minutes idle

# Model definitions (shared across agents)
models:
  - id: "claude-3.5-sonnet"
    nickname: "sonnet"
    base_url: "https://api.anthropic.com/v1"
    api_env_var: "ANTHROPIC_API_KEY"

  - id: "claude-3-haiku"
    nickname: "haiku"
    base_url: "https://api.anthropic.com/v1"
    api_env_var: "ANTHROPIC_API_KEY"
```

### Database Schema

**Conversations Table** (extended):
```sql
CREATE TABLE conversations (
  id INTEGER PRIMARY KEY,
  agent_id TEXT,           -- Which agent owns this conversation
  type TEXT,               -- 'task' or 'ask' (how conversation originated)
  request_id TEXT,         -- NATS request ID for correlation
  status TEXT NOT NULL,    -- 'active', 'completed'
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  metadata TEXT            -- JSON metadata
);

CREATE INDEX idx_conversations_agent ON conversations(agent_id);
CREATE INDEX idx_conversations_type ON conversations(type);
CREATE INDEX idx_conversations_request ON conversations(request_id);
CREATE INDEX idx_conversations_status ON conversations(status);
```

**Task Executions Table** (new):
```sql
CREATE TABLE task_executions (
  id INTEGER PRIMARY KEY,
  conversation_id INTEGER,
  agent_id TEXT NOT NULL,
  request_id TEXT NOT NULL,
  status TEXT NOT NULL,      -- 'pending', 'running', 'completed', 'failed'
  started_at TEXT,
  completed_at TEXT,
  tokens_used INTEGER,
  result_summary TEXT,
  artifacts TEXT,            -- JSON array of file paths
  FOREIGN KEY(conversation_id) REFERENCES conversations(id)
);

CREATE INDEX idx_task_executions_agent ON task_executions(agent_id);
CREATE INDEX idx_task_executions_request ON task_executions(request_id);
```

**Context Management**:
- **Task requests**: Create new conversation (type='task', fresh context, no history loaded)
- **Ask requests**: Load/continue existing conversation (type='ask', builds context)
  - If conversationId provided: load that specific conversation
  - If no conversationId: load agent's current ask conversation or create new
- Agent tracks current conversation ID in memory
- All messages persisted for audit/debugging
- Conversations marked 'completed' when finished
- Task completion restores previous conversation context

## Implementation Phases

### Phase 0: Foundation Solidification (1 week) ⭐⭐⭐ CRITICAL

**Goal**: Fix critical gaps in current task system - prerequisite for everything

**Tasks**:
1. **Resolve circular import** (`src/core/task_executor.nim`)
   - Exactly how, unsure, but no dependency injection please.

2. **Integrate tool execution into task conversation loop** (`task_executor.nim:244-258`)
   - Handle tool call responses from LLM
   - Execute tools via tool worker
   - Validate against agent.allowedTools whitelist
   - Inject tool results back into conversation
   - Continue until task completion

3. **Extract artifacts**
   - Parse file references from tool calls
   - Track files read/created during task
   - Include in TaskResult.artifacts

4. **Task result visualization** (`src/ui/cli.nim`)
   - Display task approval prompt
   - Show progress indicator
   - Render results with artifacts
   - Show error details if failed

5. **Test end-to-end task execution**
   - Multi-turn tasks with 3+ tool calls
   - Tool access control enforcement
   - Error handling (tool failures, LLM errors)
   - Concurrent task execution

**Deliverable**: Working single-process task delegation with tool execution

**Success Criteria**: Task can execute tool calls, continue conversation, complete with summary

### Phase 3: Multi-Process Architecture (4-6 weeks) ⭐⭐ HIGH

**Prerequisites**: Phase 0 complete and tested

#### Phase 3.1: NATS Communication Layer (1 week)

**Using**: https://github.com/gokr/natswrapper (NOT nim-nats)

1. **NATS Client Integration** (`src/core/nats_client.nim`)
   - Replace nim-nats references with gokr/natswrapper
   - Connection management with auto-reconnect
   - Publish/subscribe primitives
   - Request/reply pattern support
   - Error handling and timeouts

2. **Message Type Definitions** (`src/types/nats_messages.nim`)
   - Complete JSON serialization/deserialization
   - TaskRequest message type
   - StatusUpdate message type
   - Response message type
   - Heartbeat message type
   - Message validation helpers

3. **NATS Integration Tests**
   - Publish/subscribe between processes
   - Message integrity (serialize → deserialize)
   - Reconnection scenarios
   - Performance baseline
   - Requires `nats-server` running

#### Phase 3.2: Agent Mode (1 week)

1. **Agent Mode CLI** (`src/ui/agent_cli.nim` - new file)
   - Add `--agent <name>` flag
   - Load agent definition from `~/.niffler/agents/`
   - Initialize NATS connection
   - Subscribe to agent-specific request subject
   - Display agent info on startup

2. **Request Processing**
   - Parse TaskRequest messages
   - Create new conversation (fresh context)
   - Route to task executor
   - Stream LLM output to stdout
   - Display tool calls and results

3. **Status and Response Publishing**
   - Publish status updates during processing
   - Publish final result with summary and artifacts
   - Include token usage statistics

4. **Heartbeat Publishing**
   - Publish every 30 seconds
   - Include status (idle/busy)
   - Include uptime and request count

#### Phase 3.3: Master Mode (1-2 weeks)

1. **Master Mode CLI** (`src/ui/master_cli.nim` - new file)
   - Detect master mode (no `--agent` flag)
   - Simplified input loop
   - Initialize NATS connection
   - Load agent configurations

2. **Input Parsing and Routing**
   - Parse `@agent prompt` syntax
   - Fallback to default_agent
   - Tab completion for agent names
   - Validate agent exists

3. **NATS Request/Reply**
   - Build TaskRequest message
   - Generate unique requestId
   - Publish to agent request subject
   - Wait for response with timeout
   - Display completion status

4. **Agent Auto-Start** (`src/core/agent_manager.nim` - new file)
   - Spawn agents with `auto_start: true`
   - Track PIDs
   - Wait for heartbeats (confirm ready)
   - Report startup status

5. **Agent Management Commands**
   - `/agents list` - Show active agents
   - `/agents start <name>` - Spawn agent
   - `/agents stop <name>` - Graceful shutdown
   - `/agents restart <name>` - Stop and start
   - `/agents health` - Health status table

#### Phase 3.4: Process Management (1 week)

1. **Process Spawning**
   - AgentProcess type (config, pid, startTime, lastHeartbeat, status)
   - startAgent() proc (fork/exec)
   - Handle failures gracefully

2. **Heartbeat Monitoring**
   - Subscribe to wildcard heartbeat subject
   - Track last heartbeat time
   - Detect stale agents (>90s)
   - Mark unhealthy agents

3. **Auto-Restart**
   - Detect crashes (process exit)
   - Detect hangs (heartbeat timeout)
   - Auto-restart persistent agents
   - Limit restart attempts (max 3 in 5 min)

4. **Graceful Shutdown**
   - Publish shutdown message
   - Agent finishes current request
   - Agent cleanup (close DB, close NATS)
   - Wait for exit (max 10s)
   - SIGKILL if timeout

5. **Ephemeral vs Persistent**
   - Persistent: stay alive when idle
   - Ephemeral: shutdown after `max_idle_seconds`
   - Master respawns on demand

#### Phase 3.5: Configuration and Database (1 week)

1. **YAML Config Extension**
   - Parse `nats:` section
   - Parse `master:` section
   - Parse `agents:` array
   - Validate NATS server URL

2. **Database Schema Extensions**
   - Add `agent_id` to conversations
   - Add `request_id` to conversations
   - Add `status` field
   - Create task_executions table
   - Add queries for agent conversations

3. **Task Context Management**
   - All requests create new conversation
   - No context loading between tasks
   - Store with agent_id and request_id
   - Mark completed when done

4. **Migration Utilities**
   - `--migrate-config` command
   - Add NATS and master sections
   - Create example agents in `~/.niffler/agents/`

#### Phase 3.6: Integration and Testing (1 week)

1. **End-to-End Tests**
   - Master starts, spawns agents
   - Route request, agent processes, return result
   - Multiple sequential tasks (fresh context each)
   - Agent crash detection and restart
   - Heartbeat timeout detection
   - Graceful shutdown
   - Tool access control across processes
   - Concurrent requests to different agents

2. **Documentation**
   - Multi-process usage examples
   - NATS setup guide
   - Master/agent CLI usage
   - Agent configuration format
   - Troubleshooting guide

3. **Example Configuration**
   - 3 agents with different models
   - Different tool permissions per agent
   - Mix of auto-start and manual
   - Mix of persistent and ephemeral

**Deliverable**: Full multi-process architecture with NATS IPC

**Success Criteria**: Master spawns agents, routes via NATS, monitors health, agents display work

## Usage Examples

### Basic Setup

**Terminal 1: Start Master**
```bash
$ niffler
Master mode initialized
Auto-starting agents: coder
✓ @coder started (pid: 12345)
Ready for commands (type /help for help)
>
```

**Terminal 2: Agent 'coder' Output**
```bash
$ niffler --agent coder
Agent 'coder' initialized (model: claude-3.5-sonnet)
Subscribed to: niffler.agent.coder.request
Ready for requests...
```

### Task Execution

**Terminal 1 (Master)**:
```bash
> @coder Create a simple HTTP server in Nim
→ Sent to @coder

(wait for completion...)

✓ @coder completed
Summary: I've created an HTTP server using Nim's asynchttpserver.
The server listens on port 8080 and handles basic GET requests.
Artifacts: src/server.nim
```

**Terminal 2 (@coder)**:
```
[RECEIVED @coder] Create a simple HTTP server in Nim

[PROCESSING...]
I'll create a simple async HTTP server using Nim's standard library...

[TOOL: create] src/server.nim
[TOOL RESULT] File created successfully

I've created an HTTP server that listens on port 8080...

[COMPLETED ✓]
```

### Multiple Sequential Tasks (Fresh Context Each Time)

**Terminal 1 (Master)**:
```bash
> @coder /task Add logging to src/server.nim
→ Sent to @coder (task)
✓ @coder completed (fresh context, no memory of previous task)
```

**Terminal 2 (@coder)**:
```
[RECEIVED:TASK @coder] Add logging to src/server.nim

[PROCESSING...] (reads file to understand it, fresh context)
[TOOL: read] src/server.nim
[TOOL: edit] src/server.nim

[COMPLETED ✓]
Sent result to master
```

### Conversational Workflow with Ask (Building Context)

**Terminal 1 (Master)**:
```bash
> @coder Create a simple HTTP server
→ Sent to @coder (ask)
✓ @coder completed

> @coder Add logging to the server
→ Sent to @coder (ask)
✓ @coder completed (continues conversation, has context from previous ask)

> @coder Now add error handling for port already in use
→ Sent to @coder (ask)
✓ @coder completed (still same conversation, full context)
```

**Terminal 2 (@coder)**:
```
[RECEIVED:ASK @coder] Create a simple HTTP server

[PROCESSING...] (fresh ask conversation)
I'll create a simple async HTTP server...
[TOOL: create] src/server.nim
[TOOL RESULT] File created successfully

[COMPLETED ✓]
(Agent stays in this conversation)

[RECEIVED:ASK @coder] Add logging to the server

[PROCESSING...] (continuing conversation with previous context)
I'll add logging to the HTTP server we just created...
[TOOL: edit] src/server.nim
[TOOL RESULT] File edited successfully

[COMPLETED ✓]
(Agent still in same conversation)

[RECEIVED:ASK @coder] Now add error handling for port already in use

[PROCESSING...] (continuing same conversation, full context)
I'll add error handling to our server for the port binding...
[TOOL: edit] src/server.nim

[COMPLETED ✓]
```

### Agent Management

```bash
> /agents list
┌─────────────┬────────────┬───────────┬───────────────┬──────────┐
│ Agent       │ Status     │ Model     │ Uptime        │ Requests │
├─────────────┼────────────┼───────────┼───────────────┼──────────┤
│ coder       │ idle       │ sonnet    │ 1h 23m        │ 15       │
│ researcher  │ stopped    │ haiku     │ -             │ -        │
└─────────────┴────────────┴───────────┴───────────────┴──────────┘

> /agents start researcher
Starting agent 'researcher'...
✓ Started (pid: 12347)

> /agents health
All agents healthy (2/2 running)
```


## Benefits of This Architecture

### User Extensibility
- **No Code Changes**: Add agents by creating markdown files
- **Transparent Definitions**: Agent capabilities clearly documented
- **Shareable**: Agent definitions are portable files
- **Version Control**: Track agent changes in git

### Safety and Control
- **Explicit Tool Whitelists**: Clear boundaries per agent
- **User Confirmation**: Tasks require approval before execution
- **Process Isolation**: OS-level fault containment
- **Fresh Context**: No cross-task contamination

### Clean Architecture
- **Leverages Existing Systems**: Uses tool registry and threading
- **Consistent Patterns**: `/agent` command mirrors `/model` command
- **Simple Enforcement**: Whitelist checking straightforward
- **Scalable Design**: Add agents without recompiling

### Operational Benefits
- **Visibility**: Each agent's work displayed in own terminal
- **Debugging**: Per-agent logs and error isolation
- **Cost Optimization**: Different models per agent (cheap for research, powerful for coding)
- **Fault Tolerance**: Agent crashes don't affect master or other agents
