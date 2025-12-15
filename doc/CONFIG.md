# Niffler Configuration System

This document describes Niffler's configuration system, including config directories, NIFFLER.md files, and the layered override mechanism.

## Configuration Directory Structure

Niffler uses a flexible configuration system with multiple config directories:

```
~/.niffler/
├── config.yaml              # Main config with model settings and active config selection
├── niffler/                # Data directory (database managed by TiDB)
├── default/                # Minimal, concise prompts (default config)
│   ├── NIFFLER.md          # System prompts and tool descriptions
│   └── agents/             # Agent definitions for this config
│       └── general-purpose.md
└── cc/                     # Claude Code style (verbose, example-rich)
    ├── NIFFLER.md          # Verbose prompts with examples and XML tags
    └── agents/             # Agent definitions for this config
        └── general-purpose.md
```

### Initializing Configuration

Run `niffler init` to create the configuration structure:

```bash
niffler init
```

This creates:
- `~/.niffler/config.yaml` with default settings and `"config": "default"`
- `~/.niffler/default/` with minimal prompts
- `~/.niffler/cc/` with Claude Code style prompts
- Default agent definitions in both config directories

## Config Selection Mechanism

### Layered Config Resolution

Niffler uses a layered approach to determine which config directory to use:

**Priority (highest to lowest):**
1. **Project-level**: `.niffler/config.yaml` in current directory
2. **User-level**: `~/.niffler/config.yaml`
3. **Default fallback**: `"default"` if no config specified

### Config.yaml Structure

The `config` field in `config.yaml` selects the active config directory:

```yaml
yourName: "User"
config: "default"
models: [ ... ]
# ...
```

Valid values for `config`:
- `"default"` - Minimal, fast prompts
- `"cc"` - Claude Code style (verbose, example-rich)
- `"custom"` - Any custom config directory you create

### Project-Level Override

Create `.niffler/config.yaml` in your project to override the config:

```bash
mkdir .niffler
cat > .niffler/config.yaml << 'EOF'
config: "cc"
EOF
```

Now when you run `niffler` in this project, it will:
1. Load `.niffler/config.yaml` → sees `"config": "cc"`
2. Use prompts from `~/.niffler/cc/NIFFLER.md`
3. Load agents from `~/.niffler/cc/agents/`

**Note:** Config content (NIFFLER.md, agents) always lives in `~/.niffler/{name}/`. The project-level file only **selects** which config to use.

### Runtime Config Switching

Use the `/config` slash command to switch configs temporarily (in-memory only):

```
/config              # List available configs
/config cc           # Switch to cc config for this session
/config default      # Switch back to default
```

**Important:** `/config` does NOT modify any config.yaml files. It only changes the active config for the current session.

## NIFFLER.md Files

### System Prompt Extraction

NIFFLER.md files contain system prompts that control Niffler's behavior. The system searches for NIFFLER.md in this order:

**Search Priority:**
1. **Active config directory**: `~/.niffler/{active}/NIFFLER.md`
2. **Current directory**: `./NIFFLER.md`
3. **Parent directories**: Up to 3 levels up

This allows for:
- **Global config-based prompts** in `~/.niffler/{name}/`
- **Project-specific overrides** in project directories

### Supported Sections

NIFFLER.md recognizes these special sections:

- **`# Common System Prompt`** - Base system prompt used for all modes
- **`# Plan Mode Prompt`** - Additional instructions for Plan mode
- **`# Code Mode Prompt`** - Additional instructions for Code mode
- **`# Tool Descriptions`** - Custom tool descriptions (future feature)

Other sections (e.g., `# Project Guidelines`) are included as instruction content but not used as system prompts.

### Variable Substitution

System prompts support these template variables:

- `{availableTools}` - List of available tools
- `{currentDir}` - Current working directory
- `{currentTime}` - Current timestamp
- `{osInfo}` - Operating system information
- `{gitInfo}` - Git repository information
- `{projectInfo}` - Project context information

### Example NIFFLER.md

```markdown
# Common System Prompt

You are Niffler, a specialized assistant for this project.
Available tools: {availableTools}
Working in: {currentDir}

# Plan Mode Prompt

In plan mode, focus on:
- Analyzing requirements
- Breaking down tasks
- Research and planning

# Code Mode Prompt

In code mode, focus on:
- Implementation
- Testing
- Bug fixes

# Project Guidelines

These guidelines will appear in instruction files, not system prompts.
```

## File Inclusion

You can include other files using the `@include` directive:

### Syntax

```markdown
@include FILENAME.md
@include /absolute/path/to/file.md
@include relative/path/to/file.md
```

### Example Usage

```markdown
# Common System Prompt

Base prompt content here.

@include shared-guidelines.md

# Project Instructions

@include CLAUDE.md
@include docs/coding-standards.md
```

### Features

- **Relative paths** - Resolved relative to the NIFFLER.md file location
- **Absolute paths** - Used as-is
- **Error handling** - Missing files shown as comments in output
- **Recursive processing** - Included files can have their own `@include` directives

## Configuration Styles

### Default Style (Minimal)

Located in `~/.niffler/default/NIFFLER.md`:

- **Concise prompts** - Short, direct instructions
- **Low token usage** - Minimal system prompt overhead
- **Fast responses** - Less context for the LLM to process
- **Best for**: Quick interactions, simple tasks, local models

### Claude Code Style (CC)

Located in `~/.niffler/cc/NIFFLER.md`:

- **Verbose prompts** - Extensive instructions with examples
- **XML tags** - `<good-example>`, `<bad-example>`, `<system-reminder>`
- **Strategic emphasis** - IMPORTANT, NEVER, VERY IMPORTANT markers
- **High steerability** - Detailed guidance for complex behaviors
- **Best for**: Complex projects, production work, cloud models

### Custom Styles

Create your own config style:

```bash
mkdir -p ~/.niffler/myteam
mkdir -p ~/.niffler/myteam/agents
cp ~/.niffler/default/NIFFLER.md ~/.niffler/myteam/
# Edit as needed
```

Then use it:
```yaml
config: "myteam"
```

## Integration with Other Tools

### Claude Code Compatibility

```markdown
# Project Instructions

@include CLAUDE.md

# Additional Niffler Settings

Niffler-specific configuration here.
```

This allows sharing CLAUDE.md between Claude Code and Niffler without duplication.

### Multi-Repository Setup

Place common instructions in a config directory:

```markdown
# Common System Prompt (in ~/.niffler/myorg/NIFFLER.md)

System-wide instructions for all projects.

# Organization Standards

@include ~/dev/standards/coding-guidelines.md
```

Individual projects can override by having their own `.niffler/config.yaml`:

```yaml
config: "myorg"
```

## Configuration Fields

Control which instruction files are searched via config.yaml:

```yaml
instructionFiles:
  - "NIFFLER.md"
  - "CLAUDE.md"
  - "OCTO.md"
  - "AGENT.md"
```

## Config Override Examples

### Example 1: Team Standardization

**Scenario:** Your team wants all projects to use Claude Code style by default.

**Solution:** Edit `~/.niffler/config.yaml`:
```yaml
config: "cc"
# ...
```

Now all projects use CC style unless they override it.

### Example 2: Project-Specific Style

**Scenario:** One project needs minimal prompts for performance, but you prefer CC globally.

**Solution:** In that project:
```bash
mkdir .niffler
echo '{"config": "default"}' > .niffler/config.yaml
```

### Example 3: Testing New Prompts

**Scenario:** You want to test modified prompts without changing files.

**Solution:** Use runtime switching:
```
/config cc           # Test cc style
/config default      # Switch back
```

Changes are session-only and don't persist.

## Best Practices

### Config Organization

1. **Use config directories for global styles** - `~/.niffler/{name}/`
2. **Use project .niffler/config.yaml for selection** - Just specify which config to use
3. **Use project NIFFLER.md for overrides** - Project-specific prompt tweaks
4. **Create team configs** - Share a config directory across team members

### Prompt Development

1. **Start with default** - Test with minimal prompts first
2. **Upgrade to cc when needed** - For complex projects requiring high steerability
3. **Create custom configs** - For specific workflows or teams
4. **Version control** - Commit `.niffler/config.yaml` to git
5. **Test changes** - System prompts affect LLM behavior significantly

### File Inclusion

1. **Share common guidelines** - Use `@include` to avoid duplication
2. **Separate concerns** - System prompts vs instruction content
3. **Use relative paths** - Makes configs portable
4. **Document includes** - Comment what each include provides

## Troubleshooting

### Config not loading

Check the resolution order:
1. Is there a `.niffler/config.yaml` in current directory?
2. Does `~/.niffler/config.yaml` have a valid `"config"` field?
3. Does the config directory exist in `~/.niffler/{name}/`?

### Prompts not applying

1. Run `/config` to see which config is active
2. Check `~/.niffler/{active}/NIFFLER.md` exists
3. Verify section headings are exact: `# Common System Prompt`
4. Check for syntax errors in NIFFLER.md

### Project override not working

1. Ensure `.niffler/config.yaml` is in the project root
2. Verify JSON syntax is correct
3. Check that the specified config exists in `~/.niffler/`

## Migration from Legacy Setup

If you have an existing `~/.niffler/NIFFLER.md`:

1. Run `niffler init` to create new structure
2. Copy your custom prompts to `~/.niffler/default/NIFFLER.md`
3. Or create a custom config directory for your setup

The old system still works for backward compatibility, but the new config system takes priority.

## Implementation Status

### Completed Features
- ✅ Session management with active config tracking (`src/core/session.nim`)
- ✅ Config directory structure (`~/.niffler/{name}/`)
- ✅ Layered config resolution (project > user > default)
- ✅ `/config` command for listing and switching configs
- ✅ Agent loading from active config directory
- ✅ Runtime config diagnostics and validation
- ✅ Session-aware system prompt generation

### Remaining Work
- ⚠️ **Session threading** - Session parameter needs to be threaded through all of `cli.nim`
- ⚠️ **Command handlers** - All command handlers need session parameter in signature
- ⚠️ **Conversation manager** - Session threading through conversation manager functions

See TODO.md for priority and detailed tasks.

## Model Configuration

Niffler supports multiple AI models with extensive configuration options, including thinking token support for models that provide reasoning.

### Basic Model Configuration

```yaml
models:
  - nickname: "claude-sonnet"           # Friendly name for the model
    model: "claude-3-5-sonnet-20241022" # Model identifier for the API
    base_url: "https://api.anthropic.com/v1"
    api_key: "sk-ant-..."              # Or use api_env_var
    context: 200000                     # Context window size
    enabled: true                       # Enable this model
```

### Thinking Token Configuration

Enable and configure thinking token support for models that provide reasoning:

```yaml
models:
  - nickname: "claude-thinking"
    model: "claude-3-7-sonnet-20250219"
    base_url: "https://api.anthropic.com/v1"
    # Thinking token configuration
    include_reasoning_in_context: true  # Include thinking in context for follow-ups
    thinking_format: "anthropic"        # anthropic, openai, or auto-detect
    max_thinking_tokens: 4000           # Limit thinking tokens (optional)
```

**Configuration Options:**
- `include_reasoning_in_context` (boolean): When true, model receives previous thinking as context
- `thinking_format` (string): Provider format - "anthropic", "openai", or "auto"
- `max_thinking_tokens` (integer): Optional limit to prevent excessive thinking

### Advanced Model Options

```yaml
models:
  - nickname: "gpt-4"
    model: "gpt-4-turbo"
    base_url: "https://api.openai.com/v1"
    # API authentication
    api_env_var: "OPENAI_API_KEY"       # Use environment variable
    # Token costs for tracking
    input_cost_per_mtoken: 0.01         # Cost per million input tokens
    output_cost_per_mtoken: 0.03        # Cost per million output tokens
    # Generation parameters
    temperature: 0.7                    # Sampling temperature
    top_p: 0.9                          # Top-p sampling
    max_tokens: 4096                    # Maximum response tokens
    # Context window
    context: 128000                     # Model's context window
    enabled: true
```

### Reasoning Levels

For models that support adjustable reasoning (like o1 variants):

```yaml
models:
  - nickname: "o1-mini"
    model: "o1-mini"
    reasoning: "medium"                 # low, medium, or high
```

### Model Types

Specify model type for special handling:

```yaml
models:
  - nickname: "deepseek"
    model: "deepseek-chat"
    type: "deepseek"                    # Enables DeepSeek-specific handling
```

**Supported Types:**
- `anthropic` - Anthropic Claude models
- `openai` - OpenAI models
- `deepseek` - DeepSeek models
- `mistral` - Mistral models
- Default: Auto-detect based on base URL

## NATS Configuration

Niffler uses NATS for multi-agent communication and master mode routing. NATS configuration is optional and only required when using master mode or running multiple agents.

### Configuration Fields

Add to your `~/.niffler/config.yaml`:

```yaml
# NATS Server Configuration
nats:
  url: "nats://127.0.0.1:4222"    # NATS server URL
  username: ""                    # Optional username
  password: ""                    # Optional password
  token: ""                       # Optional auth token
  timeout: 5000                   # Connection timeout in ms

# Master Mode Configuration
masterMode:
  enabled: false                  # Enable master mode CLI
  defaultAgent: "general-purpose" # Default agent to route to
  timeout: 30000                  # Agent request timeout in ms
  retryAttempts: 3                # Number of retry attempts
  presenceInterval: 5000          # Agent presence check interval in ms
```

### NATS Server Setup

#### Quick Start (Local)

```bash
# Install NATS Server
curl -L https://github.com/nats-io/nats-server/releases/download/v2.10.5/nats-server-v2.10.5-linux-amd64.tar.gz | tar xz
sudo cp nats-server-v2.10.5-linux-amd64/nats-server /usr/local/bin/

# Start NATS Server
nats-server

# Or with custom config
nats-server -c nats.conf
```

#### Docker

```bash
# Basic NATS server
docker run --name nats -p 4222:4222 -d nats:latest

# With persistent storage and monitoring
docker run --name nats \
  -p 4222:4222 \
  -p 8222:8222 \
  -v nats-data:/data \
  -d nats:latest \
  -js \  # Enable JetStream
  -m 8222  # Enable HTTP monitoring
```

#### NATS Configuration File (nats.conf)

```ini
# Basic configuration
listen: 0.0.0.0:4222
http_port: 8222

# Authorization (optional)
authorization {
  users: [
    {user: admin, password: secret, permissions: {
      publish: "niffler.>"
      subscribe: "niffler.>"
    }}
  ]
}

# JetStream for persistence (optional)
jetstream {
  store_dir: "/data/jetstream"
}

# Clustering (for production)
cluster {
  name: "niffler-cluster"
  listen: 0.0.0.0:6222
  routes: ["nats://other-node:6222"]
}
```

### Master Mode Configuration

Master mode allows routing requests to specialized agents and managing a fleet of Niffler agents.

#### Enabling Master Mode

```yaml
masterMode:
  enabled: true                   # Enable master mode
  defaultAgent: "general-purpose" # Fallback agent

# Agent configuration
agents:
  - name: "general-purpose"
    model: "gpt-4"
    config: "default"
    skills: ["general", "conversation", "analysis"]

  - name: "coder"
    model: "gpt-4"
    config: "cc"
    skills: ["coding", "debugging", "architecture"]

  - name: "researcher"
    model: "gpt-4-turbo"
    config: "default"
    skills: ["research", "writing", "analysis"]
```

#### Agent Auto-Start Configuration

```yaml
# Auto-start agents with master mode
masterMode:
  autoStart: true                   # Auto-start configured agents
  agentTimeout: 30000               # Wait time for agent startup
  healthCheckInterval: 5000         # Health check frequency

agents:
  - name: "coder"
    autoStart: true
    arguments: ["--agent", "--name", "coder", "--config", "cc"]

  - name: "researcher"
    autoStart: true
    arguments: ["--agent", "--name", "researcher", "--model", "gpt-4-turbo"]
```

### NATS Subjects and Patterns

Niffler uses these NATS subject patterns:

- `niffler.agent.{agent_name}.request` - Send commands to specific agents
- `niffler.agent.{agent_name}.response` - Receive responses from agents
- `niffler.master.{session_id}.status` - Master mode status updates
- `niffler.presence.{agent_name}` - Agent presence announcements

### Security Considerations

#### Authentication

```yaml
nats:
  url: "tls://nats.example.com:4222"
  username: "${NATS_USER}"         # Use environment variables
  password: "${NATS_PASS}"
  tls:
    enabled: true
    ca_file: "/path/to/ca.pem"
    cert_file: "/path/to/cert.pem"
    key_file: "/path/to/key.pem"
```

#### Network Security

1. **Use TLS in production**: Enable TLS encryption for all NATS connections
2. **Firewall rules**: Restrict NATS ports (4222, 6222, 8222) to trusted networks
3. **Account-based isolation**: Use NATS accounts to isolate multi-tenant deployments
4. **Subject permissions**: Limit publish/subscribe permissions per user

### Best Practices

#### Development Environment

```yaml
nats:
  url: "nats://127.0.0.1:4222"

masterMode:
  enabled: true
  timeout: 10000                # Shorter timeout for development
  retryAttempts: 1              # Fail fast for debugging
```

#### Production Environment

```yaml
nats:
  url: "nats://nats-cluster.example.com:4222"
  username: "${NATS_USER}"
  password: "${NATS_PASS}"
  timeout: 30000
  maxReconnects: 10
  reconnectWait: 2000

masterMode:
  enabled: true
  timeout: 60000                # Longer timeout for production
  retryAttempts: 3
  healthCheckInterval: 10000
```

### Troubleshooting

#### Connection Issues

```bash
# Test NATS connection
nats sub "niffler.>" &
nats pub "niffler.test" "hello world"

# Check server status
curl http://localhost:8222/varz
curl http://localhost:8222/connz
```

#### Agent Discovery Issues

1. **Check presence messages**: Monitor `niffler.presence.>` subjects
2. **Verify connectivity**: Ensure agents can reach NATS server
3. **Check subject patterns**: Verify agent names match subject patterns
4. **Authentication**: Validate credentials and permissions

#### Master Mode Issues

1. **Agent not found**: Check agent auto-start and presence registration
2. **Request timeout**: Increase timeout or check agent responsiveness
3. **Route conflicts**: Verify agent names don't conflict with built-in commands

### Multi-Region Deployment

For distributed deployments, configure NATS clustering:

```yaml
# Region 1
nats:
  url: "nats://region1-nats.example.com:4222"
  cluster:
    name: "niffler-global"
    routes: ["nats://region2-nats.example.com:6222"]

# Region 2
nats:
  url: "nats://region2-nats.example.com:4222"
  cluster:
    name: "niffler-global"
    routes: ["nats://region1-nats.example.com:6222"]
```

### Monitoring NATS

#### HTTP Endpoints

- `/varz` - Server variables and statistics
- `/connz` - Connection information
- `/routez` - Route information
- `/gatewayz` - Gateway information (if enabled)
- `/leafz` - Leaf node connections (if enabled)

#### Prometheus Metrics

Enable Prometheus metrics:

```yaml
# In nats.conf
http_port: 8222
monitor_host: "0.0.0.0"
```

Access metrics at: `http://localhost:8222/metrics`

### JetStream for Persistence

For reliable message delivery:

```yaml
nats:
  url: "nats://127.0.0.1:4222"
  jetstream: enabled  #Enable JetStream

masterMode:
  jetStream: true     # Use JetStream for agent requests
  streamConfig:
    replicas: 3       # Number of replicas for durability
    max_age: "24h"    # Message retention
```

### Environment Variables

Use environment variables for sensitive configuration:

```bash
export NATS_URL="nats://nats.example.com:4222"
export NATS_USER="niffler"
export NATS_PASS="secure-password"
export NATS_TLS_CERT="/path/to/cert.pem"
export NATS_TLS_KEY="/path/to/key.pem"
export NATS_CA="/path/to/ca.pem"

# In config.yaml
nats:
  url: "${NATS_URL}"
  username: "${NATS_USER}"
  password: "${NATS_PASS}"
```

## Database Configuration

Niffler uses TiDB (MySQL-compatible) for persistent storage. Configure database connection in `~/.niffler/config.yaml`:

```yaml
# Database Configuration
database:
  host: "127.0.0.1"
  port: 4000
  user: "root"
  password: ""                    # Leave empty for default TiDB setup
  database: "niffler"
  ssl: false                      # Set to true for production
  maxConnections: 10
  connectionTimeout: 5000
  maxIdleTime: 3600
```

### Environment Variables

```bash
export DB_HOST="127.0.0.1"
export DB_PORT="4000"
export DB_USER="root"
export DB_PASSWORD=""
export DB_NAME="niffler"

# In config.yaml
database:
  host: "${DB_HOST}"
  port: ${DB_PORT}
  user: "${DB_USER}"
  password: "${DB_PASSWORD}"
  database: "${DB_NAME}"
```

### Database Setup

#### TiDB Quick Start (Persistent)

For development, run TiDB with persistent data storage:

```bash
# Create a directory for TiDB data
mkdir -p ~/tidb-data

# Run TiDB with volume mount for persistence
docker run -d \
  --name tidb \
  -p 4000:4000 \
  -p 10080:10080 \
  -v ~/tidb-data:/data \
  pingcap/tidb:latest

# Create database
mysql -h 127.0.0.1 -P 4000 -u root
CREATE DATABASE niffler;
```

**To stop and restart TiDB:**
```bash
# Stop TiDB (data persists in ~/tidb-data)
docker stop tidb

# Restart TiDB
docker start tidb
```

**For a fresh database:**
```bash
# Remove all data
docker stop tidb
docker rm tidb
rm -rf ~/tidb-data

# Then run the docker command above again
```

#### MySQL Alternative

```yaml
database:
  host: "mysql.example.com"
  port: 3306
  user: "niffler"
  password: "secure-password"
  database: "niffler"
  ssl: true
  charset: "utf8mb4"
```

### Connection Pooling

For production deployments:

```yaml
database:
  pool:
    minConnections: 5
    maxConnections: 50
    acquireTimeoutMillis: 10000
    createTimeoutMillis: 30000
    destroyTimeoutMillis: 5000
    idleTimeoutMillis: 30000
    reapIntervalMillis: 1000
    createRetryIntervalMillis: 100
```

### Database Migration

Schema is auto-created on first run. For production, run migrations manually:

```bash
# Using the built-in migration tool
./src/niffler --migrate

# Or apply schema directly
mysql -h 127.0.0.1 -P 4000 -u root niffler < schema.sql
```

For complete database documentation, see [DATABASE_SCHEMA.md](DATABASE_SCHEMA.md).
