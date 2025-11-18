# Niffler Tool Calling Tests

This directory contains comprehensive tests for the tool calling functionality implemented in Phase 5.

## Test Files

### `test_tool_calling.nim`
Core functionality tests:
- Tool schema generation and validation
- Message type conversions 
- Tool call creation and parsing
- Basic integration tests

### `test_api_integration.nim` 
API integration tests:
- ChatMessage conversion with tool calls
- JSON serialization/deserialization
- OpenAI API format compatibility
- Multi-turn conversation handling

### `test_tool_execution.nim`
Tool execution and validation tests:
- Individual tool argument validation
- File system operations (create, read, edit, list)
- Security and safety checks
- Error handling scenarios

## Running Tests

### Run All Tests
```bash
nimble test
```

### Run Individual Test Suites
```bash
# Tool calling core tests
nim c -r --threads:on -d:ssl test_tool_calling.nim

# API integration tests  
nim c -r --threads:on -d:ssl test_api_integration.nim

# Tool execution tests
nim c -r --threads:on -d:ssl test_tool_execution.nim
```

## What These Tests Verify

### ✅ Tool Schema System
- All 6 tools (bash, read, list, edit, create, fetch) have proper schemas
- Schema validation works correctly
- Parameter validation catches invalid arguments
- Tool confirmation requirements are properly defined

### ✅ API Integration
- Messages convert correctly between internal and OpenAI formats
- Tool calls serialize/deserialize properly in JSON
- Multi-turn conversations with tools work
- Error responses are handled gracefully

### ✅ Tool Execution
- Tool arguments are validated before execution
- File system operations are safe and secure
- Path sanitization prevents directory traversal
- Timeout and permission checks work

### ✅ Safety & Security
- Malicious paths are blocked
- Invalid permissions are rejected
- Tool execution timeouts are enforced
- Error handling is comprehensive

## Expected Output

When all tests pass, you should see:
```
🎉 ALL TESTS PASSED!

Tool calling functionality is working correctly:
✓ Tool schema generation and validation
✓ API integration with tool calls  
✓ Message type conversions
✓ Tool execution validation
✓ Error handling and safety checks

Ready for production use!
```

## Test Coverage

These tests cover:
- **Schema Generation**: All tool schemas are properly formed
- **Validation**: Arguments are validated according to schemas
- **API Compatibility**: OpenAI-compatible JSON format
- **Message Flow**: Complete tool calling conversation flow
- **Security**: Path validation, permission checks, timeouts
- **Error Handling**: Graceful failure modes

## Integration with Phase 5

These tests validate the complete Phase 5 implementation:
1. **Tool Schema System** (`src/tools/schemas.nim`)
2. **API Integration** (`src/api/worker.nim`, `src/api/http_client.nim`)  
3. **Message Types** (`src/types/messages.nim`)
4. **Tool Validation** (`src/tools/common.nim`)
5. **Worker Integration** (tool worker ↔ API worker communication)

## Next Steps

After all tests pass, Phase 5 is complete and you can proceed with:
- **Phase 6**: Rich Terminal UI with illwill
- **Streaming Improvements**: Enhanced SSE parsing
- **Production Testing**: Real LLM integration testing

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