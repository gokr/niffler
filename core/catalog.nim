## Catalog — the live registry of components and their tools.
##
## Populated by reg.publish / reg.depart on the bus. Presence = connection;
## hard crashes are cleaned up by the supervisor matching pid → component.
## Every change is announced as ev.catalog.updated so discovery and UIs stay
## fresh; each conversation keeps its own immutable direct-tool snapshot.

import std/[algorithm, json, os, strutils, tables, times]
import natswrapper
import ../sdk/envelope

type
  ToolReg* = object
    name*: string
    schema*: JsonNode
    component*: string

  ComponentReg* = object
    name*: string
    version*: string
    pid*: int
    client*: bool       ## interactive frontend (UI) — keeps an autostarted core alive
    tools*: seq[ToolReg]
    registeredAt*: float  ## epochTime of reg.publish (uptime for UIs)

  Catalog* = ref object
    nc*: NatsConnection
    components*: Table[string, ComponentReg]
    toolIndex*: Table[string, string]  ## tool name -> component name
    sub*: ptr natsSubscription

proc newCatalog*(nc: NatsConnection): Catalog =
  result = Catalog(nc: nc,
                   components: initTable[string, ComponentReg](),
                   toolIndex: initTable[string, string]())
  # Core's tools are handled locally in dispatch. discover/invoke stay direct;
  # lifecycle controls remain in the full catalog as on-demand capabilities.
  var coreReg = ComponentReg(name: "core", version: "0.1.0",
                             pid: getCurrentProcessId(),
                             registeredAt: epochTime())
  coreReg.tools.add(ToolReg(name: "spawn", component: "core",
    schema: %*{
      "type": "object",
      "description": "Start a compiled component binary; it registers itself and becomes available through discover/invoke. To stop it again: core.kill (restored on next boot) or core.remove (forgotten permanently)",
      "properties": {
        "name": {"type": "string", "description": "Component name (must match its registration)"},
        "binary": {"type": "string", "description": "Path to the compiled binary (relative to the Niffler root or absolute)"}
      },
      "required": ["name", "binary"],
      "x-harness": {"approval": "always", "onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "kill", component: "core",
    schema: %*{
      "type": "object",
      "description": "Stop a running component (drain + terminate). It stays persisted in the store and is restored on the next boot; use remove to delete it for good",
      "properties": {"name": {"type": "string", "description": "Component name"}},
      "required": ["name"],
      "x-harness": {"approval": "always", "onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "remove", component: "core",
    schema: %*{
      "type": "object",
      "description": "Stop a component and delete its persisted record — it will not be restored on the next boot",
      "properties": {"name": {"type": "string", "description": "Component name"}},
      "required": ["name"],
      "x-harness": {"approval": "always", "onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "catalog", component: "core",
    schema: %*{
      "type": "object",
      "description": "Inspect the component catalog (list = LLM toolset)",
      "properties": {"op": {"type": "string", "enum": ["list"]}},
      "required": ["op"],
      "x-harness": {"onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "status", component: "core",
    schema: %*{
      "type": "object",
      "description": "Report the live set of components the supervisor is running and their health. Source of truth is the supervisor (process state), cross-referenced with the catalog. Corresponds to the UI's Live components view.",
      "properties": {},
      "x-harness": {"onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "discover", component: "core",
    schema: %*{
      "type": "object",
      "description": "Find live components and tools outside the fixed direct toolset. Use query for concise hints, or pass component plus up to 16 tool names for their full schemas. Call returned tools through invoke.",
      "properties": {
        "query": {"type": "string", "description": "Case-insensitive component, tool-name, or description filter"},
        "component": {"type": "string", "description": "Exact component name whose tools you want to inspect"},
        "tools": {"type": "array", "items": {"type": "string"}, "maxItems": 16,
                  "description": "Exact tool names whose full schemas to return"}
      }
    }))
  coreReg.tools.add(ToolReg(name: "invoke", component: "core",
    schema: %*{
      "type": "object",
      "description": "Call a non-hidden tool after discover returns its schema. Put the target tool's arguments unchanged under arguments. The target's normal approval and timeout policy still applies.",
      "properties": {
        "tool": {"type": "string", "description": "Exact tool name returned by discover"},
        "arguments": {"type": "object", "description": "Arguments matching the discovered target schema"}
      },
      "required": ["tool", "arguments"]
    }))
  coreReg.tools.add(ToolReg(name: "session", component: "core",
    schema: %*{
      "type": "object",
      "description": "Run one conversation turn or update its model selection (used by UIs)",
      "properties": {
        "sessionId": {"type": "string"},
        "content": {"type": "string"},
        "model": {"type": "string", "description": "Conversation model override; empty clears it"}
      },
      "required": ["sessionId"],
      "x-harness": {"hidden": true}
    }))
  coreReg.tools.add(ToolReg(name: "session_prepare", component: "core",
    schema: %*{
      "type": "object",
      "description": "Ensure a conversation's session runner is alive and return its direct call subject, without running a turn. Used by components that drive subagent sessions mid-turn (core's session tool would stash them until the running turn ends).",
      "properties": {"sessionId": {"type": "string"}},
      "required": ["sessionId"],
      "x-harness": {"hidden": true}
    }))
  result.components["core"] = coreReg
  for t in coreReg.tools:
    result.toolIndex[t.name] = "core"
  var sub: ptr natsSubscription
  let st = natsConnection_SubscribeSync(addr sub, nc.conn, "reg.>".cstring)
  if not checkStatus(st):
    raise newException(IOError, "subscribe reg.>: " & getErrorString(st))
  result.sub = sub

proc normalizeToolSchema*(schema: JsonNode): JsonNode =
  ## Drop invalid/missing root fields from a component-registered schema.
  ## OpenAI tool calling requires parameters to be a JSON Schema of
  ## 'type:"object"'. Components (especially LLM-authored Go ones) routinely
  ## omit 'type'; normalize here so *every* catalog read — the LLM tools
  ## parameter, ev.catalog.updated, a store-resume rebuild — is already valid.
  if schema == nil or schema.kind != JObject:
    return %*{"type": "object", "properties": {}}
  result = schema
  if result{"type"} == nil or result{"type"}.kind == JNull or
      result{"type"}.getStr("").len == 0:
    result["type"] = %"object"
  if result{"properties"} == nil or result{"properties"}.kind != JObject:
    result["properties"] = %*{}

proc isHidden*(schema: JsonNode): bool =
  schema != nil and schema{"x-harness"}{"hidden"}.getBool(false)

proc isOnDemand*(schema: JsonNode): bool =
  schema != nil and schema{"x-harness"}{"onDemand"}.getBool(false)

proc sortedTools(cat: Catalog): seq[ToolReg] =
  for comp in cat.components.values:
    for tool in comp.tools:
      result.add(tool)
  result.sort(proc(a, b: ToolReg): int = cmp(a.name, b.name))

proc sortedComponentNames*(cat: Catalog): seq[string] =
  for name in cat.components.keys:
    result.add(name)
  result.sort()

proc promptTools*(cat: Catalog): JsonNode =
  ## Direct, non-hidden tools as stable [{name, schema}] for LLM requests.
  result = newJArray()
  for tool in cat.sortedTools():
    if tool.schema.isHidden() or tool.schema.isOnDemand():
      continue
    result.add(%*{"name": tool.name,
                  "schema": normalizeToolSchema(tool.schema)})

proc shortDescription(schema: JsonNode): string =
  result = schema{"description"}.getStr("").splitWhitespace().join(" ")
  if result.len > 200:
    result = result[0 ..< 197] & "..."

proc toolHint(tool: ToolReg): JsonNode =
  %*{"name": tool.name, "description": shortDescription(tool.schema)}

proc componentSummary(reg: ComponentReg, query: string): JsonNode =
  let componentMatches = query.len == 0 or
    reg.name.toLowerAscii().contains(query)
  var direct = newJArray()
  var onDemand = newJArray()
  var tools: seq[ToolReg] = @[]
  for tool in reg.tools:
    tools.add(tool)
  tools.sort(proc(a, b: ToolReg): int = cmp(a.name, b.name))
  for tool in tools:
    if tool.schema.isHidden():
      continue
    let toolMatches = componentMatches or
      tool.name.toLowerAscii().contains(query) or
      tool.schema{"description"}.getStr("").toLowerAscii().contains(query)
    if not toolMatches:
      continue
    if tool.schema.isOnDemand():
      onDemand.add(toolHint(tool))
    else:
      direct.add(toolHint(tool))
  if direct.len == 0 and onDemand.len == 0:
    return nil
  return %*{"name": reg.name, "version": reg.version,
            "direct": direct, "onDemand": onDemand}

proc discover*(cat: Catalog, args: JsonNode): JsonNode =
  ## Return deterministic component hints or selected non-hidden schemas.
  let component = args{"component"}.getStr("").strip()
  let requested = args{"tools"}
  if component.len == 0:
    if requested != nil and requested.kind != JNull:
      return %*{"error": "discover tools needs component"}
    let query = args{"query"}.getStr("").strip().toLowerAscii()
    var components = newJArray()
    for name in cat.sortedComponentNames():
      let summary = componentSummary(cat.components[name], query)
      if summary != nil:
        components.add(summary)
    return %*{"components": components, "count": components.len}

  if not cat.components.hasKey(component):
    return %*{"error": "no discoverable component '" & component & "'"}
  let summary = componentSummary(cat.components[component], "")
  if summary == nil:
    return %*{"error": "no discoverable component '" & component & "'"}
  if requested == nil or requested.kind == JNull or
      (requested.kind == JArray and requested.len == 0):
    return %*{"component": summary}
  if requested.kind != JArray:
    return %*{"error": "discover tools must be an array"}
  if requested.len > 16:
    return %*{"error": "discover returns at most 16 tool schemas"}

  var names: seq[string] = @[]
  for node in requested:
    if node.kind != JString or node.getStr("").len == 0:
      return %*{"error": "discover tool names must be non-empty strings"}
    let name = node.getStr("")
    if name notin names:
      names.add(name)
  names.sort()

  var schemas = newJArray()
  let reg = cat.components[component]
  for name in names:
    var found = false
    for tool in reg.tools:
      if tool.name == name and not tool.schema.isHidden():
        schemas.add(%*{"name": tool.name,
                       "schema": normalizeToolSchema(tool.schema)})
        found = true
        break
    if not found:
      return %*{"error": "one or more requested tools are not discoverable in component '" &
                           component & "'"}
  return %*{"component": component, "tools": schemas}

proc toolSchema*(cat: Catalog, tool: string): JsonNode =
  let comp = cat.toolIndex.getOrDefault(tool)
  if comp.len == 0: return nil
  for t in cat.components[comp].tools:
    if t.name == tool: return t.schema

proc announce(cat: Catalog) =
  let env = Envelope(v: 1, id: newId(), kind: ekEvent,
                     payload: cat.promptTools())
  cat.nc.publish("ev.catalog.updated", env.encode())

proc handle(cat: Catalog, subject, data: string) =
  var node: JsonNode
  try:
    node = data.parseJson()
  except CatchableError:
    return
  let name = node{"name"}.getStr("")
  if name.len == 0: return

  # "core" is the control plane itself — its tools are seeded above and
  # must not be spoofable or replaceable by a bus citizen (docs/ARCHITECTURE.md)
  if name == "core":
    echo "catalog: rejecting " & name & " — reserved component name"
    return

  if subject == "reg.publish":
    var reg = ComponentReg(name: name,
                           version: node{"version"}.getStr(""),
                           pid: node{"pid"}.getInt(0),
                           client: node{"client"}.getBool(false),
                           registeredAt: epochTime())
    for t in node{"tools"}:
      let tname = t{"name"}.getStr("")
      if tname.len == 0: continue
      # tool names are unique across the whole catalog (docs/WIRE.md)
      let owner = cat.toolIndex.getOrDefault(tname)
      if owner.len > 0 and owner != name:
        echo "catalog: rejecting " & name & " — tool '" & tname &
             "' already provided by " & owner
        continue
      reg.tools.add(ToolReg(name: tname, schema: normalizeToolSchema(t{"schema"}), component: name))
      cat.toolIndex[tname] = name
    cat.components[name] = reg
    echo "catalog: " & name & " v" & reg.version & " registered (" &
         $reg.tools.len & " tools)"
    cat.announce()

  elif subject == "reg.depart":
    if cat.components.hasKey(name):
      for t in cat.components[name].tools:
        if cat.toolIndex.getOrDefault(t.name) == name:
          cat.toolIndex.del(t.name)
      cat.components.del(name)
      echo "catalog: " & name & " departed"
      cat.announce()

proc applyReg*(cat: Catalog, node: JsonNode) =
  ## Inject one registration payload ({name, version, pid, tools}) as if it
  ## had arrived on reg.publish — used by session runners to seed their
  ## catalog from the system's snapshot taken at startup.
  handle(cat, "reg.publish", $node)

proc clientCount*(cat: Catalog): int =
  ## Registered interactive frontends (reg.publish with "client": true).
  ## An autostarted core exits when this returns to zero.
  for comp in cat.components.values:
    if comp.client: inc result

proc dropComponent*(cat: Catalog, name: string) =
  ## Called by the supervisor when a child process dies (crash — no reg.depart).
  if cat.components.hasKey(name):
    for t in cat.components[name].tools:
      if cat.toolIndex.getOrDefault(t.name) == name:
        cat.toolIndex.del(t.name)
    cat.components.del(name)
    echo "catalog: " & name & " lost (process died)"
    cat.announce()

proc pump*(cat: Catalog) =
  ## Drain pending registration messages; call from event gaps in the loop.
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, cat.sub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let subject = $natsMsg_GetSubject(msg)
    let data = $natsMsg_GetData(msg)
    natsMsg_Destroy(msg)
    cat.handle(subject, data)
