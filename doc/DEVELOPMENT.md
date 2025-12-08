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
- Direct command-line routing: `./src/niffler agent <name> --task="task"`
- Fire-and-forget mode (default)
- Wait mode (basic version)
- Support for `/task`, `/plan`, `/code` commands in agent mode with --task

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

## Recent Features and Updates

### Integration Testing Framework (v0.5.0)

The testing framework has been comprehensive completed with real LLM integration:

#### Real LLM Workflows
- `test_real_llm_workflows.nim` - Tests actual LLM interactions
- Environment-based configuration for API keys
- Support for different model providers
- Token usage tracking verification

#### Master-Agent Scenarios
- `test_master_agent_scenario.nim` - Multi-agent coordination
- NATS messaging verification
- Agent health monitoring
- Task completion validation

#### Testing Infrastructure
- `test_integration_framework.nim` - Core testing utilities
- `run_integration_tests.sh` - Test runner script
- Environment configuration and cleanup
- Parallel test execution support

### MCP Integration (v0.5.0)

Model Context Protocol support for external tools:

#### Core Components
- `src/mcp/mcp.nim` - MCP client implementation
- `src/mcp/manager.nim` - Service discovery and management
- `src/mcp/protocol.nim` - Protocol handling
- `src/mcp/tools.nim` - Tool integration

#### Key Features
- Dynamic external tool loading
- Cross-thread accessibility with caching
- Service discovery and configuration
- `/mcp status` command for monitoring
- Tool registry integration

### Advanced Conversation Features

#### Thinking Token Support
- `src/ui/thinking_visualizer.nim` - Real-time thinking display
- Database storage in `conversation_thinking_token` table
- Model-specific reasoning capture
- UI streaming with progress indicators

#### Enhanced Message Persistence
- Extended tool call metadata
- Tool execution tracking
- Performance metrics storage
- Multiple content blocks support

### Configuration System Updates

#### NATS and Master Mode Configuration
- Multi-environment setup support
- Agent auto-start configuration
- Security and authentication options
- Clustering and high availability setup
- Complete NATS server setup documentation

#### Advanced Configuration Patterns
- Environment-specific configurations
- Dynamic model selection
- Custom agent definitions
- Security and access control
- Performance optimization settings

### Database Schema Enhancements

#### New Tables (v0.5.0)
- `conversation_thinking_token` - Reasoning token storage
- `token_correction_factor` - Token counting accuracy
- `token_log_entry` - Debugging and analysis
- `system_prompt_token_usage` - System prompt tracking
- `prompt_history_entry` - Prompt optimization data

#### Database Features
- Complete schema documentation in `DATABASE_SCHEMA.md`
- Performance optimization recommendations
- Security considerations
- Backup and migration procedures

### CLI and UI Improvements

#### Enhanced CLI Features
- `--ask` option for single prompt execution
- `--dumpsse` for debugging server-sent events
- Response header visualization
- Model configuration in agent markdown files

#### Better Visualization
- Progress indicators for long operations
- Tool execution status updates
- Diff visualization improvements
- Table formatting utilities

## Implementation Status Updates

### Recently Completed Features

#### Multi-Agent System (✅ Complete)
- Agent discovery via NATS presence
- Master mode CLI with @agent routing
- Task result visualization
- Single-prompt routing support
- **All Phase 3 goals met**

#### Task and Agent System (✅ Complete)
- Soft agent type system
- Default agents: general-purpose, code-focused
- Task executor with isolated execution
- Full tool integration
- Agent-based conversation tracking

#### Database Capabilities (✅ Complete)
- TiDB integration with all tables
- Conversation tracking and persistence
- Token usage and cost tracking
- Todo system with database persistence
- Complete database schema

### Current Testing Capabilities

#### Unit Tests (✅ Complete)
- Core modules coverage
- Tool validation testing
- Database operations
- MCP integration basics

#### Integration Tests (✅ Complete)
- Real LLM workflow testing
- Master-agent scenarios
- NATS messaging validation
- Database integration

#### Performance Testing
- Token usage tracking
- Multi-agent load testing
- Database query optimization
- NATS throughput validation

### Tools and Utilities

#### Database Inspector (`scripts/db_inspector.sh`)
- Conversation analysis
- Token usage reports
- Database health checks
- Migration assistance

#### Development Scripts
- `run_integration_tests.sh` - Full test suite
- Token monitoring scripts
- Debugging utilities
- Performance profiling tools

## Development Patterns

### Adding New Tools

1. **Schema Definition** (`src/tools/schemas.nim`)
2. **Tool Implementation** (new `.nim` file in `src/tools/`)
3. **GC Safety** - Mark all tool functions with `{.gcsafe.}`
4. **Registration** (`src/tools/registry.nim`)
5. **Testing** - Add tests in `tests/test_*.nim`

### Thread Safety Requirements

All tool functions MUST use this pattern:

```nim
proc executeTool*(args: JsonNode): string {.gcsafe.} =
  ## Tool description
  {.gcsafe.}:
    try:
      # Tool implementation here
      # Access to database via getGlobalDatabase()
      # Access to globals only inside {.gcsafe.}: block
      result = "success"
    except Exception as e:
      return $ %*{"error": e.msg}
```

### Error Handling Patterns

Use standardized error responses throughout:

```nim
# Standard error format
return $ %*{
  "error": "Descriptive error message",
  "type": "ErrorType",
  "context": "Additional context"
}

# Tool errors
return $ %*{
  "error": "Parameter validation failed",
  "field": "param_name",
  "expected": "string",
  "received": "null"
}
```

### Configuration Integration

For new configuration options:

1. **Update Default Config** - Add to `src/core/config.nim`
2. **Environment Variable Support** - Use `${VAR_NAME}` pattern
3. **Documentation** - Update `CONFIG.md`
4. **Validation** - Add schema validation where appropriate
5. **Testing** - Add config validation tests

## Testing Strategy Evolution

### Current Testing Levels

#### ✅ Unit Tests
- Tool execution and validation
- Database operations
- Configuration parsing
- Agent system components
- **Files:** `tests/test_*.nim`

#### ✅ Integration Tests
- Real LLM workflows
- Master-agent communication
- NATS messaging
- Database persistence
- **Files:** `tests/test_integration_framework.nim`, `test_real_llm_workflows.nim`, `test_master_agent_scenario.nim`

#### ✅ System Tests
- End-to-end workflows
- Multi-agent scenarios
- Performance under load
- Memory leak detection
- **Files:** `tests/test_system_*.nim` (planned)

### Running Tests

```bash
# All unit tests
nimble test

# Integration tests (requires NATS + API keys)
./tests/run_integration_tests.sh

# Specific test suites
nim c -r tests/test_conversation.nim
nim c -r tests/test_tools.nim

# Skip tests that require running services
nim test -- --exclude "integration"
```

## Debugging Guide

### Debug Mode

```bash
# Enable debug output
./src/niffler --debug

# Specific debug topics
./src/niffler --debug topics=api,tools,nats

# Database debugging
./src/niffler --debug topics=database

# Token usage debugging
./src/niffler --debug topics=token,correction
```

### Common Debugging Scenarios

#### Tool Not Working
```bash
# Enable tool debugging
./src/niffler --debug topics=tools,validation

# Check tool registration
grep "tools: register" logs/niffler.log
```

#### NATS Connection Issues
```bash
# NATS debugging
./src/niffler --debug topics=nats,master

# Test NATS directly
nats sub "niffler.>" &
./src/niffler agent test-agent
```

#### Database Issues
```bash
# Database debugging
./src/niffler --debug topics=database

# Check database schema
mysql -h 127.0.0.1 -P 4000 -u root -e "SHOW TABLES FROM niffler"
```

## Performance Optimization

### Current Optimizations

#### Token Usage
- Token correction factors for accuracy
- Local token counting
- Prompt caching strategies
- Usage tracking and limits

#### Database Performance
- Connection pooling
- Query optimization
- Index tuning recommendations
- Monitoring and alerting

#### Multi-Agent Scaling
- NATS clustering support
- Agent load balancing
- Health monitoring
- Graceful shutdown handling

## Future Development Areas

### High Priority Opportunities

1. **Performance Optimization**
   - Query optimization for large datasets
   - Memory usage reduction
   - Parallel tool execution

2. **Enhanced Security**
   - Input validation improvements
   - API key rotation
   - Access control refinement

3. **Developer Experience**
   - Better debugging tools
   - Automated testing improvements
   - Performance profiling tools

### Medium Priority Enhancements

1. **Advanced Features**
   - Custom plugin system
   - Workflow automation
   - Advanced filtering and search

2. **Integration Improvements**
   - More MCP servers
   - Additional model providers
   - CI/CD integrations

## Resources and References

### Technical Documentation
- [Architecture Overview](ARCHITECTURE.md) - System design and patterns
- [Task System](TASK.md) - Multi-agent architecture
- [Database Schema](DATABASE_SCHEMA.md) - Complete database documentation
- [Configuration Guide](CONFIG.md) - All configuration options
- [Advanced Configuration](ADVANCED_CONFIG.md) - Production setup

### Development Resources
- [Contribution Guidelines](CONTRIBUTING.md) - How to contribute
- [Examples](EXAMPLES.md) - Common usage patterns
- [Integration Tests](INTEGRATION_TESTS.md) - Testing framework
- [Model Documentation](MODELS.md) - API and model reference

### External Resources
- [Nim Documentation](https://nim-lang.org/docs.html) - Language reference
- [NATS Documentation](https://docs.nats.io/) - Messaging system
- [TiDB Documentation](https://docs.pingcap.com/tidb) - Database system
- [OpenAI API](https://platform.openai.com/docs) - Primary API reference

---

**Last Updated:** 2025-12-08
**Document Version:** 0.5.0
**Features Covered:** Through v0.5.0 completion
