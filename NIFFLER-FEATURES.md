# NIFFLER.md files

This document describes how to use NIFFLER.md files.

## System Prompt Extraction

Niffler can extract system prompts from specific sections in NIFFLER.md files. This way you can both inspect and tweak system wide prompts in `~/.niffler/NIFFLER.md` but also tweak for specific projects.

### Supported Sections

- **`# Common System Prompt`** - Base system prompt used for all modes
- **`# Plan Mode Prompt`** - Additional instructions for Plan mode
- **`# Code Mode Prompt`** - Additional instructions for Code mode

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

## Search Hierarchy

Niffler searches for NIFFLER.md files in this order:

1. **Current directory**
2. **Parent directories** (up to 3 levels)
3. **Config directory** (`~/.niffler/`)

This allows for:
- **Project-specific** prompts in project directories
- **System-wide** prompts in `~/.niffler/NIFFLER.md`

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

Place common instructions in `~/.niffler/NIFFLER.md`:

```markdown
# Common System Prompt

System-wide instructions for all projects.

# Organization Standards

@include ~/dev/standards/coding-guidelines.md
```

Individual projects can override by having their own NIFFLER.md.

## Configuration

Control which instruction files are searched via config:

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

## Best Practices

1. **Use hierarchy** - System-wide prompts in `~/.niffler/`, project-specific in project root
2. **Include shared content** - Use `@include` to share common guidelines
3. **Separate concerns** - System prompts vs instruction content
4. **Test changes** - System prompts affect LLM behavior significantly
5. **Version control** - Include NIFFLER.md in your repository