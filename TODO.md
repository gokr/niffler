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
- ❌ **Thinking Token Streaming** - Real-time processing of reasoning content during streaming

## Gap Analysis: Key Missing Features for Agentic Coding

### **High Priority: Core Agentic Features**

#### **1. Plan/Code Mode System**
- ✅ **Plan Mode** - Analysis, research, and planning focus with specialized prompts
- ✅ **Code Mode** - Implementation mode that executes plans with specialized prompts
- ✅ **Mode Switching** - Seamless transition between planning and implementation (Shift+Tab)

#### **2. Dynamic System Prompt Generation** 
*Crucial for agentic behavior*
- ✅ **Context-Aware Prompts** - Generate prompts based on current workspace state
- ✅ **Workspace Context Injection** - Include current directory, git status, project info
- ✅ **Tool Availability Awareness** - Only describe actually available tools
- ✅ **Instruction File Support** - Automatically include CLAUDE.md, OCTO.md project instructions and find them in hierarchy
- ✅ **Environment Information** - Current time, git status, OS information
- ✅ **NIFFLER.md System Prompts** - Extract system prompts from NIFFLER.md with fallback to defaults
- ✅ **File Inclusion Support** - @include directive for modular instruction files
- ✅ **Config Directory Search** - System-wide NIFFLER.md in ~/.niffler/

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
- ❌ **Thinking Token Storage** - Store reasoning content separately with encryption support

### **Medium Priority: User Experience**

#### **5. Context Management**
*User-controlled*
- ❌ **Context Window Monitoring** - Warn when approaching token limits
- ❌ **User-Controlled Condensing** - Let user choose condensing vs sliding window
- ❌ **Conversation Summarization** - LLM-powered context condensing with fallback
- ❌ **Transparent Management** - Clear indication of context operations
- ❌ **@ Referencing** - No context referencing system (@file.txt, @folder/)
- ❌ **Thinking Token Budget Management** - Dynamic token allocation for reasoning vs output content

#### **6. Basic Terminal UI Enhancements**
- ❌ **Enhanced help system** - Update for new Plan/Code workflow
- ❌ **Markdown Rendering** - Basic markdown display for responses
- ❌ **Colored Output** - Syntax highlighting and colored diffs
- ❌ **Status Indicators** - Model, token count, mode, connection status
- ❌ **History Navigation** - Arrow key navigation through prompt history

### **Lower Priority: Advanced Features**

#### **7. Thinking Token Support** *(NEW HIGH PRIORITY)*
*Essential for next-generation reasoning models like GPT-5 and Claude 4*
- ❌ **Multi-Provider Thinking Architecture** - Separate handling for Anthropic thinking blocks vs OpenAI reasoning content
- ❌ **Unified Thinking Token IR** - Consistent interface with `reasoningContent`, `encryptedReasoningContent`, `reasoningId` fields
- ❌ **Streaming Thinking Processing** - Real-time thinking token handling with separate callbacks
- ❌ **Budget Configuration** - Configurable reasoning levels (low: 2048, medium: 4096, high: 8192 tokens)
- ❌ **Encryption Support** - Handle both clear-text and redacted/encrypted thinking blocks
- ❌ **Context-Aware Windowing** - Intelligent preservation of important reasoning content
- ❌ **Provider Abstraction** - Unified interface while preserving provider-specific features

#### **8. Multiple Provider Support**
- ❌ **Anthropic Integration** - Dedicated Claude API client with thinking token support
- ❌ **Provider-Specific Features** - Thinking tokens, reasoning content, encrypted content
- ❌ **Reasoning Effort** - Configurable low/medium/high reasoning control

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

### **Phase 5: Agentic Core (COMPLETED ✅)**

#### 5.1: Plan/Code Mode System
- [x] Implement mode switching (Shift+Tab toggle)
- [x] Define mode-specific behavior and prompts  
- [x] Add mode indicator in the prompt, color and "(plan)"/"(code)" text

#### 5.2: Dynamic System Prompt Generation
- [x] Create modular prompt assembly system
- [x] Implement workspace context detection (cwd, git status, project info)
- [x] Add instruction file discovery (CLAUDE.md, OCTO.md, NIFFLER.md, AGENT.md)
- [x] Include environment information (time, git status, OS information)
- [x] Add tool availability awareness
- [x] NIFFLER.md system prompt extraction with fallback to hardcoded defaults
- [x] File inclusion support (@include directive)
- [x] Config directory search for system-wide NIFFLER.md
- [x] Init command creates default NIFFLER.md for user customization

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

### **Phase 7: Thinking Token Support (HIGH PRIORITY)**

#### 7.1: Multi-Provider Thinking Architecture
- [ ] Implement Anthropic thinking block parser (streaming XML-like format)
- [ ] Add OpenAI reasoning content handler (native reasoning_content field)
- [ ] Create provider detection and routing logic

#### 7.2: Unified Thinking Token IR
- [ ] Extend message types with reasoningContent, encryptedReasoningContent, reasoningId
- [ ] Create thinking token abstraction layer
- [ ] Add provider-specific metadata support

#### 7.3: Streaming and Budget Management
- [ ] Implement real-time thinking token processing during streaming
- [ ] Add configurable reasoning budgets (low/medium/high)
- [ ] Create dynamic token allocation between reasoning and output

### **Phase 8: Provider Support (MEDIUM PRIORITY)**

#### 8.1: Anthropic Integration
- [ ] Add dedicated Claude API client with thinking token support
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
- **Phase 7**: Thinking token support across providers with unified IR and streaming
- **Phase 8**: Multi-provider support with Anthropic integration
- **Phase 9**: Advanced file management and session capabilities

### **Agentic Capability Goal**
Target: Full agentic coding assistant capability with Plan/Code workflow supporting complex multi-step development tasks.

**Current Progress: ~95% Foundation Complete**
- ✅ Tool System: 100% (all 6 core tools implemented)
- ✅ Threading Architecture: 100% (robust worker system)
- ✅ LLM Integration: 95% (tool calling and real streaming working)
- ✅ Agentic Features: 90% (Plan/Code modes implemented, needs todolist tool)
- ✅ Dynamic Prompts: 100% (context-aware prompts with NIFFLER.md support)
- ❌ User Experience: 30% (CLI needs more refinement)

## Immediate Next Steps

1. ✅ **Plan/Code Mode System**: COMPLETED - Core agentic workflow foundation
2. ✅ **Dynamic System Prompt Generation**: COMPLETED - Context-aware prompt assembly with NIFFLER.md support
3. **Create Todolist Tool**: Essential for task breakdown and tracking (CURRENT PRIORITY)
4. **Thinking Token Support**: Critical for next-generation reasoning models (HIGH PRIORITY)
5. **Enhanced Message Persistence**: Support tool calls, conversation metadata, and thinking token storage

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

### **From Octofriend:**
- Thinking token support is essential for next-generation reasoning models (GPT-5, Claude 4)
- Multi-provider architecture enables seamless switching between LLM providers
- Unified IR with provider-specific features preserves capabilities while maintaining consistency
- Streaming thinking token processing enables real-time reasoning display
- Budget management prevents thinking tokens from overwhelming context windows
- Encryption support future-proofs against privacy-preserving reasoning models

### **Design Philosophy:**
- Embrace simplicity over complexity (Plan/Code vs multi-mode)
- Prioritize user control and transparency
- Build on solid foundation (current tool system is excellent)
- Focus on agentic patterns that demonstrably improve coding workflows

This roadmap represents a focused path toward creating a sophisticated agentic coding assistant while maintaining Niffler's core design principles and Nim-based architecture.