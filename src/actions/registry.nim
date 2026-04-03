## Action registry for metadata and execution

import std/[tables, options, algorithm, sequtils, strutils, json]
import types
import ../core/session
import ../types/config as configTypes
import ../types/messages

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

proc getAllActions*(): seq[ActionDefinition] {.gcsafe.} =
  ## Get all registered actions sorted by command pattern
  {.gcsafe.}:
    for _, action in actionRegistry:
      result.add(action.definition)
    result.sort(proc(a, b: ActionDefinition): int = cmp(a.commandPattern, b.commandPattern))

proc getHelpActions*(): seq[ActionDefinition] {.gcsafe.} =
  ## Get actions visible in generated help
  {.gcsafe.}:
    result = getAllActions().filterIt(it.showInHelp)

proc getMasterCliActions*(): seq[ActionDefinition] =
  ## Get actions available in master CLI
  result = getHelpActions().filterIt(asMasterCli in it.surfaces)

proc getRoutableAgentActions*(): seq[ActionDefinition] =
  ## Get actions that humans can route to agents
  result = getHelpActions().filterIt(it.routableToAgent)

proc getToolCallableActions*(): seq[ActionDefinition] {.gcsafe.} =
  ## Get actions agents may invoke through tools
  {.gcsafe.}:
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

proc parseActionCapability*(capability: string): Option[ActionCapability] =
  ## Parse capability names from agent definitions/config
  case capability.strip().toLowerAscii()
  of "inspect_agents": some(acInspectAgents)
  of "manage_agents": some(acManageAgents)
  of "dispatch_tasks": some(acDispatchTasks)
  of "manage_conversations": some(acManageConversations)
  of "inspect_system": some(acInspectSystem)
  else: none(ActionCapability)

proc getEffectiveActionCapabilities*(allowedTools: seq[string], explicitCapabilities: seq[string]): set[ActionCapability] =
  ## Combine explicit capabilities with transitional defaults derived from allowed tools
  result = {}

  for capability in explicitCapabilities:
    let parsed = parseActionCapability(capability)
    if parsed.isSome():
      result.incl(parsed.get())

  if "agent_manage" in allowedTools:
    result.incl(acInspectAgents)
    result.incl(acManageAgents)

  if "task_dispatch" in allowedTools:
    result.incl(acDispatchTasks)

proc getToolCallableActionsForCapabilities*(capabilities: set[ActionCapability]): seq[ActionDefinition] {.gcsafe.} =
  ## Get tool-callable actions allowed by a capability set
  {.gcsafe.}:
    for action in getToolCallableActions():
      if action.agentCapabilities.len == 0:
        result.add(action)
        continue

      var allowed = true
      for capability in action.agentCapabilities:
        if capability notin capabilities:
          allowed = false
          break
      if allowed:
        result.add(action)

proc filterToolSchemaForCapabilities*(toolSchema: ToolDefinition,
                                     capabilities: set[ActionCapability]): Option[ToolDefinition] =
  ## Filter action-backed tool schemas to match an agent's effective capabilities
  if toolSchema.function.name notin ["agent_manage", "task_dispatch"]:
    return some(toolSchema)

  let allowedActions = getToolCallableActionsForCapabilities(capabilities).filterIt(
    it.toolName.isSome() and it.toolName.get() == toolSchema.function.name
  )
  if allowedActions.len == 0:
    return none(ToolDefinition)

  var filteredSchema = toolSchema

  if toolSchema.function.name == "agent_manage":
    var operations: seq[string] = @[]
    for action in allowedActions:
      case action.id
      of "agent.listDefinitions": operations.add("list_definitions")
      of "agent.showDefinition": operations.add("show_definition")
      of "agent.listRunning": operations.add("list_running")
      of "agent.start": operations.add("start")
      of "agent.stop": operations.add("stop")
      else: discard

    if filteredSchema.function.parameters.hasKey("properties") and
       filteredSchema.function.parameters["properties"].hasKey("operation"):
      filteredSchema.function.parameters["properties"]["operation"]["enum"] = %operations

  return some(filteredSchema)

proc isActionToolCallAllowed*(toolName: string, args: JsonNode,
                             capabilities: set[ActionCapability]): tuple[allowed: bool, error: string] {.gcsafe.} =
  ## Enforce capability checks for action-backed tools at execution time
  {.gcsafe.}:
    if toolName == "task_dispatch":
      let allowedActions = getToolCallableActionsForCapabilities(capabilities).filterIt(it.id == "task.dispatchToAgent")
      if allowedActions.len == 0:
        return (false, "Missing required capability: dispatch_tasks")
      return (true, "")

    if toolName != "agent_manage":
      return (true, "")

    if not args.hasKey("operation") or args["operation"].kind != JString:
      return (false, "Missing required string argument: operation")

    let operation = args["operation"].getStr()
    let requiredActionId =
      case operation
      of "list_definitions": "agent.listDefinitions"
      of "show_definition": "agent.showDefinition"
      of "list_running": "agent.listRunning"
      of "start": "agent.start"
      of "stop": "agent.stop"
      else: return (false, "Unknown agent_manage operation: " & operation)

    let allowedActions = getToolCallableActionsForCapabilities(capabilities).filterIt(it.id == requiredActionId)
    if allowedActions.len == 0:
      let requiredCaps = getToolCallableActions().filterIt(it.id == requiredActionId)
      let capabilityText = if requiredCaps.len > 0 and requiredCaps[0].agentCapabilities.len > 0:
        requiredCaps[0].agentCapabilities.toSeq().mapIt(formatActionCapability(it)).join(", ")
      else:
        "required capability"
      return (false, "Missing required capability: " & capabilityText)

    (true, "")

proc isLocalCommand*(command: string): bool =
  ## Check if a slash command should execute locally in agent mode
  for action in getAllActions():
    let baseCommand = action.commandPattern.split(' ')[0]
    if baseCommand == command and asAgentCli in action.surfaces:
      return true
  false
