# Discord Bot Setup Guide

This guide walks you through setting up Niffler as a Discord bot that can receive tasks via Discord messages and execute them autonomously.

## Prerequisites

- Working Niffler installation with database (see main README)
- Discord account

## Step 1: Create Discord Bot

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

### Get Guild ID (Optional)

For filtering to a specific server:
1. In Discord, enable Developer Mode (User Settings → Advanced → Developer Mode)
2. Right-click your server name
3. Click "Copy Server ID"

## Step 2: Configure Discord in Niffler

Start Niffler and use the `/discord` commands to configure:

### Connect Discord Bot

```
/discord connect YOUR_BOT_TOKEN [GUILD_ID]
```

Example:
```
/discord connect OTk2MTg5NjQxNjk3MjYzMDQw.GhK7Xa.abc123
/discord connect OTk2MTg5NjQxNjk3MjYzMDQw.GhK7Xa.abc123 123456789
```

### Test Connection

```
/discord test
```

This validates your token and shows the bot username.

### Configure Channels (Optional)

To monitor specific channels only:

```
/discord channels add general
/discord channels add dev
/discord channels list
```

When no channels are specified, the bot monitors all channels it has access to.

### Enable/Disable Discord

```
/discord enable
/discord disable
```

### Check Status

```
/discord status
```

## Step 3: Start the Agent

```bash
./niffler agent coder
```

The agent will connect to Discord and start listening for messages.

## Step 4: Test Discord Integration

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

## Discord Commands Reference

| Command | Description |
|---------|-------------|
| `/discord status` | Show current Discord configuration |
| `/discord connect <token> [guildId]` | Set Discord bot token |
| `/discord test` | Test Discord connection |
| `/discord enable` | Enable Discord integration |
| `/discord disable` | Disable Discord integration |
| `/discord channels list` | List monitored channels |
| `/discord channels add <name>` | Add channel to monitor |
| `/discord channels remove <name>` | Remove channel from monitor |

## Troubleshooting

### Bot Not Responding

1. **Check if bot is online** in Discord
2. **Verify token**: Run `/discord test` to validate
3. **Check permissions**: Bot needs MESSAGE CONTENT INTENT enabled
4. **Check status**: Run `/discord status` to see configuration

### Token Invalid

1. Go to Discord Developer Portal
2. Reset the token
3. Run `/discord connect <new-token>`

### Tasks Not Processing

1. Verify agent is running: `ps aux | grep niffler`
2. Check Discord status: `/discord status`
3. Test connection: `/discord test`

## Security Notes

⚠️ **Never commit your Discord token or API keys to git!**

- Tokens are stored in database only
- Run `/discord status` shows masked token
- Rotate tokens regularly via Discord Developer Portal
- Use Discord's permission system to limit bot access

## Next Steps

Once Discord is working:

1. **Test different tasks**: Code review, refactoring, documentation
2. **Configure multiple channels**: `/discord channels add <channel>`
3. **Set up workspaces**: See workspace documentation
4. **Add file watchers**: React to code changes

---

**Need help?** Check the main README.md or file an issue on GitHub.
