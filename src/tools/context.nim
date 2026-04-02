## Tool Context
##
## Thread-local context for tool execution, providing conversation ID
## and other context needed by tools during execution.

# Thread-local storage for current conversation ID (used by todolist and similar tools)
var currentToolConversationId {.threadvar.}: int64

proc getCurrentToolConversationId*(): int64 =
  ## Get the current conversation ID for tool execution
  ## Returns 0 if not set (should not happen in normal operation)
  result = currentToolConversationId

proc setCurrentToolConversationId*(id: int64) =
  ## Set the current conversation ID for tool execution
  currentToolConversationId = id
