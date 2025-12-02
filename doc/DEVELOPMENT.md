# Niffler Development Guide

This document provides detailed information for developers working on Niffler, including architecture decisions, implementation phases, and development patterns.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Multi-Agent System Implementation](#multi-agent-system-implementation)
- [Task Tool Integration (Phase 0)](#task-tool-integration-phase-0)
- [Development Patterns](#development-patterns)
- [Future Roadmap](#future-roadmap)

## Architecture Overview

Niffler uses a **multi-threaded single-process architecture** with clear separation of concerns:

### Threading Model

- **Main Thread**: Handles CLI interaction and user input
- **API Worker Thread**: Manages LLM API communication and streaming responses
- **Tool Worker Thread**: Executes tool operations with validation and security
- **Thread-Safe Channels**: Coordinate communication between threads using Nim channels

### Communication Flow

```
User Input → Main Thread → API Worker → LLM API
                                    ↓
                              Tool Calls Detected
                                    ↓
                              Tool Worker → File System/Commands
                                    ↓
                              Tool Results → API Worker
                                    ↓
                              Final Response → Main Thread → User
```

Key files:
- `src/core/channels.nim` - Channel definitions and message types
- `src/api/api.nim` - API worker implementation
- `src/tools/worker.nim` - Tool worker implementation
- `src/ui/cli.nim` - Main thread and CLI interface

## Multi-Agent System Implementation

Niffler implements a **process-per-agent architecture** using NATS messaging for inter-process communication.

### Core Design Principles

1. **Process Isolation**: One agent = one persistent process for true fault isolation
2. **Markdown-Based Agents**: User-extensible agent definitions in `~/.niffler/default/agents/`
3. **NATS Messaging**: Inter-process communication via `gokr/natswrapper`
4. **Task vs Ask Model**: Clear semantics for different interaction patterns

### Agent Types

**Ask Model** (`@agent prompt`): Default behavior
- Continues agent's current conversation context
- Maintains context across multiple interactions
- Agent stays in conversation after responding
- **Use case**: Multi-step problems, refinement, iterative development

**Task Model** (`@agent /task prompt`):
- Creates fresh context for isolated execution
- No previous conversation history
- Returns result via NATS and restores previous context
- **Use case**: One-off operations, isolated problems, research tasks

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

### Implementation Status

#### ✅ **Phase 3.1: NATS Communication Layer** (COMPLETE)

**Components:**
- `src/core/nats_client.nim` - NATS client wrapper (229 lines)
- `src/types/nats_messages.nim` - Message type definitions (~60 lines)
- `tests/test_nats_*.nim` - Integration tests (20 tests passing)

**Features:**
- Connection management and message passing
- Request/reply pattern support
- JetStream KV presence tracking with 15-second TTL
- Automatic JSON serialization via Sunny

**Message Types:**
- `NatsRequest` - Agent parses /plan, /task, /model from input
- `NatsResponse` - Streaming responses with done flag
- `NatsStatusUpdate` - Status updates during execution
- `NatsHeartbeat` - Presence tracking with auto-expiration

#### ✅ **Phase 3.2: Agent Mode** (COMPLETE)

**Key Components:**
- `src/ui/agent_cli.nim` - Agent process CLI (278 lines)
- `src/core/command_parser.nim` - Shared command parser (106 lines)
- `~/.niffler/default/agents/*.md` - Agent definitions

**Features:**
- Long-running agent processes with dedicated terminals
- Command parsing for /plan, /code, /task, /ask, /model commands
- NATS presence tracking via heartbeats
- Tool permission enforcement via allowedTools

#### ✅ **Phase 3.3: Master Mode** (CORE COMPLETE)

**Key Components:**
- `src/ui/master_cli.nim` - Master CLI and routing (301 lines)
- `@agent` syntax for routing requests
- NATS request/reply with agent processes

**Features:**
- Agent discovery via NATS presence
- Request routing and response handling
- Agent listing via `/agents` command
- Task and ask model support

**Not Yet Implemented:**
- Agent auto-start from configuration
- Start/stop/restart agent commands
- Tab completion for agent names

#### ✅ **Phase 3.4: Auto-Start System** (COMPLETE)

**Key Components:**
- `src/core/agent_manager.nim` - Agent lifecycle management
- `src/types/config.nim` - Configuration types
- YAML configuration parsing

**Features:**
- Automatic spawning of agents with `auto_start: true`
- Configuration-driven agent definitions
- Duplicate detection and error handling

**Configuration Example:**
```yaml
masters:
  enabled: true
  default_agent: "coder"
  auto_start_agents: true
  heartbeat_check_interval: 30

agents:
  - id: "coder"
    auto_start: true
    persistent: true
    model: "claude-sonnet"
    capabilities: ["coding", "debugging", "architecture"]
    tools: ["read", "edit", "create", "bash", "list", "fetch"]
```

#### ✅ **Phase 3.5: Single-Prompt Routing** (COMPLETE)

**Features:**
- Direct command-line routing: `./src/niffler --prompt="@agent task"`
- Fire-and-forget mode (default)
- Wait mode (with `/wait` flag)
- Support for `/task`, `/plan`, `/code` commands

## Task Tool Integration (Phase 0)

**Status:** ✅ **COMPLETE** - All tasks completed, 8 tests passing

The Task Tool Integration was a critical prerequisite for the multi-agent system, resolving circular import issues and enabling autonomous agent execution.

### Key Achievements

#### 1.1 Circular Import Resolution ✅
- Tool execution via channels (lines 329-383 in `src/core/task_executor.nim`)
- Uses existing tool worker with thread-safe communication
- Clean architecture with no circular dependencies

#### 1.2 Tool Execution Integration ✅
- Full tool execution loop in task conversation
- Tool call collection from LLM responses (lines 262-266)
- Tool access validation against `agent.allowedTools` (lines 318-327)
- Tool execution via tool worker (lines 329-383)
- Tool result formatting and conversation continuation (lines 358-385)
- Graceful error handling for tool failures

#### 1.3 Artifact Extraction ✅
- `extractArtifacts()` function implemented (lines 25-62)
- Parses file operations (read, create, edit, list)
- Extracts file paths from tool arguments
- Returns sorted unique file paths
- Called during task completion (line 402)

#### 1.4 Result Visualization ✅
- `renderTaskResult()` function in `src/ui/cli.nim`
- Success/failure formatting with theme colors
- Summary display when available
- Artifacts listed with 📄 icons
- Tool call count and token usage metrics
- Error details when failed

#### 1.5 Testing ✅
- Tool call parsing and validation against whitelist
- Artifact extraction from various tool calls
- Tool access control enforcement
- Error handling for graceful failures
- TaskResult structure validation
- System prompt generation
- **All 8 tests passing** in `tests/test_task_execution.nim`

## Development Patterns

### Adding New Tools

1. **Create tool implementation** in `src/tools/`
```nim
proc executeMyTool*(args: JsonNode): string {.gcsafe.} =
  try:
    let param = getArgStr(args, "parameter")
    let result = performOperation(param)
    return $ %*{"success": true, "result": result}
  except Exception as e:
    return $ %*{"error": e.msg}
```

2. **Register tool** in tool registry
```nim
registerTool("myTool", Tool(
  name: "myTool",
  description: "Description",
  execute: executeMyTool,
  schema: parseJson("""{...}""")
))
```

3. **Add security considerations** - validation, timeouts, path sanitization

### Thread Safety Patterns

**GC-Safe Blocks:**
```nim
proc checkPlanModeProtection*(path: string): bool {.gcsafe.} =
  {.gcsafe.}:
    try:
      let db = getGlobalDatabase()
      # ... safe operations
    except Exception as e:
      return false
```

**Channel Communication:**
```nim
# Send message
channel.send(msg)

# Receive with timeout
let msg = channel.tryReceive(timeout = 50)
if msg.dataAvailable:
  process(msg.data)
```

### Configuration Management

**Layered Configuration:**
1. Project-level: `.niffler/config.yaml`
2. User-level: `~/.niffler/config.yaml`
3. Default fallback: `"default"`

**NIFFLER.md Search Order:**
1. Active config: `~/.niffler/{active}/NIFFLER.md`
2. Current directory: `./NIFFLER.md`
3. Parent directories: Up to 3 levels up

### Agent Definition Format

Agent definitions are markdown files in `~/.niffler/default/agents/`:

```markdown
# Agent Name

**ID:** coder
**Model:** claude-sonnet

## Description

Full-stack developer agent with complete tool access.

## Capabilities

- Coding and implementation
- Debugging and troubleshooting
- Architecture design

## Tools

Allowed tools:
- read
- edit
- create
- bash
- list
- fetch
```

## Future Roadmap

### Medium Priority

**Enhanced Message Persistence:**
- Extended tool call metadata tracking
- Tool execution time and success/failure rates
- Summary flags for condensed messages
- Multiple content blocks per message

**Thread Channel Optimization:**
- Replace polling with blocking operations
- Timeout-based blocking instead of sleep delays
- Expected 20-50ms latency reduction

**Advanced Context Management:**
- Truncate and smart_window condensation strategies
- Context size warnings
- Enhanced @ referencing with folder support

### Lower Priority

**Content Visualization:**
- Integration with delta for git-style diff visualization
- Enhanced display with batcat
- Configurable external renderers

**Sub-Task Spawning:**
- Recursive task spawning with depth limits
- Automatic context inheritance from parent

**Provider Support:**
- Dedicated Claude API client
- Unified provider interface
- Provider-specific optimizations

## Key Architectural Decisions

### 1. Process-Per-Agent Architecture

**Rationale:**
- True fault isolation (crash in one agent doesn't affect others)
- Per-agent visibility (each has own terminal)
- Better resource management and monitoring
- Foundation for distributed deployment

**Trade-offs:**
- Higher memory usage vs single-process
- More complex process management
- NATS dependency for communication

### 2. Markdown-Based Agent Definitions

**Rationale:**
- User-extensible without code changes
- Version controllable
- Easy to read and modify
- No compilation required

**Implementation:**
- Soft agent type system
- Runtime agent loading
- Tool permission enforcement

### 3. Task vs Ask Model

**Rationale:**
- Clear semantics for different use cases
- Task provides isolation and fresh context
- Ask enables multi-turn collaboration
- Consistent with industry patterns

**Usage:**
```bash
# Ask - continue conversation
@coder How do I optimize this function?

# Task - isolated execution
@coder /task Research three different optimization approaches
```

## Testing Strategy

### Unit Tests

- Tool call parsing and validation
- Artifact extraction from conversations
- Tool access control enforcement
- Error handling and edge cases
- **Located in:** `tests/test_*.nim`

### Integration Tests

- NATS message serialization
- Multi-client communication
- End-to-end task execution
- **Located in:** `tests/test_nats_*.nim`

### Manual Testing

```bash
# Test master + agent communication
# Terminal 1:
./src/niffler agent coder

# Terminal 2:
./src/niffler
> @coder /task "List all Nim files in src/"

# Verify:
# - Agent receives request
# - Task executes successfully
# - Results displayed in master terminal
```

## Resources

- [Architecture Overview](ARCHITECTURE.md) - System design and architecture
- [Task System](TASK.md) - Multi-agent architecture details
- [Examples](../doc/EXAMPLES.md) - Usage patterns and examples
- [Configuration](CONFIG.md) - Configuration system guide

---

**Last Updated:** 2025-12-02
**Document Version:** 0.4.0
