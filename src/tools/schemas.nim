import std/[options, json]
import ../types/messages

# Simplified tool schemas using JSON string parsing
# This avoids complex JsonValue construction issues

proc bashToolSchema*(): ToolDefinition =
  # Create a proper JSON schema for bash tool using JsonNode
  let paramsStr = """
    {
      "type": "object",
      "properties": {
        "command": {
          "type": "string",
          "description": "The shell command to execute"
        }
      },
      "required": ["command"]
    }
  """
  let jsonNode = parseJson(paramsStr)
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "bash",
      description: "Execute shell commands",
      parameters: jsonNode
    )
  )

proc readToolSchema*(): ToolDefinition =
  let paramsStr = """
    {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "The file path to read"
        }
      },
      "required": ["path"]
    }
  """
  let jsonNode = parseJson(paramsStr)
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "read",
      description: "Read file contents",
      parameters: jsonNode
    )
  )

proc listToolSchema*(): ToolDefinition =
  let paramsStr = """
    {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "The directory path to list"
        }
      },
      "required": ["path"]
    }
  """
  let jsonNode = parseJson(paramsStr)
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "list",
      description: "List directory contents",
      parameters: jsonNode
    )
  )

proc editToolSchema*(): ToolDefinition =
  let paramsStr = """
    {
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
  """
  let jsonNode = parseJson(paramsStr)
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "edit",
      description: "Edit files",
      parameters: jsonNode
    )
  )

proc createToolSchema*(): ToolDefinition =
  let paramsStr = """
    {
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
  """
  let jsonNode = parseJson(paramsStr)
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "create",
      description: "Create files",
      parameters: jsonNode
    )
  )

proc fetchToolSchema*(): ToolDefinition =
  let paramsStr = """
    {
      "type": "object",
      "properties": {
        "url": {
          "type": "string",
          "description": "The URL to fetch content from"
        }
      },
      "required": ["url"]
    }
  """
  let jsonNode = parseJson(paramsStr)
  result = ToolDefinition(
    `type`: "function",
    function: ToolFunction(
      name: "fetch",
      description: "Fetch web content",
      parameters: jsonNode
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