# Niffler Project Status & Roadmap

*Consolidated status and todo document - Last updated: August 2025 (MAJOR UPDATE)*

## Project Overview

Niffler is an AI-powered terminal assistant written in Nim, designed to replicate and enhance the functionality of the original Octofriend (TypeScript). This document tracks our progress in achieving feature parity and beyond.

## Current Implementation Status

### ✅ **Phase 1-3: Foundation (COMPLETED)**
- Multi-threaded architecture with dedicated workers
- OpenAI-compatible HTTP client with SSL support
- Configuration management (TOML-based)
- Basic CLI interface with commands (`/help`, `/models`, `/clear`)
- Message history tracking
- Environment variable support
- Debug logging control

### ✅ **Phase 4: Tool System (COMPLETED)**

**Core Tool Infrastructure:**
- Exception-based error handling with custom types
- Tool registry and discovery system  
- Dedicated tool worker thread
- Thread-safe channel communication
- JSON schema validation framework

**Implemented Tools (6/6):**
- **bash** - Command execution with timeout/process management
- **read** - File reading with encoding detection and size limits
- **list** - Directory listing with filtering and metadata
- **edit** - Diff-based editing with backup system
- **create** - File creation with safety checks
- **fetch** - HTTP/HTTPS content fetching with scraping

### ✅ **Phase 5: Advanced LLM Integration (LARGELY COMPLETED)**

**✅ Tool Calling Infrastructure - FULLY IMPLEMENTED:**
- ✅ **Tool Calling** - Complete OpenAI-compatible tool calling with execution pipeline
- ✅ **JSON Schema Validation** - All tools have schema validation and parameter checking
- ✅ **Multi-turn Conversations** - Tool results integrated back into conversation flow
- ✅ **Tool Call Buffering** - Sophisticated fragment buffering for partial tool calls during streaming
- ✅ **Error Recovery** - Comprehensive error handling and timeout management
- ✅ **Tool Confirmation** - Implemented in individual tools (bash, edit, create require confirmation)

**✅ Streaming Infrastructure - IMPLEMENTED (but simulated):**
- ✅ **Server-Sent Events** - SSE parsing and chunk processing (simulated streaming)
- ✅ **Streaming Message Handler** - Real-time chunk processing with callbacks
- ✅ **Tool Execution During Streaming** - Tools execute during streaming responses
- ⚠️ **Real Network Streaming** - Currently simulated (receives full response then processes chunks)

**✅ Context Management:**
- ✅ **Message History** - Complete conversation history tracking
- ✅ **Tool Result Integration** - Tool results properly formatted and included in context

## Gap Analysis: Niffler vs Octofriend

### **Major Missing Features**

#### **LLM Integration (High Priority)**
- ⚠️ **Real-time Streaming** - SSE parsing implemented but simulated (needs real network streaming)
- ✅ **Tool Calling** - Complete OpenAI-compatible tool calling system implemented
- ❌ **Multiple Providers** - Only OpenAI-compatible APIs (needs dedicated Anthropic client)
- ❌ **Thinking Tokens** - Reasoning content parsing not implemented
- ✅ **Context Management** - Basic message history and tool result integration working

#### **Rich Terminal UI (High Priority)**
- ❌ **Enhanced Interface** - Prompt box at bottom with status indicators
- ✅ **Streaming Display** - Real-time response rendering working (with simulated streaming)
- ❌ **Colored Output** - No syntax highlighting or colored diffs yet
- ❌ **Command System** - Uses `/` commands, not ESC menus (by design)
- ❌ **Status Indicators** - No model, token count, or status display
- ❌ **History Navigation** - No arrow key navigation through prompt history
- ❌ **@ Referencing** - No context referencing system (@file.txt, @folder/)
- ❌ **Markdown Rendering** - No markdown parsing and display

#### **Auto-fix System (Octofriend's Key Differentiator)**
- ❌ **Diff Apply** - ML models for fixing edit mistakes
- ❌ **JSON Fix** - Malformed JSON correction
- ❌ **Error Recovery** - Automatic retry with smart fixes

#### **Advanced Features**
- ❌ **MCP Integration** - Model Context Protocol for external tools
- ✅ **File Safety** - Path validation and safety checks implemented in tools
- ❌ **Session Management** - No save/restore conversations
- ❌ **Reasoning Effort** - No low/medium/high reasoning control
- ✅ **Tool Confirmation** - Interactive confirmations for dangerous operations (bash, edit, create)

### **Minor Missing Features**
- Web tool for browsing (vs just fetch)
- Export functionality (markdown, JSON)
- Keyboard shortcuts and copy/paste
- Workspace management
- Git integration
- Permission management
- Interactive setup wizard

## Next Phase Priorities

### **Phase 5: Real SSE Streaming (IMMEDIATE PRIORITY)**

#### 5.1: Real Network Streaming
- [ ] Investigate alternative HTTP clients (Harpoon, etc.) for real SSE streaming
- [ ] Replace simulated streaming with true server-sent events parsing
- [ ] Maintain thread-based architecture (no async dispatch)
- [ ] Ensure tool calling integration works with new HTTP client

#### 5.2: CLI Interface Updates
- [ ] Remove `prompt` subcommand, add `--prompt/-p` option for one-liners
- [ ] Rename `list` command to `models` command
- [ ] Update help and documentation for new CLI interface

### **Phase 6: Enhanced Terminal UI (HIGH PRIORITY)**

#### 6.1: Prompt-Centric Interface
- [ ] Implement prompt box at bottom of screen
- [ ] Add fixed status indicators below prompt (model, token counts, connection status)
- [ ] Arrow key history navigation (up/down through previous prompts)
- [ ] @ referencing system for context (@file.txt, @folder/, etc.)

#### 6.2: Visual Enhancements
- [ ] Rudimentary markdown rendering via illwill library
- [ ] Colored output and syntax highlighting for responses
- [ ] Progress indicators during tool execution
- [ ] Diff visualization for file changes with colors

#### 6.3: Command System
- [ ] Enhanced `/` command system (not ESC menus)
- [ ] Model selection via `/model` command
- [ ] Help system improvements

### **Phase 7: Multiple Provider Support (MEDIUM PRIORITY)**

#### 7.1: Anthropic Integration
- [ ] Add dedicated Anthropic Claude API client
- [ ] Implement provider-specific optimizations
- [ ] Provider switching via `/model` command

#### 7.2: Provider Features
- [ ] Thinking tokens support for Claude
- [ ] Provider-specific parameter handling
- [ ] Unified provider interface

### **Phase 8: Advanced Features (LOWER PRIORITY)**

#### 8.1: Session Management
- [ ] Save/restore conversation sessions
- [ ] Export functionality (markdown, JSON)
- [ ] Workspace management

#### 8.2: File Enhancement
- [ ] Advanced file tracking and change detection
- [ ] Git integration
- [ ] Enhanced backup systems

### **Phase 9: MCP Integration (LOWER PRIORITY)**

#### 9.1: MCP Client
- [ ] Server connection and communication
- [ ] Dynamic tool loading from servers
- [ ] Resource access management
- [ ] Caching system for performance

#### 9.2: External Tools
- [ ] Integration with external services
- [ ] Service discovery
- [ ] Protocol versioning support
- [ ] Security model for external tools

## Technical Implementation Notes

### **Architecture Decisions**
- **Threading**: Maintain current thread-based approach vs async
- **Error Handling**: Continue exception-based approach where appropriate
- **Terminal UI**: Evaluate illwill library vs custom React/Ink equivalent
- **HTTP Streaming**: Implement SSE without async/await pattern

### **Nim-Specific Challenges**
- **Terminal UI Library**: Need React/Ink equivalent functionality
- **JSON Schema**: Runtime validation without TypeScript structural types
- **HTTP Streaming**: SSE parsing in threaded environment
- **Memory Management**: Leverage Nim's deterministic memory management

### **Quality Gates**
- All features must compile with `--threads:on -d:ssl`
- Comprehensive error handling for API interactions
- Thread-safe operations throughout
- Performance equal to or better than TypeScript version

## Success Metrics

### **Phase Completion Criteria**
- **Phase 5**: Streaming responses and tool calling functional
- **Phase 6**: Rich terminal interface with menu navigation  
- **Phase 7**: Basic auto-fix system working
- **Phase 8**: Safe file operations with change detection

### **Feature Parity Goal**
Target: 80%+ of Octofriend's core functionality working in Niffler by end of Phase 6.

**Current Progress: ~75%** (Major Status Update)
- ✅ Foundation: 100%
- ✅ Tool System: 95% (only MCP missing)
- ✅ **LLM Integration: 85%** (streaming + tool calling working, needs real SSE)
- ❌ Terminal UI: 15% (basic CLI, needs prompt box and enhancements)
- ❌ Provider Support: 40% (OpenAI-compatible only, needs Anthropic)
- ✅ File Management: 70% (safety features implemented in tools)

## Immediate Next Steps

1. **Fix Real SSE Streaming**: Replace simulated streaming with real network SSE parsing
2. **CLI Interface Update**: Remove prompt subcommand, add --prompt/-p option, rename list to models
3. **Enhanced Terminal UI**: Implement prompt box with status indicators and history navigation
4. **Anthropic Support**: Add dedicated Claude API client

## File Structure Status

### **Completed Implementation Files**
```
src/
├── types/
│   ├── tools.nim            # Tool system types and interfaces  
│   └── messages.nim         # LLM message types with tool calling support
├── tools/
│   ├── registry.nim         # Tool registry and discovery
│   ├── worker.nim           # Tool worker thread
│   ├── schemas.nim          # JSON schema definitions
│   ├── bash.nim             # Command execution
│   ├── read.nim             # File reading
│   ├── list.nim             # Directory listing
│   ├── edit.nim             # File editing
│   ├── create.nim           # File creation
│   └── fetch.nim            # HTTP fetching
├── api/
│   ├── httpClient.nim       # HTTP client with simulated SSE
│   └── api.nim              # API worker with full tool calling
├── core/
│   ├── app.nim              # Application lifecycle
│   └── channels.nim         # Thread communication
└── ui/
    └── cli.nim              # Basic CLI interface
```

### **Files Requiring Updates**
- `src/api/httpClient.nim` - Replace simulated streaming with real SSE parsing
- `src/ui/cli.nim` - Enhanced terminal interface with prompt box and status indicators
- `src/niffler.nim` - Update CLI interface (remove prompt subcommand, add --prompt/-p)
- CLI help system - Update documentation for new interface

This document replaces both STATUS.md and TODO.md as the single source of truth for project progress and planning.