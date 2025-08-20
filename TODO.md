# Niffler Development Roadmap

This document outlines the features from the original Octofriend (TypeScript) that haven't been ported to Niffler (Nim) yet, organized by implementation phases and complexity.

## Current Status (Phase 3 Complete ✅)

**What Niffler Has:**
- ✅ Basic CLI interface with interactive chat
- ✅ Configuration management for models and API keys  
- ✅ HTTP client for OpenAI-compatible APIs
- ✅ Threading-based architecture (no async)
- ✅ Basic message history tracking
- ✅ Model switching and basic commands (`/help`, `/models`, `/clear`)
- ✅ Debug logging control
- ✅ SSL/HTTPS support
- ✅ Environment variable configuration

## Phase 4: Tool System (High Priority)

### Core Tools Implementation
- [x] **bash** - Execute shell commands with timeout and process management
  - [x] Command execution with proper error handling
  - [x] Process timeout and signal management
  - [x] Output streaming and capture
  - [x] Working directory and environment control

- [x] **read** - Read file contents with change tracking
  - [x] File timestamp tracking for modifications
  - [x] Safe reading with encoding detection
  - [ ] Change notification system
  - [x] File size limits and streaming for large files

- [x] **list** - Directory listing with filtering
  - [x] Directory traversal with depth limits
  - [x] File/directory filtering and sorting
  - [x] Permission and metadata display
  - [x] Hidden file handling

- [x] **edit** - Advanced file editing operations
  - [x] Diff-based editing with preview
  - [x] Append/prepend operations
  - [x] Rewrite mode with backup
  - [x] Edit validation and conflict detection

- [x] **create** - File creation with safety checks
  - [x] Existence checking and confirmation
  - [x] Directory creation as needed
  - [ ] Template support
  - [x] Permission setting

- [x] **fetch** - HTTP/HTTPS content fetching
  - [x] Web scraping with HTML-to-text conversion
  - [x] Header customization and authentication
  - [x] Response size limits and streaming
  - [x] Content type detection and handling

### Tool Infrastructure
- [x] Tool validation and argument parsing
- [ ] Tool confirmation system with user interaction
- [x] Tool error handling and recovery mechanisms
- [x] Tool output processing and formatting
- [x] Tool execution queue and threading

## Phase 5: Advanced LLM Integration

### Streaming and Tool Calling
- [ ] **Real-time streaming** - Proper Server-Sent Events (SSE) parsing
- [ ] **Tool calling** - JSON schema validation and execution
- [ ] **Function calling** - Integration with tool system
- [ ] **Multi-turn conversations** - Context management across tool calls

### Provider-Specific Features
- [ ] **Anthropic integration** - Native Anthropic API client
  - Tool use format support
  - Thinking/reasoning content parsing
  - XML tag processing
- [ ] **OpenAI advanced features** - Function calling, vision, etc.
- [ ] **Provider auto-detection** - Smart model routing

### Context Management
- [ ] **Context window management** - Intelligent message truncation
- [ ] **Token counting** - Accurate token estimation per model
- [ ] **History compression** - Smart conversation summarization
- [ ] **Message windowing** - Automatic context optimization

## Phase 6: Rich Terminal UI

### Interactive Components (Requires Terminal UI Library)
- [ ] **Rich terminal interface** - Beyond basic text I/O
  - Colored output and syntax highlighting
  - Progress bars and loading indicators
  - Interactive menus and navigation
  - Panel layouts and text wrapping

- [ ] **Streaming display** - Real-time response rendering
  - Typewriter effect for responses
  - Diff visualization with colors
  - Tool output formatting
  - Status indicators

- [ ] **Menu system** - ESC-triggered navigation
  - Main menu with options
  - Model selection interface
  - Settings configuration UI
  - Help system with navigation

### User Experience
- [ ] **Keyboard shortcuts** - Efficient navigation
- [ ] **Copy/paste integration** - System clipboard support
- [ ] **Session management** - Save/restore conversations
- [ ] **Export functionality** - Markdown, text, JSON exports

## Phase 7: File Management System

### File Tracking and Safety
- [ ] **File modification detection** - Timestamp-based tracking
- [ ] **Safe editing** - Prevent editing of modified files
- [ ] **File locking** - Multi-process safety
- [ ] **Backup system** - Automatic backups before edits

### Directory Operations  
- [ ] **Workspace management** - Project-aware file operations
- [ ] **File watching** - Real-time change notifications
- [ ] **Git integration** - Git-aware file operations
- [ ] **Permission management** - Safe file permission handling

## Phase 8: Configuration and Setup

### Advanced Configuration
- [ ] **Multi-model management** - Complex model configurations
  - Model-specific settings (temperature, context, etc.)
  - Provider-specific authentication
  - Reasoning levels (low/medium/high)
  - Custom endpoints and parameters

- [ ] **Interactive setup wizard** - First-time user experience
  - Model detection and configuration
  - API key setup flow
  - Feature discovery and onboarding

### Configuration Features
- [ ] **Model Context Protocol (MCP)** - External tool integration
- [ ] **Autofix models** - Specialized correction models
- [ ] **Default overrides** - User preference management
- [ ] **Profile management** - Multiple configuration profiles

## Phase 9: Autofix System

### Error Recovery
- [ ] **Diff Apply** - Automatic fixing of edit mistakes
  - Integration with specialized diff-fix models
  - Smart diff parsing and correction
  - Confidence scoring and user confirmation

- [ ] **JSON Fix** - Malformed JSON correction
  - Tool call JSON repair
  - Schema validation and fixing
  - Fallback to manual correction

- [ ] **Error Recovery** - Automatic retry with fixes
  - Context-aware error analysis
  - Automatic prompt refinement
  - Progressive fallback strategies

## Phase 10: Model Context Protocol (MCP)

### MCP Client Implementation
- [ ] **Server connection** - MCP server communication
- [ ] **Tool discovery** - Dynamic tool loading from servers
- [ ] **Resource access** - File system and external resource access
- [ ] **Caching system** - Performance optimization for MCP calls

### MCP Integration
- [ ] **External tools** - Integration with external services
- [ ] **Service discovery** - Automatic MCP server detection
- [ ] **Protocol versioning** - Multiple MCP version support
- [ ] **Security model** - Safe execution of external tools

## Phase 11: Developer Experience

### Advanced Features
- [ ] **System prompts** - Dynamic system prompt generation
- [ ] **Instruction files** - Support for CLAUDE.md, OCTO.md
- [ ] **XML utilities** - Structured response parsing
- [ ] **Debug tools** - Advanced debugging and inspection

### Logging and Monitoring
- [ ] **Comprehensive logging** - Detailed operation logs
- [ ] **Performance metrics** - Token usage and timing
- [ ] **Error tracking** - Crash reporting and recovery
- [ ] **Usage analytics** - Feature usage statistics

## Phase 12: Security and Reliability

### Security Enhancements
- [ ] **Secure key storage** - Encrypted API key management
- [ ] **Input validation** - Comprehensive input sanitization
- [ ] **Sandbox execution** - Safe tool execution environment
- [ ] **Permission system** - Fine-grained access controls

### Reliability Features
- [ ] **Comprehensive error handling** - Robust error recovery
- [ ] **Retry logic** - Smart retry with backoff
- [ ] **Abort handling** - Proper cancellation support
- [ ] **Memory management** - Efficient resource usage

## Implementation Priority Guide

### Must Have (Core Functionality)
1. **Tool System** - Essential for AI coding assistant functionality
2. **Advanced LLM Integration** - Required for proper AI interaction
3. **File Management** - Critical for safe file operations

### Should Have (Enhanced Experience)  
1. **Rich Terminal UI** - Significantly improves user experience
2. **Configuration Management** - Better usability and setup
3. **Autofix System** - Reduces user friction

### Nice to Have (Advanced Features)
1. **MCP Integration** - Extensibility and external tool access
2. **Developer Experience** - Advanced debugging and customization
3. **Security Enhancements** - Production-ready security

## Technical Considerations

### Nim-Specific Challenges
- **Terminal UI Library**: Need equivalent to React/Ink (consider `illwill` or custom solution)
- **Async vs Threading**: Maintain threading-based approach while handling streaming
- **JSON Schema**: Need runtime validation equivalent to TypeScript's `structural`
- **HTTP Streaming**: Proper SSE parsing without async/await

### Architecture Decisions
- **Taskpools**: Consider migrating from threads to taskpools as suggested
- **Options Avoidance**: Continue minimizing Option usage as requested
- **Error Handling**: Prefer explicit error types over exceptions where possible
- **Memory Management**: Leverage Nim's deterministic memory management

## Success Metrics

### Phase Completion Criteria
- [ ] **Tool System**: All core tools functional with proper error handling
- [ ] **LLM Integration**: Streaming responses and tool calling working
- [ ] **Terminal UI**: Rich interface with menu navigation
- [ ] **File Management**: Safe file operations with change detection
- [ ] **Feature Parity**: 80%+ of Octofriend features working in Niffler

### Quality Gates
- All features must compile with `--threads:on -d:ssl`
- Comprehensive error handling for all API interactions
- Thread-safe operations throughout
- Minimal Options usage maintained
- Performance comparable to or better than TypeScript version


## Claude Code features

- Custom /-commands
- Task with indented arrow showing what was done
- Markdown rendering
- Diff rendering with red and gren
