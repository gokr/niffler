#!/bin/bash

# Niffler Database Inspector
# This script connects to the niffler.db SQLite database and displays its contents

DB_PATH="$HOME/.niffler/niffler.db"

# Colors for output formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}=== Niffler Database Inspector ===${NC}"
echo -e "Database location: ${YELLOW}$DB_PATH${NC}"

# Check if database file exists
if [ ! -f "$DB_PATH" ]; then
    echo -e "${RED}Error: Database file not found at $DB_PATH${NC}"
    exit 1
fi

# Check if database file is readable
if [ ! -r "$DB_PATH" ]; then
    echo -e "${RED}Error: Database file is not readable${NC}"
    exit 1
fi

# Get database file info
echo -e "\n${BLUE}=== Database File Info ===${NC}"
echo -e "File size: $(du -h "$DB_PATH" | cut -f1)"
echo -e "Last modified: $(stat -c %y "$DB_PATH")"

# Function to execute SQL and format output
execute_sql() {
    local query="$1"
    local title="$2"
    
    echo -e "\n${GREEN}=== $title ===${NC}"
    
    # Check if database has any tables first
    local table_count=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table';")
    
    if [ "$table_count" -eq 0 ]; then
        echo -e "${YELLOW}No tables found in database (database may be empty or uninitialized)${NC}"
        return
    fi
    
    # Execute the query
    local result=$(sqlite3 "$DB_PATH" -header -column "$query" 2>&1)
    
    if [ $? -eq 0 ]; then
        if [ -z "$result" ]; then
            echo -e "${YELLOW}No data found${NC}"
        else
            echo "$result"
        fi
    else
        echo -e "${RED}Error executing query: $result${NC}"
    fi
}

# Show database schema
echo -e "\n${BLUE}=== Database Schema ===${NC}"
schema_output=$(sqlite3 "$DB_PATH" ".schema" 2>&1)
if [ $? -eq 0 ]; then
    if [ -z "$schema_output" ]; then
        echo -e "${YELLOW}No schema found (database is empty)${NC}"
    else
        echo "$schema_output"
    fi
else
    echo -e "${RED}Error reading schema: $schema_output${NC}"
fi

# List all tables
execute_sql "SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') ORDER BY name;" "Tables and Views"

# Show table counts and structure
tables=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null)

if [ -n "$tables" ]; then
    echo -e "\n${BLUE}=== Table Information ===${NC}"
    
    for table in $tables; do
        echo -e "\n${MAGENTA}Table: $table${NC}"
        
        # Get table info
        table_info=$(sqlite3 "$DB_PATH" "PRAGMA table_info($table);" 2>&1)
        if [ $? -eq 0 ]; then
            echo -e "${YELLOW}Columns:${NC}"
            echo "$table_info" | while IFS='|' read -r cid name type notnull dflt_value pk; do
                echo "  - $name ($type)"
            done
        fi
        
        # Get row count
        row_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM $table;" 2>/dev/null)
        echo -e "${YELLOW}Row count:${NC} $row_count"
        
        # Show sample data if table has rows
        if [ "$row_count" -gt 0 ]; then
            echo -e "${YELLOW}Sample data (first 5 rows):${NC}"
            sqlite3 "$DB_PATH" -header -column "SELECT * FROM $table LIMIT 5;" 2>/dev/null
        fi
    done
fi

# Show recent data from specific tables if they exist
if sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='TokenLogEntry';" | grep -q TokenLogEntry; then
    execute_sql "SELECT created_at, model, inputTokens, outputTokens, totalCost FROM TokenLogEntry ORDER BY created_at DESC LIMIT 10;" "Recent Token Usage (Last 10 entries)"
fi

if sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='PromptHistoryEntry';" | grep -q PromptHistoryEntry; then
    execute_sql "SELECT created_at, model, substr(userPrompt, 1, 50) || '...' as prompt_preview FROM PromptHistoryEntry ORDER BY created_at DESC LIMIT 10;" "Recent Prompts (Last 10 entries)"
fi

# Show recent data from new conversation tracking tables if they exist
if sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='Conversation';" | grep -q Conversation; then
    execute_sql "SELECT id, started_at, title FROM Conversation ORDER BY started_at DESC LIMIT 10;" "Recent Conversations (Last 10 entries)"
fi

if sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='ConversationMessage';" | grep -q ConversationMessage; then
    execute_sql "SELECT conversation_id, message_id, role, substr(content, 1, 50) || '...' as content_preview FROM ConversationMessage ORDER BY created_at DESC LIMIT 10;" "Recent Conversation Messages (Last 10 entries)"
fi

if sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='ModelTokenUsage';" | grep -q ModelTokenUsage; then
    execute_sql "SELECT created_at, model, input_tokens, output_tokens, total_cost FROM ModelTokenUsage ORDER BY created_at DESC LIMIT 10;" "Recent Model Token Usage (Last 10 entries)"
fi

# Show cost breakdown by model if ModelTokenUsage table exists
if sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='table' AND name='ModelTokenUsage';" | grep -q ModelTokenUsage; then
    execute_sql "SELECT model, SUM(input_tokens) as total_input_tokens, SUM(output_tokens) as total_output_tokens, SUM(total_cost) as total_cost FROM ModelTokenUsage GROUP BY model ORDER BY total_cost DESC;" "Cost Breakdown by Model"
fi

# Show database statistics
echo -e "\n${BLUE}=== Database Statistics ===${NC}"
db_size=$(sqlite3 "$DB_PATH" "PRAGMA page_size; PRAGMA page_count;" 2>/dev/null | paste -sd'*' | bc 2>/dev/null)
if [ -n "$db_size" ]; then
    echo -e "Database size: $(echo "scale=2; $db_size / 1024" | bc) KB"
fi

# Show indexes
indexes=$(sqlite3 "$DB_PATH" "SELECT name FROM sqlite_master WHERE type='index' AND name NOT LIKE 'sqlite_%';" 2>/dev/null)
if [ -n "$indexes" ]; then
    echo -e "\n${BLUE}=== Indexes ===${NC}"
    for index in $indexes; do
        echo "- $index"
    done
fi

echo -e "\n${CYAN}=== End of Database Inspection ===${NC}"