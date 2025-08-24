# Changelog

All notable changes to the Niffler project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Log file support for centralized output control
- Enhanced conversation history debugging for tool calls
- Recursive tool calling system with deduplication and depth limits

### Changed
- Cleaned up system configuration documentation
- Improved logging system with centralized log file module

## [0.3.0] - 2025-08-22

### Added
- **Plan/Code Mode System**: Dynamic mode switching with Shift+Tab toggle
- **Dynamic System Prompt Generation**: Context-aware prompts based on workspace state
- **Tool Registry System**: Object variant-based tool definitions with centralized registry
- **Todolist Tool**: Essential agentic feature for task breakdown and tracking
- **NIFFLER.md System**: Default system prompt configuration with mode-specific sections
- **Bash-like Tab Completion**: Enhanced command completion behavior
- **Thinking Token Support**: Comprehensive analysis and roadmap for next-generation reasoning models
- **Multi-agent Architecture Documentation**: Detailed analysis of Octofriend's approach

### Changed
- Reorganized documentation structure with archived analysis docs
- Updated tests for new agentic architecture
- Enhanced configuration system with instruction file discovery

## [0.2.4] - 2025-08-16

### Added
- **CLI Framework Migration**: Replaced cligen with docopt for cleaner interface
- **Enhanced Model Configuration**: Comprehensive OpenAI protocol parameters support
- **Database Configuration**: SQLite/TiDB support with cost tracking
- **Cost Tracking**: Per-token pricing with detailed usage analytics
- **Platform-appropriate Configuration Paths**: Cross-platform directory structure

### Changed
- Updated dependencies: docopt, debby, noise
- Consolidated UI architecture
- Enhanced API streaming with improved tool call handling

## [0.2.3] - 2025-08-15

### Added
- **LICENSE**: MIT License added to project

### Changed
- Enhanced UI with improved command-line interface
- Updated option parsing and CLI framework

## [0.2.2] - 2025-08-14

### Added
- **Dynamic Colored Prompts**: Personalized prompts with cyan/green color coding
- **HTTP Request/Response Dump**: Comprehensive debugging with --dump flag
- **Real-time Streaming**: Enhanced HTTP client with streaming response logging

### Changed
- Updated README.md with comprehensive documentation
- Improved user experience with personalized prompts

## [0.2.1] - 2025-08-14

### Added
- **Comprehensive README**: Detailed project documentation with features and examples
- **Tool Buffering**: Efficient tool execution mechanism
- **Test Suite**: Basic and comprehensive test files

### Changed
- Enhanced core application architecture
- Improved history management system

## [0.2.0] - 2025-08-13

### Added
- **Tool System Infrastructure**: 6 core tools (bash, read, list, edit, create, fetch)
- **Tool Registry**: Thread-safe tool discovery and execution system
- **JSON Schema Validation**: Framework for tool parameter validation
- **Security Features**: Path sanitization, size limits, and timeouts
- **Exception Handling**: Custom tool error types and handling

### Changed
- Refactored JSON handling to use idiomatic Nim patterns
- Updated HTTP client architecture
- Enhanced CLI interface with tool-aware processing

## [0.1.3] - 2025-08-13

### Added
- **Tool Timeout Fixes**: Proper timeout control with process management
- **Process Execution**: Enhanced bash tool with timeout handling
- **Error Handling**: Distinguish timeout vs execution errors

### Changed
- Replaced execCmdEx with startProcess + waitForExit
- Increased API worker timeout from 10s to 30s

## [0.1.2] - 2025-08-13

### Added
- **Project Documentation**: Consolidated PROJECT-STATUS.md with roadmap
- **Enhanced TODO.md**: Detailed feature comparison vs Octofriend
- **STATUS.md**: Completed Phase 4 implementation documentation

### Changed
- Updated nimble configuration with new dependencies
- Enhanced gitignore for build artifacts

## [0.1.1] - 2025-08-13

### Added
- **Core Application Integration**: Tool system orchestration with API worker
- **Enhanced HTTP Client**: Improved error handling and streaming preparation
- **Multi-threaded Tool Execution**: Dedicated tool worker thread
- **Message Types**: Enhanced communication between components

### Changed
- Updated CLI interface for tool-aware command processing
- Improved application lifecycle management

## [0.1.0] - 2025-08-13

### Added
- **Initial Release**: First functional version of Niffler
- **Basic CLI Interface**: Command-line interaction system
- **API Integration**: OpenAI-compatible API client
- **Conversation History**: Basic message persistence
- **Multi-model Support**: Configurable model endpoints
- **Core Architecture**: Threading and channel-based communication

### Changed
- Initial project setup and configuration

## [0.0.1] - 2025-08-13

### Added
- **Project Initialization**: First code commit
- **CLAUDE.md**: Initial project documentation and guidelines
- **Basic Structure**: Core project layout and configuration

---

## Version History Summary

- **0.3.x Series**: Agentic features and advanced AI assistant capabilities
- **0.2.x Series**: CLI framework and configuration enhancements
- **0.1.x Series**: Tool system and core functionality implementation
- **0.0.x Series**: Initial project setup and basic architecture

## Migration Notes

### From 0.2.x to 0.3.x
- Configuration format updated with new model parameters
- CLI interface changed from cligen to docopt
- New NIFFLER.md system for system prompts
- Tool registry system replaces direct tool implementation

### From 0.1.x to 0.2.x
- HTTP client refactored to curlyStreaming.nim
- Enhanced UI with colored prompts
- Added comprehensive debugging features
- Improved error handling and timeout management

## Roadmap

See [TODO.md](TODO.md) for detailed upcoming features and development phases.