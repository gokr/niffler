## Action-backed orchestration tools

import std/[json, strformat, sequtils, strutils]
import ../core/[agent_manager, session as sessionMod, nats_client, config, agent_dispatch]
import ../ui/master_cli
import ../types/agents

proc startAgentInstance(agentName: string, nick: string = "", model: string = ""): tuple[success: bool, message: string] =
  try:
    let masterStatePtr = getGlobalMasterState()
    let spawned = startAgent(agentName, agentNick = nick, modelOverride = model, nifflerPath = "./niffler")
    let routingName = if nick.len > 0: nick else: agentName
    let ready = if masterStatePtr != nil and masterStatePtr[].connected:
      waitForAgentReady(masterStatePtr[].natsClient, routingName, timeoutSec = 15)
    else:
      false
    let label = if nick.len > 0: fmt("{nick} ({agentName})") else: agentName
    let readiness = if ready: "online" else: "spawned"
    return (true, fmt("Started {label} (pid {spawned.pid}, {readiness})."))
  except Exception as e:
    return (false, fmt("Failed to start agent: {e.msg}"))

proc stopAgentInstance(routingName: string): tuple[success: bool, message: string] =
  let matches = listRunningAgentProcesses().filterIt(it.routingName == routingName)
  if matches.len == 0:
    return (false, fmt("No running agent matches '{routingName}'."))
  if matches.len > 1:
    return (false, fmt("Multiple running agents match '{routingName}'. Use a unique nick before stopping."))
  if stopAgent(routingName):
    return (true, fmt("Stopped {formatRunningAgentLabel(matches[0])}."))
  (false, fmt("Failed to stop '{routingName}'."))

proc dispatchTaskToAgent(targetAgent: string, description: string): tuple[success: bool, message: string] =
  let requestId = "tool-" & generateAgentRequestId()
  var client = initNatsClient(getNatsUrl(), "tool-dispatch", presenceTTL = 5)

  try:
    let prepared = prepareAgentRequest(client, targetAgent, "/task " & description, requestId)
    if not prepared.success:
      return (false, prepared.error)

    publishAgentRequest(client, prepared.request)
    let collected = collectAgentResult(client, prepared.request.requestId, timeoutSec = 120)
    return (collected.success, collected.message)
  finally:
    client.close()

proc listDefinitionsOutput(): string =
  let currentSession = sessionMod.initSession()
  let agents = loadAgentDefinitions(currentSession.getAgentsDir())
  if agents.len == 0:
    return "No agent definitions found."

  var lines = @["Agent definitions:"]
  for agent in agents:
    lines.add(fmt("- {agent.name}: {agent.description}"))
  lines.join("\n")

proc showDefinitionOutput(agentName: string): string =
  let currentSession = sessionMod.initSession()
  let agents = loadAgentDefinitions(currentSession.getAgentsDir())
  let agent = agents.findAgent(agentName)
  if agent.name.len == 0:
    return fmt("Agent '{agentName}' not found.")

  result = fmt("Agent: {agent.name}\n")
  result &= fmt("Description: {agent.description}\n")
  result &= "Allowed Tools: " & agent.allowedTools.join(", ") & "\n"
  result &= fmt("File: {agent.filePath}")

proc listRunningOutput(): string =
  let runningAgents = listRunningAgentProcesses()
  let masterStatePtr = getGlobalMasterState()
  let presentAgents = if masterStatePtr != nil and masterStatePtr[].connected:
    masterStatePtr[].discoverAgents()
  else:
    @[]

  if runningAgents.len == 0 and presentAgents.len == 0:
    return "No running agents."

  var lines = @["Running agents:"]
  for agent in runningAgents:
    let presence = if agent.routingName in presentAgents: "online" else: "starting"
    let modelName = if agent.modelName.len > 0: agent.modelName else: "-"
    lines.add(fmt("- {formatRunningAgentLabel(agent)} | pid={agent.pid} | model={modelName} | {presence}"))
  for agentName in presentAgents:
    if runningAgents.anyIt(it.routingName == agentName):
      continue
    lines.add(fmt("- {agentName} | online"))
  lines.join("\n")

proc executeAgentManage*(args: JsonNode): string {.gcsafe.} =
  {.gcsafe.}:
    try:
      if not args.hasKey("operation"):
        return $ %*{"error": "Missing required argument: operation"}

      let operation = args["operation"].getStr()
      let operationResult =
        case operation
        of "list_definitions":
          (true, listDefinitionsOutput())
        of "show_definition":
          if not args.hasKey("name"):
            return $ %*{"error": "Missing required argument: name"}
          (true, showDefinitionOutput(args["name"].getStr()))
        of "list_running":
          (true, listRunningOutput())
        of "start":
          if not args.hasKey("name"):
            return $ %*{"error": "Missing required argument: name"}
          let nick = if args.hasKey("nick"): args["nick"].getStr() else: ""
          let model = if args.hasKey("model"): args["model"].getStr() else: ""
          let startResult = startAgentInstance(args["name"].getStr(), nick, model)
          (startResult.success, startResult.message)
        of "stop":
          if not args.hasKey("routing_name"):
            return $ %*{"error": "Missing required argument: routing_name"}
          let stopResult = stopAgentInstance(args["routing_name"].getStr())
          (stopResult.success, stopResult.message)
        else:
          return $ %*{"error": fmt("Unknown operation '{operation}'")}

      return $ %*{
        "success": operationResult[0],
        "message": operationResult[1]
      }
    except Exception as e:
      return $ %*{"error": fmt("agent_manage error: {e.msg}")}

proc executeTaskDispatch*(args: JsonNode): string {.gcsafe.} =
  {.gcsafe.}:
    try:
      if not args.hasKey("target"):
        return $ %*{"error": "Missing required argument: target"}
      if not args.hasKey("description"):
        return $ %*{"error": "Missing required argument: description"}

      let dispatchResult = dispatchTaskToAgent(args["target"].getStr(), args["description"].getStr())
      return $ %*{
        "success": dispatchResult.success,
        "message": dispatchResult.message
      }
    except Exception as e:
      return $ %*{"error": fmt("task_dispatch error: {e.msg}")}
