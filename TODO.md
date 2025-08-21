# Niffler Development Roadmap

*Consolidated roadmap and implementation guide - Last updated: August 2025*

## Project Overview

Niffler is an AI-powered terminal assistant written in Nim, designed to provide an agentic coding experience with Plan/Code workflow inspired by Claude Code. This document consolidates all development planning and tracks progress toward feature parity and enhancement beyond the original Octofriend.

## Current Implementation Status

**Core Infrastructure:**
- ✅ Multi-threaded architecture with dedicated workers
- ✅ OpenAI-compatible HTTP client with SSL support
- ✅ Configuration management (TOML-based) with environment variables
- ✅ Basic CLI interface with commands (`/help`, `/models`, `/clear`)
- ✅ SQLite-based message history tracking
- ✅ Debug logging control

**Tool System (6/6 tools completed):**
- ✅ **bash** - Command execution with timeout/process management
- ✅ **read** - File reading with encoding detection and size limits
- ✅ **list** - Directory listing with filtering and metadata
- ✅ **edit** - Diff-based editing with backup system
- ✅ **create** - File creation with safety checks
- ✅ **fetch** - HTTP/HTTPS content fetching with scraping
- ✅ Tool registry, JSON schema validation, and worker threading
- ✅ Exception-based error handling with custom types

**LLM Integration:**
- ✅ **Tool Calling** - Complete OpenAI-compatible tool calling pipeline
- ✅ **Multi-turn Conversations** - Tool results integrated into conversation flow
- ✅ **Streaming Infrastructure** - Real network-level SSE streaming using Curly/libcurl
- ✅ **Context Management** - Basic message history with tool result integration

## Gap Analysis: Key Missing Features for Agentic Coding

### **High Priority: Core Agentic Features**

#### **1. Plan/Code Mode System**
- ❌ **Plan Mode** - Analysis, research, and planning focus with todo generation
- ❌ **Code Mode** - Implementation mode that executes plans and todos
- ❌ **Mode Switching** - Seamless transition between planning and implementation

#### **2. Dynamic System Prompt Generation** 
*Crucial for agentic behavior*
- ❌ **Context-Aware Prompts** - Generate prompts based on current workspace state
- ❌ **Workspace Context Injection** - Include current directory, recent files, open tabs
- ❌ **Tool Availability Awareness** - Only describe actually available tools
- ❌ **Instruction File Support** - Automatically include CLAUDE.md, OCTO.md project instructions and find them in hierarchy
- ❌ **Environment Information** - Current time, git status, OS information

#### **3. Todolist Tool Implementation**
*Essential agentic feature for task breakdown and tracking*
- ❌ **Structured Todo Management** - Parse/generate markdown checklists with state tracking
- ❌ **State Persistence** - Maintain todo state across conversation turns
- ❌ **User Approval Flow** - Show proposed todo updates before applying
- ❌ **Progress Integration** - Link todos to actual implementation progress
- ❌ **Plan Mode Integration** - Generate comprehensive implementation plans as todos

#### **4. Enhanced Message Persistence**
*Building on existing SQLite foundation*
- ❌ **Tool Call Integration** - Store tool calls and results with messages
- ❌ **Message Metadata** - Support timestamps, summary flags, tool metadata
- ❌ **Rich Content Support** - Handle multiple content blocks per message
- ❌ **Conversation Summarization** - Mark messages as condensed summaries

### **Medium Priority: User Experience**

#### **5. Context Management**
*User-controlled*
- ❌ **Context Window Monitoring** - Warn when approaching token limits
- ❌ **User-Controlled Condensing** - Let user choose condensing vs sliding window
- ❌ **Conversation Summarization** - LLM-powered context condensing with fallback
- ❌ **Transparent Management** - Clear indication of context operations
- ❌ **@ Referencing** - No context referencing system (@file.txt, @folder/)

#### **6. Basic Terminal UI Enhancements**
- ❌ **Enhanced help system** - Update for new Plan/Code workflow
- ❌ **Markdown Rendering** - Basic markdown display for responses
- ❌ **Colored Output** - Syntax highlighting and colored diffs
- ❌ **Status Indicators** - Model, token count, mode, connection status
- ❌ **History Navigation** - Arrow key navigation through prompt history

### **Lower Priority: Advanced Features**

#### **7. Multiple Provider Support**
- ❌ **Anthropic Integration** - Dedicated Claude API client, not sure needed, OpenAPI seems like a good standard?
- ❌ **Provider-Specific Features** - Thinking tokens, reasoning content
- ❌ **Reasoning Effort** - No low/medium/high reasoning control

#### **8. File Enhancement Features**
- ❌ **Advanced Change Detection** - Timestamp-based file modification tracking
- ❌ **Git Integration** - Git-aware file operations and status
- ❌ **Session Management** - Save/restore conversation sessions

#### **9. MCP Integration** *(Future consideration)*
- ❌ **MCP Client** - Model Context Protocol support
- ❌ **External Tools** - Dynamic tool loading from servers
- ❌ **Service Discovery** - Automatic MCP server detection

## Diff rendering
**`hldiff`** - Perfect for git-style diffs
   - Ports Python's difflib with ~100x performance improvement
   - Colored terminal output with customizable ANSI/SGR escapes
   - Git diff compatibility: `git diff | hldiff`
   - Installation: `nimble install hldiff`

## Implementation Phases

### **Phase 5: Agentic Core (IMMEDIATE PRIORITY)**

#### 5.1: Plan/Code Mode System
- [ ] Implement mode switching (we do not need mode **detection**)
- [ ] Define mode-specific behavior and prompts  
- [ ] Add mode indicator in the prompt, color and perhaps added "(plan)" text

#### 5.2: Dynamic System Prompt Generation
- [ ] Create modular prompt assembly system
- [ ] Implement workspace context detection (cwd, recent files)
- [ ] Add instruction file discovery (CLAUDE.md, OCTO.md)
- [ ] Include environment information (time, git status)
- [ ] Add tool availability awareness

#### 5.3: Todolist Tool Implementation
- [ ] Create todo data structures and persistence
- [ ] Implement markdown checklist parsing/generation
- [ ] Add user approval flows for todo updates
- [ ] Integrate with Plan mode for task breakdown
- [ ] Link todos to Code mode implementation progress

#### 5.4: Enhanced Message Persistence
- [ ] Extend SQLite schema for tool calls and metadata
- [ ] Add support for rich content blocks
- [ ] Implement conversation summarization flags
- [ ] Maintain backward compatibility with existing history

### **Phase 6: User Experience (HIGH PRIORITY)**

#### 6.1: Context Management
- [ ] Add token counting and context window monitoring
- [ ] Implement user-controlled conversation condensing
- [ ] Create LLM-powered summarization with sliding window fallback
- [ ] Add transparent context operation indicators

#### 6.2: CLI and UI Improvements
- [ ] Enhance terminal output with basic markdown rendering
- [ ] Add colored diffs and syntax highlighting
- [ ] Implement status indicators and history navigation

### **Phase 7: Provider Support (MEDIUM PRIORITY)**

#### 7.1: Anthropic Integration
- [ ] Add thinking tokens and reasoning content support
- [ ] Create unified provider interface
- [ ] Add provider-specific optimizations

### **Phase 8: Advanced Features (LOWER PRIORITY)**

#### 8.1: File and Session Management
- [ ] Advanced file change detection and tracking
- [ ] Git integration for repository awareness
- [ ] Session save/restore functionality
- [ ] Export capabilities for conversations

#### 8.2: MCP Integration (Future)
- [ ] Model Context Protocol client implementation
- [ ] Dynamic external tool loading
- [ ] Service discovery and security model

## Architecture Principles

### **Agentic Design Patterns** *(learned from Claude Code and Roo Code)*
- **Plan First**: Always break down complex tasks into actionable todos
- **User Control**: Transparent operations with user approval for major changes
- **Context Awareness**: Dynamic prompts based on current workspace state
- **Tool Orchestration**: Sophisticated tool coordination with error recovery
- **Mode Separation**: Clear distinction between planning and implementation

### **Nim-Specific Approach**
- **Threading Over Async**: Maintain current thread-based architecture
- **Exception Handling**: Continue exception-based error handling where appropriate
- **Memory Management**: Leverage Nim's deterministic memory management
- **Performance**: Target equal or better performance than TypeScript alternatives

### **Quality Gates**
- Thread-safe operations throughout
- User transparency and control maintained

## Success Metrics

### **Phase Completion Criteria**
- **Phase 5**: Plan/Code modes working with dynamic prompts and todolist tool
- **Phase 6**: Real streaming, context management, and enhanced CLI working
- **Phase 7**: Multi-provider support with Anthropic integration
- **Phase 8**: Advanced file management and session capabilities

### **Agentic Capability Goal**
Target: Full agentic coding assistant capability with Plan/Code workflow supporting complex multi-step development tasks.

**Current Progress: ~80% Foundation Complete**
- ✅ Tool System: 100% (all 6 core tools implemented)
- ✅ Threading Architecture: 100% (robust worker system)
- ✅ LLM Integration: 95% (tool calling and real streaming working)
- ❌ Agentic Features: 20% (basic conversations, needs Plan/Code modes and todos)
- ❌ Dynamic Prompts: 10% (static prompts, needs context awareness)
- ❌ User Experience: 30% (CLI needs more refinement)

## Immediate Next Steps

1. **Implement Plan/Code Mode System**: Core agentic workflow foundation
2. **Add Dynamic System Prompt Generation**: Context-aware prompt assembly  
3. **Create Todolist Tool**: Essential for task breakdown and tracking
4. **Enhanced Message Persistence**: Support tool calls and conversation metadata

## Key Insights from Research

### **From Claude Code:**
- Plan/Code workflow is more intuitive than complex multi-mode systems
- Todolist tool is essential for agentic behavior and user transparency
- User approval flows prevent surprises while maintaining autonomy

### **From Roo Code:**
- Dynamic system prompt generation dramatically improves context awareness
- Structured message persistence enables sophisticated conversation management
- User-controlled context management prevents unwanted automatic behaviors
- Modular prompt assembly allows flexible agent behavior

### **Design Philosophy:**
- Embrace simplicity over complexity (Plan/Code vs multi-mode)
- Prioritize user control and transparency
- Build on solid foundation (current tool system is excellent)
- Focus on agentic patterns that demonstrably improve coding workflows

This roadmap represents a focused path toward creating a sophisticated agentic coding assistant while maintaining Niffler's core design principles and Nim-based architecture.