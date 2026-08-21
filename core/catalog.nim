## Catalog — the live registry of components and their tools.
##
## Populated by reg.publish / reg.depart on the bus. Presence = connection;
## hard crashes are cleaned up by the supervisor matching pid → component.
## Every change is announced as ev.catalog.updated so the LLM tools
## parameter and any UI stay fresh.

import std/[json, os, tables, times]
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
  # core's own tools are handled locally in dispatch; announce them so the
  # LLM sees the full self-extension loop (spawn, catalog)
  var coreReg = ComponentReg(name: "core", version: "0.1.0", pid: getCurrentProcessId())
  coreReg.tools.add(ToolReg(name: "spawn", component: "core",
    schema: %*{
      "type": "object",
      "description": "Start a compiled component binary; it registers itself and its tools appear in your toolset. To stop it again: core.kill (restored on next boot) or core.remove (forgotten permanently)",
      "properties": {
        "name": {"type": "string", "description": "Component name (must match its registration)"},
        "binary": {"type": "string", "description": "Path to the compiled binary (relative to the Niffler root or absolute)"}
      },
      "required": ["name", "binary"],
      "x-harness": {"approval": "always"}
    }))
  coreReg.tools.add(ToolReg(name: "kill", component: "core",
    schema: %*{
      "type": "object",
      "description": "Stop a running component (drain + terminate). It stays persisted in the store and is restored on the next boot; use remove to delete it for good",
      "properties": {"name": {"type": "string", "description": "Component name"}},
      "required": ["name"],
      "x-harness": {"approval": "always"}
    }))
  coreReg.tools.add(ToolReg(name: "remove", component: "core",
    schema: %*{
      "type": "object",
      "description": "Stop a component and delete its persisted record — it will not be restored on the next boot",
      "properties": {"name": {"type": "string", "description": "Component name"}},
      "required": ["name"],
      "x-harness": {"approval": "always"}
    }))
  coreReg.tools.add(ToolReg(name: "catalog", component: "core",
    schema: %*{
      "type": "object",
      "description": "Inspect the component catalog (list = LLM toolset)",
      "properties": {"op": {"type": "string", "enum": ["list"]}},
      "required": ["op"]
    }))
  coreReg.tools.add(ToolReg(name: "status", component: "core",
    schema: %*{
      "type": "object",
      "description": "Report the live set of components the supervisor is running and their health. Source of truth is the supervisor (process state), cross-referenced with the catalog. Corresponds to the UI's Live components view.",
      "properties": {}
    }))
  coreReg.tools.add(ToolReg(name: "session", component: "core",
    schema: %*{
      "type": "object",
      "description": "Run one conversation turn in a session (used by UIs)",
      "properties": {
        "sessionId": {"type": "string"},
        "content": {"type": "string"}
      },
      "required": ["sessionId", "content"],
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

proc allTools*(cat: Catalog): JsonNode =
  ## All non-hidden tools as [{name, schema}] — what the LLM gets to see.
  result = newJArray()
  for comp in cat.components.values:
    for t in comp.tools:
      if t.schema{"x-harness"}{"hidden"}.getBool(false):
        continue
      result.add(%*{"name": t.name, "schema": normalizeToolSchema(t.schema)})

proc toolSchema*(cat: Catalog, tool: string): JsonNode =
  let comp = cat.toolIndex.getOrDefault(tool)
  if comp.len == 0: return nil
  for t in cat.components[comp].tools:
    if t.name == tool: return t.schema

proc announce(cat: Catalog) =
  let env = Envelope(v: 1, id: newId(), kind: ekEvent, payload: cat.allTools())
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
