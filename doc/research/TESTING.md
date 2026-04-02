# Testing the Loop-Based Tool Execution Fix

## What Was Fixed

**Problem:** Tool calls and results were getting mismatched in database-backed conversations due to recursive execution with `database=nil`.

**Solution:** Replaced recursion with a simple while loop that stores every message to the database immediately.

## Manual Testing Instructions

### Test 1: Multi-Turn Tool Calling

**Run this command:**
```bash
./src/niffler agent coder --task="Can you write, compile and run hello world in Nim?" --model=synthetic-glm46
```

**Expected behavior:**
- Agent should make multiple tool calls sequentially
- Example flow: check nim version → create file → compile → run
- No errors about "Tool execution failed" or "maximum recursion depth"
- Clean execution with visible tool call/result pairs

### Test 2: Database Consistency Check

**After running a test conversation, check the database:**

```bash
# Get the most recent conversation ID
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
SELECT MAX(id) as latest_conv_id FROM conversation"

# Replace <ID> with the actual conversation ID from above
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
SELECT
  id,
  role,
  LEFT(content, 60) as content_preview,
  JSON_UNQUOTE(JSON_EXTRACT(tool_calls, '$[0].function.name')) as tool_name,
  JSON_UNQUOTE(JSON_EXTRACT(tool_calls, '$[0].id')) as stored_call_id,
  tool_call_id as result_call_id
FROM conversation_message
WHERE conversation_id = <ID>
ORDER BY id"
```

**What to look for:**
- ✅ **No duplicate messages** - Each message should appear only once
- ✅ **No concatenated content** - Content shouldn't combine multiple assistant responses
- ✅ **Matching IDs** - `stored_call_id` in assistant message should match `result_call_id` in the following tool message
- ✅ **Clean sequence** - Pattern should be: user → assistant+tool → tool_result → assistant+tool → tool_result... → final_assistant

### Test 3: Compare with Old Behavior

**Check old broken conversation (if available):**
```bash
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
SELECT id, role, LEFT(content, 60),
       JSON_UNQUOTE(JSON_EXTRACT(tool_calls, '$[0].id')) as call_id,
       tool_call_id as result_id
FROM conversation_message
WHERE conversation_id = 17  -- The broken conversation from our analysis
ORDER BY id"
```

You should see the OLD bug:
- ✗ Message 541: Duplicate with concatenated content
- ✗ Message 542: Mismatched tool_call_id

NEW conversations should NOT have these issues!

## Success Criteria

### ✅ All Tests Pass If:

1. **Compilation:** `nim c src/niffler.nim` succeeds ✅
2. **Agent execution:** Multi-turn tool calls complete without errors ✅
3. **Database consistency:**
   - No duplicate messages ✅
   - Tool IDs match between calls and results ✅
   - Clean message sequence ✅
4. **No recursion errors:** No "maximum recursion depth" failures ✅

## Architecture Validation

**Key changes to verify:**
- `callLLMWithFollowUp()` function exists (helper for LLM streaming)
- `executeAgenticLoop()` uses a while loop (no recursive calls)
- `handleFollowUpRequest()` function deleted (no longer needed)
- All code compiles without warnings about recursion

**Check with:**
```bash
# Verify handleFollowUpRequest is gone
grep -n "proc handleFollowUpRequest" src/api/api.nim
# Should return nothing

# Verify loop-based approach exists
grep -A 5 "while currentToolResults.len > 0" src/api/api.nim
# Should show the loop in executeAgenticLoop
```

## Troubleshooting

### If tool calls fail:
- Check model is accessible: `./src/niffler models`
- Verify database connection: `mysql -h 127.0.0.1 -P 4000 -u root niffler -e "SELECT 1"`
- Check for errors in debug output

### If database shows duplicates:
- This shouldn't happen with the new code
- If it does, check git commit is correct: `git log --oneline | head -1`
- Should show: `d8fcd78 Refactor: Replace recursive tool execution...`

## Next Steps

After successful testing:
1. Mark this refactoring as complete
2. Consider updating task mode to also use database (future enhancement)
3. Add integration tests for multi-turn tool calling
4. Document the loop-based pattern for future tool implementations
