# Niffler TODO

Niffler is an AI-powered terminal assistant written in Nim with Plan/Code workflow.

## Remaining Tasks

### **1. Enhanced Message Persistence** *(HIGH PRIORITY)*

**Tool Call Integration:**
- [ ] Extend database schema to store tool calls with rich metadata
- [ ] Track tool execution time, success/failure, parameters
- [ ] Link tool calls to specific messages and conversations

**Message Metadata Support:**
- [ ] Add summary flags to mark condensed messages
- [ ] Store tool metadata (execution context, timing, results)
- [ ] Support multiple content blocks per message

**Rich Content Support:**
- [ ] Handle multi-part messages (text + code + images)
- [ ] Store content type metadata for different message parts
- [ ] Support message threading and reply structures

**Conversation Summarization:**
- [ ] Add marking system for condensed summaries
- [ ] Implement LLM-powered summarization integration
- [ ] Track original vs summarized content relationships

### **2. Advanced Context Management** *(HIGH PRIORITY)*

**User-Controlled Condensing:**
- [ ] Add user preference for condensing vs sliding window
- [ ] Implement interactive condensing approval flow
- [ ] Provide context size indicators and warnings

**LLM-Powered Summarization:**
- [ ] Create summarization tool for context condensing
- [ ] Implement fallback to sliding window if summarization fails
- [ ] Track summarization quality and user feedback

**Transparent Management:**
- [ ] Add clear indicators when context operations occur
- [ ] Show before/after token counts for context changes
- [ ] Provide undo/restore options for context modifications

**Advanced @ Referencing:**
- [ ] Extend @ syntax for folder references (@folder/)
- [ ] Support glob patterns in @ references (@*.py, @src/*)
- [ ] Fix the search and completion to be smarter

### **3. User Message Queue & Always-There Input** *(HIGH PRIORITY)*

**Message Queueing System:**
- [ ] Implement user message queue for background processing
- [ ] Queue multiple user inputs while model is responding
- [ ] Handle queue priority and ordering
- [ ] Support message cancellation and reordering
- [ ] Prevent message loss during streaming

**Always-There Input Prompt:**
- [ ] Persistent input field that's always available
- [ ] Allow typing while model is streaming/responding
- [ ] Non-blocking input collection
- [ ] Visual indicator for queued messages
- [ ] Hotkey to interrupt current response and send queued input

**Input State Management:**
- [ ] Track input state across conversation turns
- [ ] Preserve partial input during interruptions
- [ ] Auto-save draft messages
- [ ] Input history separate from conversation history
- [ ] Multi-line input support with proper formatting

### **4. Multi-Config System** *(MEDIUM PRIORITY)*
*Based on IDEAS.md*

**Three-Model Configs:**
- [ ] Plan model with default reasoning level
- [ ] Code model optimized for implementation
- [ ] Fast tool model for quick operations

**Hotkey Support:**
- [ ] Switch model (rotate within current mode)
- [ ] Switch plan/code mode
- [ ] Switch config (rotate among full configs)  
- [ ] Switch reasoning level

**Dynamic System Prompt Selection:**
- [ ] Analyze prompt using fast model
- [ ] Select appropriate system prompt based on context
- [ ] Multiple specialized system prompts available

### **5. UI/UX Polish** *(MEDIUM PRIORITY)*

**Enhanced Help System:**
- [ ] Update `/help` command for Plan/Code workflow
- [ ] Add contextual help for current mode
- [ ] Document plan mode file protection behavior

**Status Indicators:**
- [ ] Show current model in prompt/status line
- [ ] Display token count and context window usage
- [ ] Add connection status indicators

**History Navigation:**
- [ ] Implement arrow key navigation through command history
- [ ] Add search functionality in command history
- [ ] Persist command history across sessions

**Custom Slash Commands:**
- [ ] Support user-defined slash commands
- [ ] Command registration and dispatch system
- [ ] Parameterized command support

### **6. Advanced Features** *(MEDIUM PRIORITY)*

**Content Visualization:**
- [ ] Use delta for git-style diff visualization
- [ ] Use batcat for enhanced content display
- [ ] Configurable external renderers

**Context Squashing:**
- [ ] `/squash` command for context compression
- [ ] Start new chat after heavy plan building
- [ ] Preserve important context during squash

**Sub-Task Spawning:**
- [ ] Spawn "self" instances for sub-tasks
- [ ] Built-in tool call for task delegation
- [ ] New context per sub-task

### **7. Provider Support** *(LOW PRIORITY)*

**Anthropic Integration:**
- [ ] Add dedicated Claude API client with thinking token support
- [ ] Create unified provider interface
- [ ] Add provider-specific optimizations

### **8. Advanced File Features** *(LOW PRIORITY)*

- [ ] Advanced change detection with timestamps
- [ ] Git integration for repository awareness
- [ ] Session save/restore functionality
- [ ] Export capabilities for conversations

### **9. MCP Integration** *(FUTURE)*

- [ ] Model Context Protocol client implementation
- [ ] Dynamic external tool loading
- [ ] Service discovery and security model

## Fun Easter Eggs *(LOW PRIORITY)*

- [ ] `/niffler` - ASCII art niffler creature
- [ ] `/magic` - Magic mode with sparkles
- [ ] `/coffee` - Coffee break messages
- [ ] Seasonal surprises and developer humor
- [ ] Configuration toggle for easter eggs
