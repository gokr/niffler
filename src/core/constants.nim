## Centralized Constants for Niffler
##
## This module defines all shared constants used throughout the application:
## - Timeout and duration settings
## - File size limits and buffer sizes
## - Token and context limits
## - UI display limits and thresholds
## - Default values for various operations
##
## Benefits:
## - Single source of truth for all constants
## - Easy to modify behavior globally
## - Better maintainability and consistency
## - Clear documentation of all limits and defaults

# === TIMEOUT CONSTANTS ===
const
  DEFAULT_TIMEOUT* = 30000           # 30 seconds default timeout
  MAX_TIMEOUT* = 300000              # 5 minutes maximum timeout
  COMMAND_TIMEOUT* = 30000           # Default command execution timeout

# === FILE SIZE LIMITS ===
const
  MAX_FILE_SIZE* = 10 * 1024 * 1024       # 10MB default max file size
  MAX_FETCH_SIZE* = 10 * 1024 * 1024      # 10MB default max fetch size  
  MAX_FETCH_SIZE_LIMIT* = 100 * 1024 * 1024  # 100MB absolute limit for fetching
  BUFFER_SIZE* = 4096                      # Default buffer size for operations

# === TOKEN AND CONTEXT LIMITS ===
const
  DEFAULT_CONTEXT_SIZE* = 128000     # Default context window size
  MAX_TOKENS_LIMIT* = 128000         # Maximum tokens limit for validation
  MIN_TOKENS_LIMIT* = 1              # Minimum tokens limit
  
# === THINKING TOKEN CONSTANTS ===
const  
  THINKING_TOKEN_LOW_BUDGET* = 2048      # Low reasoning level budget
  THINKING_TOKEN_MEDIUM_BUDGET* = 4096   # Medium reasoning level budget  
  THINKING_TOKEN_HIGH_BUDGET* = 8192     # High reasoning level budget
  THINKING_TOKEN_DEFAULT_BUDGET* = 4096  # Default thinking token budget

# === UI DISPLAY LIMITS ===
const
  TOOL_RESULT_MAX_LENGTH_SHORT* = 2000   # Short tool result display limit
  TOOL_RESULT_MAX_LENGTH_LONG* = 5000    # Long tool result display limit
  TOOL_ARGS_COMPACT_LENGTH* = 60         # Length limit for compact tool args display
  
# === ERROR MESSAGES ===
const
  USER_ABORTED_ERROR_MESSAGE* = "Aborted by user"