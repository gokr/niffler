# Niffler Test Suite

This directory contains the consolidated test suite for the Niffler AI terminal assistant.

## Test Structure

The test suite has been consolidated from 32 to 24 files to reduce redundancy while maintaining full coverage.

### Core Test Categories

- **Basic Functionality**: `test_basic.nim` - Core types and schema validation
- **Tool Integration**: `test_tool_integration.nim` - Consolidated tool testing, task execution, and agent handling
- **TodayList**:
  - `test_todolist_core.nim` - Functional tests + validation (merged)
  - `test_todolist_database.nim` - Database integration
  - `test_todolist_e2e.nim` - End-to-end scenarios
- **Conversation**: CLI, infrastructure, mode restore, and e2e tests
- **Specialized**: Individual suites for NATS, thinking tokens, streaming, etc.

### Manual Tests

Manual integration tests that require LLM API access are located in `tests/manual/`.

## Running Tests

```bash
# Run all tests
nimble test

# Run individual test files
nim c -r tests/test_basic.nim
nim c -r tests/test_tool_integration.nim
```

## Consolidation Results

- **Before**: 32 test files with significant redundancy
- **After**: 24 test files with minimal overlap
- **Reduction**: 25% fewer files, ~20% line count reduction
- **Coverage**: All critical functionality maintained

### Key Consolidations

1. **Removed irrelevant tests**: `test_hello.nim`, `test_nim_features.nim` (tested Nim language, not niffler)
2. **Eliminated duplicate feedback tests**: Removed redundant `test_duplicate_feedback_core.nim`
3. **Merged tool integration**: Consolidated 3 separate tool test files into 1 comprehensive test
4. **Streamlined todolist tests**: Reorganized 4 files into 3 focused test suites

## Test Categories

| Category | Files | Purpose |
|----------|-------|---------|
| Core | 1 | Basic functionality and schemas |
| Integration | 1 | Tool system, task execution, agents |
| Todolist | 3 | Core/functional, database, e2e |
| Conversation | 4 | CLI, infrastructure, modes, e2e |
| Specialized | 11 | Individual component testing |
| Manual | 1 | LLM integration (separate directory) |

## Troubleshooting

### Compilation Issues
- Ensure `--threads:on -d:ssl` flags are used
- Check that all dependencies are installed via nimble
- Verify Nim version >= 2.2.4

### Test Failures
- Check file permissions in test directory
- Ensure no conflicting processes are running
- Review error messages for specific validation failures

### Missing Dependencies
```bash
nimble install sunny
```