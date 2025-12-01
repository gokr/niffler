#!/bin/bash
# Automated test script for agent single-shot task execution
# Tests all 4 verification points automatically

set -euo pipefail

# Test parameters
TASK="What is 7+8? Explain your answer step by step."
LOG_BASE="test-task-$(date +%s)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to query database
query_db() {
    local query="$1"
    mysql -h 127.0.0.1 -P 4000 -u root niffler -e "$query" 2>/dev/null
}

# Function to print test result
print_result() {
    local test_name="$1"
    local passed="$2"
    if [ "$passed" = "true" ]; then
        echo -e "${GREEN}✓${NC} $test_name"
    else
        echo -e "${RED}✗${NC} $test_name"
    fi
}

# Function to test a model
test_model() {
    local model="$1"
    local log_file="${LOG_BASE}-${model}"

    echo ""
    echo "========================================="
    echo "Testing model: $model"
    echo "========================================="
    echo ""

    # Record conversation count before
    local conv_count_before=$(query_db "SELECT COUNT(*) as count FROM conversation" | tail -1)

    # Execute the task
    echo "Executing task..."
    ./src/niffler agent coder --task="$TASK" --model="$model" --debug --log="$log_file" > "/tmp/agent_output_${model}.txt" 2>&1
    local exit_code=$?

    echo ""
    echo "Task execution completed (exit code: $exit_code)"
    echo ""

    # Show output
    echo "=== Agent Output ==="
    cat "/tmp/agent_output_${model}.txt"
    echo "===================="
    echo ""

    # Verification Point 1: Check if API responses were received
    echo "Verification Point 1: API Responses Received"
    local http_status=""
    local bytes_read=0
    local chunks_parsed=0

    if [ -f "$HOME/.niffler/logs/${log_file}.log" ]; then
        if grep -q "Received HTTP status:" "$HOME/.niffler/logs/${log_file}.log"; then
            http_status=$(grep "Received HTTP status:" "$HOME/.niffler/logs/${log_file}.log" | tail -1 | awk '{print $NF}')
            echo "  HTTP Status: $http_status"
        fi

        if grep -q "Stream ended normally" "$HOME/.niffler/logs/${log_file}.log"; then
            local stream_line=$(grep "Stream ended normally" "$HOME/.niffler/logs/${log_file}.log" | tail -1)
            bytes_read=$(echo "$stream_line" | grep -oP 'total bytes: \K[0-9]+' || echo "0")
            chunks_parsed=$(echo "$stream_line" | grep -oP 'chunks: \K[0-9]+' || echo "0")
            echo "  Bytes read: $bytes_read"
            echo "  Chunks parsed: $chunks_parsed"
        fi
    fi

    local v1_passed="false"
    if [ "$http_status" = "200" ] && [ "$bytes_read" -gt 0 ] && [ "$chunks_parsed" -gt 0 ]; then
        v1_passed="true"
    fi
    print_result "Point 1: API responses received (status=$http_status, bytes=$bytes_read, chunks=$chunks_parsed)" "$v1_passed"
    echo ""

    # Verification Point 2: Check parsing and accumulation
    echo "Verification Point 2: Response Parsing & Accumulation"
    local response_in_output=$(grep -c "Task Completed Successfully" "/tmp/agent_output_${model}.txt" || echo "0")
    local v2_passed="false"
    if [ "$response_in_output" -gt 0 ] && [ "$chunks_parsed" -gt 0 ]; then
        v2_passed="true"
    fi
    print_result "Point 2: Response parsed and displayed (success_msg=$response_in_output, chunks=$chunks_parsed)" "$v2_passed"
    echo ""

    # Verification Point 3: Check database persistence
    echo "Verification Point 3: Database Persistence"
    local conv_count_after=$(query_db "SELECT COUNT(*) as count FROM conversation" | tail -1)
    local latest_conv_id=$(query_db "SELECT id FROM conversation ORDER BY created_at DESC LIMIT 1" | tail -1)
    local msg_count=$(query_db "SELECT COUNT(*) as count FROM conversation_message WHERE conversation_id=$latest_conv_id" | tail -1)
    local assistant_msg_length=$(query_db "SELECT LENGTH(content) as len FROM conversation_message WHERE conversation_id=$latest_conv_id AND role='assistant' ORDER BY created_at DESC LIMIT 1" | tail -1 || echo "0")

    echo "  New conversations: $((conv_count_after - conv_count_before))"
    echo "  Messages in conversation: $msg_count"
    echo "  Assistant response length: $assistant_msg_length chars"

    local v3_passed="false"
    if [ "$assistant_msg_length" -gt 0 ] && [ "$msg_count" -ge 2 ]; then
        v3_passed="true"
    fi
    print_result "Point 3: Messages persisted to database (msg_count=$msg_count, assistant_len=$assistant_msg_length)" "$v3_passed"
    echo ""

    # Verification Point 4: Check conversation data consistency
    echo "Verification Point 4: Data Consistency"
    local user_msg=$(query_db "SELECT content FROM conversation_message WHERE conversation_id=$latest_conv_id AND role='user' LIMIT 1" | tail -1)
    local contains_task="false"
    if echo "$user_msg" | grep -q "7+8"; then
        contains_task="true"
    fi

    local v4_passed="false"
    if [ "$contains_task" = "true" ]; then
        v4_passed="true"
    fi
    print_result "Point 4: Conversation data is consistent (contains_task=$contains_task)" "$v4_passed"
    echo ""

    # Overall result
    echo "=== Summary for $model ==="
    if [ "$v1_passed" = "true" ] && [ "$v2_passed" = "true" ] && [ "$v3_passed" = "true" ] && [ "$v4_passed" = "true" ]; then
        echo -e "${GREEN}All verification points passed!${NC}"
        return 0
    else
        echo -e "${RED}Some verification points failed.${NC}"
        echo "Debug log: $HOME/.niffler/logs/${log_file}.log"
        return 1
    fi
}

# Main execution
echo "========================================="
echo "Automated Agent Task Testing"
echo "========================================="
echo "Task: $TASK"
echo ""

# Test both models
test_model "kimi"
kimi_result=$?

echo ""
echo "---"
echo ""

test_model "qwen3-coder"
qwen_result=$?

# Final summary
echo ""
echo "========================================="
echo "Final Results"
echo "========================================="
echo ""

if [ $kimi_result -eq 0 ]; then
    echo -e "${GREEN}✓${NC} kimi: PASSED"
else
    echo -e "${RED}✗${NC} kimi: FAILED"
fi

if [ $qwen_result -eq 0 ]; then
    echo -e "${GREEN}✓${NC} qwen3-coder: PASSED"
else
    echo -e "${RED}✗${NC} qwen3-coder: FAILED"
fi

echo ""

if [ $kimi_result -eq 0 ] && [ $qwen_result -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${YELLOW}Some tests failed. Check the output above for details.${NC}"
    exit 1
fi
