## Tool Argument Type Definitions
##
## This module provides type-safe argument structures for all tools using Sunny's
## JSON serialization capabilities. Each tool has a corresponding Args type that
## defines its parameters with appropriate JSON field mappings and default values.
##
## Features:
## - Type-safe argument parsing with compile-time field checking
## - Automatic JSON deserialization via Sunny's fromJson()
## - Support for required and optional fields with defaults
## - Custom JSON field name mapping via {.json.} pragmas
## - Integration with existing ToolValidationError system
##
## Usage:
## ```nim
## let args = BashArgs.parseArgs(argsJsonNode)
## # Now use args.command, args.timeout with full type safety
## ```

import std/json
import sunny
import tools
import ../core/constants

type
  BashArgs* = object
    command*: string
    timeout*: int

  ReadArgs* = object
    path*: string
    encoding*: string
    maxSize* {.json: "max_size".}: int
    linerange*: string

  ListArgs* = object
    path*: string
    recursive*: bool
    maxDepth* {.json: "max_depth".}: int
    includeHidden* {.json: "include_hidden".}: bool
    sortBy* {.json: "sort_by".}: string
    sortOrder* {.json: "sort_order".}: string
    filterType* {.json: "filter_type".}: string

  FetchArgs* = object
    url*: string
    timeout*: int
    maxSize* {.json: "max_size".}: int
    `method`*: string
    headers*: JsonNode
    body*: string
    convertToText* {.json: "convert_to_text".}: bool

  CreateArgs* = object
    path*: string
    content*: string
    overwrite*: bool
    createDirs* {.json: "create_dirs".}: bool
    permissions*: string

  EditArgs* = object
    path*: string
    operation*: string
    oldText* {.json: "old_text".}: string
    newText* {.json: "new_text".}: string
    createBackup* {.json: "create_backup".}: bool

  TaskArgs* = object
    agentType* {.json: "agent_type".}: string
    description*: string
    estimatedComplexity* {.json: "estimated_complexity".}: string

  TodolistArgs* = object
    operation*: string
    content*: string
    priority*: string
    itemNumber* {.json: "itemNumber".}: int
    state*: string
    todos*: string

proc jsonNodeToString*(node: JsonNode): string =
  ## Convert JsonNode to string for Sunny's fromJson()
  ## This allows us to parse JsonNode arguments that tools receive
  $node

proc parseArgs*[T](argsType: typedesc[T], args: JsonNode, toolName: string): T =
  ## Parse JSON arguments into typed Args structure with error handling
  ## Wraps Sunny parsing errors into ToolValidationError for consistency
  try:
    let jsonStr = jsonNodeToString(args)
    result = T.fromJson(jsonStr)
  except CatchableError as e:
    raise newToolValidationError(toolName, "arguments", "parseable arguments", e.msg)

proc applyDefaults*(args: var BashArgs) =
  ## Apply default values for optional BashArgs fields
  if args.timeout == 0:
    args.timeout = DEFAULT_TIMEOUT

proc applyDefaults*(args: var ReadArgs) =
  ## Apply default values for optional ReadArgs fields
  if args.encoding.len == 0:
    args.encoding = "auto"
  if args.maxSize == 0:
    args.maxSize = MAX_FILE_SIZE

proc applyDefaults*(args: var ListArgs) =
  ## Apply default values for optional ListArgs fields
  if args.maxDepth == 0:
    args.maxDepth = 10
  if args.sortBy.len == 0:
    args.sortBy = "name"
  if args.sortOrder.len == 0:
    args.sortOrder = "asc"

proc applyDefaults*(args: var FetchArgs) =
  ## Apply default values for optional FetchArgs fields
  if args.timeout == 0:
    args.timeout = DEFAULT_TIMEOUT
  if args.maxSize == 0:
    args.maxSize = MAX_FETCH_SIZE
  if args.`method`.len == 0:
    args.`method` = "GET"
  if args.headers == nil:
    args.headers = newJObject()

proc applyDefaults*(args: var CreateArgs) =
  ## Apply default values for optional CreateArgs fields
  if args.permissions.len == 0:
    args.permissions = "644"

proc applyDefaults*(args: var TaskArgs) =
  ## Apply default values for optional TaskArgs fields
  if args.estimatedComplexity.len == 0:
    args.estimatedComplexity = "moderate"

proc parseWithDefaults*[T](argsType: typedesc[T], args: JsonNode, toolName: string): T =
  ## Parse JSON arguments and apply default values
  ## This is the recommended way to parse tool arguments
  result = parseArgs(T, args, toolName)
  when compiles(applyDefaults(result)):
    applyDefaults(result)
