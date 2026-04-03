## Action types for shared command/tool behavior

import std/options
import ../core/session
import ../types/config as configTypes

type
  ActionSurface* = enum
    asMasterCli
    asAgentCli
    asTool

  ActionCapability* = enum
    acInspectAgents
    acManageAgents
    acDispatchTasks
    acManageConversations
    acInspectSystem

  ActionResult* = object
    success*: bool
    message*: string
    shouldExit*: bool
    shouldContinue*: bool
    shouldResetUI*: bool

  ActionDefinition* = object
    id*: string
    description*: string
    commandPattern*: string
    aliases*: seq[string]
    surfaces*: set[ActionSurface]
    routableToAgent*: bool
    toolName*: Option[string]
    agentCapabilities*: set[ActionCapability]
    showInHelp*: bool

  ActionHandler* = proc(args: seq[string], session: var Session,
                       currentModel: var configTypes.ModelConfig): ActionResult
