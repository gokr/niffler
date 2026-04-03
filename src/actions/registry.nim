## Action registry for metadata and execution

import std/[tables, options, algorithm, sequtils, strutils]
import types
import ../core/session
import ../types/config as configTypes

type
  RegisteredAction = object
    definition: ActionDefinition
    handler: ActionHandler

var actionRegistry = initTable[string, RegisteredAction]()

proc registerAction*(definition: ActionDefinition, handler: ActionHandler = nil) =
  ## Register action metadata and optional executor
  actionRegistry[definition.id] = RegisteredAction(definition: definition, handler: handler)

proc executeAction*(actionId: string, args: seq[string], session: var Session,
                   currentModel: var configTypes.ModelConfig): ActionResult =
  ## Execute a registered action by ID
  if not actionRegistry.hasKey(actionId):
    return ActionResult(
      success: false,
      message: "Unknown action: " & actionId,
      shouldExit: false,
      shouldContinue: true,
      shouldResetUI: false
    )

  let action = actionRegistry[actionId]
  if action.handler == nil:
    return ActionResult(
      success: false,
      message: "Action is metadata-only: " & actionId,
      shouldExit: false,
      shouldContinue: true,
      shouldResetUI: false
    )

  action.handler(args, session, currentModel)

proc getAllActions*(): seq[ActionDefinition] =
  ## Get all registered actions sorted by command pattern
  for _, action in actionRegistry:
    result.add(action.definition)
  result.sort(proc(a, b: ActionDefinition): int = cmp(a.commandPattern, b.commandPattern))

proc getHelpActions*(): seq[ActionDefinition] =
  ## Get actions visible in generated help
  result = getAllActions().filterIt(it.showInHelp)

proc getMasterCliActions*(): seq[ActionDefinition] =
  ## Get actions available in master CLI
  result = getHelpActions().filterIt(asMasterCli in it.surfaces)

proc getRoutableAgentActions*(): seq[ActionDefinition] =
  ## Get actions that humans can route to agents
  result = getHelpActions().filterIt(it.routableToAgent)

proc getToolCallableActions*(): seq[ActionDefinition] =
  ## Get actions agents may invoke through tools
  result = getHelpActions().filterIt(it.toolName.isSome())

proc formatActionCapability*(capability: ActionCapability): string =
  ## Format capability enum for help output
  case capability
  of acInspectAgents: "inspect_agents"
  of acManageAgents: "manage_agents"
  of acDispatchTasks: "dispatch_tasks"
  of acManageConversations: "manage_conversations"
  of acInspectSystem: "inspect_system"

proc formatActionMarkers*(action: ActionDefinition): string =
  ## Format compact surface markers for help output
  var markers: seq[string] = @[]
  if asMasterCli in action.surfaces:
    markers.add("master")
  if action.routableToAgent:
    markers.add("route")
  if action.toolName.isSome():
    markers.add("tool")

  if markers.len == 0:
    return ""

  result = " [" & markers.join(",") & "]"

proc formatActionReference*(action: ActionDefinition, preferToolName: bool = false): string =
  ## Format the visible action name for help output
  if preferToolName and action.toolName.isSome():
    return action.toolName.get()

  if asMasterCli in action.surfaces or asAgentCli in action.surfaces or action.routableToAgent:
    return "/" & action.commandPattern

  if action.toolName.isSome():
    return action.toolName.get()

  action.commandPattern
