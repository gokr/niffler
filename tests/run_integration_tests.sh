#!/bin/bash

## Integration Test Runner for Niffler
##
## This script sets up the environment and runs all integration tests
## with real LLMs, NATS, and database connections.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧪 Niffler Integration Test Runner${NC}"
echo "=================================="
echo

# Default configuration
export NIFflER_TEST_MODEL="${NIFflER_TEST_MODEL:-gpt-4o-mini}"
export NIFflER_TEST_BASE_URL="${NIFflER_TEST_BASE_URL:-https://api.openai.com/v1}"
export NIFflER_TEST_NATS_URL="${NIFflER_TEST_NATS_URL:-nats://localhost:4222}"
export NIFflER_LOG_LEVEL="${NIFflER_LOG_LEVEL:-WARN}"  # Reduce log noise

# Check prerequisites
echo -e "${YELLOW}📋 Checking prerequisites...${NC}"
echo

# Check for API key
if [ -z "$NIFflER_TEST_API_KEY" ]; then
    echo -e "${YELLOW}⚠️  NIFflER_TEST_API_KEY not set${NC}"
    echo "   Set it to enable real LLM tests:"
    echo "   export NIFflER_TEST_API_KEY='your-api-key'"
    echo
    read -p "Continue without API key? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Exiting..."
        exit 1
    fi
else
    echo -e "${GREEN}✅ API key configured${NC}"
    echo "   Model: $NIFflER_TEST_MODEL"
    echo "   Base URL: $NIFflER_TEST_BASE_URL"
fi
echo

# Check for NATS
if pgrep -f "nats-server" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ NATS server is running${NC}"
    NATS_AVAILABLE=true
else
    echo -e "${YELLOW}⚠️  NATS server not found${NC}"
    echo "   Start with: nats-server -js"
    echo "   Master-agent tests will be skipped"
    NATS_AVAILABLE=false
fi
echo

# Check for database
if mysql -h 127.0.0.1 -P 4000 -u root -e "SELECT 1" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Database (TiDB/MySQL) is running${NC}"
    DB_AVAILABLE=true
else
    echo -e "${YELLOW}⚠️  Database not accessible${NC}"
    echo "   Ensure TiDB or MySQL is running on localhost:4000"
    echo "   Persistence tests may fail"
    DB_AVAILABLE=false
fi
echo

# Build test binaries
echo -e "${YELLOW}🔨 Building test binaries...${NC}"
echo

# Compile tests with proper flags
nim c -r --threads:on -d:ssl --warning:UnusedImport:off tests/test_integration_framework.nim --run --testutils
echo

nim c -r --threads:on -d:ssl --warning:UnusedImport:off tests/test_master_agent_scenario.nim --run --testutils
echo

nim c -r --threads:on -d:ssl --warning:UnusedImport:off tests/test_real_llm_workflows.nim --run --testutils
echo

# Run tests
echo -e "${YELLOW}🚀 Running integration tests...${NC}"
echo "============================="
echo

# Track test results
PASSED=0
FAILED=0

# Function to run a test suite
run_test_suite() {
    local test_file=$1
    local test_name=$2

    echo -e "${BLUE}Running: $test_name${NC}"
    echo "---------------------------"

    if nim c -r --threads:on -d:ssl "$test_file" 2>&1; then
        echo -e "${GREEN}✅ $test_name: PASSED${NC}"
        ((PASSED++))
    else
        echo -e "${RED}❌ $test_name: FAILED${NC}"
        ((FAILED++))
    fi
    echo
}

# Run test suites
run_test_suite "tests/test_integration_framework.nim" "Integration Framework"
run_test_suite "tests/test_master_agent_scenario.nim" "Master-Agent Scenario"

# Only run LLM workflows if API key is available
if [ -n "$NIFflER_TEST_API_KEY" ]; then
    run_test_suite "tests/test_real_llm_workflows.nim" "Real LLM Workflows"
else
    echo -e "${YELLOW}⏭️  Skipping Real LLM Workflows (no API key)${NC}"
    echo
fi

# Summary
echo "=================================="
echo -e "${BLUE}📊 Test Summary${NC}"
echo "=================================="
echo -e "Total: $((PASSED + FAILED)) tests"
if [ $PASSED -gt 0 ]; then
    echo -e "${GREEN}Passed: $PASSED${NC}"
fi
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Failed: $FAILED${NC}"
fi
echo

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}💥 Some tests failed${NC}"
    echo
    echo "Tips for debugging:"
    echo "  1. Set NIFflER_LOG_LEVEL=DEBUG for verbose output"
    echo "  2. Ensure all required services are running"
    echo "  3. Check API key and internet connection"
    echo "  4. Verify database permissions"
    exit 1
fi