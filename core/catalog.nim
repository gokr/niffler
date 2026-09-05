## Catalog — the live registry of components and their tools.
##
## Populated by reg.publish / reg.depart on the bus. Presence = connection;
## hard crashes are cleaned up by the supervisor matching pid → component.
## Every change is announced as ev.catalog.updated so discovery and UIs stay
## fresh; each conversation keeps its own immutable direct-tool snapshot.

import std/[algorithm, json, os, sets, strutils, tables, times]
{.push warning[Deprecated]: off.}
import std/sha1
{.pop.}
import natswrapper
import ../sdk/envelope
import schema_validation

type
  ToolReg* = object
    name*: string
    schema*: JsonNode
    component*: string

  SlashParam* = object
    name*: string
    kind*: string        ## string | bool | int | enum (default string)
    description*: string
    source*: JsonNode    ## nil or {tool, args} — completion candidates source
    default*: JsonNode   ## optional default value
    values*: seq[string] ## optional inline completion candidates (enums)

  SlashCommand* = object
    name*: string        ## command word; unique across the catalog
    description*: string
    tool*: string        ## target tool in the same component (defaults to name)
    component*: string
    params*: seq[SlashParam]

  ComponentReg* = object
    name*: string
    version*: string
    pid*: int            ## primary/compatibility PID (first live replica)
    pids*: seq[int]      ## all live replicas of this logical component
    services*: Table[int, string] ## accepted PID -> private call subject
    client*: bool       ## interactive frontend (UI) — keeps an autostarted core alive
    tools*: seq[ToolReg]
    slash*: seq[SlashCommand]
    registeredAt*: float  ## epochTime of reg.publish (uptime for UIs)

  Catalog* = ref object
    nc*: NatsConnection
    components*: Table[string, ComponentReg]
    toolIndex*: Table[string, string]   ## tool name -> component name
    slashIndex*: Table[string, string]  ## slash command name -> component name
    ## onChange fires after ev.catalog.updated is published; the system core
    ## uses it to checkpoint the merged slash table into the store.
    onChange*: proc (cat: Catalog)
    sub*: ptr natsSubscription
    serve: bool
    routes: Table[string, ptr natsSubscription]
    nextReplica: Table[string, int]

proc newCatalog*(nc: NatsConnection, serve = false): Catalog =
  result = Catalog(nc: nc, serve: serve,
                   components: initTable[string, ComponentReg](),
                   toolIndex: initTable[string, string](),
                   slashIndex: initTable[string, string]())
  # Core's tools are handled locally in dispatch. discover/invoke stay direct;
  # lifecycle controls remain in the full catalog as on-demand capabilities.
  let corePid = getCurrentProcessId()
  var coreReg = ComponentReg(name: "core", version: "0.1.0",
                             pid: corePid, pids: @[corePid],
                             registeredAt: epochTime())
  coreReg.tools.add(ToolReg(name: "spawn", component: "core",
    schema: %*{
      "type": "object",
      "description": "Start a compiled component binary (optionally as identical stateless process replicas); it registers and becomes available through discover/invoke. To stop the logical group: core.kill (restored on next boot) or core.remove (forgotten permanently)",
      "properties": {
        "name": {"type": "string", "description": "Component name (must match its registration)"},
        "binary": {"type": "string", "description": "Path to the compiled binary (relative to the Niffler root or absolute)"},
        "replicas": {"type": "integer", "minimum": 1, "maximum": 16, "description": "Number of identical stateless component processes to run behind the accepted-instance router (default 1)"}
      },
      "required": ["name", "binary"],
      "x-harness": {"approval": "always", "onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "kill", component: "core",
    schema: %*{
      "type": "object",
      "description": "Stop every supervised process replica of a running logical component, preserving external replicas. It stays persisted in the store and is restored on the next boot; use remove to delete it for good",
      "properties": {"name": {"type": "string", "description": "Component name"}},
      "required": ["name"],
      "x-harness": {"approval": "always", "onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "remove", component: "core",
    schema: %*{
      "type": "object",
      "description": "Stop supervised replicas of a logical component and delete its persisted record, preserving external replicas — it will not be restored on the next boot",
      "properties": {"name": {"type": "string", "description": "Component name"}},
      "required": ["name"],
      "x-harness": {"approval": "always", "onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "catalog", component: "core",
    schema: %*{
      "type": "object",
      "description": "Inspect the component catalog (list = LLM toolset)",
       "properties": {
         "op": {"type": "string",
                "enum": ["list", "schemas"]},
         "tools": {"type": "array", "items": {"type": "string"},
                   "maxItems": 16}
       },
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
  coreReg.tools.add(ToolReg(name: "doctor", component: "core",
    schema: %*{
      "type": "object",
      "description": "Machine-readable one-shot health report: bus and store reachability, llm availability (component registered + active provider/model), systemprompt component presence, catalog size, conversation count. All probes are read-only and never execute anything. Use it to diagnose a harness before debugging anything else, or from scripts/CI as a cheap liveness gate.",
      "properties": {},
      "x-harness": {"onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "prompt_preview", component: "core",
    schema: %*{
      "type": "object",
      "description": "Inspect the composed request context of a conversation without sending anything: where the system prompt came from (component vs minimal fallback), which project context files feed it, the frozen direct tool names, schemas discovered so far, any frozen tool allowlist, and message/token counts. Read-only provenance for debugging prompt or tool-selection problems. Called without sessionId (or with an empty one) it answers about the CURRENT session. Never sends a request and never mutates anything.",
      "properties": {
        "sessionId": {"type": "string",
                      "description": "Conversation id (conv-*). Omit or leave empty to preview the current session"}
      },
      "x-harness": {"onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "session_info", component: "core",
    schema: %*{
      "type": "object",
      "description": "Summarize a conversation: id, title, model, thinking effort, context window and token usage, message counts by role. Without sessionId: the current conversation. With an id: that conversation (enumerate stored ones with store list, kind \"conversation\").",
      "properties": {
        "sessionId": {"type": "string",
                      "description": "Conversation id (conv-*). Omit or leave empty to summarize the current session"}
      },
      "x-harness": {"onDemand": true}
    }))
  coreReg.tools.add(ToolReg(name: "discover", component: "core",
    schema: %*{
      "type": "object",
      "description": "Find live components and tools outside the fixed direct toolset. query returns concise hints; component or tools (up to 16 names) return full schemas. Call returned tools through invoke — plugins (packages) and skills (workflow guides) live here too.",
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
      "description": "Call a non-hidden tool after discover returns its schema: put the target's arguments unchanged under arguments. Its normal approval and timeout policy applies.",
      "properties": {
        "tool": {"type": "string", "description": "Exact tool name returned by discover"},
        "arguments": {"type": "object", "description": "Arguments matching the discovered target schema"}
      },
      "required": ["tool", "arguments"]
    }))
  coreReg.tools.add(ToolReg(name: "session", component: "core",
    schema: %*{
      "type": "object",
      "description": "Run one conversation turn or update its selection (used by UIs)",
      "properties": {
        "sessionId": {"type": "string"},
        "content": {"type": "string"},
        "title": {"type": "string", "description": "Rename the conversation (shown in session lists); non-empty updates the title, empty/absent leaves it"},
        "model": {"type": "string", "description": "Conversation model override; empty clears it"},
        "thinking": {"type": "string", "enum": ["low", "medium", "high"],
                     "description": "Per-conversation thinking effort forwarded to the LLM as reasoning_effort; empty clears it (provider default). Values: low, medium, high, max (deepest)"},
        "cwd": {"type": "string", "description": "Conversation workspace inside NIF_ROOT; immutable after creation"}
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

proc canonicalJson*(node: JsonNode): string =
  ## Stable JSON independent of object insertion order.
  if node == nil: return "null"
  case node.kind
  of JObject:
    var keys: seq[string]
    for key, value in node: keys.add(key)
    keys.sort()
    result.add('{')
    for i, key in keys:
      if i > 0: result.add(',')
      result.add($(%key))
      result.add(':')
      result.add(canonicalJson(node[key]))
    result.add('}')
  of JArray:
    result.add('[')
    for i in 0 ..< node.len:
      if i > 0: result.add(',')
      result.add(canonicalJson(node[i]))
    result.add(']')
  else:
    result = $node

proc schemaFingerprint*(schema: JsonNode): string =
  ## SHA-1 is an identity checksum here, not a security boundary.
  result = $secureHash(canonicalJson(normalizeToolSchema(schema)))

proc isHidden*(schema: JsonNode): bool
proc toolSchema*(cat: Catalog, tool: string): JsonNode

proc selectedSchemas*(cat: Catalog, requested: JsonNode): JsonNode =
  ## Return a deterministic, bounded schema snapshot for typed Fabric runs.
  if requested == nil or requested.kind != JArray or requested.len == 0:
    return %*{"error": "catalog schemas needs a non-empty tools array"}
  if requested.len > 16:
    return %*{"error": "catalog schemas returns at most 16 tools"}
  var names: seq[string]
  var seen = initHashSet[string]()
  for node in requested:
    if node.kind != JString or node.getStr("").len == 0:
      return %*{"error": "catalog schema names must be non-empty strings"}
    let name = node.getStr("")
    if name notin seen:
      seen.incl(name)
      names.add(name)
  names.sort()
  var tools = newJArray()
  for name in names:
    let owner = cat.toolIndex.getOrDefault(name)
    let schema = cat.toolSchema(name)
    if owner.len == 0 or schema == nil or schema.isHidden():
      return %*{"error": "one or more requested tools are not available"}
    let normalized = normalizeToolSchema(schema).copy()
    let boundsError = validateSchemaBounds(normalized)
    if boundsError.len > 0:
      return %*{"error": "tool schema is not available: " & boundsError}
    let reg = cat.components[owner]
    tools.add(%*{"name": name, "component": owner, "version": reg.version,
                 "schema": normalized,
                 "fingerprint": schemaFingerprint(normalized)})
    if ($(%*{"tools": tools})).len > 512_000:
      return %*{"error": "catalog schema snapshot exceeds 512000 bytes"}
  result = %*{"tools": tools}

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
    # Snap the cut to a UTF-8 boundary: descriptions can contain CJK text
    # (e.g. a localized tool doc comment), and a split rune would make the
    # hint JSON invalid.
    var cut = 197
    while cut > 0 and (result[cut].uint8 and 0xC0) == 0x80:
      dec cut
    result = result[0 ..< cut] & "..."

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

proc sortedSlashCommands*(cat: Catalog): seq[SlashCommand] =
  for comp in cat.components.values:
    for cmd in comp.slash:
      result.add(cmd)
  result.sort(proc(a, b: SlashCommand): int = cmp(a.name, b.name))

proc slashTable*(cat: Catalog): JsonNode =
  ## Merged slash-command table — the store checkpoint and snapshot shape
  ## (docs/WIRE.md). Name-sorted, every entry already validated.
  var cmds = newJArray()
  for cmd in cat.sortedSlashCommands():
    var node = %*{"name": cmd.name, "description": cmd.description,
                  "component": cmd.component, "tool": cmd.tool}
    if cmd.params.len > 0:
      var params = newJArray()
      for p in cmd.params:
        var pn = %*{"name": p.name, "kind": p.kind}
        if p.description.len > 0: pn["description"] = %p.description
        if p.source != nil: pn["source"] = p.source
        if p.default != nil: pn["default"] = p.default
        if p.values.len > 0: pn["values"] = %p.values
        params.add(pn)
      node["params"] = %params
    cmds.add(node)
  %*{"updatedAt": epochTime(), "commands": cmds}

proc slashList*(reg: ComponentReg): JsonNode =
  ## Per-component slash surface for catalog snapshots.
  var cmds = newJArray()
  for cmd in reg.slash:
    var node = %*{"name": cmd.name, "description": cmd.description,
                  "tool": cmd.tool}
    if cmd.params.len > 0:
      var params = newJArray()
      for p in cmd.params:
        var pn = %*{"name": p.name, "kind": p.kind}
        if p.description.len > 0: pn["description"] = %p.description
        if p.source != nil: pn["source"] = p.source
        if p.default != nil: pn["default"] = p.default
        if p.values.len > 0: pn["values"] = %p.values
        params.add(pn)
      node["params"] = %params
    cmds.add(node)
  cmds

proc syncRoutes(cat: Catalog) =
  ## Only the system catalog owns public service addresses. Session catalogs
  ## are read-only mirrors and must never compete for routed calls.
  if not cat.serve: return
  for name, reg in cat.components:
    if reg.services.len == 0 or cat.routes.hasKey(name): continue
    var sub: ptr natsSubscription
    let subject = "svc." & name & ".call"
    let st = natsConnection_QueueSubscribeSync(addr sub, cat.nc.conn,
                                               subject.cstring, "core-router")
    if not checkStatus(st):
      raise newException(IOError, "subscribe service route: " & getErrorString(st))
    cat.routes[name] = sub

proc announce(cat: Catalog) =
  cat.syncRoutes()
  let env = Envelope(v: 1, id: newId(), kind: ekEvent,
                     payload: cat.promptTools())
  cat.nc.publish("ev.catalog.updated", env.encode())
  if cat.onChange != nil:
    try:
      cat.onChange(cat)
    except CatchableError:
      discard  # checkpointing is best effort

proc dropRegistration(cat: Catalog, name, reason: string) =
  ## Remove one logical component and its tool/slash indexes.
  if not cat.components.hasKey(name): return
  for t in cat.components[name].tools:
    if cat.toolIndex.getOrDefault(t.name) == name:
      cat.toolIndex.del(t.name)
  for s in cat.components[name].slash:
    if cat.slashIndex.getOrDefault(s.name) == name:
      cat.slashIndex.del(s.name)
  cat.components.del(name)
  if cat.routes.hasKey(name):
    discard natsSubscription_Unsubscribe(cat.routes[name])
    natsSubscription_Destroy(cat.routes[name])
    cat.routes.del(name)
    cat.nextReplica.del(name)
  echo "catalog: " & name & " " & reason
  cat.announce()

proc handle(cat: Catalog, subject, data: string): bool =
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
    # Snapshot seeding can carry the whole live replica set; ordinary
    # reg.publish carries only this process's pid.
    let announcedPids = node{"pids"}
    if announcedPids != nil and announcedPids.kind == JArray:
      for p in announcedPids:
        let pid = p.getInt(0)
        if pid > 0 and pid notin reg.pids: reg.pids.add(pid)
    if reg.pid > 0 and reg.pid notin reg.pids:
      reg.pids.add(reg.pid)
    if reg.pid <= 0 and reg.pids.len > 0:
      reg.pid = reg.pids[0]
    let service = node{"service"}.getStr("")
    if service.len > 0:
      if not name.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}):
        echo "catalog: rejecting invalid service component name"
        return
      let prefix = "svc." & name & ".instance."
      if reg.pid <= 0 or not service.startsWith(prefix) or
         not service.endsWith(".call") or service.len <= prefix.len + 5:
        echo "catalog: rejecting invalid instance service for " & name
        return
      let token = service[prefix.len ..< service.len - 5]
      if token.len == 0 or not token.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}):
        echo "catalog: rejecting invalid instance service for " & name
        return
      reg.services[reg.pid] = service
    # tool names are unique across the whole catalog (docs/WIRE.md). A clash
    # refuses the ENTIRE registration, before any state changes: a component
    # that joins minus its colliding tool shows up "installed" while silently
    # doing nothing — a loud missing component beats a broken one.
    if node{"tools"} != nil:
      for t in node{"tools"}:
        let tname = t{"name"}.getStr("")
        if tname.len == 0: continue
        let owner = cat.toolIndex.getOrDefault(tname)
        if owner.len > 0 and owner != name:
          echo "catalog: rejecting " & name & " — tool '" & tname &
               "' already provided by " & owner &
               " (refused; use component-prefixed tool names)"
          return
        reg.tools.add(ToolReg(name: tname,
                              schema: normalizeToolSchema(t{"schema"}),
                              component: name))
    if cat.serve and reg.tools.len > 0 and service.len == 0:
      echo "catalog: rejecting " & name & " — service instance address required"
      return
    # A second process with the same logical name is a service
    # replica. It must advertise an identical tool contract; then only its
    # PID joins the existing registration. This keeps global tool identity
    # singular while the service has N workers.
    if cat.components.hasKey(name):
      var current = cat.components[name]
      var compatible = current.client == reg.client and
                       current.tools.len == reg.tools.len
      if compatible:
        for incoming in reg.tools:
          var found = false
          for existing in current.tools:
            if existing.name == incoming.name and
                schemaFingerprint(existing.schema) ==
                  schemaFingerprint(incoming.schema):
              found = true
              break
          if not found:
            compatible = false
            break
      if not compatible:
        echo "catalog: rejecting replica " & name &
             " — registration contract differs from the live group"
        return
      for pid, service in reg.services:
        current.services[pid] = service
      for pid in reg.pids:
        if pid notin current.pids: current.pids.add(pid)
      if current.pid <= 0 and current.pids.len > 0:
        current.pid = current.pids[0]
      current.version = reg.version
      cat.components[name] = current
      echo "catalog: " & name & " replica registered (" &
           $current.pids.len & " live)"
      cat.announce()
      return true
    for t in reg.tools:
      cat.toolIndex[t.name] = name
    # Slash commands: declarative UI surface (docs/WIRE.md). Validated here
    # so every catalog read and the store checkpoint is already sane.
    if node{"slash"} != nil and node{"slash"}.kind == JArray:
      for s in node{"slash"}:
        if reg.slash.len >= 32:
          echo "catalog: rejecting " & name & " — too many slash commands"
          break
        let sname = s{"name"}.getStr("").toLowerAscii().strip()
        if sname.len == 0 or sname.len > 32 or
           not sname.allCharsInSet({'a'..'z', '0'..'9', '-', '_'}):
          echo "catalog: rejecting " & name & " — invalid slash command name"
          continue
        let sowner = cat.slashIndex.getOrDefault(sname)
        if sowner.len > 0 and sowner != name:
          echo "catalog: rejecting " & name & " — slash '" & sname &
               "' already provided by " & sowner
          continue
        var cmd = SlashCommand(name: sname,
                               description: s{"description"}.getStr(""),
                               tool: s{"tool"}.getStr(""),
                               component: name)
        if cmd.tool.len == 0: cmd.tool = sname
        var targetOK = false
        for t in reg.tools:
          if t.name == cmd.tool: targetOK = true
        if not targetOK:
          echo "catalog: rejecting " & name & " — slash '" & sname &
               "' targets unknown tool '" & cmd.tool & "'"
          continue
        if s{"params"} != nil and s{"params"}.kind == JArray:
          for p in s{"params"}:
            if cmd.params.len >= 16: break
            var param = SlashParam(name: p{"name"}.getStr(""),
                                   kind: p{"kind"}.getStr("string"),
                                   description: p{"description"}.getStr(""),
                                   source: p{"source"},
                                   default: p{"default"})
            if param.name.len == 0: continue
            if param.kind notin ["string", "bool", "int", "enum"]:
              param.kind = "string"
            if p{"values"} != nil and p{"values"}.kind == JArray:
              for v in p{"values"}:
                if v.kind == JString: param.values.add(v.getStr(""))
            cmd.params.add(param)
        reg.slash.add(cmd)
        cat.slashIndex[sname] = name
    cat.components[name] = reg
    echo "catalog: " & name & " v" & reg.version & " registered (" &
         $reg.tools.len & " tools, " & $reg.slash.len & " slash commands)"
    cat.announce()
    return true

  elif subject == "reg.depart":
    if cat.components.hasKey(name):
      let pid = node{"pid"}.getInt(0)
      var reg = cat.components[name]
      let service = node{"service"}.getStr("")
      # Snapshot-seeded session mirrors track membership by PID and do not
      # own private routes. Only the authority validates endpoint identity.
      if cat.serve and service.len > 0 and reg.services.getOrDefault(pid) != service: return
      if pid > 0 and reg.pids.len > 0:
        var remaining: seq[int]
        for livePid in reg.pids:
          if livePid != pid: remaining.add(livePid)
        # Ignore a stale/duplicate departure rather than dropping peers.
        if remaining.len == reg.pids.len: return
        if remaining.len > 0:
          reg.services.del(pid)
          reg.pids = remaining
          reg.pid = remaining[0]
          cat.components[name] = reg
          echo "catalog: " & name & " replica departed (" &
               $remaining.len & " live)"
          cat.announce()
          return
      cat.dropRegistration(name, "departed")

proc applyReg*(cat: Catalog, node: JsonNode) =
  ## Inject one registration payload ({name, version, pid, pids?, tools}) as if it
  ## had arrived on reg.publish — used by session runners to seed their
  ## catalog from the system's snapshot taken at startup.
  discard handle(cat, "reg.publish", $node)

proc clientCount*(cat: Catalog): int =
  ## Registered interactive frontends (reg.publish with "client": true).
  ## An autostarted core exits when this returns to zero.
  for comp in cat.components.values:
    if comp.client: inc result

proc dropReplica*(cat: Catalog, name: string, pid: int) =
  ## Called by the supervisor when one process dies without reg.depart. Keep
  ## the logical component registered while another accepted replica lives.
  if not cat.components.hasKey(name): return
  var reg = cat.components[name]
  if pid > 0 and reg.pids.len > 0:
    var remaining: seq[int]
    for livePid in reg.pids:
      if livePid != pid: remaining.add(livePid)
    if remaining.len == reg.pids.len: return
    if remaining.len > 0:
      reg.services.del(pid)
      reg.pids = remaining
      reg.pid = remaining[0]
      cat.components[name] = reg
      echo "catalog: " & name & " replica lost (" & $remaining.len & " live)"
      cat.announce()
      return
  cat.dropRegistration(name, "lost (last process died)")

proc dropComponent*(cat: Catalog, name: string) =
  ## Remove an entire logical component (all replicas), used by explicit
  ## core.kill/core.remove. Crashes use dropReplica instead.
  cat.dropRegistration(name, "removed")

proc pump*(cat: Catalog) =
  ## Drain pending registration messages; call from event gaps in the loop.
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, cat.sub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let subject = $natsMsg_GetSubject(msg)
    let data = $natsMsg_GetData(msg)
    let reply = $natsMsg_GetReply(msg)
    natsMsg_Destroy(msg)
    let accepted = cat.handle(subject, data)
    if cat.serve and subject == "reg.publish" and reply.len > 0:
      cat.nc.publish(reply, $(%*{"accepted": accepted}))

  # Forward without waiting for a result: the original reply inbox travels
  # with the request, so calls and replicas remain concurrent. Rejected
  # registrations never enter this address selection.
  if cat.serve:
    for name, sub in cat.routes:
      # Never wait on an idle service: routing latency must not grow with
      # the number of registered components.
      var pending: cint
      if natsSubscription_GetPending(sub, addr pending, nil) != NATS_OK: continue
      for i in 0 ..< min(64, pending.int):
        var msg: ptr natsMsg
        let st = natsSubscription_NextMsg(addr msg, sub, 1)
        if st != NATS_OK: break
        let reg = cat.components[name]
        var endpoints: seq[string]
        for pid in reg.pids:
          if reg.services.hasKey(pid): endpoints.add(reg.services[pid])
        if endpoints.len > 0:
          let index = cat.nextReplica.getOrDefault(name) mod endpoints.len
          cat.nextReplica[name] = (index + 1) mod endpoints.len
          let reply = $natsMsg_GetReply(msg)
          if reply.len > 0:
            discard natsConnection_PublishRequest(cat.nc.conn,
              endpoints[index].cstring, reply.cstring,
              natsMsg_GetData(msg), natsMsg_GetDataLength(msg))
          else:
            discard natsConnection_Publish(cat.nc.conn, endpoints[index].cstring,
              natsMsg_GetData(msg), natsMsg_GetDataLength(msg))
        natsMsg_Destroy(msg)
