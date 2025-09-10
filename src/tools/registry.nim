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
import bash, create, edit, fetch, list, read, todolist

type
  ToolKind* = enum
    tkBash, tkRead, tkList, tkEdit, tkCreate, tkFetch, tkTodolist

  Tool* = object
    name*: string
    description*: string
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
    name: "bash",
    description: "Execute shell commands",
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
    name: "read",
    description: "Read file contents",
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
    name: "list",
    description: "List directory contents",
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
    name: "edit",
    description: "Edit files with diff-based changes",
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
    name: "create",
    description: "Create new files",
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
    name: "fetch",
    description: "Fetch web content",
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
    name: "todolist",
    description: "Manage todo lists and task tracking",
    requiresConfirmation: false,
    schema: schema,
    todolistExecute: executeTodolist
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
    createTodolistTool()
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

proc getAllToolSchemas*(): seq[ToolDefinition] =
  ## Get JSON schemas for all registered tools (for LLM function calling)
  initializeRegistry()
  return toolSeq.mapIt(it.schema)

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