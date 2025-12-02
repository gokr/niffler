# Niffler Development Roadmap

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
- ✅ Full tool execution integration and testing

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

### **Multi-Agent System (Phase 3)**
- ✅ Auto-start system for agents
- ✅ Single-prompt routing
- ✅ Task result visualization
- ✅ **MVP COMPLETE** - Production ready multi-agent system

## Remaining Tasks

### **1. User Message Queue** *(Not Started)*
- Message queueing system via NATS JetStream
- Message cancellation before agent acceptance
- Delivery acknowledgment visualization

**Related Files:** `src/core/nats_client.nim`, `src/ui/master_cli.nim`

### **2. Enhanced Message Persistence** *(Partially Implemented)*
- Extended tool call metadata tracking
- Tool execution time and success/failure rates
- Summary flags for condensed messages
- Support for multiple content blocks per message

**Related Files:** `src/core/database.nim`

### **3. Advanced Context Management** *(Partially Implemented)*
- Truncate and smart_window condensation strategies
- Context size warnings
- Enhanced @ referencing with folder/glob pattern support

**Related Files:** `src/core/condense.nim`, `src/ui/file_completion.nim`

### **4. Multi-Config System** *(Not Started)*
- Plan model with default reasoning level
- Code model optimized for implementation
- Fast tool model for quick operations
- Hotkey support for config switching
- Dynamic system prompt selection

**Related Files:** `src/core/config.nim`, `src/ui/cli.nim`

### **5. UI/UX Polish** *(Partially Implemented)*
- Enhanced help system for Plan/Code workflow
- Contextual help for current mode
- Token count and context window usage display
- Custom slash commands support

**Related Files:** `src/ui/commands.nim`, `src/ui/cli.nim`

### **6. Process Management** *(Not Started)*
- Health monitoring with heartbeat timeout detection
- Auto-restart for persistent agents
- Graceful shutdown handling
- Ephemeral vs persistent agent lifecycle

**Related Files:** New `src/core/agent_manager.nim` required

### **7. Advanced Features** *(Not Started)*
- delta integration for git-style diff visualization
- Context squashing with `/squash` command
- Recursive task spawning with depth limits
- Enhanced content display options

**Related Files:** `src/ui/cli.nim`, `src/tools/task.nim`

### **8. Provider Support** *(Partially Implemented)*
- Dedicated Claude API client (beyond OpenAI-compatible)
- Unified provider interface
- Provider-specific optimizations

**Related Files:** `src/api/http_client.nim`, `src/types/models.nim`

## Detailed Implementation Guides

For comprehensive technical details, architecture decisions, and implementation patterns, see:

- **[Development Guide](DEVELOPMENT.md)** - Detailed architecture, patterns, and implementation
- **[Architecture Overview](ARCHITECTURE.md)** - System design and technical architecture
- **[Task System](TASK.md)** - Multi-agent architecture and agent system design
- **[Examples](EXAMPLES.md)** - Common usage patterns and workflows

## Priority Guidelines

**High Priority:**
- Process management and health monitoring (robustness)
- Enhanced message persistence (data quality)

**Medium Priority:**
- Thread channel optimization (performance)
- Advanced context management (usability)
- UI/UX polish (user experience)

**Lower Priority:**
- Advanced features (enhancements)
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

**Last Updated:** 2025-12-02
**Current Version:** 0.4.0
**Next Milestone:** Enhanced process management and monitoring
