# Niffler Configuration System

This document describes Niffler's configuration system, including config directories, NIFFLER.md files, and the layered override mechanism.

## Configuration Directory Structure

Niffler uses a flexible configuration system with multiple config directories:

```
~/.niffler/
├── config.json              # Main config with model settings and active config selection
├── niffler.db              # SQLite database for conversations
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
- `~/.niffler/config.json` with default settings and `"config": "default"`
- `~/.niffler/default/` with minimal prompts
- `~/.niffler/cc/` with Claude Code style prompts
- Default agent definitions in both config directories

## Config Selection Mechanism

### Layered Config Resolution

Niffler uses a layered approach to determine which config directory to use:

**Priority (highest to lowest):**
1. **Project-level**: `.niffler/config.json` in current directory
2. **User-level**: `~/.niffler/config.json`
3. **Default fallback**: `"default"` if no config specified

### Config.json Structure

The `config` field in `config.json` selects the active config directory:

```json
{
  "yourName": "User",
  "config": "default",
  "models": [ ... ],
  ...
}
```

Valid values for `config`:
- `"default"` - Minimal, fast prompts
- `"cc"` - Claude Code style (verbose, example-rich)
- `"custom"` - Any custom config directory you create

### Project-Level Override

Create `.niffler/config.json` in your project to override the config:

```bash
mkdir .niffler
cat > .niffler/config.json << 'EOF'
{
  "config": "cc"
}
EOF
```

Now when you run `niffler` in this project, it will:
1. Load `.niffler/config.json` → sees `"config": "cc"`
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

**Important:** `/config` does NOT modify any config.json files. It only changes the active config for the current session.

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
```json
{
  "config": "myteam"
}
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

Individual projects can override by having their own `.niffler/config.json`:

```json
{
  "config": "myorg"
}
```

## Configuration Fields

Control which instruction files are searched via config.json:

```json
{
  "instructionFiles": [
    "NIFFLER.md",
    "CLAUDE.md",
    "OCTO.md",
    "AGENT.md"
  ]
}
```

## Config Override Examples

### Example 1: Team Standardization

**Scenario:** Your team wants all projects to use Claude Code style by default.

**Solution:** Edit `~/.niffler/config.json`:
```json
{
  "config": "cc",
  ...
}
```

Now all projects use CC style unless they override it.

### Example 2: Project-Specific Style

**Scenario:** One project needs minimal prompts for performance, but you prefer CC globally.

**Solution:** In that project:
```bash
mkdir .niffler
echo '{"config": "default"}' > .niffler/config.json
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
2. **Use project .niffler/config.json for selection** - Just specify which config to use
3. **Use project NIFFLER.md for overrides** - Project-specific prompt tweaks
4. **Create team configs** - Share a config directory across team members

### Prompt Development

1. **Start with default** - Test with minimal prompts first
2. **Upgrade to cc when needed** - For complex projects requiring high steerability
3. **Create custom configs** - For specific workflows or teams
4. **Version control** - Commit `.niffler/config.json` to git
5. **Test changes** - System prompts affect LLM behavior significantly

### File Inclusion

1. **Share common guidelines** - Use `@include` to avoid duplication
2. **Separate concerns** - System prompts vs instruction content
3. **Use relative paths** - Makes configs portable
4. **Document includes** - Comment what each include provides

## Troubleshooting

### Config not loading

Check the resolution order:
1. Is there a `.niffler/config.json` in current directory?
2. Does `~/.niffler/config.json` have a valid `"config"` field?
3. Does the config directory exist in `~/.niffler/{name}/`?

### Prompts not applying

1. Run `/config` to see which config is active
2. Check `~/.niffler/{active}/NIFFLER.md` exists
3. Verify section headings are exact: `# Common System Prompt`
4. Check for syntax errors in NIFFLER.md

### Project override not working

1. Ensure `.niffler/config.json` is in the project root
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
