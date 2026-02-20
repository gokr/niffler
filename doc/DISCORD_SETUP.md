# Discord Bot Setup Guide

This guide walks you through setting up Niffler as a Discord bot that can receive tasks via Discord messages and execute them autonomously.

## Prerequisites

- Discord account
- TiDB database running (see Database Setup below)
- Nim 2.2.6+ installed
- Niffler compiled from source

## Step 1: Database Setup

### Option A: Local TiDB with Docker

```bash
# Pull and run TiDB
docker run -d --name tidb-server \
  -p 4000:4000 \
  pingcap/tidb:latest

# Verify it's running
docker ps | grep tidb
```

### Option B: Managed TiDB Cloud

1. Sign up at https://tidbcloud.com/
2. Create a free Serverless Tier cluster
3. Get connection details (host, port, user, password)

### Verify Database Connection

```bash
# Install MySQL client if needed
# On Ubuntu/Debian: sudo apt install mysql-client
# On macOS: brew install mysql

# Test connection
mysql -h 127.0.0.1 -P 4000 -u root

# You should see the MySQL prompt
# Type 'exit' to quit
```

## Step 2: Create Discord Bot

### Create Application

1. Go to https://discord.com/developers/applications
2. Click "New Application" button
3. Give it a name (e.g., "Niffler Bot")
4. Click "Create"

### Configure Bot

1. In the left sidebar, click "Bot"
2. Click "Add Bot" and confirm
3. Under "Privileged Gateway Intents", enable:
   - ✅ MESSAGE CONTENT INTENT (required to read message content)
   - ✅ SERVER MEMBERS INTENT
   - ✅ PRESENCE INTENT
4. Scroll down and click "Save Changes"

### Get Bot Token

1. In the Bot section, click "Reset Token"
2. Copy the token and save it securely (you'll need it later)
3. **Never share this token or commit it to git!**

### Invite Bot to Server

1. In the left sidebar, click "OAuth2" → "URL Generator"
2. Under "Scopes", select:
   - ✅ `bot`
   - ✅ `applications.commands`
3. Under "Bot Permissions", select:
   - ✅ Send Messages
   - ✅ Send Messages in Threads
   - ✅ Create Public Threads
   - ✅ Create Private Threads
   - ✅ Embed Links
   - ✅ Attach Files
   - ✅ Read Message History
   - ✅ Mention Everyone
   - ✅ Add Reactions
   - ✅ Use Slash Commands
4. Copy the generated URL
5. Open it in a browser
6. Select your server and authorize the bot

## Step 3: Configure Niffler

### Create Database Config

Create a minimal database configuration file:

```bash
mkdir -p ~/.config/niffler

# Create config file
cat > ~/.config/niffler/db_config.yaml << 'EOF'
{
  "host": "127.0.0.1",
  "port": 4000,
  "database": "niffler",
  "username": "root",
  "password": ""
}
EOF
```

**For TiDB Cloud**, use your connection details:

```bash
cat > ~/.config/niffler/db_config.yaml << 'EOF'
{
  "host": "gateway01.us-west-2.prod.aws.tidbcloud.com",
  "port": 4000,
  "database": "niffler",
  "username": "your-username",
  "password": "your-password"
}
EOF
```

### Store Discord Token in Database

Connect to your database and store the Discord configuration:

```bash
# Connect to database
mysql -h 127.0.0.1 -P 4000 -u root niffler

# Run this SQL to add Discord config:
INSERT INTO agent_config (`key`, value, updated_at) VALUES (
  'discord',
  '{
    "enabled": true,
    "token": "YOUR_DISCORD_BOT_TOKEN_HERE",
    "guildId": "YOUR_GUILD_ID_HERE",
    "monitoredChannels": ["general", "dev"]
  }',
  NOW()
);
```

Replace:
- `YOUR_DISCORD_BOT_TOKEN_HERE` with your actual bot token
- `YOUR_GUILD_ID_HERE` with your server's guild ID (optional, for filtering)
- `monitoredChannels` with the channels you want Niffler to monitor (optional)

**How to get Guild ID:**
1. In Discord, enable Developer Mode (User Settings → Advanced → Developer Mode)
2. Right-click your server name
3. Click "Copy Server ID"

### Store Model Configuration

Add at least one AI model to the database:

```sql
-- For OpenAI
INSERT INTO agent_config (`key`, value, updated_at) VALUES (
  'models',
  '[
    {
      "nickname": "gpt4",
      "model": "gpt-4",
      "baseUrl": "https://api.openai.com/v1",
      "apiKey": "sk-your-openai-key",
      "context": 8192
    }
  ]',
  NOW()
);

-- For Claude (Anthropic)
INSERT INTO agent_config (`key`, value, updated_at) VALUES (
  'models',
  '[
    {
      "nickname": "claude",
      "model": "claude-3-sonnet-20240229",
      "baseUrl": "https://api.anthropic.com/v1",
      "apiKey": "sk-ant-your-claude-key",
      "context": 200000
    }
  ]',
  NOW()
);
```

### Create a Workspace

```sql
-- Create your first workspace
INSERT INTO workspace (name, path, description, git_remote, default_branch, settings, created_at) VALUES (
  'myproject',
  '/home/user/projects/myproject',
  'My main project',
  'https://github.com/username/myproject.git',
  'main',
  '{}',
  NOW()
);
```

## Step 4: Build Niffler

```bash
# Clone or navigate to repository
cd /path/to/niffler

# Install dependencies
nimble install -d

# Build
nim c src/niffler.nim

# Verify it compiled
ls -la src/niffler
```

## Step 5: Run Niffler

### Start the Agent

```bash
# Start with default model
./src/niffler agent coder --model=gpt4

# Or with specific model
./src/niffler agent mybot --model=claude
```

You should see:
```
Agent 'coder' registered. Ready for tasks.
Press Ctrl+C to stop.
```

### Check Logs

In another terminal:

```bash
# View running processes
ps aux | grep niffler

# Check database for agent registration
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "SELECT * FROM agent;"
```

## Step 6: Test Discord Integration

### Send a Task via Discord

1. Go to your Discord server
2. In a channel the bot has access to, send:

```
@NifflerBot review the code in src/main.nim
```

Or with the command prefix:

```
!review the code in src/main.nim
```

Or via DM (direct message to the bot):

```
review the code in src/main.nim
```

### Expected Behavior

1. **Acknowledgment**: Bot should reply immediately:
   ```
   Task created (ID: 123). I'll work on this and report back when done.
   ```

2. **Processing**: The task will be processed by the task queue
3. **Result**: When complete, results will be stored in the database

### Check Task Status

```bash
# Connect to database
mysql -h 127.0.0.1 -P 4000 -u root niffler

# List recent tasks
SELECT id, status, instruction, result 
FROM task_queue_entry 
ORDER BY created_at DESC 
LIMIT 5;

# Check specific task
SELECT * FROM task_queue_entry WHERE id = 123;
```

### View Results

Results are stored as JSON in the `result` column:

```sql
-- Get task result
SELECT id, status, 
       JSON_EXTRACT(result, '$.summary') as summary,
       JSON_EXTRACT(result, '$.artifacts') as artifacts,
       JSON_EXTRACT(result, '$.toolCalls') as tool_calls,
       JSON_EXTRACT(result, '$.durationMs') as duration_ms
FROM task_queue_entry 
WHERE id = 123;
```

## Troubleshooting

### Bot Not Responding

1. **Check if bot is online** in Discord
2. **Verify token**: Ensure the token in database matches your bot token
3. **Check permissions**: Bot needs MESSAGE CONTENT INTENT enabled
4. **Check database**: Verify agent is registered:
   ```sql
   SELECT * FROM agent WHERE agent_id = 'your-agent-name';
   ```

### Database Connection Issues

1. **Verify TiDB is running**:
   ```bash
   docker ps | grep tidb
   ```

2. **Test connection**:
   ```bash
   mysql -h 127.0.0.1 -P 4000 -u root -e "SELECT 1"
   ```

3. **Check config file**:
   ```bash
   cat ~/.config/niffler/db_config.yaml
   ```

### Tasks Not Processing

1. **Check task queue**:
   ```sql
   SELECT COUNT(*) FROM task_queue_entry WHERE status = 'pending';
   ```

2. **Check agent status**:
   ```sql
   SELECT agent_id, status, last_heartbeat FROM agent;
   ```

3. **View recent tasks**:
   ```sql
   SELECT id, status, instruction, error 
   FROM task_queue_entry 
   ORDER BY created_at DESC 
   LIMIT 10;
   ```

### Compilation Errors

If you get compilation errors:

```bash
# Clean and rebuild
rm -f src/niffler
nim c src/niffler.nim 2>&1 | head -100
```

## Advanced Configuration

### Environment Variables

You can also use environment variables instead of the config file:

```bash
export NIFFLER_DB_HOST=127.0.0.1
export NIFFLER_DB_PORT=4000
export NIFFLER_DB_DATABASE=niffler
export NIFFLER_DB_USERNAME=root
export NIFFLER_DB_PASSWORD=""
export DISCORD_TOKEN="your-bot-token"

./src/niffler agent coder
```

### Multiple Channels

To monitor multiple channels:

```sql
UPDATE agent_config 
SET value = '{
  "enabled": true,
  "token": "your-token",
  "guildId": "your-guild-id",
  "monitoredChannels": ["general", "dev", "alerts"]
}'
WHERE `key` = 'discord';
```

### Task Priority

Tasks are automatically assigned priority based on source:
- Discord mentions: High priority (10)
- Direct messages: Medium priority (5)
- Other: Normal priority (0)

## Security Notes

⚠️ **Never commit your Discord token or API keys to git!**

- Store tokens in database only
- Use environment variables if needed
- Rotate tokens regularly
- Use Discord's permission system to limit bot access

## Next Steps

Once Discord is working:

1. **Test different tasks**: Code review, refactoring, documentation
2. **Configure workspaces**: Add more projects to work on
3. **Set up scheduled jobs**: Regular maintenance tasks
4. **Add file watchers**: React to code changes
5. **Enable webhooks**: GitHub integration

## Quick Reference

| Command | Description |
|---------|-------------|
| `./src/niffler agent coder` | Start agent named "coder" |
| `mysql -h 127.0.0.1 -P 4000 -u root niffler` | Connect to database |
| `SELECT * FROM task_queue_entry ORDER BY created_at DESC LIMIT 5;` | View recent tasks |
| `SELECT * FROM agent;` | View registered agents |

---

**Need help?** Check the main README.md or file an issue on GitHub.
