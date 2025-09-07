# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Niffler is an AI-powered terminal assistant written in Nim. It provides a conversational interface to interact with AI models while supporting tool calling for file operations, command execution, and web fetching.

## Build and Development Commands

### Building
```bash
# Development build
nim c src/niffler.nim

# Optimized release build  
nimble build

# Quick build task
nimble test
```

### Testing
```bash
# Run all tests
cd tests && nim c -r run_tests.nim

# Run individual test suites
nim c -r --threads:on -d:ssl test_tool_calling.nim
nim c -r --threads:on -d:ssl test_api_integration.nim
nim c -r --threads:on -d:ssl test_tool_execution.nim
```

### Dependencies
```bash
# Install dependencies
nimble install cligen sunny

# Required Nim version: >= 2.2.4
# Compile with: --threads:on -d:ssl (set in config.nims)
```

## Architecture

### Core Components

**Thread-based Architecture**: The application uses a multi-threaded design with dedicated workers:
- **API Worker** (`src/api/worker.nim`): Handles LLM communication and tool calling orchestration
- **Tool Worker** (`src/tools/worker.nim`): Executes individual tools with validation
- **Main Thread**: Manages UI and coordinates between workers via channels

**Channel Communication** (`src/core/channels.nim`): Thread-safe message passing between workers using Nim's channels for:
- API requests/responses
- Tool execution requests/results  
- UI updates and shutdown signals

**Tool System** (`src/tools/`):
- **Schema-based validation** (`schemas.nim`): JSON Schema validation for tool parameters
- **Registry pattern** (`registry.nim`): Central tool registration and lookup
- **Six core tools**: bash, read, list, edit, create, fetch
- **Security features**: Path sanitization, timeout enforcement, confirmation requirements

**Message Flow**:
1. User input → Main thread
2. Main thread → API worker (via channels)
3. API worker → LLM API → Tool calls detected
4. API worker → Tool worker (tool execution)
5. Tool worker → File system/commands → Results back to API worker
6. API worker → LLM API (continue conversation with tool results)
7. Final response → Main thread → User display

### Key Files

- `src/niffler.nim`: CLI entry point with cligen command dispatch
- `src/core/app.nim`: Application lifecycle and coordination
- `src/api/api.nim`: LLM API integration with tool calling support
- `src/api/http_client.nim`: OpenAI-compatible HTTP client
- `src/tools/worker.nim`: Tool execution engine
- `src/types/messages.nim`: Message type definitions for LLM and tool communication
- `src/ui/cli.nim`: Interactive terminal interface

### Configuration

Configuration system (`src/core/config.nim`):
- Model definitions with nicknames, base URLs, and API keys
- Environment variable support for API keys
- Config file location: `~/.config/niffler/config.toml`

## Tool Calling Implementation

The tool calling system follows OpenAI's function calling specification:
- Tool schemas are JSON Schema definitions
- Tool calls are validated before execution
- Tools requiring confirmation: bash, edit, create (dangerous operations)
- Tools skipping confirmation: read, list, fetch (safe operations)
- Multi-turn conversations supported with tool result integration

## Dependencies and Libraries

- **cligen**: Command line argument parsing
- **sunny**: JSON Schema validation
- **JsonSchemaValidator**: Additional schema validation support

## Development Notes

- All compilation requires `--threads:on -d:ssl` flags (set in config.nims)
- Thread safety is critical - use channels for inter-thread communication
- Tool implementations must validate arguments against their schemas
- Security is paramount - all file paths are sanitized and validated
- The codebase follows Nim naming conventions and coding style

## Nim Coding Guidelines

### Code Style and Conventions
- Use camelCase, not snake_case (avoid `_` in naming)
- Do not shadow the local `result` variable (Nim built-in)
- Doc comments: `##` below proc signature
- Prefer generics or object variants over methods and type inheritance
- Use `return expression` for early exits
- Prefer direct field access over getters/setters
- Avoid creating accessor functions for simple field access - use `.field` syntax directly
- **NO `asyncdispatch`** - use threads or taskpools for concurrency
- Remove old code during refactoring
- Import full modules, not selected symbols
- Use `*` to export fields that should be publicly accessible
- If something is not exported, export it instead of doing workarounds
- Do not be afraid to break backwards compatibility

### Function and Return Style
- **Single-line functions**: Use direct expression without `result =` assignment or `return` statement
- **Multi-line functions**: Use `result =` assignment and `return` statement for clarity
- **Early exits**: Use `return value` instead of `result = value; return`
- **Exception handlers**: Use `return expression` for error cases

### JSON and Data Handling
- **JSON Object Construction**: Prefer the `%*{}` syntax for clean, readable JSON creation
- **Content Serialization**: Use centralized utilities for consistent formatting
- **Error Response Creation**: Use standardized error utilities across all transport layers

### Comments and Documentation
- Do not add comments talking about how good something is, it is just noise. Be brief.
- Do not add comments that reflect what has changed, we use git for change tracking, only describe current code
- Do not add unnecessary commentary or explain code that is self-explanatory

### Refactoring and Code Cleanup
- **Remove old unused code during refactoring** - We prioritize clean, maintainable code over backwards compatibility
- When implementing new architecture patterns, completely remove the old implementation patterns
- Delete deprecated methods, unused types, and obsolete code paths immediately
- Keep the codebase lean and focused on the current architectural approach

### Testing Best Practices
- Always end todolists by running all the tests at the end to verify everything compiles and works