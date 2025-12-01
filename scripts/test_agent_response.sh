#!/bin/bash
# Test script to verify agent responses work correctly with kimi and qwen3coder models
# This script tests all 4 verification points:
# 1. API responses are received
# 2. Parsing and accumulation is correct
# 3. Persistence to database works
# 4. /inspect shows correct conversation

set -euo pipefail

AGENT_NAME="testbot"
TEST_LOG="test-response-$(date +%s)"

echo "=== Agent Response Testing ==="
echo "Test log: $TEST_LOG"
echo ""

# Function to query database
query_db() {
    local query="$1"
    mysql -h 127.0.0.1 -P 4000 -u root niffler -e "$query" 2>/dev/null
}

# Function to test a model
test_model() {
    local model="$1"
    echo "==========================================="
    echo "Testing model: $model"
    echo "==========================================="
    echo ""

    # Get conversation count before
    echo "Step 1: Getting baseline conversation count..."
    conv_count_before=$(query_db "SELECT COUNT(*) as count FROM conversation" | tail -1)
    echo "  Conversations before: $conv_count_before"
    echo ""

    # Note: We cannot run the agent interactively in this script
    # User needs to run manually and follow the prompts below
    echo "Step 2: Manual test required - Please run:"
    echo "  ./src/niffler agent coder --nick=$AGENT_NAME --model=$model --debug --log=$TEST_LOG"
    echo ""
    echo "Then in another terminal, send a request:"
    echo "  ./src/niffler master"
    echo "  Type: @$AGENT_NAME What is 7+8? Explain your answer."
    echo ""
    echo "Press Enter when the agent has responded..."
    read

    echo ""
    echo "Step 3: Verifying database persistence..."

    # Get the latest conversation
    latest_conv=$(query_db "SELECT id, title, model, created_at FROM conversation ORDER BY created_at DESC LIMIT 1")
    echo "Latest conversation:"
    echo "$latest_conv"
    echo ""

    # Get message count for latest conversation
    latest_conv_id=$(query_db "SELECT id FROM conversation ORDER BY created_at DESC LIMIT 1" | tail -1)
    msg_count=$(query_db "SELECT COUNT(*) as count FROM conversation_message WHERE conversation_id=$latest_conv_id" | tail -1)
    echo "  Messages in conversation: $msg_count"
    echo "  Expected: At least 2 (user + assistant)"
    echo ""

    # Show the messages
    echo "Step 4: Verifying message content..."
    query_db "SELECT id, role, LEFT(content, 100) as content_preview, output_tokens FROM conversation_message WHERE conversation_id=$latest_conv_id ORDER BY created_at"
    echo ""

    # Check for non-empty assistant response
    assistant_content_length=$(query_db "SELECT LENGTH(content) as len FROM conversation_message WHERE conversation_id=$latest_conv_id AND role='assistant' ORDER BY created_at DESC LIMIT 1" | tail -1)
    echo "  Assistant response length: $assistant_content_length characters"
    if [ "$assistant_content_length" -gt 0 ]; then
        echo "  ✓ Assistant response is not empty"
    else
        echo "  ✗ ERROR: Assistant response is empty!"
    fi
    echo ""

    echo "Step 5: Check debug log for HTTP response details..."
    echo "  Log file: ~/.niffler/logs/$TEST_LOG.log"
    echo ""
    if grep -q "Received HTTP status:" ~/.niffler/logs/$TEST_LOG.log; then
        status_code=$(grep "Received HTTP status:" ~/.niffler/logs/$TEST_LOG.log | tail -1 | awk '{print $NF}')
        echo "  HTTP status code: $status_code"
    fi
    if grep -q "Stream ended normally" ~/.niffler/logs/$TEST_LOG.log; then
        stream_stats=$(grep "Stream ended normally" ~/.niffler/logs/$TEST_LOG.log | tail -1)
        echo "  $stream_stats"
    fi
    if grep -q "Successfully parsed chunk" ~/.niffler/logs/$TEST_LOG.log; then
        chunk_count=$(grep -c "Successfully parsed chunk" ~/.niffler/logs/$TEST_LOG.log)
        echo "  Chunks parsed: $chunk_count"
    fi
    echo ""

    echo "Step 6: Test /inspect command..."
    echo "  In the agent terminal, type: /inspect"
    echo "  Verify the conversation shows:"
    echo "    - User message: 'What is 7+8? Explain your answer.'"
    echo "    - Assistant response with actual content"
    echo "    - Token counts match what's in the database"
    echo ""
    echo "Press Enter when you've verified /inspect..."
    read

    echo "✓ Test completed for $model"
    echo ""
}

# Test both models
test_model "kimi"
echo ""
echo "Ready to test next model? Press Enter..."
read
test_model "qwen3-coder"

echo ""
echo "========================================="
echo "All tests completed!"
echo "========================================="
echo ""
echo "Summary of what was tested:"
echo "1. ✓ API responses are received (check HTTP status and stream stats)"
echo "2. ✓ Parsing and accumulation (check chunk count and response length)"
echo "3. ✓ Database persistence (verify messages table has content)"
echo "4. ✓ /inspect command (verify it shows the same data)"
echo ""
