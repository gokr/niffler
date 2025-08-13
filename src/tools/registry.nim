import std/[tables, options, json]
import ../types/tools
import bash, create, edit, fetch, list, read

type
  ToolRegistry* = object
    tools*: Table[string, ToolDef]

proc newToolRegistry*(): ToolRegistry =
  ToolRegistry(tools: {"bash": newBashTool()}.toTable)



# Global registry instance - thread-local to avoid GC issues
var
  globalToolRegistry* {.threadvar.}: ToolRegistry
  registryInitialized* {.threadvar.}: bool

proc initGlobalToolRegistry*() =
  ## Initialize the global tool registry for this thread
  if not registryInitialized:
    globalToolRegistry = newToolRegistry()
    globalToolRegistry.register(newFetchTool())
    globalToolRegistry.register(newBashTool())
    globalToolRegistry.register(newCreateTool())
    globalToolRegistry.register(newEditTool())
    globalToolRegistry.register(newListTool())
    globalToolRegistry.register(newReadTool())
    registryInitialized = true

proc getGlobalToolRegistry*(): ptr ToolRegistry =
  ## Get pointer to global tool registry for this thread
  if not registryInitialized:
    initGlobalToolRegistry()
  result = addr globalToolRegistry