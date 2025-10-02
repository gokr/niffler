## Tool Registry System
##
## This module implements a centralized tool registry using object variants
## to eliminate code duplication and provide a clean, extensible tool system.
##
## Key Features:
## - Object variant-based tool definitions with embedded execution functions
## - Centralized registry that creates and manages all tools
## - Schema and metadata co-located with execution logic
## - Type-safe tool dispatch without case statements
## - Easy extensibility for new tools
##
## Design:
## - ToolKind enum defines all available tool types
## - Tool object variant contains execution function and metadata per tool
## - Registry creates and populates itself during module initialization
## - Lookup functions replace all case-of statements throughout codebase

import std/[options, json, tables, sequtils, strutils]
import ../types/messages
import ../tokenization/tokenizer
import bash, create, edit, fetch, list, read, todolist, task
import ../mcp/tools as mcpTools

type
  ToolKind* = enum
    tkBash, tkRead, tkList, tkEdit, tkCreate, tkFetch, tkTodolist, tkTask

  Tool* = object
    requiresConfirmation*: bool
    schema*: ToolDefinition
    case kind*: ToolKind
    of tkBash:
      bashExecute*: proc(args: JsonNode): string {.gcsafe.}
    of tkRead:
      readExecute*: proc(args: JsonNode): string {.gcsafe.}
    of tkList:
      listExecute*: proc(args: JsonNode): string {.gcsafe.}
    of tkEdit:
      editExecute*: proc(args: JsonNode): string {.gcsafe.}
    of tkCreate:
      createExecute*: proc(args: JsonNode): string {.gcsafe.}
    of tkFetch:
      fetchExecute*: proc(args: JsonNode): string {.gcsafe.}
    of tkTodolist:
      todolistExecute*: proc(args: JsonNode): string {.gcsafe.}
    of tkTask:
      taskExecute*: proc(args: JsonNode): string {.gcsafe.}

# Accessor methods for Tool fields
proc name*(tool: Tool): string = tool.schema.function.name
proc description*(tool: Tool): string = tool.schema.function.description

# Global tool registry
var toolRegistry {.threadvar.}: Table[string, Tool]
var toolSeq {.threadvar.}: seq[Tool]
var registryInitialized {.threadvar.}: bool

proc createBashTool(): Tool =
  ## Create the bash command execution tool with schema and execution function
  let parameters = %*{
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "description": "The shell command to execute"
      }
    },
    "required": ["command"]
  }
  let schema = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "bash",
      description: "Execute shell commands",
      parameters: parameters
    )
  )
  
  Tool(
    kind: tkBash,
    requiresConfirmation: true,
    schema: schema,
    bashExecute: executeBash
  )

proc createReadTool(): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The file path to read"
      }
    },
    "required": ["path"]
  }
  let schema = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "read",
      description: "Read file contents",
      parameters: parameters
    )
  )
  
  Tool(
    kind: tkRead,
    requiresConfirmation: false,
    schema: schema,
    readExecute: executeRead
  )

proc createListTool(): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The directory path to list"
      }
    },
    "required": ["path"]
  }
  let schema = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "list",
      description: "List directory contents",
      parameters: parameters
    )
  )
  
  Tool(
    kind: tkList,
    requiresConfirmation: false,
    schema: schema,
    listExecute: executeList
  )

proc createEditTool(): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The file path to edit"
      },
      "operation": {
        "type": "string",
        "description": "The edit operation to perform",
        "enum": ["replace", "insert", "delete", "append", "prepend", "rewrite"]
      },
      "old_text": {
        "type": "string", 
        "description": "Text to find and replace/delete (required for replace/delete operations)"
      },
      "new_text": {
        "type": "string",
        "description": "New text to insert/append/prepend/rewrite (required for most operations)"
      },
      "line_range": {
        "type": "array",
        "description": "Line range for insert operation [start_line, end_line]",
        "items": {"type": "integer"},
        "minItems": 2,
        "maxItems": 2
      },
      "create_backup": {
        "type": "boolean",
        "description": "Whether to create a backup before editing (default: false)",
        "default": false
      }
    },
    "required": ["path", "operation"]
  }
  let schema = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "edit",
      description: "Edit files with diff-based changes",
      parameters: parameters
    )
  )
  
  Tool(
    kind: tkEdit,
    requiresConfirmation: true,
    schema: schema,
    editExecute: executeEdit
  )

proc createCreateTool(): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The file path to create"
      },
      "content": {
        "type": "string",
        "description": "The content for the new file"
      }
    },
    "required": ["path", "content"]
  }
  let schema = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "create",
      description: "Create new files",
      parameters: parameters
    )
  )
  
  Tool(
    kind: tkCreate,
    requiresConfirmation: true,
    schema: schema,
    createExecute: executeCreate
  )

proc createFetchTool(): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "url": {
        "type": "string",
        "description": "The URL to fetch content from"
      }
    },
    "required": ["url"]
  }
  let schema = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "fetch",
      description: "Fetch web content",
      parameters: parameters
    )
  )
  
  Tool(
    kind: tkFetch,
    requiresConfirmation: false,
    schema: schema,
    fetchExecute: executeFetch
  )

proc createTodolistTool(): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "operation": {
        "type": "string",
        "description": "The todo operation to perform",
        "enum": ["add", "update", "delete", "list", "show", "bulk_update"]
      },
      "content": {
        "type": "string",
        "description": "Todo item content (for add operation)"
      },
      "itemId": {
        "type": "integer",
        "description": "Todo item ID (for update/delete operations)"
      },
      "state": {
        "type": "string",
        "description": "New state for todo item",
        "enum": ["pending", "in_progress", "completed", "cancelled"]
      },
      "priority": {
        "type": "string",
        "description": "Priority level for todo item",
        "enum": ["low", "medium", "high"]
      },
      "todos": {
        "type": "string",
        "description": "Markdown checklist content (for bulk_update operation)"
      }
    },
    "required": ["operation"]
  }
  let schema = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "todolist",
      description: "Manage todo lists and task tracking",
      parameters: parameters
    )
  )
  
  Tool(
    kind: tkTodolist,
    requiresConfirmation: false,
    schema: schema,
    todolistExecute: executeTodolist
  )

proc createTaskTool(): Tool =
  let parameters = %*{
    "type": "object",
    "properties": {
      "agent_type": {
        "type": "string",
        "description": "Name of agent to execute the task (e.g., 'general-purpose', 'code-focused'). Use 'list' to see available agents."
      },
      "description": {
        "type": "string",
        "description": "Detailed task description including context and expected outcome"
      },
      "model_nickname": {
        "type": "string",
        "description": "Model to use for task execution (optional, defaults to current model)"
      },
      "estimated_complexity": {
        "type": "string",
        "description": "Complexity estimate for token budget planning",
        "enum": ["simple", "moderate", "complex"]
      }
    },
    "required": ["agent_type", "description"]
  }
  let schema = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "task",
      description: "Create an autonomous task for a specialized agent to execute. Agents have restricted tool access based on their type.",
      parameters: parameters
    )
  )

  Tool(
    kind: tkTask,
    requiresConfirmation: false,
    schema: schema,
    taskExecute: executeTask
  )

proc initializeRegistry() =
  ## Initialize the tool registry with all available tools (thread-safe, idempotent)
  if registryInitialized:
    return

  toolRegistry = initTable[string, Tool]()
  toolSeq = @[]

  # Create and register all tools
  let tools = @[
    createBashTool(),
    createReadTool(),
    createListTool(),
    createEditTool(),
    createCreateTool(),
    createFetchTool(),
    createTodolistTool(),
    createTaskTool()
  ]
  
  for tool in tools:
    toolRegistry[tool.name] = tool
    toolSeq.add(tool)
  
  registryInitialized = true

# Public API functions

proc getAllTools*(): seq[Tool] =
  ## Get all registered tools
  initializeRegistry()
  return toolSeq

proc getTool*(name: string): Option[Tool] =
  ## Get a specific tool by name
  initializeRegistry()
  if name in toolRegistry:
    some(toolRegistry[name])
  else:
    none(Tool)

proc executeTool*(tool: Tool, args: JsonNode): string =
  ## Execute a tool with the given arguments using object variant dispatch
  case tool.kind:
  of tkBash: tool.bashExecute(args)
  of tkRead: tool.readExecute(args)
  of tkList: tool.listExecute(args)
  of tkEdit: tool.editExecute(args)
  of tkCreate: tool.createExecute(args)
  of tkFetch: tool.fetchExecute(args)
  of tkTodolist: tool.todolistExecute(args)
  of tkTask: tool.taskExecute(args)

proc getAllToolSchemas*(): seq[ToolDefinition] =
  ## Get JSON schemas for all registered tools (for LLM function calling)
  ## Includes both built-in tools and MCP tools
  initializeRegistry()
  var schemas = toolSeq.mapIt(it.schema)

  # Add MCP tool schemas
  {.gcsafe.}:
    schemas.add(mcpTools.getMcpToolSchemas())

  return schemas

proc getAllToolNames*(): seq[string] =
  ## Get names of all registered tools (built-in and MCP)
  initializeRegistry()
  result = toolSeq.mapIt(it.name)

  # Add MCP tool names
  {.gcsafe.}:
    result.add(mcpTools.getMcpToolNames())

proc countToolSchemaTokens*(modelName: string = "default"): int =
  ## Count tokens used by all tool schemas when sent to LLM
  ## This estimates the overhead of including tool definitions in API requests
  let schemas = getAllToolSchemas()
  if schemas.len == 0:
    return 0
  
  try:
    # Convert tool schemas to JSON format as they would be sent to API
    let toolsJson = $(%schemas)
    return countTokensForModel(toolsJson, modelName)
  except Exception:
    # Fallback estimation if tokenization fails
    return schemas.len * 200  # Rough estimate: 200 tokens per tool schema

proc getToolSchema*(name: string): Option[ToolDefinition] =
  ## Get JSON schema for a specific tool by name
  let maybeTool = getTool(name)
  if maybeTool.isSome():
    some(maybeTool.get().schema)
  else:
    none(ToolDefinition)

proc requiresConfirmation*(toolName: string): bool =
  ## Check if a tool requires user confirmation before execution (dangerous tools)
  let maybeTool = getTool(toolName)
  if maybeTool.isSome():
    maybeTool.get().requiresConfirmation
  else:
    false

proc getAvailableToolsList*(): string =
  ## Get comma-separated list of available tools with descriptions for system prompt
  initializeRegistry()
  let toolDescriptions = toolSeq.mapIt(it.name & " - " & it.description)
  return toolDescriptions.join(", ")