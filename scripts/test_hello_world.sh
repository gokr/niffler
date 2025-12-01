#!/bin/bash
# Test script to verify clean hello world task execution
# Validates: clean conversation, correct number of tool calls, no duplicates

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
MODEL="synthetic-glm46"
TASK="Create a file hello.nim with echo \"Hello, World!\", compile it with nim c, and run the executable"
LOG_FILE="test-hello-$(date +%s)"

# Expected values
EXPECTED_TOOL_CALLS=3  # create, nim c, run
MAX_MESSAGES=10        # Should be user + assistant + 3 tools + final assistant = ~6 messages
MAX_ASSISTANT_MSGS=3   # Initial response + final summary (maybe intermediate)

echo -e "${BLUE}=== Hello World Task Test ===${NC}"
echo "Model: $MODEL"
echo "Task: $TASK"
echo ""

# Step 1: Clean up any existing files
echo -e "${YELLOW}Step 1: Cleaning up existing files...${NC}"
rm -f hello.nim hello
if [ -f hello.nim ] || [ -f hello ]; then
    echo -e "${RED}✗ Failed to clean up files${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Files cleaned${NC}"
echo ""

# Step 2: Get baseline conversation count
echo -e "${YELLOW}Step 2: Getting baseline conversation count...${NC}"
conv_count_before=$(mysql -h 127.0.0.1 -P 4000 -u root niffler -e "SELECT COUNT(*) as count FROM conversation" 2>/dev/null | tail -1)
echo "Conversations before: $conv_count_before"
echo ""

# Step 3: Run the task
echo -e "${YELLOW}Step 3: Executing hello world task...${NC}"
echo "(This will take 30-60 seconds)"
./src/niffler agent coder --task="$TASK" --model="$MODEL" --log="$LOG_FILE" > /tmp/hello_test_output.txt 2>&1

exit_code=$?
echo ""

# Step 4: Check exit code
echo -e "${YELLOW}Step 4: Checking task completion...${NC}"
if [ $exit_code -ne 0 ]; then
    echo -e "${RED}✗ Task failed with exit code $exit_code${NC}"
    echo "Output:"
    cat /tmp/hello_test_output.txt
    exit 1
fi

# Check if task succeeded
if grep -q "Task Completed Successfully" /tmp/hello_test_output.txt; then
    echo -e "${GREEN}✓ Task completed successfully${NC}"
else
    echo -e "${RED}✗ Task did not complete successfully${NC}"
    echo "Output:"
    tail -20 /tmp/hello_test_output.txt
    exit 1
fi
echo ""

# Step 5: Get the latest conversation
echo -e "${YELLOW}Step 5: Analyzing conversation in database...${NC}"
latest_conv_id=$(mysql -h 127.0.0.1 -P 4000 -u root niffler -e "SELECT id FROM conversation ORDER BY created_at DESC LIMIT 1" 2>/dev/null | tail -1)
echo "Latest conversation ID: $latest_conv_id"
echo ""

# Step 6: Count messages
echo -e "${YELLOW}Step 6: Validating message counts...${NC}"
msg_count=$(mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
    SELECT COUNT(*) as count
    FROM conversation_message
    WHERE conversation_id = $latest_conv_id" 2>/dev/null | tail -1)

user_msg_count=$(mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
    SELECT COUNT(*) as count
    FROM conversation_message
    WHERE conversation_id = $latest_conv_id AND role = 'user'" 2>/dev/null | tail -1)

assistant_msg_count=$(mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
    SELECT COUNT(*) as count
    FROM conversation_message
    WHERE conversation_id = $latest_conv_id AND role = 'assistant'" 2>/dev/null | tail -1)

tool_msg_count=$(mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
    SELECT COUNT(*) as count
    FROM conversation_message
    WHERE conversation_id = $latest_conv_id AND role = 'tool'" 2>/dev/null | tail -1)

echo "Total messages: $msg_count"
echo "  User messages: $user_msg_count"
echo "  Assistant messages: $assistant_msg_count"
echo "  Tool messages: $tool_msg_count"
echo ""

# Validate message counts
PASS=true

if [ "$user_msg_count" -ne 1 ]; then
    echo -e "${RED}✗ Expected 1 user message, got $user_msg_count${NC}"
    PASS=false
else
    echo -e "${GREEN}✓ User message count correct (1)${NC}"
fi

if [ "$tool_msg_count" -ne "$EXPECTED_TOOL_CALLS" ]; then
    echo -e "${RED}✗ Expected $EXPECTED_TOOL_CALLS tool messages, got $tool_msg_count${NC}"
    PASS=false
else
    echo -e "${GREEN}✓ Tool message count correct ($EXPECTED_TOOL_CALLS)${NC}"
fi

if [ "$assistant_msg_count" -gt "$MAX_ASSISTANT_MSGS" ]; then
    echo -e "${RED}✗ Too many assistant messages: $assistant_msg_count (max: $MAX_ASSISTANT_MSGS)${NC}"
    PASS=false
else
    echo -e "${GREEN}✓ Assistant message count acceptable ($assistant_msg_count <= $MAX_ASSISTANT_MSGS)${NC}"
fi

if [ "$msg_count" -gt "$MAX_MESSAGES" ]; then
    echo -e "${RED}✗ Too many total messages: $msg_count (max: $MAX_MESSAGES)${NC}"
    PASS=false
else
    echo -e "${GREEN}✓ Total message count acceptable ($msg_count <= $MAX_MESSAGES)${NC}"
fi
echo ""

# Step 7: Check for duplicates
echo -e "${YELLOW}Step 7: Checking for duplicate messages...${NC}"
duplicate_count=$(mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
    SELECT content, COUNT(*) as cnt
    FROM conversation_message
    WHERE conversation_id = $latest_conv_id AND role = 'assistant'
    GROUP BY content
    HAVING cnt > 1" 2>/dev/null | wc -l)

if [ "$duplicate_count" -gt 1 ]; then  # Header line counts as 1
    echo -e "${RED}✗ Found duplicate assistant messages${NC}"
    mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
        SELECT content, COUNT(*) as cnt
        FROM conversation_message
        WHERE conversation_id = $latest_conv_id AND role = 'assistant'
        GROUP BY content
        HAVING cnt > 1" 2>/dev/null
    PASS=false
else
    echo -e "${GREEN}✓ No duplicate assistant messages${NC}"
fi
echo ""

# Step 8: Show conversation flow
echo -e "${YELLOW}Step 8: Conversation flow:${NC}"
mysql -h 127.0.0.1 -P 4000 -u root niffler -e "
    SELECT
        id,
        role,
        LEFT(content, 60) as preview
    FROM conversation_message
    WHERE conversation_id = $latest_conv_id
    ORDER BY id" 2>/dev/null
echo ""

# Step 9: Verify files were created
echo -e "${YELLOW}Step 9: Verifying files were created...${NC}"
if [ ! -f hello.nim ]; then
    echo -e "${RED}✗ hello.nim was not created${NC}"
    PASS=false
else
    echo -e "${GREEN}✓ hello.nim exists${NC}"
    echo "Content:"
    cat hello.nim
fi

if [ ! -f hello ]; then
    echo -e "${RED}✗ hello executable was not created${NC}"
    PASS=false
else
    echo -e "${GREEN}✓ hello executable exists${NC}"
fi
echo ""

# Step 10: Run the executable and verify output
echo -e "${YELLOW}Step 10: Testing executable...${NC}"
if [ -f hello ]; then
    output=$(./hello)
    if echo "$output" | grep -q "Hello, World!"; then
        echo -e "${GREEN}✓ Executable produces correct output: $output${NC}"
    else
        echo -e "${RED}✗ Unexpected output: $output${NC}"
        PASS=false
    fi
fi
echo ""

# Final summary
echo -e "${BLUE}=== Test Summary ===${NC}"
if [ "$PASS" = true ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
    echo ""
    echo "Conversation quality metrics:"
    echo "  Messages: $msg_count (limit: $MAX_MESSAGES)"
    echo "  Tool calls: $tool_msg_count (expected: $EXPECTED_TOOL_CALLS)"
    echo "  No duplicates: Yes"
    echo "  Files created: Yes"
    echo "  Executable works: Yes"
    exit 0
else
    echo -e "${RED}❌ SOME TESTS FAILED${NC}"
    echo ""
    echo "Review the output above for details."
    echo "Debug log: ${LOG_FILE}.log"
    exit 1
fi
