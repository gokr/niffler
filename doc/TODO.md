# Niffler Development Roadmap

Niffler is an AI-powered terminal assistant written in Nim with Plan/Code workflow.

## Recently Completed ✅

### **Master Mode (Phase 3.3)**
- ✅ Master mode CLI with NATS connection (`src/ui/master_cli.nim`)
- ✅ `@agent` routing syntax for directing requests to agents
- ✅ NATS request/reply with status updates and responses
- ✅ `/agents` command to list running agents via presence tracking
- ✅ Integrated into main CLI input loop
- ✅ Single prompt mode with `niffler --master @agent "prompt"`

### **Conversation Condensation**
- ✅ `/condense` command for LLM-based conversation summarization
- ✅ Database schema with parent conversation linking
- ✅ Condensation module (`src/core/condense.nim`)
- ✅ LLM summary strategy implemented
- ⚠️ Truncate and smart_window strategies planned

### **CLI & Mode Management Enhancements**
- ✅ `--ask` CLI option for quick single-prompt queries
- ✅ `--loglevel` flag replacing deprecated `--debug/--info`
- ✅ `--dumpsse` option for server-sent events debugging
- ✅ `--dump-json` flag support for streaming client
- ✅ Mode persistence fix for `/plan` and `/code` commands
- ✅ Session consistency across mode switches

### **MCP Integration**
- ✅ Model Context Protocol client implementation (`src/mcp/mcp.nim`)
- ✅ MCP worker thread with dedicated message processing
- ✅ Dynamic external tool loading from MCP servers
- ✅ Service discovery and configuration (`src/mcp/manager.nim`, `src/mcp/protocol.nim`)
- ✅ Cross-thread accessibility with caching
- ✅ `/mcp status` command for monitoring
- ✅ Tool integration with MCP tools in tool registry

### **Task & Agent System**
- ✅ Soft agent type system with markdown-based definitions (`src/types/agents.nim`)
- ✅ Default agents: general-purpose, code-focused (`src/core/agent_defaults.nim`)
- ✅ Tool access control for agent-based restrictions
- ✅ Task tool for autonomous agent execution (`src/tools/task.nim`)
- ✅ Task executor with isolated execution context (`src/core/task_executor.nim`)
- ✅ Full tool execution integration and testing
- ✅ Agent-based conversation tracking

### **Todolist Tool**
- ✅ Database-backed todo persistence (`src/tools/todolist.nim`)
- ✅ Markdown checklist parsing and generation
- ✅ State tracking (pending, in_progress, completed, cancelled)
- ✅ Priority support (low, medium, high)
- ✅ Bulk update operations

### **CLI & Output Improvements**
- ✅ Buffered streaming output with user input display
- ✅ Tool visualization with progress indicators
- ✅ Thinking token display and storage (`src/ui/thinking_visualizer.nim`)
- ✅ Enhanced markdown rendering (`src/ui/markdown_cli.nim`)
- ✅ Diff visualization (`src/ui/diff_visualizer.nim`)
- ✅ Table formatting utilities (`src/ui/table_utils.nim`)

### **Database & Persistence**
- ✅ Conversation tracking with metadata (TiDB integration)
- ✅ Message persistence with extended tool call support
- ✅ Token usage logging and cost tracking per model
- ✅ Thinking token storage (conversation_thinking_token table)
- ✅ Todo system database schema
- ✅ Task execution results database storage

### **Multi-Agent System (Phase 3)**
- ✅ Agent discovery via NATS presence
- ✅ Single-prompt routing with fire-and-forget
- ✅ Task result visualization
- ✅ Agent health monitoring
- ✅ **PRODUCTION READY** - Full multi-agent system with NATS messaging

## Current Testing Status

### **Existing Tests** ✅
- ✅ Unit tests for core modules (conversation, database, tools)
- ✅ NATS integration tests (require running NATS server)
- ✅ Tool execution tests (mock LLM responses)
- ✅ Conversation end-to-end tests (simulated)
- ✅ Real integration tests with actual LLMs
- ✅ Multi-agent system tests
- ✅ Master mode integration tests

### **Completed** ✅
- **Integration Testing Framework** - Complete with real LLM workflows, master-agent scenarios, and environment configuration

### **Test Files** (`tests/`)
- `test_basic.nim` - Core functionality tests
- `test_conversation_*.nim` - Conversation system tests
- `test_nats_*.nim` - NATS integration tests
- `test_tool_*.nim` - Tool execution tests
- `test_todolist_*.nim` - Todo system tests
- `test_thinking_*.nim` - Thinking token tests

## Remaining Development Tasks

### 🔴 High Priority

#### **1. Multi-Agent Coordination System** *(Not Started)*

**The next major evolution of Niffler - enabling Claude Code-like hierarchical agent execution**

##### **1.1 Hierarchical Agent Execution**
- Manager agent for intelligent task decomposition and planning
- Dynamic sub-agent spawning with specialized roles (analyzer, coder, debugger, tester)
- Result collection and synthesis pipeline with quality scoring
- Task dependency graph management and execution ordering
- Context inheritance between parent/child agents with selective sharing
- Sub-agent lifecycle management (creation, monitoring, cleanup)

##### **1.2 Agent-to-Agent Communication Hub**
- Direct messaging between agents (bypassing NATS for local optimization)
- Shared context store for collaborative problem-solving
- Agent capability discovery and automatic matching
- Inter-agent security and permissions system
- Agent reputation and reliability scoring

##### **1.3 Workflow Orchestration Engine**
- Visual workflow definition (similar to GitHub Actions YAML)
- Conditional branching based on agent results and quality metrics
- Parallel execution with synchronization points and barriers
- Rollback and error recovery mechanisms
- Workflow templates for common patterns (debug session, feature implementation)

**Related Files:** `src/core/agent_orchestrator.nim`, `src/core/workflow_engine.nim`, `src/core/agent_registry.nim`

#### **2. Niffler Next Development Phase Investigation** *(Not Started)*
- Investigate and plan Niffler's next development phase
- Evaluate current system capabilities and identify improvement areas
- Research emerging AI/LLM integration patterns
- Define roadmap for next major version
- Assess scalability and performance requirements
- Consider user feedback and feature requests

#### **3. Integration Testing Framework** ✅ **PRODUCTION READY**
- ✅ Comprehensive real LLM integration tests (no mocks) - `test_real_llm_workflows.nim`
- ✅ Master mode E2E tests with agents and NATS - `test_master_agent_scenario.nim`
- ✅ Agent task completion verification - Full integration test framework
- ✅ Test data fixtures and cleanup scripts - `run_integration_tests.sh`
- ✅ CI/CD integration for automated testing - Environment configuration
- ✅ Complete test coverage for all major features

**Related Files:** `tests/test_integration_framework.nim`, `tests/test_master_agent_scenario.nim`, `tests/test_real_llm_workflows.nim`, `INTEGRATION_TESTS.md`

#### **4. Documentation Alignment** ✅ **Mostly Complete**
- ✅ `doc/DATABASE_SCHEMA.md` - Complete table documentation created
- ✅ `doc/CONFIG.md` - Updated with NATS and master mode configuration
- ✅ `doc/ADVANCED_CONFIG.md` - Multi-environment setup documentation
- ✅ `doc/CONTRIBUTING.md` - Development guidelines created
- [ ] Update `doc/DEVELOPMENT.md` with latest features (agent orchestration, CLI improvements)

**Related Files:** All `doc/*.md` files

### 🟡 Medium Priority

#### **5. Reliable Inter-Agent Communication** *(Not Started)*
- NATS JetStream for guaranteed message delivery between distributed agents
- Message cancellation and timeout handling for sub-agent tasks
- Delivery acknowledgment and real-time status visualization
- Message queuing for offline agents and fault tolerance
- Priority-based message routing for urgent tasks

**Related Files:** `src/core/nats_client.nim`, `src/ui/master_cli.nim`

#### **6. Collaborative Workflow Tracking** *(Partially Implemented)*
- Extended tool call metadata for multi-agent workflows
- Agent execution time and success/failure rate tracking
- Task relationship mapping (parent-child, dependencies)
- Result provenance and attribution tracking
- Support for collaborative artifacts and shared resources

**Related Files:** `src/core/database.nim`

#### **7. Shared Context for Collaboration** *(Partially Implemented)*
- Truncate and smart_window condensation for agent conversations
- Context size warnings with automatic agent-specific suggestions
- Enhanced @ referencing with folder/glob pattern support
- Context window optimization per agent model and role
- Shared context pools for agent collaboration

**Related Files:** `src/core/condense.nim`, `src/ui/file_completion.nim`

### 🟢 Lower Priority

#### **8. Multi-Config System** *(Not Started)*
- Plan model with default reasoning level
- Code model optimized for implementation
- Fast tool model for quick operations
- Hotkey support for config switching
- Dynamic system prompt selection per mode
- Agent-specific configuration profiles

**Related Files:** `src/core/config.nim`, `src/ui/cli.nim`

#### **9. Process Management & Monitoring** *(Not Started)*
- Health monitoring with heartbeat timeout detection
- Auto-restart for persistent agents
- Graceful shutdown handling for all processes
- Ephemeral vs persistent agent lifecycle management
- Resource usage monitoring for multi-agent systems
- Distributed agent health dashboard

**Related Files:** `src/core/agent_manager.nim`

#### **10. Advanced Features** *(Not Started)*
- Git integration for diff visualization
- Context squashing with `/squash` command
- Recursive task spawning with depth limits
- Enhanced content display options
- Workspace management commands
- Agent collaboration visualization

**Related Files:** `src/ui/cli.nim`, `src/tools/task.nim`

#### **11. Native Provider Support** *(Partially Implemented)*
- Dedicated Claude API client (beyond OpenAI-compatible)
- Unified provider interface architecture
- Provider-specific optimizations and features
- Custom endpoint configuration
- Multi-provider failover and load balancing

**Related Files:** `src/api/http_client.nim`, `src/types/models.nim`

## Detailed Implementation Guides

For comprehensive technical details, architecture decisions, and implementation patterns, see:

- **[Development Guide](DEVELOPMENT.md)** - Detailed architecture, patterns, and implementation
- **[Architecture Overview](ARCHITECTURE.md)** - System design and technical architecture
- **[Task System](TASK.md)** - Multi-agent architecture and agent system design
- **[Examples](EXAMPLES.md)** - Common usage patterns and workflows

## Proposed Integration Tests

Below are concrete integration test proposals that would verify Niffler's core functionality with real LLMs:

### 1. **Master Mode E2E Test** (`tests/test_master_mode_e2e.nim`)
```nim
# Test workflow:
# 1. Start NATS server
# 2. Launch agent process
# 3. Launch master process
# 4. Send command via master to agent
# 5. Verify agent executes and responds
# 6. Check persistence in database
```

### 2. **Agent Task Completion Test** (`tests/test_agent_tasks.nim`)
```nim
# Test scenarios:
# - Agent creates a file via task
# - Agent reads and analyzes code
# - Agent uses multiple tools in sequence
# - Verify task results stored in database
```

### 3. **Simple Question & Answer Test** (`tests/test_qa_integration.nim`)
```nim
# Test basic LLM integration:
# - Ask factual question
# - Verify response accuracy
# - Test token usage tracking
```

### 4. **Tool Execution Verification** (`tests/test_tool_execution_real.nim`)
```nim
# Test each tool with real LLM:
# - File operations (read, write, edit, list)
# - Bash command execution
# - Web fetching
# - Verify validation and security
```

## Task Statistics

- **Total Tasks:** 11
- **🔴 High Priority:** 4
- **🟡 Medium Priority:** 3
- **🟢 Lower Priority:** 4
- **Completed:** 50+ major features

## Priority Guidelines

**High Priority:**
- Multi-Agent Coordination System (next major evolution)
- Niffler Next Development Phase Investigation
- Documentation alignment (nearly complete)
- Process management and health monitoring (robustness)

**Medium Priority:**
- Advanced context management (usability)
- User message queue enhancement (reliability)
- Multi-config system (flexibility)

**Lower Priority:**
- Advanced features (enhancements)
- UI/UX polish (nice-to-have)
- Provider-specific optimizations (niche)

## Contributing

When working on remaining tasks:

1. Update this roadmap with status changes
2. Add implementation details to [DEVELOPMENT.md](DEVELOPMENT.md)
3. Create/update tests in `tests/`
4. Update documentation in `doc/`
5. Follow established patterns in [DEVELOPMENT.md#development-patterns](DEVELOPMENT.md#development-patterns)

## Status Indicators

- ✅ **Complete** - Fully implemented and tested
- ⚠️ **Partial** - Partially implemented, needs completion
- [ ] **Not Started** - Ready to be worked on

---

**Last Updated:** 2025-12-12
**Current Version:** 0.5.0
**Next Milestone:** Multi-Agent Coordination System - Hierarchical Agent Execution
