# Integration Tests Guide

This guide explains Niffler's integration test framework and how to run end-to-end tests with real LLMs.

## Overview

The integration tests verify Niffler's functionality using actual services rather than mocks:

- **Real LLM APIs** - Test against OpenAI, Anthropic, or custom endpoints
- **Database Persistence** - Verify data storage in TiDB/MySQL
- **NATS Messaging** - Test multi-agent communication
- **Tool Execution** - Verify file operations and command execution

## Quick Start

### 1. Set Up Environment

```bash
# Required for real LLM tests
export NIFflER_TEST_API_KEY="your-api-key-here"

# Optional: Override defaults
export NIFflER_TEST_MODEL="gpt-4o-mini"
export NIFflER_TEST_BASE_URL="https://api.openai.com/v1"
export NIFflER_TEST_NATS_URL="nats://localhost:4222"
```

### 2. Start Required Services

```bash
# NATS server (for master-agent tests)
nats-server -js

# TiDB/MySQL (for persistence tests)
# Ensure it's running on localhost:4000 with root access
```

### 3. Run All Integration Tests

```bash
cd /home/gokr/tankfeud/niffler
./tests/run_integration_tests.sh
```

## Test Suites

### 1. Integration Framework (`test_integration_framework.nim`)

Tests foundational components and basic LLM integration:

- **Simple Q&A**: Verifies API connectivity and basic responses
- **Tool Execution**: Tests LLM's ability to call tools
- **Master Mode Components**: Tests NATS client and message parsing

### 2. Master-Agent Scenario (`test_master_agent_scenario.nim`)

Tests the multi-agent architecture:

- **Agent Definitions**: Loads and validates agent markdown files
- **Message Routing**: Tests @agent syntax and NATS messaging
- **Fallback Behavior**: Verifies operation without NATS
- **Process Utilities**: Helper functions for spawning agents

### 3. Real LLM Workflows (`test_real_llm_workflows.nim`)

Tests realistic user workflows:

- **Code Analysis**: LLM reads and analyzes Python code
- **Multi-step Editing**: Sequential file operations (read → edit → verify)
- **Error Handling**: Graceful recovery from tool failures

## Running Individual Tests

### Using Test Runner Script

```bash
# Run only framework tests
./tests/run_integration_tests.sh framework

# Run with verbose logging
NIFflER_LOG_LEVEL=DEBUG ./tests/run_integration_tests.sh
```

### Direct Compilation

```bash
# Build and run a specific test
nim c -r --threads:on -d:ssl tests/test_integration_framework.nim

# Run with test output
nim c -r --threads:on -d:ssl tests/test_integration_framework.nim --run --testutils
```

## Test Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `NIFflER_TEST_API_KEY` | LLM API key for testing | Required |
| `NIFflER_TEST_MODEL` | Model name to test | `gpt-4o-mini` |
| `NIFflER_TEST_BASE_URL` | API base URL | `https://api.openai.com/v1` |
| `NIFflER_TEST_NATS_URL` | NATS server URL | `nats://localhost:4222` |
| `NIFflER_LOG_LEVEL` | Logging verbosity | `WARN` |

### Test Agents

Create test agents in `tests/test_agents/*.md`:

```markdown
## Description
Test agent for integration testing

## Allowed Tools
- read
- create
- edit

## System Prompt
You are a test agent...
```

## Expected Behavior

### Successful Test Output

```
🧪 Niffler Integration Test Runner
==================================

✅ API key configured
   Model: gpt-4o-mini
   Base URL: https://api.openai.com/v1

✅ NATS server is running
✅ Database (TiDB/MySQL) is running

🔨 Building test binaries...

🚀 Running integration tests...
=============================

Running: Integration Framework
---------------------------
[PASS] Test A
[PASS] Test B
✅ Integration Framework: PASSED

Running: Master-Agent Scenario
---------------------------
[PASS] Test C
[PASS] Test D
✅ Master-Agent Scenario: PASSED

Running: Real LLM Workflows
---------------------------
[PASS] Code analysis workflow
[PASS] Multi-step editing workflow
✅ Real LLM Workflows: PASSED

==================================
📊 Test Summary
==================================
Total: 15 tests
Passed: 15

🎉 All tests passed!
```

### Handling Failures

Common failure scenarios and solutions:

1. **API Key Issues**
   ```
   ⚠️  NIFflER_TEST_API_KEY not set
   ```
   Solution: Export a valid API key

2. **NATS Not Running**
   ```
   ⚠️  NATS server not found
   ```
   Solution: `nats-server -js`

3. **Database Connection**
   ```
   ⚠️  Database not accessible
   ```
   Solution: Ensure TiDB/MySQL on localhost:4000

4. **Test Timeouts**
   ```
   ❌ Test timeout
   ```
   Solutions:
   - Check internet connection
   - Increase timeout values
   - Use faster model (gpt-4o-mini)

## Debugging Tips

### Enable Verbose Logging

```bash
export NIFflER_LOG_LEVEL=DEBUG
./tests/run_integration_tests.sh
```

### Test Individual Components

```bash
# Test only NATS connectivity
nim c -r tests/test_nats_integration.nim

# Test database connection
nim -e "import src/core/database; var db = initMysqlBackend(...); echo db.ping()"
```

### Manual Testing

```bash
# Quick LLM test
./bin/niffler --single "What is 2+2?"

# Test master mode
./bin/niffler --master --agents
```

## Adding New Tests

### 1. Create Test File

```nim
# tests/test_my_feature.nim
import std/[unittest]
import ../src/core/[config, database]

suite "My Feature Tests":
  test "Basic functionality":
    check true
```

### 2. Add to Test Runner

Update `tests/run_integration_tests.sh`:

```bash
run_test_suite "tests/test_my_feature.nim" "My Feature"
```

### 3. Best Practices

- Use `skip()` for optional tests based on environment
- Clean up test data in `defer` blocks
- Provide clear error messages
- Test both success and failure cases

## Continuous Integration

These tests are designed to run in CI/CD pipelines:

```yaml
# .github/workflows/integration.yml
- name: Run Integration Tests
  env:
    NIFflER_TEST_API_KEY: ${{ secrets.TEST_API_KEY }}
  run: |
    nats-server -js &
    ./tests/run_integration_tests.sh
```

## Troubleshooting

### Common Issues

1. **SSL/TLS Errors**
   ```bash
   export OPENSSL_CONF=/etc/ssl/openssl.cnf
   ```

2. **Thread Safety Issues**
   - Use `--threads:on` flag
   - Ensure `{.gcsafe.}` pragma on threaded functions

3. **Database Permissions**
   ```sql
   GRANT ALL PRIVILEGES ON niffler_test.* TO 'root'@'%';
   ```

### Getting Help

- Check test output for specific error messages
- Enable debug logging: `NIFflER_LOG_LEVEL=DEBUG`
- Run with GDB for crashes: `gdb nim`
- Check existing issues in the repository

## Contributing

When adding integration tests:

1. Follow the existing test structure
2. Clean up resources (files, database records)
3. Document any prerequisites
4. Update this guide with new test descriptions
5. Ensure tests work without services (use `skip()`)