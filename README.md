# Niffler - AI Assistant in Nim

![Nim](https://img.shields.io/badge/Nim-2.2.4-yellow.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-0.2.2-green.svg)

**Niffler** is a "Claude Code" style AI assistant built in Nim with support for multiple AI models and providers, a builtin tool system and a fully persistent conversation model using Sqlite3. Niffler is heavily inspired by Claude Code but was initially started when I stumbled over [Octofriend](https://github.com/synthetic-lab/octofriend/).

**NOTE: Niffler is to a large extent vibe coded using Claude Code and RooCode!**

Niffler is a work-in-progress. Some of the things that perhaps **stand out** are these:

- **Native multithreaded**. The tool executions are in one thread. The UI is in one thread. The communication with the LLM is in one thread.
- **CLI Interface**. Built on linecross for input handling with tab completion, history and more. A bit less polished as Ink-based tools but very terminal friendly and *cross platform* including copy paste support.
- **Has a client side database**. Niffler has a single Sqlite3 database where conversations are persisted and helps with tracking token use etc. It can use a remote server as well.
- **Single binary and portable between Linux, OSX and Windows**. Libraries are chosen to make sure it works on all three platforms.


## AI Capabilities
- **Multi-Model Support**: Seamlessly switch between different AI models (OpenAI, Anthropic, and other OpenAI-compatible APIs)
- **Plan/Code Mode System**: Toggle between planning and coding modes with mode-specific system prompts
- **Dynamic System Prompts**: Context-aware prompts that include workspace information, git status, and project details
- **Single Prompt Mode**: Can be used in scripting to send one shot prompts and get an immediate response
- **Model Management**: Easy configuration and switching between AI models
- **Thinking Token Support**: Manages, shows and stores thinking tokens separately  
- **NIFFLER.md handling**: Customizable system prompts and instruction files with include directive support


### Tool System
Niffler includes a tool system that enables AI assistants to interact with your development environment. All tool executions are being run in a separate thread. It should be easy to add more builtin tools:

#### 🛠️ Core Tools
- **bash**: Execute shell commands with timeout control and process management
- **read**: Read file contents with encoding detection and size limits
- **list**: Directory listing with filtering, sorting, and metadata display
- **edit**: Advanced file editing with diff-based operations and backup creation
- **create**: Safe file creation with directory management and permission control
- **fetch**: HTTP/HTTPS content fetching with web scraping capabilities
- **todolist**: Task management and todo tracking with persistent state and progress monitoring

## 📦 Installation

### Prerequisites
- Nim 2.2.4 or later
- Git

### Build and install from Source
```bash
git clone https://github.com/gokr/niffler.git
cd niffler
nimble install
```

### Build Optimized Release
```bash
nimble build
```

## 🎯 Quick Start

### 1. Initialize Configuration
```bash
niffler init
```
This creates default configuration files:
- **Linux/macOS**: `~/.niffler/config.json` and `~/.niffler/NIFFLER.md`
- **Windows**: `%APPDATA%\niffler\config.json` and `%APPDATA%\niffler\NIFFLER.md`

The NIFFLER.md file contains customizable system prompts that you can edit to tailor Niffler's behavior to your preferences.

### 2. Configure Your AI Model
Edit the configuration file to add (or enable) at least one AI model and API key:
```json
{
  "models": [
    {
      "nickname": "gpt4",
      "baseUrl": "https://api.openai.com/v1",
      "model": "gpt-4",
      "apiKey": "your-api-key-here",
      "enabled": true
    }
  ]
}
```

### 3. Start Interactive Mode
```bash
niffler
```

## 💻 Usage Examples

### Interactive Mode
```bash
# List available models
niffler model list

# Send a single prompt
niffler -p "Hello, how are you?"

# Use specific model
niffler --model gpt4

# Enable debug logging
niffler --debug

# Enable info logging
niffler --info

# Enable HTTP request/response dumping for debugging
niffler --dump

# Combine debug and dump for maximum visibility
niffler --debug --dump
```

### Plan/Code Mode System

Niffler features an intelligent mode system that adapts its behavior based on the current task:

**Mode Switching:**
- **Shift+Tab**: Toggle between Plan and Code modes
- **Visual Indicators**: Mode displayed in prompt with color coding (green for plan, blue for code)
- **Dynamic Prompts**: Each mode has specialized system prompts for optimal AI behavior

**Plan Mode:**
- Focus on analysis, research, and task breakdown
- Emphasizes understanding requirements before implementation
- Encourages thorough exploration of codebases and documentation
- **File Protection**: Automatically prevents editing files that existed before entering plan mode to maintain separation between planning and implementation phases

**Code Mode:**
- Focus on implementation and execution
- Emphasizes making concrete changes and testing
- Optimized for completing established plans and fixing issues
- **Full File Access**: Allows editing all files for active development and implementation

### Thinking Token Support

Niffler includes cutting-edge support for **thinking tokens** (reasoning tokens) from next-generation AI models. These models can show their internal reasoning process, which Niffler automatically captures, stores, and integrates into conversations.

**Supported Models:**
- **GPT-5** and future OpenAI reasoning models (native `reasoning_content` field)
- **Claude 4** and Anthropic reasoning models (XML `<thinking>` blocks)
- **DeepSeek R1** and similar reasoning-capable models
- **Privacy models** with encrypted/redacted reasoning content

**Key Features:**
- **Real-time Reasoning Capture**: Automatically detects and stores thinking content during streaming responses
- **Multi-provider Support**: Handles different reasoning formats transparently
- **Conversation Persistence**: Thinking tokens are stored in the database and linked to conversation history
- **Cost Tracking**: Reasoning tokens are tracked separately and included in usage/cost calculations
- **Enhanced Problem Solving**: See exactly how the AI reaches its conclusions

**Configuration:**
Add reasoning capabilities to your model configuration:
```json
{
  "models": [
    {
      "nickname": "gpt5-reasoning",
      "baseUrl": "https://api.openai.com/v1",
      "model": "gpt-5-turbo",
      "reasoning": "high",
      "reasoningContent": "visible",
      "reasoningCostPerMToken": 10.0,
      "enabled": true
    }
  ],
  "thinkingTokensEnabled": true,
  "defaultReasoningLevel": "medium"
}
```

**Benefits:**
- **Self-Correcting AI**: Models can catch and fix their own reasoning errors
- **Transparency**: Users see exactly how conclusions are reached  
- **Better First Responses**: Reduced trial-and-error through deliberate reasoning
- **Multi-Turn Intelligence**: Preserved reasoning context across conversation turns

For detailed information about thinking token implementation and architecture, see [doc/THINK.md](doc/THINK.md).

### Plan Mode File Protection

Niffler implements file protection to maintain clear separation between planning and implementation phases:

**How It Works:**
- When entering **Plan Mode**, Niffler scans the current directory and subdirectories
- All existing files are marked as "protected" and stored in the conversation database
- The AI assistant can read protected files but cannot edit them while in Plan Mode
- New files created during Plan Mode are allowed to be edited (as they don't exist in the baseline)
- When switching to **Code Mode**, all file protection is removed for active development

This allows new files and documentation to be created in Plan Mode.

**User Experience:**
- Transparent operation - protection is applied automatically on mode entry
- Clear error messages when attempting to edit protected files
- Visual mode indicators show current protection status
- Seamless transition between modes with automatic protection management

**Database Integration:**
- Protection state is persisted across conversation sessions
- File lists are stored efficiently as JSON in the conversation database
- Protection is automatically cleared when exiting Plan Mode

### Enhanced Terminal Features

**Cursor Key Support:**
- **←/→ Arrow Keys**: Navigate within your input line for editing
- **↑/↓ Arrow Keys**: Navigate through command history (persisted across sessions)
- **Home/End**: Jump to beginning/end of current line
- **Ctrl+C**: Graceful exit
- **Ctrl+Z**: Suspend to background (Unix/Linux/macOS)
- **Shift+Tab**: Toggle between Plan and Code modes

**Visual Enhancements:**
- **Colored Prompts**: Username appears in blue and cannot be backspaced over
- **Mode Indicators**: Current mode (plan/code) with color coding in prompt
- **History Persistence**: Your conversation history is saved to a SQLite database and restored between sessions
- **Cross-Platform**: Works consistently on Windows, Linux, and macOS

**Database Integration:**
All conversations are automatically saved to a SQLite database located at:
- **Linux/macOS**: `~/.niffler/niffler.db`
- **Windows**: `%APPDATA%\niffler\niffler.db`

### Configuration Management
```bash
# Initialize configuration
niffler init

# Initialize with custom path
niffler init --config-path /path/to/config.json
```

## 🔧 Configuration

### Configuration File Location

**Linux/macOS:**
- Default: `~/.niffler/config.json`
- Directory: `~/.niffler/` (hidden directory)

**Windows:**
- Default: `%APPDATA%\niffler\config.json`
- Directory: `%APPDATA%\niffler\` (e.g., `C:\Users\Username\AppData\Roaming\niffler\`)

**Custom:**
- Can be specified via `--config-path` argument for any platform

### Configuration Structure
```json
{
  "models": [
    {
      "nickname": "gpt4o",
      "baseUrl": "https://api.openai.com/v1",
      "model": "gpt-4o",
      "apiEnvVar": "OPENAI_API_KEY",
      "enabled": true
    },
    {
      "nickname": "claude",
      "baseUrl": "https://api.anthropic.com/v1",
      "model": "claude-3-sonnet-20240229",
      "apiKey": "sk-ant-api03-...",
      "enabled": true
    },
    {
      "nickname": "local-llm",
      "baseUrl": "http://localhost:1234/v1",
      "model": "llama-3.2-3b-instruct",
      "apiKey": "not-needed",
      "enabled": false
    }
  ],
  "instructionFiles": [
    "NIFFLER.md",
    "CLAUDE.md",
    "OCTO.md",
    "AGENT.md"
  ]
}
```

### Model Configuration Options

Each model in the configuration supports the following fields:

**Core Settings:**
- **nickname**: Friendly name to identify the model
- **baseUrl**: API base URL for the model provider
- **model**: Specific model identifier 
- **context**: Maximum context window size (optional, defaults based on model)
- **apiEnvVar**: Environment variable containing the API key (optional)
- **apiKey**: Direct API key specification (optional)
- **enabled**: Whether this model is available for use (defaults to true)

**Thinking Token Settings:**
- **reasoning**: Reasoning budget level - "low" (2048), "medium" (4096), "high" (8192), or "none"
- **reasoningContent**: Reasoning visibility - "visible", "hidden", or "encrypted"
- **reasoningCostPerMToken**: Cost per million reasoning tokens (optional, for cost tracking)

**Cost Tracking:**
- **inputCostPerMToken**: Cost per million input tokens (optional)
- **outputCostPerMToken**: Cost per million output tokens (optional)
- **reasoningCostPerMToken**: Cost per million reasoning tokens (optional)

### API Key Priority
When both `apiEnvVar` and `apiKey` are specified, the environment variable takes precedence. This allows you to override hardcoded keys with environment variables for security.

### Environment Variables
You can configure API keys using environment variables:
```bash
export OPENAI_API_KEY="your-openai-key"
export ANTHROPIC_API_KEY="your-anthropic-key"
```

### NIFFLER.md System Prompt Customization

Niffler supports advanced customization through NIFFLER.md files that can contain both system prompts and project instructions:

**System Prompt Sections:**
- `# Common System Prompt` - Base instructions for all modes
- `# Plan Mode Prompt` - Specific instructions for Plan mode
- `# Code Mode Prompt` - Specific instructions for Code mode

**Search Hierarchy:**
1. **Project directory** - Current and parent directories (up to 3 levels)
2. **Config directory** - `~/.niffler/NIFFLER.md` for system-wide defaults

**File Inclusion Support:**
```markdown
# Common System Prompt
Base instructions here

@include CLAUDE.md
@include shared/guidelines.md

# Project Instructions
Additional project-specific content
```

**Features:**
- **Dynamic prompts** with template variables (`{availableTools}`, `{currentDir}`, etc.)
- **Hierarchical configuration** - project-specific overrides system-wide defaults
- **Claude Code compatibility** - include CLAUDE.md for seamless integration
- **Modular organization** - break up large instruction files with includes

For detailed documentation and examples, see [NIFFLER-FEATURES.md](NIFFLER-FEATURES.md).

## 🛠️ Tool System Details

### Tool Execution
Niffler's tool system allows AI models to safely interact with your system:

#### Smart Duplicate Tool Call Handling
Niffler implements intelligent duplicate detection that keeps conversations flowing smoothly:

**How It Works:**
- **Signature-based Detection**: Uses `toolName(normalizedArguments)` signatures to identify duplicate calls
- **Graceful Recovery**: Instead of stopping conversation, sends helpful feedback to the model
- **Conversation Continuity**: Allows the model to respond with different approaches or continue naturally
- **Recursive Tool Support**: Handles new tool calls that arise from duplicate feedback

**Benefits Over Hard Stops:**
- **No Conversation Interruption**: Models can recover and try alternative approaches
- **Better User Experience**: Users don't hit unexpected conversation terminations  
- **Follows AI Best Practices**: Multi-turn tool calling with contextual feedback
- **Prevents Infinite Loops**: Still protects against runaway tool calling with depth limits

This approach follows industry best practices from OpenAI, Google, and other AI tool providers who recommend continuing conversations with feedback rather than hard termination.

#### Example Tool Usage
The AI can use tools like:
```json
{
  "name": "read",
  "arguments": {
    "path": "src/main.nim",
    "encoding": "utf-8",
    "max_size": 1048576
  }
}
```

#### Tool Features
- **Safety First**: All tools include validation, size limits, and security checks
- **Error Handling**: Comprehensive exception-based error reporting
- **Performance**: Efficient execution with timeout control
- **Extensibility**: Easy to add new tools following established patterns

### Available Tools

#### bash Tool
Execute shell commands safely:
```json
{
  "name": "bash",
  "arguments": {
    "command": "ls -la",
    "timeout": 30000
  }
}
```

#### read Tool
Read file contents with encoding detection:
```json
{
  "name": "read",
  "arguments": {
    "path": "README.md",
    "encoding": "auto",
    "max_size": 10485760
  }
}
```

#### list Tool
List directory contents:
```json
{
  "name": "list",
  "arguments": {
    "path": "./src",
    "recursive": true,
    "max_depth": 3
  }
}
```

#### edit Tool
Edit files with diff-based operations:
```json
{
  "name": "edit",
  "arguments": {
    "path": "src/main.nim",
    "operations": [
      {
        "type": "replace",
        "old_text": "old code",
        "new_text": "new code"
      }
    ]
  }
}
```

#### create Tool
Create new files safely:
```json
{
  "name": "create",
  "arguments": {
    "path": "src/newfile.nim",
    "content": "echo \"Hello World\"",
    "overwrite": false,
    "create_dirs": true
  }
}
```

#### fetch Tool
Fetch web content:
```json
{
  "name": "fetch",
  "arguments": {
    "url": "https://example.com",
    "method": "GET",
    "timeout": 30000,
    "max_size": 1048576
  }
}
```

## 🏗️ Architecture

### Core Components
- **CLI Interface**: Command-line interface with interactive and single-prompt modes
- **Core Application**: Main application logic and model management
- **API Client**: HTTP client for AI API communication
- **Tool System**: Comprehensive tool execution framework
- **Configuration Management**: Flexible configuration system
- **History Management**: Conversation history and message tracking

### Threading Architecture
- **Main Thread**: Handles user interaction and CLI operations
- **API Worker Thread**: Manages AI API communication
- **Tool Worker Thread**: Executes tool operations safely
- **Thread-Safe Communication**: Uses channels for inter-thread communication

## 🧪 Development

### Running Tests
```bash
# Run all tests including thinking token integration tests
nimble test

# Run specific thinking token tests
nim c -r --threads:on -d:ssl -d:testing tests/test_thinking_token_integration.nim
```

### Building
```bash
# Development build
nim c src/niffler.nim

# Release build
nimble build
```

### Debugging API Issues

The `--dump` flag provides complete HTTP request and response logging for debugging API communication:

```bash
# See full HTTP transactions
niffler -p "Hello" --dump

# Example output shows:
# - Complete request headers (Authorization masked for security)
# - Full JSON request body with tools, messages, and parameters
# - Real-time streaming response with individual SSE chunks
# - Token usage information in final response chunk
```

This is invaluable for:
- Debugging API connectivity issues
- Understanding request formatting
- Monitoring token usage patterns
- Verifying streaming response handling

See [TODO.md](TODO.md) for detailed development roadmap and [STATUS.md](STATUS.md) for current implementation status.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

### Development Guidelines
- Follow Nim coding conventions
- Use exception-based error handling
- Maintain thread safety
- Add comprehensive error messages
- Include tests for new features

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **Nim Programming Language**: For providing an excellent, performant language for systems programming
- **Original Octofriend**: For inspiring the feature set and a very friendly Discord
