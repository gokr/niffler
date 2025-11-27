# Niffler - AI Assistant in Nim

![Nim](https://img.shields.io/badge/Nim-2.2.4-yellow.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-0.4.0-green.svg)

**Niffler** is a "Claude Code" style AI assistant built in Nim with support for multiple AI models and providers, a builtin tool system and a fully persistent conversation model using TiDB (MySQL-compatible distributed database). Niffler is heavily inspired by Claude Code but was initially started when I stumbled over [Octofriend](https://github.com/synthetic-lab/octofriend/).

**NOTE: Niffler is to a large extent vibe coded using Claude Code and RooCode!**

## 🏗️ Architecture & Design

Niffler features a **multi-threaded single-process architecture** with a foundation for future distributed multi-agent capabilities.

**Current Architecture:**
- Multi-threaded design with dedicated workers for UI, API, and tool execution
- Thread-safe channels for inter-component communication
- Persistent TiDB database for conversation history and state
- NATS infrastructure ready for future multi-agent expansion

**Key Features:**
- 🧵 **Multi-threaded**: UI, API, and tool operations run in separate threads
- 💾 **Persistent Storage**: TiDB (MySQL-compatible) database for conversations, messages, and usage tracking
- 🛠️ **Tool System**: Extensible architecture with built-in tools for development tasks
- 🔄 **Security**: Sanitized paths, timeout controls, and permission management
- 📡 **NATS Ready**: Foundation for distributed multi-agent expansion

Learn more about the architecture and future multi-agent plans in **[doc/ARCHITECTURE.md](doc/ARCHITECTURE.md)**.


## 🤖 AI Capabilities

- **Multi-Model Support**: Seamlessly switch between different AI models (OpenAI, Anthropic, and other OpenAI-compatible APIs)
- **Plan/Code Mode System**: Toggle between planning and coding modes with mode-specific system prompts
- **Dynamic System Prompts**: Context-aware prompts that include workspace information, git status, and project details
- **Single Prompt Mode**: Scripting support for one-shot prompts with immediate responses
- **Model Management**: Easy configuration and switching between AI models
- **Thinking Token Support**: Manages, shows and stores reasoning tokens separately
- **Custom Instructions**: NIFFLER.md handling with include directive support

## 💰 Token Counting & Cost Tracking

Niffler features an intelligent token estimation system with dynamic correction factors that learns from actual API usage to provide increasingly accurate cost predictions.

**Features:**
- **Heuristic-Based Estimation**: 7-16% accuracy using language-specific heuristics without heavy tokenizers
- **Dynamic Learning**: Automatically improves accuracy through comparison with actual API responses
- **Cost Optimization**: Better estimates lead to more accurate cost predictions
- **Model-Specific**: Each model gets its own correction factor based on real usage data

**Learn More:** Complete details about the token estimation system and cost tracking in **[doc/TOKEN_COUNTING.md](doc/TOKEN_COUNTING.md)**.


## 🛠️ Tool System & Extensions

Niffler includes a comprehensive tool system that enables AI assistants to safely interact with your development environment.

### Core Tools
- **bash**: Execute shell commands with timeout control and process management
- **read**: Read file contents with encoding detection and size limits
- **list**: Directory listing with filtering, sorting, and metadata display
- **edit**: Advanced file editing with diff-based operations and backup creation
- **create**: Safe file creation with directory management and permission control
- **fetch**: HTTP/HTTPS content fetching with web scraping capabilities
- **todolist**: Task management and todo tracking with persistent state

**Learn More:** Complete documentation of the tool system, security features, and custom tool development in **[doc/TOOLS.md](doc/TOOLS.md)**.

### MCP (Model Context Protocol) Integration

Extend Niffler's capabilities with external MCP servers that provide additional specialized tools and resources for your development workflow.

**Key Features:**
- **External Server Support**: Integration with any MCP-compatible server
- **Automatic Discovery**: Tools are automatically discovered at startup
- **Flexible Configuration**: Easy YAML-based server setup
- **Health Monitoring**: Automatic server health checks and recovery

**Popular MCP Servers:**
- **Filesystem**: Secure file operations with directory access controls
- **GitHub**: Repository management, issue tracking, and PR operations
- **Git**: Version control operations and repository management

**Quick Setup:**
```yaml
mcpServers:
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/projects"]
    enabled: true

  github:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_TOKEN: "your-github-token"
    enabled: true
```

**Check Status:**
```bash
# View all MCP servers and available tools
/mcp status
```

**Learn More:** Complete MCP setup guide with installation, configuration, and troubleshooting in **[doc/MCP_SETUP.md](doc/MCP_SETUP.md)**.

## 📦 Installation

### Prerequisites
- Nim 2.2.4 or later
- Git
- **NATS Server**: Required for multi-agent IPC and will be automatically started by Niffler

#### NATS Server Installation

Niffler requires a NATS server for communication between agents. You have several options:

**Option 1: Docker (Recommended)**
```bash
# Pull and run NATS server
docker run -d --name nats -p 4222:4222 nats:latest

# Or using docker-compose
echo 'version: "3.7"
services:
  nats:
    image: nats:latest
    ports:
      - "4222:4222"
    command: ["-js"]  # Enable JetStream for persistence
' > docker-compose.yml
docker-compose up -d
```

**Option 2: Binary Download**
```bash
# Download the latest NATS server binary
curl -L https://github.com/nats-io/nats-server/releases/latest/download/nats-server-linux-amd64.tar.gz | tar xz
sudo mv nats-server-*/nats-server /usr/local/bin/nats-server

# Or download specific version
OS=linux ARCH=amd64 VERSION=2.10.7
wget https://github.com/nats-io/nats-server/releases/download/v${VERSION}/nats-server-${VERSION}-${OS}-${ARCH}.tar.gz
tar xzf nats-server-${VERSION}-${OS}-${ARCH}.tar.gz
sudo mv nats-server-${VERSION}-${OS}-${ARCH}/nats-server /usr/local/bin/
```

**Option 3: Package Manager**
```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y nats-server

# macOS
brew install nats-server

# Windows (using Chocolatey)
choco install nats-server
```

Once installed, you can start NATS with:
```bash
nats-server -js  # -js enables JetStream for persistence
```

**Note**: Niffler will automatically detect and connect to a running NATS server on `localhost:4222`. If no server is running, Niffler will attempt to start one automatically.

### Optional Prerequisites (Enhanced Rendering)
- **[batcat](https://github.com/sharkdp/bat)**: For syntax-highlighted file content display
- **[delta](https://github.com/dandavison/delta)**: For advanced diff visualization with side-by-side view and word-level highlighting
- **[trafilatura](https://trafilatura.readthedocs.io/)**: For enhanced web content extraction with the fetch tool

If these tools are not installed, Niffler will automatically fall back to built-in rendering.

### System Libraries

Before building, ensure you have the required system libraries installed:

**Linux (Ubuntu/Debian):**
```bash
sudo apt update
sudo apt install -y libnats3.7t64 libnats-dev
```

**Linux (CentOS/RHEL/Fedora):**
```bash
# For CentOS/RHEL
sudo yum install nats-devel
# Or for Fedora
sudo dnf install nats-devel
```

**macOS:**
```bash
brew install nats
```

**Windows:**
> The NATS library is typically bundled with the Nim package on Windows.

## 🏗️ Building Niffler

Niffler needs to be built from source at this time. Follow these steps to build and install the application on your system.

### Build Notes

- All compilation requires `--threads:on -d:ssl` flags (automatically set in build configuration)
- The optimized build (`nimble build`) creates a single static binary
- Windows users may need to install Visual Studio Build Tools for native compilation

## 🎯 Quick Start

### 1. Initialize Configuration
```bash
niffler init
```
This creates default configuration files:
- **Linux/macOS**: `~/.niffler/config.yaml` and `~/.niffler/NIFFLER.md`
- **Windows**: `%APPDATA%\niffler\config.yaml` and `%APPDATA%\niffler\NIFFLER.md`

The NIFFLER.md file contains customizable system prompts that you can edit to tailor Niffler's behavior to your preferences.

### 2. Configure Your AI Model
Edit the configuration file to add (or enable) at least one AI model and API key:
```yaml
models:
  - nickname: "gpt4"
    baseUrl: "https://api.openai.com/v1"
    model: "gpt-4"
    apiKey: "your-api-key-here"
    enabled: true
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
niffler -p="Hello, how are you?"

# Use specific model
niffler --model=gpt4

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
```yaml
models:
  - nickname: "gpt5-reasoning"
    baseUrl: "https://api.openai.com/v1"
    model: "gpt-5-turbo"
    reasoning: "high"
    reasoningContent: "visible"
    reasoningCostPerMToken: 10.0
    enabled: true

thinkingTokensEnabled: true
defaultReasoningLevel: "medium"
```

**Benefits:**
- **Self-Correcting AI**: Models can catch and fix their own reasoning errors
- **Transparency**: Users see exactly how conclusions are reached  
- **Better First Responses**: Reduced trial-and-error through deliberate reasoning
- **Multi-Turn Intelligence**: Preserved reasoning context across conversation turns

For detailed information about thinking token implementation and architecture, see [doc/THINK.md](doc/THINK.md).

### Plan Mode File Protection

Niffler implements intelligent file protection to maintain clear separation between planning and implementation phases:

**How It Works:**
- When entering **Plan Mode**, Niffler initializes an empty "created files" list for the conversation
- As new files are created during the Plan Mode session, they are automatically tracked in this list
- The AI assistant can **only edit files that were created during the current Plan Mode session**
- Existing files (that existed before Plan Mode) are protected from editing to prevent accidental changes during planning
- When switching to **Code Mode**, file tracking is cleared and all file editing restrictions are removed

**When Protection is Activated:**
- **Manual Mode Toggle**: Pressing `Shift+Tab` to enter Plan Mode
- **Conversation Loading**: When loading a conversation that's already in Plan Mode
- **Application Startup**: If the last active conversation was in Plan Mode
- **Conversation Switching**: Using `/conv` command to switch to a Plan Mode conversation

**File Creation Tracking:**
- **Automatic Detection**: Files created via the `create` tool are automatically added to the created files list
- **Persistent Tracking**: Created file lists are stored per conversation in the database
- **Path Normalization**: Uses relative paths for portability across different working directories
- **Session Scope**: Each Plan Mode session maintains its own created files list

**User Experience:**
- **Transparent Operation**: File creation tracking happens automatically without user intervention
- **Clear Error Messages**: Informative messages when attempting to edit protected files:
  ```
  Cannot edit existing files in plan mode. Only files created during this plan mode session can be edited.
  Switch to code mode to edit existing files, or create new files which can then be edited.
  ```
- **Visual Indicators**: Mode displayed in prompt with color coding (green for plan, blue for code)
- **Seamless Transitions**: Automatic tracking management during mode switches
- **New File Creation**: Full ability to create and subsequently edit new files during planning

**Database Integration:**
- **Persistent State**: Created file lists are stored in the conversation database and survive application restarts
- **Efficient Storage**: File lists are stored as compact JSON arrays in the database
- **Automatic Cleanup**: Created file tracking is cleared when exiting Plan Mode
- **Cross-Session Consistency**: File creation tracking works correctly when resuming conversations across different sessions

**Technical Implementation:**
- File protection is checked at tool execution time, not file system level
- Uses thread-safe database operations for created file list management
- Implements "fail-open" error handling - allows operations if database is unavailable
- Integrates with Niffler's conversation management and mode switching system
- Files created during Plan Mode are automatically tracked by the `create` tool

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
- **History Persistence**: Your conversation history is saved to a TiDB database and restored between sessions
- **Cross-Platform**: Works consistently on Windows, Linux, and macOS

**Database Integration:**
All conversations are automatically saved to a TiDB database. See the Database Setup section below for configuration.

### Configuration Management
```bash
# Initialize configuration
niffler init

# Initialize with custom path
niffler init /path/to/config
```

## 🔧 Configuration

### Configuration File Location

**Linux/macOS:**
- Default: `~/.niffler/config.yaml`
- Directory: `~/.niffler/` (hidden directory)

**Windows:**
- Default: `%APPDATA%\niffler\config.yaml`
- Directory: `%APPDATA%\niffler\` (e.g., `C:\Users\Username\AppData\Roaming\niffler\`)

**Custom:**
- Can be specified via `--config-path` argument for any platform

### Database Setup (TiDB)

Niffler requires TiDB for persistent storage of conversations, messages, and usage data.

**Quick Start (Local Development):**

1. Install TiUP (TiDB package manager):
```bash
curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh
```

2. Start local TiDB playground:
```bash
tiup playground
```

3. Configure database in `~/.niffler/config.yaml`:
```yaml
database:
  enabled: true
  host: "127.0.0.1"
  port: 4000
  database: "niffler"
  username: "root"
  password: ""
  poolSize: 10
```

**Production Setup:**

For production deployments, refer to the official TiDB documentation at https://docs.pingcap.com/tidb/stable for cluster setup and management. Or just use the serverless option for free (up to a certain size) at https://tidbcloud.com

**Database Configuration Options:**
- **enabled**: Enable/disable database persistence (default: true)
- **host**: TiDB server host (default: "127.0.0.1")
- **port**: TiDB server port (default: 4000)
- **database**: Database name (default: "niffler")
- **username**: Database username (default: "root")
- **password**: Database password (default: "")
- **poolSize**: Connection pool size (default: 10)

### Configuration Structure
```yaml
models:
  - nickname: "gpt4o"
    baseUrl: "https://api.openai.com/v1"
    model: "gpt-4o"
    apiEnvVar: "OPENAI_API_KEY"
    enabled: true

  - nickname: "claude"
    baseUrl: "https://api.anthropic.com/v1"
    model: "claude-3-sonnet-20240229"
    apiKey: "sk-ant-api03-..."
    enabled: true

  - nickname: "local-llm"
    baseUrl: "http://localhost:1234/v1"
    model: "llama-3.2-3b-instruct"
    apiKey: "not-needed"
    enabled: false

instructionFiles:
  - "NIFFLER.md"
  - "CLAUDE.md"
  - "OCTO.md"
  - "AGENT.md"
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

### External Rendering Configuration

Niffler supports configurable external tools for enhanced content and diff rendering. By default, it uses [batcat](https://github.com/sharkdp/bat) for syntax-highlighted file content and [delta](https://github.com/dandavison/delta) for advanced diff visualization.

#### Default Configuration

When you initialize Niffler, the following external rendering configuration is automatically added:

```yaml
externalRendering:
  enabled: true
  contentRenderer: "batcat --color=always --style=numbers --theme=auto {file}"
  diffRenderer: "delta --line-numbers --syntax-theme=auto"
  fallbackToBuiltin: true
```

#### Configuration Options

- **`enabled`**: Enable/disable external rendering (boolean, default: true)
- **`contentRenderer`**: Command template for file content rendering with placeholders:
  - `{file}`: File path to render
  - `{theme}`: Theme name (auto, dark, light, etc.)
  - `{syntax}`: Syntax/language for highlighting
  - `{line-numbers}`: Expands to `--line-numbers` flag
- **`diffRenderer`**: Command template for diff rendering (stdin-based)
- **`fallbackToBuiltin`**: Use built-in rendering if external tools fail (boolean, default: true)

#### Template Placeholders

External rendering commands support flexible placeholder substitution:

| Placeholder | Description | Example Value |
|-------------|-------------|---------------|
| `{file}` | Absolute file path | `/home/user/project/src/main.nim` |
| `{path}` | Alias for `{file}` | `/home/user/project/src/main.nim` |
| `{theme}` | Theme name | `monokai`, `auto`, `dark` |
| `{syntax}` | File language/syntax | `nim`, `python`, `javascript` |
| `{language}` | Alias for `{syntax}` | `nim`, `python`, `javascript` |
| `{line-numbers}` | Line numbers flag | `--line-numbers` (or empty) |

#### Custom Tool Configuration

You can customize external rendering to use different tools:

```yaml
externalRendering:
  enabled: true
  contentRenderer: "highlight --syntax={syntax} --out-format=ansi {file}"
  diffRenderer: "diff-so-fancy"
  fallbackToBuiltin: true
```

#### Features

- **Automatic Tool Detection**: Niffler checks if external tools are available before using them
- **Graceful Fallback**: If external tools fail or are unavailable, built-in rendering is used seamlessly
- **Context-Aware**: File content rendering detects syntax from file extensions
- **Performance Optimized**: External rendering is used intelligently (e.g., not for line range selections)
- **Error Handling**: Comprehensive error handling with informative messages

#### Installing External Tools

**Install batcat:**
```bash
# Ubuntu/Debian
sudo apt install bat

# macOS
brew install bat

# Windows (via chocolatey)
choco install bat

# Note: On some systems, the command is 'bat' instead of 'batcat'
# Update your config accordingly if needed
```

**Install delta:**
```bash
# Ubuntu/Debian (from releases)
wget https://github.com/dandavison/delta/releases/download/0.17.0/git-delta_0.17.0_amd64.deb
sudo dpkg -i git-delta_0.17.0_amd64.deb

# macOS
brew install git-delta

# Windows (via chocolatey)
choco install delta

# Cargo (all platforms)
cargo install git-delta
```

**Install trafilatura:**
```bash
# Using pipx (recommended for CLI tools)
sudo apt install pipx
pipx install trafilatura

# Using pip in a virtual environment
python3 -m venv ~/venv
~/venv/bin/pip install trafilatura

# System-wide (if available)
sudo apt install python3-trafilatura
```

#### Benefits

- **Enhanced Syntax Highlighting**: Rich color coding and theme support
- **Advanced Diff Visualization**: Side-by-side view, word-level highlighting, and better formatting
- **Consistent Terminal Experience**: Integrates seamlessly with your existing terminal workflow
- **Customizable**: Full control over rendering commands and options

### Text Extraction Configuration

Niffler supports configurable external tools for enhanced web content text extraction. By default, it uses a built-in HTML parser, but you can configure external tools like [trafilatura](https://trafilatura.readthedocs.io/) for superior text extraction quality.

#### Default Configuration

Without configuration, Niffler uses its built-in HTML-to-text converter. To enable external text extraction:

```yaml
textExtraction:
  enabled: true
  command: "trafilatura -u {url}"
  mode: "url"
  fallbackToBuiltin: true
```

#### Configuration Options

- **`enabled`**: Enable/disable external text extraction (boolean, default: false)
- **`command`**: Command template for text extraction tool
  - Use `{url}` placeholder for URL-based mode
  - Command alone for stdin-based mode
- **`mode`**: How to pass content to the external tool:
  - `"url"`: Pass URL as command argument (e.g., `trafilatura -u {url}`)
  - `"stdin"`: Pipe HTML content via stdin (e.g., `trafilatura`)
- **`fallbackToBuiltin`**: Use built-in extraction if external tool fails (boolean, default: true)

#### Example Configurations

**URL Mode (recommended for trafilatura):**
```yaml
textExtraction:
  enabled: true
  command: "trafilatura -u {url}"
  mode: "url"
  fallbackToBuiltin: true
```

**Stdin Mode (pipe HTML content):**
```yaml
textExtraction:
  enabled: true
  command: "trafilatura"
  mode: "stdin"
  fallbackToBuiltin: true
```

**Custom Tool Example:**
```yaml
textExtraction:
  enabled: true
  command: "html2text"
  mode: "stdin"
  fallbackToBuiltin: true
```

#### Features

- **Automatic Tool Detection**: Checks if external tools are available before using them
- **Graceful Fallback**: Uses built-in extraction if external tool fails or is unavailable
- **Two Operating Modes**: URL-based or stdin-based depending on tool capabilities
- **Enhanced Quality**: External tools like trafilatura provide superior text extraction with better content detection
- **Fetch Tool Integration**: Automatically used by the `fetch` tool when processing HTML content

#### How It Works

When the AI uses the `fetch` tool to retrieve web content:

1. **HTML Detection**: If the response is HTML and text conversion is enabled
2. **External Extraction** (if configured): Attempts to use the configured external tool
3. **Fallback**: If external tool fails and `fallbackToBuiltin` is true, uses built-in parser
4. **Result**: Returns extracted text with `extraction_method` field indicating which method was used

The `extraction_method` in fetch results can be:
- `"external"`: Successfully used external tool
- `"builtin"`: Used built-in HTML parser
- `"builtin-fallback"`: External tool failed, fell back to builtin
- `"none"`: No text extraction performed

#### Benefits

- **Better Content Extraction**: Tools like trafilatura excel at identifying main content and removing boilerplate
- **Configurable**: Choose the tool that best fits your needs
- **Reliable**: Automatic fallback ensures fetch always works
- **Flexible**: Supports both URL-passing and stdin-piping modes for different tools
### Archive and Unarchive Commands

Niffler provides conversation archiving functionality to help you organize your conversations while preserving them for future reference. Archived conversations are hidden from the main conversation list but can be restored when needed.

#### `/archive` Command

Archive a conversation to remove it from the active conversation list:

```bash
# Archive a conversation by ID
/archive 123

# Archive multiple conversations
/archive 456
/archive 789
```

**Features:**
- **Soft Delete**: Archived conversations are preserved in the database but marked as inactive
- **Tab Completion**: Press Tab after `/archive` to see a formatted table of active conversations
- **Immediate Effect**: Archived conversations disappear from `/conv` list immediately
- **Data Preservation**: All messages, tokens, and metadata are retained

**Use Cases:**
- Clean up your conversation list while keeping important discussions
- Archive completed projects or resolved issues
- Organize conversations by project status (active vs. completed)

#### `/unarchive` Command

Restore an archived conversation back to the active list:

```bash
# Unarchive a conversation by ID
/unarchive 123

# Unarchive multiple conversations
/unarchive 456
/unarchive 789
```

**Features:**
- **Full Restoration**: Restores conversations with all original messages and metadata
- **Tab Completion**: Press Tab after `/unarchive` to see a formatted table of archived conversations
- **Seamless Integration**: Restored conversations appear immediately in `/conv` list
- **Context Preservation**: Original mode, model, and conversation settings are maintained

#### Archive Management Workflow

**1. Viewing Conversations:**
```bash
# List only active conversations (default)
/conv

# List all conversations including archived (via search)
/search your-query
```

**2. Archiving Process:**
```bash
# See active conversations
/conv

# Archive completed conversation
/archive 42

# Verify it's archived
/conv  # Should no longer show conversation 42
```

**3. Unarchiving Process:**
```bash
# Find archived conversations
/unarchive  # Press Tab to see archived list

# Restore conversation
/unarchive 42

# Verify it's active
/conv  # Should now show conversation 42
```

**4. Search Integration:**
The `/search` command includes both active and archived conversations, making it easy to find content regardless of archive status:
```bash
# Search across all conversations
/search "project planning"

# Results show both active and archived matches
```

#### Database Integration

Archived conversations are managed through Niffler's TiDB database system:

- **Data Structure**: Uses `is_active` boolean field in `conversation` table
- **Performance**: Lightweight boolean toggle operation
- **Persistence**: Archive status survives application restarts and is stored in TiDB

#### Best Practices

**When to Archive:**
- Completed projects or tasks
- Resolved issues or debugging sessions
- Old reference conversations you might need later
- Conversations you want to keep but don't need active access to

**When to Unarchive:**
- Revisiting past projects or decisions
- Referencing old solutions or approaches
- Continuing paused conversations
- Researching historical context

**Archive Management Tips:**
- Use descriptive conversation titles to easily identify them later
- Archive conversations in batches when cleaning up
- Use `/search` to find specific content in archived conversations
- Consider archiving rather than deleting to preserve valuable context

#### Integration with Other Commands

The archive system integrates seamlessly with Niffler's conversation management:

- **`/conv`**: Shows only active conversations by default
- **`/search`**: Searches across both active and archived conversations
- **`/new`**: Creates new active conversations
- **`/info`**: Shows current conversation status (active or archived)
- **Tab Completion**: Context-aware completion shows appropriate conversation lists

### Configuration Management
```bash
# Initialize configuration
niffler init

# Initialize with custom path
niffler init /path/to/config
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
