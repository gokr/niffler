import std/[unittest, json, options, strutils]
import ../src/actions/[registry, types]
import ../src/types/messages
import ../src/tools/registry as toolRegistry
import ../src/ui/commands

suite "Action capability filtering":
  setup:
    initializeCommands()

  test "agent manage schema is filtered for inspect-only agents":
    let schemaOpt = toolRegistry.getToolSchema("agent_manage")
    check schemaOpt.isSome()

    let filtered = filterToolSchemaForCapabilities(schemaOpt.get(), {acInspectAgents})
    check filtered.isSome()
    let operations = filtered.get().function.parameters["properties"]["operation"]["enum"]
    let operationNames = @[operations[0].getStr(), operations[1].getStr(), operations[2].getStr()]
    check operations.len == 3
    check "list_definitions" in operationNames
    check "show_definition" in operationNames
    check "list_running" in operationNames

  test "task dispatch schema is hidden without capability":
    let schemaOpt = toolRegistry.getToolSchema("task_dispatch")
    check schemaOpt.isSome()
    let filtered = filterToolSchemaForCapabilities(schemaOpt.get(), {})
    check filtered.isNone()

  test "effective capabilities preserve transitional tool defaults":
    let caps = getEffectiveActionCapabilities(@["agent_manage", "task_dispatch"], @[])
    check acInspectAgents in caps
    check acManageAgents in caps
    check acDispatchTasks in caps

  test "agent manage operation enforcement rejects missing capability":
    let args = %*{"operation": "start", "name": "coder"}
    let permission = isActionToolCallAllowed("agent_manage", args, {acInspectAgents})
    check not permission.allowed
    check permission.error.contains("manage_agents")

  test "task dispatch enforcement allows dispatch capability":
    let args = %*{"target": "coder", "description": "hello"}
    let permission = isActionToolCallAllowed("task_dispatch", args, {acDispatchTasks})
    check permission.allowed
