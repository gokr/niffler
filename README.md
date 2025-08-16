# Niffler - AI Assistant in Nim

![Nim](https://img.shields.io/badge/Nim-2.2.4-yellow.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-0.2.2-green.svg)

**Niffler** is a "Claude Code" style AI assistant built in Nim with support for multiple AI models and providers and a tool system for file operations, command execution, and web interactions. Niffler is heavily inspired by Claude Code but was initially started when I stumbled over Octofriend.

**NOTE: Niffler is to a large extent vibe coded using Claude Code and RooCode!**

## 🚀 Features

### Core AI Capabilities
- **Multi-Model Support**: Seamlessly switch between different AI models (OpenAI, Anthropic, and other OpenAI-compatible APIs)
- **Interactive Chat Mode**: Real-time conversation with streaming responses
- **Single Prompt Mode**: Send individual prompts directly from your command line and get immediate responses
- **Model Management**: Easy configuration and switching between AI models
- **Single binary and Cross Platform**: Written in Nim means it is a single cross platform binary.

### Tool System
Niffler includes a tool system that enables AI assistants to interact with your development environment:

#### 🛠️ Core Tools
- **bash**: Execute shell commands with timeout control and process management
- **read**: Read file contents with encoding detection and size limits
- **list**: Directory listing with filtering, sorting, and metadata display
- **edit**: Advanced file editing with diff-based operations and backup creation
- **create**: Safe file creation with directory management and permission control
- **fetch**: HTTP/HTTPS content fetching with web scraping capabilities

#### 🔧 Tool Infrastructure
- **Thread-Safe Execution**: Dedicated worker threads for safe tool execution
- **Argument Validation**: Input validation with detailed error messages
- **Security Features**: Path sanitization, size limits, and permission checks
- **Modular Architecture**: Easy to extend with new tools

### Advanced Features
- **Configuration Management**: Simple JSON configuration with platform-appropriate directories
- **Enhanced Terminal Interface**: Full cursor key support, history navigation, and colored prompts
- **Database Persistence**: SQLite-based prompt and response history with cross-session persistence
- **Job Control Support**: Ctrl+Z background suspension (Unix/Linux/macOS)
- **History Tracking**: Conversation history with message persistence and database storage
- **Debug Logging**: Logging with info & debug levels
- **HTTP Request/Response Dumping**: Complete HTTP transaction visibility for debugging API issues

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
This creates a configuration file at the platform-appropriate location:
- **Linux/macOS**: `~/.niffler/config.json`
- **Windows**: `%APPDATA%\niffler\config.json`

### 2. Configure Your AI Model
Edit the configuration file to add (or enable) at least one AI model and API key:
```json
{
  "models": [
    {
      "nickname": "gpt-4",
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
niffler models

# Send a single prompt
niffler -p "Hello, how are you?"

# Use specific model
niffler --model gpt-4

# Enable debug logging
niffler --debug

# Enable info logging
niffler --info

# Enable HTTP request/response dumping for debugging
niffler --dump

# Combine debug and dump for maximum visibility
niffler --debug --dump
```

### Available Commands in Interactive Mode
- `/help` - Show available commands
- `/models` - List available models
- `/model <nickname>` - Switch to a different model
- `/clear` - Clear conversation history
- `/exit` or `/quit` - Exit Niffler

### Enhanced Terminal Features

**Cursor Key Support:**
- **←/→ Arrow Keys**: Navigate within your input line for editing
- **↑/↓ Arrow Keys**: Navigate through command history (persisted across sessions)
- **Home/End**: Jump to beginning/end of current line
- **Ctrl+C**: Graceful exit
- **Ctrl+Z**: Suspend to background (Unix/Linux/macOS)

**Visual Enhancements:**
- **Colored Prompts**: Username appears in blue and cannot be backspaced over
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
  ]
}
```

### Model Configuration Options

Each model in the configuration supports the following fields:

- **nickname**: Friendly name to identify the model
- **baseUrl**: API base URL for the model provider
- **model**: Specific model identifier 
- **context**: Maximum context window size (optional, defaults based on model)
- **apiEnvVar**: Environment variable containing the API key (optional)
- **apiKey**: Direct API key specification (optional)
- **enabled**: Whether this model is available for use (defaults to true)

### API Key Priority
When both `apiEnvVar` and `apiKey` are specified, the environment variable takes precedence. This allows you to override hardcoded keys with environment variables for security.

### Environment Variables
You can configure API keys using environment variables:
```bash
export OPENAI_API_KEY="your-openai-key"
export ANTHROPIC_API_KEY="your-anthropic-key"
```

## 🛠️ Tool System Details

### Tool Execution
Niffler's tool system allows AI models to safely interact with your system:

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
nimble test
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
