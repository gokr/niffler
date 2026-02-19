# Niffler - Autonomous Coding Agent

![Nim](https://img.shields.io/badge/Nim-2.2.4-yellow.svg)
![License](https://img.shields.io/badge/License-MIT-blue.svg)
![Version](https://img.shields.io/badge/Version-0.5.0-green.svg)

**Niffler** is a self-hosted autonomous coding agent that works on your software projects 24/7. Unlike general-purpose AI assistants, Niffler focuses specifically on software development workflows, working independently on your codebases and reporting back through messaging platforms like Discord.

Think of it as having a tireless junior developer that never sleeps - reviewing code, fixing bugs, refactoring, writing documentation, and keeping your projects healthy.

## 🎯 What Makes Niffler Different?

**Autonomous Operation**: Once configured, Niffler works independently on your tasks. It doesn't wait for prompts - it processes task queues, monitors file changes, executes scheduled jobs, and reports results back to you.

**Software Development Focus**: Purpose-built for coding tasks with deep understanding of git, project structures, code review workflows, and development best practices.

**Multi-Platform Communication**: Talk to Niffler through Discord (and soon Slack, web interfaces). Get notifications when tasks complete, code is reviewed, or issues are found.

**Self-Hosted & Private**: Your code never leaves your infrastructure. Run Niffler in a Docker container on your own servers or development machines.

**Multi-Workspace**: Work across multiple projects simultaneously. Niffler can context-switch between different codebases seamlessly.

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Communication Layer                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                │
│  │ Discord  │  │   CLI    │  │  Future  │                │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                │
└───────┼─────────────┼─────────────┼─────────────────────┘
        │             │             │
        └─────────────┴─────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                     Task Queue                             │
│         (Polls database for pending tasks)                 │
└────────────────┬───────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                     Agent Messenger                        │
│         (Inter-agent communication via database)           │
└────────────────┬───────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                     LLM Worker                             │
│              (AI calls with tool execution)                  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     TiDB Database                          │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐     │
│  │workspace │ │task_queue│ │  agent   │ │ messages │     │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘     │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐     │
│  │scheduled │ │watched   │ │ webhook  │ │ config   │     │
│  │  jobs    │ │  paths   │ │          │ │          │     │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘     │
└─────────────────────────────────────────────────────────────┘
```

**Key Components:**

- **Communication Channels**: Discord bot, CLI, webhooks - multiple ways to interact
- **Task Queue**: Database-backed priority queue for autonomous task execution
- **Workspace Manager**: Context-switch between multiple projects
- **Agent Messaging**: Multi-agent coordination through database
- **LLM Integration**: Tool-augmented AI with file operations, code analysis
- **Persistent Storage**: TiDB for conversations, tasks, configuration

## 🚀 Quick Start

### Docker (Recommended)

```bash
# Pull and run with Docker
docker run -d \
  --name niffler \
  -e NIFFLER_DB_HOST=tidb \
  -e DISCORD_TOKEN=your-token \
  -v $(pwd)/workspaces:/workspaces \
  ghcr.io/yourusername/niffler:latest

# Or use docker-compose
cat > docker-compose.yml << 'EOF'
version: "3.8"
services:
  tidb:
    image: pingcap/tidb:latest
    ports:
      - "4000:4000"
    
  niffler:
    image: ghcr.io/yourusername/niffler:latest
    environment:
      - NIFFLER_DB_HOST=tidb
      - DISCORD_TOKEN=${DISCORD_TOKEN}
    volumes:
      - ./workspaces:/workspaces
    depends_on:
      - tidb
EOF

docker-compose up -d
```

### Binary Installation

```bash
# Download latest release
curl -L https://github.com/yourusername/niffler/releases/latest/download/niffler-linux-amd64 -o niffler
chmod +x niffler

# Set up database configuration
mkdir -p ~/.config/niffler
cat > ~/.config/niffler/db_config.yaml << 'EOF'
host: "127.0.0.1"
port: 4000
database: "niffler"
username: "root"
password: ""
EOF

# Or use environment variables
export NIFFLER_DB_HOST=127.0.0.1
export NIFFLER_DB_PORT=4000
export NIFFLER_DB_DATABASE=niffler
export NIFFLER_DB_USERNAME=root
export DISCORD_TOKEN=your-discord-token

# Run
./niffler
```

### From Source

```bash
# Prerequisites: Nim 2.2+, TiDB

git clone https://github.com/yourusername/niffler.git
cd niffler
nimble build

# Configure database (see above)
./niffler
```

## 💬 Using Niffler

### Discord Integration

Add Niffler to your Discord server and interact through channels or DMs:

```
@Niffler review the pull request at https://github.com/...

@Niffler refactor the authentication module to use JWT

@Niffler fix all TODO comments in the codebase

@Niffler create documentation for the API endpoints
```

**Channel Monitoring**: Niffler can watch specific channels and respond to relevant messages automatically.

**Proactive Notifications**: Get notified when:
- Long-running tasks complete
- Code review finds issues
- Scheduled maintenance is done
- Errors occur during task execution

### CLI Mode

For direct interaction:

```bash
# Interactive mode
niffler

> Create a REST API for user management
> Refactor the database layer to use connection pooling
> Review all error handling in src/api/

# Single task execution
niffler --task="Fix all linting errors"

# With specific workspace
niffler --workspace=myproject --task="Update dependencies"
```

## 🔧 Configuration

### Minimal Database Config

Only database connection info is stored in a local file:

```yaml
# ~/.config/niffler/db_config.yaml
host: "127.0.0.1"
port: 4000
database: "niffler"
username: "root"
password: ""
```

Or via environment:
```bash
export NIFFLER_DB_HOST=127.0.0.1
export NIFFLER_DB_PORT=4000
export NIFFLER_DB_DATABASE=niffler
export NIFFLER_DB_USERNAME=root
export NIFFLER_DB_PASSWORD=secret
```

### Everything Else in Database

All other configuration is stored in TiDB as JSON:

```bash
# Configure models
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
INSERT INTO agent_config (key, value) VALUES ('models', '
[
  {
    \"nickname\": \"claude-sonnet\",
    \"model\": \"claude-3-sonnet-20240229\",
    \"baseUrl\": \"https://api.anthropic.com/v1\",
    \"apiKey\": \"sk-ant-...\"
  }
]
');"

# Configure Discord
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
INSERT INTO agent_config (key, value) VALUES ('discord', '
{
  \"enabled\": true,
  \"token\": \"YOUR_DISCORD_TOKEN\",
  \"guildId\": \"123456789\",
  \"monitoredChannels\": [\"dev\", \"general\"]
}
');"

# Configure workspaces
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
INSERT INTO workspace (name, path, description) VALUES
('niffler', '/workspaces/niffler', 'Niffler source code'),
('myapp', '/workspaces/myapp', 'My application');"

# Configure scheduled jobs
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
INSERT INTO scheduled_job (name, cron_expr, instruction) VALUES
('daily-cleanup', '0 2 * * *', 'Clean up old log files and temp directories'),
('dependency-check', '0 9 * * 1', 'Check for outdated dependencies and create PR if updates available');"

# Configure file watchers
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
INSERT INTO watched_path (workspace_id, path, patterns, task_template) VALUES
(1, '/workspaces/niffler/src', '[\"*.nim\"]', 'Review changes in {file} and suggest improvements');"
```

## 🤖 Autonomous Features

### Task Queue

Niffler continuously polls for tasks and executes them:

```sql
-- Create a task
INSERT INTO task_queue_entry (instruction, task_type, priority)
VALUES ('Refactor the authentication module', 'user_request', 10);

-- Tasks are picked up automatically and executed
-- Results are stored in the result column
```

**Task Types:**
- `user_request` - Direct user requests via Discord/CLI
- `file_change` - Triggered by file watchers
- `scheduled` - Cron-based scheduled jobs
- `webhook` - External webhook events
- `delegated` - Tasks from other agents

### File Watchers

Monitor directories for changes and trigger tasks:

```sql
INSERT INTO watched_path (workspace_id, path, patterns, events, task_template)
VALUES (
  1,
  '/workspaces/niffler/src',
  '["*.nim"]',
  'modify',
  'Review the changes in {file} and run tests if it\'s a test file'
);
```

### Scheduled Jobs

Cron-like scheduling for recurring tasks:

```sql
INSERT INTO scheduled_job (name, cron_expr, instruction)
VALUES (
  'weekly-cleanup',
  '0 2 * * 0',
  'Archive old logs, clean temp directories, and report disk usage'
);
```

### Webhooks

Receive external events (GitHub webhooks, CI/CD, etc.):

```sql
INSERT INTO webhook_endpoint (path, secret, task_template)
VALUES (
  '/github/pr',
  'webhook-secret',
  'Review pull request: {payload.pull_request.url}'
);
```

## 🛠️ Tool System

Niffler includes specialized tools for software development:

- **read** - Read file contents with context
- **edit** - Edit files with diff-based operations
- **create** - Create new files and directories
- **list** - Directory listing with filtering
- **bash** - Execute shell commands
- **fetch** - HTTP requests and web scraping
- **task** - Spawn sub-tasks for complex workflows

All tools are workspace-aware and respect boundaries.

## 💰 Token Usage & Cost Tracking

Niffler tracks token usage per model with cost calculation:

```sql
-- View costs for a specific period
SELECT 
  model,
  SUM(input_tokens) as input,
  SUM(output_tokens) as output,
  SUM(total_cost) as cost
FROM model_token_usage
WHERE created_at >= NOW() - INTERVAL 7 DAY
GROUP BY model;
```

## 🧪 Development

### Building

```bash
# Development build
nim c src/niffler.nim

# Release build
nimble build

# Docker build
docker build -t niffler:latest .
```

### Testing

```bash
# Run tests
nimble test

# Integration tests (requires database)
nimble test --define:integration
```

### Project Structure

```
src/
├── comms/           # Communication channels (Discord, CLI)
├── autonomous/      # Task queue, scheduler, watchers
├── workspace/       # Workspace management
├── agent/           # Agent messaging and coordination
├── core/            # Core logic, database, config
├── api/             # LLM API integration
├── tools/           # Tool implementations
├── types/           # Type definitions
└── ui/              # CLI interface
```

## 📚 Documentation

- **[Architecture](doc/ARCHITECTURE.md)** - System design and components
- **[Configuration](doc/CONFIG.md)** - Database configuration guide
- **[Discord Setup](doc/DISCORD_SETUP.md)** - Discord bot configuration
- **[Task System](doc/TASK_SYSTEM.md)** - Autonomous task execution
- **[Workspace Guide](doc/WORKSPACES.md)** - Multi-project setup

## 🤝 Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## 📄 License

MIT License - see [LICENSE](LICENSE) for details.

## 🙏 Acknowledgments

- Built with [Nim](https://nim-lang.org/) for performance and elegance
- Inspired by the need for focused, autonomous coding assistance
- Database persistence via [TiDB](https://www.pingcap.com/tidb/)

---

**Niffler** - Your tireless coding companion. Works while you sleep.
