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

### **1. Complete Task Tool Integration** *(HIGH PRIORITY)*

**Missing Functionality:**
- [ ] Integrate tool execution into task executor conversation loop (currently returns "integration pending" error)
- [ ] Extract artifacts (file paths) from task conversations
- [ ] Add task result visualization in main conversation
- [ ] Support nested task spawning with depth limits

**Current Status:** Framework exists (src/core/task_executor.nim) but tool calls during task execution are not yet handled (line 244).

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

### **9. Advanced File Features** *(LOW PRIORITY)*

- [ ] Advanced change detection with timestamps
- [ ] Enhanced git integration for repository awareness
- [ ] Session save/restore functionality
- [ ] Export capabilities for conversations (current: SQLite database access)

## Fun Easter Eggs *(LOW PRIORITY)*

- [ ] `/niffler` - ASCII art niffler creature
- [ ] `/coffee` - Coffee break messages
