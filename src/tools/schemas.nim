import std/[options, json]
import ../types/messages

# Tool schemas using idiomatic %* JSON construction

proc bashToolSchema*(): ToolDefinition =
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
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "bash",
      description: "Execute shell commands",
      parameters: parameters
    )
  )

proc readToolSchema*(): ToolDefinition =
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
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "read",
      description: "Read file contents",
      parameters: parameters
    )
  )

proc listToolSchema*(): ToolDefinition =
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
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "list",
      description: "List directory contents",
      parameters: parameters
    )
  )

proc editToolSchema*(): ToolDefinition =
  let parameters = %*{
    "type": "object",
    "properties": {
      "path": {
        "type": "string",
        "description": "The file path to edit"
      },
      "content": {
        "type": "string",
        "description": "The new content for the file"
      }
    },
    "required": ["path", "content"]
  }
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "edit",
      description: "Edit files",
      parameters: parameters
    )
  )

proc createToolSchema*(): ToolDefinition =
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
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "create",
      description: "Create files",
      parameters: parameters
    )
  )

proc fetchToolSchema*(): ToolDefinition =
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
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "fetch",
      description: "Fetch web content",
      parameters: parameters
    )
  )

# Registry functions
proc getAllToolSchemas*(): seq[ToolDefinition] =
  @[
    bashToolSchema(),
    readToolSchema(),
    listToolSchema(),
    editToolSchema(),
    createToolSchema(),
    fetchToolSchema()
  ]

proc getToolSchema*(name: string): Option[ToolDefinition] =
  case name:
  of "bash": some(bashToolSchema())
  of "read": some(readToolSchema())
  of "list": some(listToolSchema())
  of "edit": some(editToolSchema())
  of "create": some(createToolSchema())
  of "fetch": some(fetchToolSchema())
  else: none(ToolDefinition)

const SKIP_CONFIRMATION_TOOLS* = ["read", "list", "fetch"]

proc requiresConfirmation*(toolName: string): bool =
  toolName notin SKIP_CONFIRMATION_TOOLS