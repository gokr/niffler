# MCP (Model Context Protocol) Setup

This guide covers setting up and troubleshooting Model Context Protocol (MCP) servers with Niffler.

## Overview

MCP allows Niffler to integrate with external MCP servers that provide additional tools and capabilities beyond the built-in tools. These servers can offer specialized functionality like filesystem access, Git operations, GitHub integration, and more.

## Quick Start

### 1. Install Required Software

**Node.js (required for most MCP servers):**
```bash
# Ubuntu/Debian
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# macOS
brew install node

# Windows (using Chocolatey)
choco install nodejs
```

### 2. Configure MCP Servers

Add MCP server configurations to your `config.yaml`:

```yaml
mcpServers:
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/projects"]
    enabled: true

  github:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_TOKEN: "your-github-token-here"
    enabled: true
```

### 3. Start Niffler

```bash
niffler
```

### 4. Verify Setup

```bash
# In Niffler, run:
/mcp status
```

You should see:
```
MCP Servers (2 configured):

  filesystem:
    Status: Running
    Errors: 0
    Restarts: 0
    Last Activity: 5s ago

  github:
    Status: Running
    Errors: 0
    Restarts: 0
    Last Activity: 3s ago

MCP Tools: 12 available

  read_file (filesystem) - Read contents of a file
  write_file (filesystem) - Write content to a file
  list_directory (filesystem) - List directory contents
  create_repository (github) - Create a new GitHub repository
  ...
```

## Configuration Details

### Server Configuration Structure

Each MCP server supports the following configuration options:

```yaml
mcpServers:
  server-name:
    command: "executable"              # Required: Command to run
    args: ["-arg1", "value1", "-arg2"]  # Optional: Command line arguments
    env:                              # Optional: Environment variables
      VAR_NAME: "value"
    workingDir: "/path/to/directory"  # Optional: Working directory
    timeout: 30000                    # Optional: Timeout in milliseconds
    enabled: true                     # Optional: Enable/disable server
```

### Configuration Options

| Option | Type | Required | Description |
|--------|------|----------|-------------|
| `command` | string | ✅ | Executable to run (e.g., "npx", "node", "mcp-server") |
| `args` | array | ❌ | Command-line arguments |
| `env` | object | ❌ | Environment variables for the server |
| `workingDir` | string | ❌ | Working directory for server process |
| `timeout` | integer | ❌ | Request timeout in milliseconds (default: 30000) |
| `enabled` | boolean | ❌ | Whether server is active (default: true) |

## Popular MCP Servers

### Filesystem Access

**Installation:**
```bash
npm install -g @modelcontextprotocol/server-filesystem
```

**Configuration:**
```yaml
mcpServers:
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/allowed/path"]
    enabled: true
```

**Available Tools:**
- `read_file` - Read file contents
- `write_file` - Write content to files
- `list_directory` - List directory contents
- `create_directory` - Create directories
- `move_file` - Move/rename files and directories

### GitHub Integration

**Installation:**
```bash
npm install -g @modelcontextprotocol/server-github
```

**Configuration:**
```yaml
mcpServers:
  github:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_TOKEN: "github_pat_..."
    enabled: true
```

**Available Tools:**
- `create_repository` - Create new repositories
- `get_repository` - Get repository information
- `create_issue` - Create GitHub issues
- `list_issues` - List repository issues
- `update_pull_request` - Update PR descriptions

### Git Operations

**Installation:**
```bash
npm install -g @modelcontextprotocol/server-git
```

**Configuration:**
```yaml
mcpServers:
  git:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-git"]
    workingDir: "."
    enabled: true
```

**Available Tools:**
- `git_status` - Show repository status
- `git_diff` - Show file differences
- `git_commit` - Create commits
- `git_branch` - Branch operations
- `git_log` - Show commit history

## Installation Guide

### Using npm (Recommended)

Most MCP servers are distributed as npm packages:

```bash
# Install globally
npm install -g @modelcontextprotocol/server-name

# Or use npx without installation
npx -y @modelcontextprotocol/server-name
```

### Using Docker

Some MCP servers provide Docker images:

```bash
# Pull and run
docker run -d --name mcp-filesystem mcp/server-filesystem

# Or use docker-compose
echo 'version: "3.7"
services:
  mcp:
    image: mcp/server-filesystem
    ports:
      - "3000:3000"' > docker-compose.yml
docker-compose up -d
```

### Manual Installation

For compiled MCP servers:

```bash
# Download binary
wget https://github.com/mcp/server/releases/latest/download/mcp-server-linux-amd64.tar.gz
tar xzf mcp-server-linux-amd64.tar.gz

# Make executable and install
sudo mv mcp-server /usr/local/bin/
```

## Advanced Configuration

### Per-Server Timeouts

Configure different timeouts based on server characteristics:

```yaml
mcpServers:
  # Fast local server
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/data"]
    timeout: 5000
    enabled: true

  # Slow remote API
  github:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_TOKEN: "your-token"
    timeout: 30000
    enabled: true
```

### Environment Variable Configuration

Use environment variables for sensitive data:

```yaml
mcpServers:
  github:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_TOKEN: "${GITHUB_TOKEN}"  # From environment
      GITHUB_API_URL: "${GITHUB_API_URL:-https://api.github.com}"  # With fallback
    enabled: true
```

### Conditional Server Activation

Enable/disable servers based on conditions:

```yaml
mcpServers:
  # Only enable in development
  dev-tools:
    command: "npx"
    args: ["-y", "@company/mcp-dev-tools"]
    enabled: ${NODE_ENV:-development} == "development"

  # Always enabled
  filesystem:
    command: "npx"
    args: ["-y", "@modelcontextprotocol/server-filesystem", "."]
    enabled: true
```

## Troubleshooting

### Common Issues

#### Server Not Starting

**Problem:** Server status shows failed or no tools available

**Solutions:**
1. **Check command and arguments:**
   ```bash
   # Test manually
   npx -y @modelcontextprotocol/server-filesystem /path/to/test
   ```

2. **Verify executable is in PATH:**
   ```bash
   which npx
   which node
   ```

3. **Check environment variables:**
   ```bash
   env | grep GITHUB_TOKEN  # Or other required env vars
   ```

#### Tools Not Appearing

**Problem:** Server status is "Running" but no tools available

**Solutions:**
1. **Restart Niffler** to re-initialize MCP servers
2. **Check server logs:**
   ```bash
   # In the directory where you started Niffler
   # Look for MCP-related messages or logs
   ```

3. **Verify server capabilities:**
   ```bash
   # Check if the server actually provides tools
   npx -y @modelcontextprotocol/server-name --help
   ```

#### Permission Issues

**Problem:** Filesystem or permission errors

**Solutions:**
1. **Check directory permissions:**
   ```bash
   ls -la /path/used/in/config
   ```

2. **Verify working directory exists:**
   ```bash
   mkdir -p /path/to/working/directory
   ```

3. **Use absolute paths:**
   ```yaml
   mcpServers:
     filesystem:
       command: "npx"
       args: ["-y", "@modelcontextprotocol/server-filesystem", "/absolute/path"]
       workingDir: "/absolute/working/dir"
   ```

### Debug Mode

Enable debug logging for troubleshooting:

1. **Start Niffler with debug:**
   ```bash
   niffler --loglevel=DEBUG
   ```

2. **Look for MCP-related messages** in the debug output

3. **Check server startup sequence** - you should see messages about each server starting

### Health Monitoring

Monitor server health programmatically:

```bash
# Check server status regularly
/mcp status
# Watch for:
# - Status should be "Running"
# - Errors should not increase
# - Restarts should be minimal
# - Last Activity should be recent
```

## Performance Considerations

### Server Selection

Choose servers based on your needs:

- **Lightweight**: Filesystem, basic Git operations
- **Heavy**: GitHub, external API integrations
- **Local vs Remote**: Local servers are faster, remote servers might be slower

### Resource Usage

Monitor resource consumption:

```bash
# CPU and memory usage
ps aux | grep niffler
ps aux | grep mcp

# Network connections
netstat -an | grep :3000  # Or other MCP ports
```

### Timeout Optimization

Adjust timeouts based on server characteristics:

- **Fast local servers**: 5-10 seconds
- **Network-based servers**: 30-60 seconds
- **API-heavy servers**: 60-120 seconds

## Security Considerations

### Environment Variables

Never commit sensitive data:

```yaml
# ❌ Don't do this
mcpServers:
  github:
    env:
      GITHUB_TOKEN: "ghp_1234567890abcdef"  # HARD CODED SECRET!

# ✅ Do this instead
mcpServers:
  github:
    env:
      GITHUB_TOKEN: "${GITHUB_TOKEN}"  # From environment
```

### Filesystem Access

Limit filesystem access to necessary directories:

```yaml
mcpServers:
  filesystem:
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/safe-dir"]
    # NOT "/" or "/home" which could access everything
```

### Network Isolation

Consider using Docker for network isolation:

```yaml
# Run MCP servers in containers
services:
  mcp-fs:
    image: mcp/server-filesystem
    volumes:
      - ./safe-dir:/data:ro  # Read-only mount
    networks:
      - internal  # Isolated network
```

## Best Practices

### Configuration Management

1. **Use environment-specific configurations**
2. **Store sensitive data in environment variables**
3. **Version control your `config.yaml` (without secrets)**
4. **Test new servers in development first**

### Monitoring

1. **Regularly check `/mcp status`**
2. **Monitor error counts and restarts**
3. **Set up logging for production use**
4. **Alert on server failures**

### Performance

1. **Only enable servers you actually use**
2. **Adjust timeouts based on server performance**
3. **Consider local alternatives to remote servers**
4. **Monitor resource usage regularly`

For more details on MCP and available servers, see the [Model Context Protocol documentation](https://modelcontextprotocol.io/).