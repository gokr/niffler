# Nedit - System Prompt for LLMs

## Overview

Nedit is a file editing CLI tool designed specifically for LLM agents. It provides safe, predictable file operations with clear feedback and exploratory help system.

## When to Use Nedit

Use nedit when you need to:
- Read file contents (with optional line ranges)
- Create new files or overwrite existing ones
- Edit existing files (replace, insert, delete, append, prepend)
- List directory contents
- Search for patterns in files
- Get file metadata

## Exploratory Usage Pattern

Nedit is designed for exploratory use. When uncertain:

1. **Start with help**: `nedit --help` shows all available commands
2. **Drill down**: `nedit <command> --help` shows detailed help for each command
3. **Learn from errors**: Commands provide helpful error messages suggesting fixes

Example exploration flow:
```
> nedit                           # Show main help
> nedit edit --help               # Learn about edit command
> nedit edit file.txt replace     # Error shows usage hint
> nedit edit file.txt replace "old" "new"  # Success!
```

## Command Reference

### read - Read File Contents

```
nedit read <file> [options]
```

**Options:**
- `--lines=N-M` - Read lines N through M (1-indexed)
- `--lines=N` - Read from line N to end
- `--head=N` - First N lines
- `--tail=N` - Last N lines
- `--show-lines` - Show line numbers
- `--max=N` - Max bytes to read

**When to use:**
- Viewing file contents before editing
- Reading specific sections of large files
- Getting line numbers for subsequent edits

**Examples:**
```
nedit read src/main.py
nedit read src/main.py --lines=10-20
nedit read config.yaml --show-lines
nedit read log.txt --tail=100
```

### write - Create or Overwrite Files

```
nedit write <file> <content> [options]
nedit write <file> --stdin
```

**Options:**
- `--mkdir` - Create parent directories
- `--backup` - Create backup before overwriting
- `--append` - Append instead of overwrite

**When to use:**
- Creating new files
- Completely replacing file contents
- Writing generated code to files

**Examples:**
```
nedit write hello.py "print('hello')"
nedit write src/new.py "content" --mkdir
nedit write config.json '{"key": "value"}' --backup
```

### edit - Modify Existing Files

```
nedit edit <file> <operation> [arguments] [options]
```

**Operations:**
- `replace <old> <new>` - Replace first occurrence
- `insert <line> <text>` - Insert at line number
- `delete <start-end>` - Delete lines
- `append <text>` - Add to end
- `prepend <text>` - Add to beginning
- `rewrite <content>` - Replace entire file

**Options:**
- `--all` - Replace all occurrences
- `--backup` - Create backup
- `--create` - Create file if doesn't exist
- `--show-result` - Show modified lines after edit (for validation)
- `--context=N` - Show N lines of context around changes (default: 3)

**When to use:**
- Making targeted edits to existing files
- Fixing specific lines or text
- Adding code to existing files

**LLM Best Practice:** Always use `--show-result` to validate changes immediately.

**Examples:**
```
nedit edit file.py replace "old_function" "new_function" --show-result
nedit edit file.py replace "foo" "bar" --all --show-result --context=5
nedit edit file.py insert 10 "# New comment" --show-result
nedit edit file.py delete 5-10
nedit edit file.py append "# Added at end" --show-result
```

### list - List Directory Contents

```
nedit list [directory] [options]
```

**Options:**
- `--all` - Show hidden files
- `--long` - Detailed info (size, date)
- `--recursive` - List recursively
- `--files-only` - Only files
- `--dirs-only` - Only directories
- `--pattern=GLOB` - Filter by pattern

**When to use:**
- Exploring project structure
- Finding files to edit
- Checking if files exist

**Examples:**
```
nedit list
nedit list src/
nedit list --recursive
nedit list --pattern="*.py"
```

### grep - Search in Files

```
nedit grep <pattern> <path> [options]
```

**Options:**
- `--recursive` - Search directories
- `--ignore-case` - Case insensitive
- `--line-number` - Show line numbers
- `--files-only` - Only show filenames
- `--count` - Only show match counts

**When to use:**
- Finding code to modify
- Locating function definitions
- Searching for patterns across files

**Examples:**
```
nedit grep "function" src/
nedit grep "TODO" src/ --recursive
nedit grep "error" log.txt --context=3
```

### stat - File Information

```
nedit stat <file>
```

**When to use:**
- Checking file exists
- Getting file metadata
- Verifying file type

## Best Practices for LLMs

1. **Always use `--show-result` for validation**: After edits, see the changed lines immediately to verify correctness.

2. **Use `--context=N` for more context**: When editing, see more surrounding lines for better understanding.

3. **Read before editing**: Use `nedit read` to understand file contents before making changes.

4. **Use line numbers**: `nedit read --show-lines` helps identify exact line numbers for insert/delete operations.

5. **Verify with grep**: After edits, use `nedit grep` to verify changes were applied correctly.

6. **Use backups for important files**: `--backup` creates `.bak` files for safety.

7. **Create directories first**: Use `--mkdir` when writing to new directory paths.

8. **Learn from error messages**: Nedit provides helpful error messages with suggestions - use them to guide corrections.

## Error Recovery with Context

Nedit provides helpful context when errors occur:

```
Error: Text not found in file

Searched for: "helo_world"

Similar lines found:
  Line 1: def hello():
  Line 5: def goodbye():

Tip: Use 'nedit read' with --show-lines to see exact content
```

This helps LLMs:
- Understand what went wrong
- Find similar text that might be what they meant
- Get guidance on how to fix the issue

## Error Recovery

Nedit errors include guidance:

```
Error: File not found: myfile.txt

Try: nedit list to see available files
```

```
Error: Text not found: 'old_text'

Use 'nedit read' to see file contents
```

## Workflow Example

```
# 1. Explore project structure
nedit list --recursive

# 2. Read file to understand it
nedit read src/main.py --show-lines

# 3. Make targeted edit
nedit edit src/main.py replace "buggy_code" "fixed_code"

# 4. Verify the change
nedit grep "fixed_code" src/main.py

# 5. Check file still works
nedit read src/main.py --lines=10-20
```

## Integration Notes

- Nedit uses 1-indexed line numbers (first line is line 1)
- All operations provide clear success/error feedback
- The tool is designed to be stateless - each command is independent
- Output includes both human-readable messages and machine-parseable information
