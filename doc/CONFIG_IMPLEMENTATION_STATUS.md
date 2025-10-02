# Config System Implementation Status

## ✅ Completed (Ready to Use)

### Core Infrastructure
1. **src/core/session.nim** - Complete session management
   - `Session` type with currentConfig field
   - `initSession()` - loads from project or user config.json
   - `getActiveConfigDir()` - resolves `.niffler/{name}/` before `~/.niffler/{name}/`
   - `getAgentsDir()` - returns agents directory for active config
   - `switchConfig()` - switches or reloads config, returns (success, reloaded) tuple
   - `listAvailableConfigs()` - returns (global, project) configs
   - `diagnoseConfig()` - comprehensive config validation
   - `displayConfigInfo()` - pretty-print config status with warnings/errors

2. **src/types/config.nim** - Config type updated
   - Added `config: Option[string]` field
   - Parsing and serialization implemented

3. **src/core/templates.nim** - Template constants
   - `MINIMAL_TEMPLATE` - concise, low-token prompts
   - `CLAUDE_CODE_TEMPLATE` - verbose, example-rich prompts
   - `DEFAULT_AGENT_MD` - default agent definition

4. **src/core/config.nim** - Init updated
   - `initializeConfig()` creates `~/.niffler/default/` and `~/.niffler/cc/`
   - No intermediate `config/` directory
   - Both configs populated with templates and agents

5. **src/core/system_prompt.nim** - Session-aware
   - All functions updated to accept `session: Session` parameter
   - `findInstructionFiles(sess)` - searches active config dir first
   - `extractSystemPromptsFromNiffler(sess)` - loads from active config
   - `generateSystemPrompt(mode, sess)` - generates with session
   - `createSystemMessage(mode, sess)` - creates message with session

6. **doc/CONFIG.md** - Complete documentation
   - Directory structure explained
   - Config selection mechanism documented
   - Examples for all workflows
   - Troubleshooting section

### Directory Structure
```
~/.niffler/
├── config.json              # {"config": "default"}
├── default/                 # Minimal config
│   ├── NIFFLER.md
│   └── agents/
│       └── general-purpose.md
└── cc/                      # Claude Code style
    ├── NIFFLER.md
    └── agents/
        └── general-purpose.md

.niffler/                    # Project-local (optional)
├── config.json              # {"config": "myproject"}
└── myproject/               # Project-specific config
    ├── NIFFLER.md
    └── agents/...
```

## 🚧 Remaining Work

### 1. Thread Session Through Application

**Why:** Session must be available everywhere system prompts or agents are used.

**Files to modify:**

#### src/niffler.nim
- ✅ Import session module
- ✅ Initialize session in `startInteractiveMode()`
- ✅ Display config info at startup
- ⚠️ Pass session to `startCLIMode()`

#### src/ui/cli.nim
- Update `startCLIMode()` signature: add `session: Session` parameter
- Thread session through interactive loop
- Pass session to system prompt calls
- Pass session to command handlers

#### src/core/conversation_manager.nim
- Update functions that call system prompt generation
- Accept and forward session parameter
- Ensure session used when loading system messages

#### src/ui/commands.nim
- Update `CommandHandler` type to include session:
  ```nim
  CommandHandler* = proc(args: seq[string], session: var Session,
                        currentModel: var ModelConfig): CommandResult
  ```
- Update all command handlers to accept session
- Implement `/config` command handler

### 2. Implement /config Command

**Location:** `src/ui/commands.nim`

**Functionality:**
```nim
proc configHandler(args: seq[string], session: var Session,
                  currentModel: var ModelConfig): CommandResult =
  if args.len == 0:
    # List available configs
    let configs = listAvailableConfigs(session)
    var output = "Available configs:\n"

    if configs.global.len > 0:
      output.add("  Global:\n")
      for cfg in configs.global:
        let marker = if cfg == session.currentConfig: " (active)" else: ""
        output.add(fmt"    - {cfg}{marker}\n")

    if configs.project.len > 0:
      output.add("  Project:\n")
      for cfg in configs.project:
        let marker = if cfg == session.currentConfig: " (active)" else: ""
        output.add(fmt"    - {cfg}{marker}\n")

    displayConfigInfo(session)

    return CommandResult(
      success: true,
      message: output,
      shouldExit: false,
      shouldContinue: true,
      shouldResetUI: false
    )
  else:
    # Switch or reload config
    let targetConfig = args[0]
    let (success, reloaded) = switchConfig(session, targetConfig)

    if not success:
      return CommandResult(
        success: false,
        message: fmt"Config '{targetConfig}' not found",
        shouldExit: false,
        shouldContinue: true,
        shouldResetUI: false
      )

    if reloaded:
      echo fmt"Reloaded config: {targetConfig}"
    else:
      echo fmt"Switched to config: {targetConfig}"

    displayConfigInfo(session)

    return CommandResult(
      success: true,
      message: "",
      shouldExit: false,
      shouldContinue: true,
      shouldResetUI: true  # Reload prompts
    )
```

**Register command:**
```nim
proc initializeCommands*() =
  # ... existing commands ...
  registerCommand("config", "Switch or list configs", "[name]", @[], configHandler)
```

### 3. Update Agent Loading

**File:** `src/types/agents.nim`

**Changes needed:**
```nim
# Find loadAgentDefinitions function
proc loadAgentDefinitions*(session: Session): seq[AgentDefinition] =
  ## Load agent definitions from active config directory
  let agentsDir = session.getAgentsDir()

  if not dirExists(agentsDir):
    return @[]

  # ... rest of implementation using agentsDir
```

**Update all call sites** to pass session parameter.

### 4. Update CONFIG.md

**Path corrections needed:**
- Change all `~/.niffler/config/default/` → `~/.niffler/default/`
- Change all `~/.niffler/config/cc/` → `~/.niffler/cc/`
- Change all `.niffler/config/myproject/` → `.niffler/myproject/`

## Testing Checklist

### Manual Testing
- [ ] Run `niffler init` - creates `~/.niffler/default/` and `~/.niffler/cc/`
- [ ] Start niffler - shows config diagnostics on startup
- [ ] Run `/config` - lists available configs with current marked
- [ ] Run `/config cc` - switches to cc config, shows diagnostics
- [ ] Run `/config cc` again - shows "Reloaded config: cc"
- [ ] Create `.niffler/myproject/` - project-local config
- [ ] Add `.niffler/config.json` with `{"config": "myproject"}`
- [ ] Restart niffler - loads project config, shows "Source: project"
- [ ] Verify prompts loaded from correct NIFFLER.md
- [ ] Verify agents loaded from correct agents/ directory

### Integration Testing
- [ ] Test with missing NIFFLER.md - shows warning
- [ ] Test with empty agents directory - shows warning
- [ ] Test with non-existent config - shows error
- [ ] Test conflicting ./NIFFLER.md - shows shadow warning
- [ ] Test switching between configs mid-conversation
- [ ] Verify system prompts update after config switch

## Implementation Order

1. **Thread session through cli.nim** (highest priority)
   - Update `startCLIMode()` signature
   - Pass to interactive loop
   - Pass to command execution

2. **Update CommandHandler signature** (blocks /config)
   - Modify type definition
   - Update all existing handlers
   - Add session parameter

3. **Implement /config command** (user-facing feature)
   - Create handler function
   - Register command
   - Test listing and switching

4. **Update agent loading** (independent task)
   - Modify `loadAgentDefinitions()`
   - Update call sites

5. **Update CONFIG.md paths** (documentation cleanup)
   - Fix all path references
   - Update examples

6. **Testing** (validate everything works)
   - Run manual test checklist
   - Fix any issues found

## Notes

- Session threading is invasive but necessary for proper config system
- Consider adding config change hooks for future extensibility
- May want to add `/config reload` as explicit command vs `/config <current>`
- Consider caching diagnostics to avoid repeated filesystem checks
