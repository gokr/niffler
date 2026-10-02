## cli component — drive the harness from a terminal or a script.
##
## A standalone bus client: reads the accepted component/tool catalog from
## core and dispatches tool calls request/reply over the bus. Component
## announcements are not registration acknowledgements. No tools of its own,
## not spawned by core — run it on demand while a harness is up:
##
##   ./var/bin/cli catalog                        # components + tools
##   ./var/bin/cli call <tool> '<json args>'      # dispatch, print result
##   ./var/bin/cli wait <component> [<secs>]      # wait for registration
##   ./var/bin/cli install <repo>[@<ref>]         # plugin_install + verify
##   ./var/bin/cli run '<prompt>'                 # headless turn, NDJSON out
##
## Every command exits 0 on success, non-zero on failure — CI-friendly.
## The bus comes from NIF_NATS_URL, then the harness's var/nats-url
## discovery file, then nats://127.0.0.1:4222.
##
## `run` is the native headless turn driver (docs/MANUAL.md "Headless turns",
## issue #124): it owns or attaches to exactly one harness, streams the turn's
## events as NDJSON on stdout with diagnostics on stderr, prints one
## authoritative result line (reply, outcome, turnId, per-turn usage — see
## docs/WIRE.md "Turn usage"), cancels on SIGINT/SIGTERM, and can export the
## complete canonical transcript through the store's cursor paging.

import std/[json, os, osproc, parseopt, re, sets, strtabs, strutils, tables,
            times, monotimes]
import natsnim
import envelope
import dotenv

when defined(posix):
  import std/posix
import subjects

var components = initTable[string, seq[string]]()  ## component -> tools
var toolIndex = initTable[string, string]()        ## tool -> component
var servingRoot = ""                               ## harness root the bus serves
var servingHash = ""                               ## its git revision

proc resolveBusUrl(): string =
  ## NIF_NATS_URL wins; otherwise follow the harness's discovery file so a
  ## randomly-port bus still answers, defaulting to the canonical 4222
  ## (SDK's resolveNatsUrl — the same order every client follows).
  resolveNatsUrl()

proc refreshCatalog(nc: NatsConnection, timeoutMs = 5_000): bool =
  ## Core owns registration acceptance. Replace both indexes on every read;
  ## a failed read must not leave stale entries available as proof of success.
  components.clear()
  toolIndex.clear()
  let data = callEnvelope("catalog", %*{"op": "components"}).encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn, "svc.core.call".cstring,
                                  data.cstring, data.len.cint, timeoutMs.int64)
  if st != NATS_OK: return false
  defer: natsMsg_Destroy(msg)
  try:
    let r = decode($natsMsg_GetData(msg))
    let snapshot = r.args{"components"}
    if r.kind != ekResult or snapshot == nil or snapshot.kind != JObject:
      return false
    ## Which harness is answering — the clone is the home of an instance, and
    ## the cli has no attach-time identity check (it trusts the discovery
    ## file), so surfacing root + gitHash here is how a mixup becomes
    ## visible instead of silent.
    servingRoot = r.args{"root"}.getStr("")
    servingHash = r.args{"gitHash"}.getStr("")
    var accepted = initTable[string, seq[string]]()
    var owners = initTable[string, string]()
    for name, tools in snapshot:
      if tools.kind != JArray: return false
      var ts: seq[string] = @[]
      for t in tools:
        if t.kind != JString: return false
        let tname = t.getStr("")
        if tname.len == 0: continue
        ts.add(tname)
        owners[tname] = name
      accepted[name] = ts
    components = accepted
    toolIndex = owners
    return true
  except CatchableError:
    return false

proc waitForRegistration(nc: NatsConnection, name: string, secs: int,
                         isTool = false): bool =
  ## Poll the authoritative snapshot; raw reg.* never grants membership.
  ## Bound each request by the remaining wait. A zero-second wait performs
  ## one bounded snapshot read, without a final unconfirmed cache lookup.
  let deadline = getMonoTime() + initDuration(seconds = max(0, secs))
  while true:
    let remaining = (deadline - getMonoTime()).inMilliseconds
    # A request fired with almost no time left cannot be answered in time;
    # publishing one anyway leaks it onto svc.core.call to confuse the next
    # caller (timer jitter makes this reachable even for a 1s wait).
    if secs > 0 and remaining < 100: return false
    let timeoutMs = if secs <= 0: 5_000
                    else: int(max(1'i64, min(5_000'i64, remaining)))
    if refreshCatalog(nc, timeoutMs):
      if isTool:
        if toolIndex.hasKey(name): return true
      elif components.hasKey(name):
        return true
    let left = (deadline - getMonoTime()).inMilliseconds
    if left <= 0: return false
    sleep(int(min(200'i64, left)))

proc waitForComponent(nc: NatsConnection, comp: string, secs: int): bool =
  waitForRegistration(nc, comp, secs)

proc waitForTool(nc: NatsConnection, tool: string, secs: int): bool =
  waitForRegistration(nc, tool, secs, isTool = true)

proc callTool(nc: NatsConnection, tool: string, args: JsonNode,
              timeoutMs: int): JsonNode =
  ## Dispatch a tool call to whatever component provides it. The catalog
  ## must have confirmed core acceptance (waitForTool) before calling.
  let comp = toolIndex.getOrDefault(tool)
  if comp.len == 0:
    raise newException(ValueError, "no component provides tool '" & tool & "'")
  let data = callEnvelope(tool, args).encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn,
    ("svc." & comp & ".call").cstring, data.cstring, data.len.cint,
    timeoutMs.int64)
  if st == NATS_TIMEOUT:
    raise newException(IOError,
      "call " & tool & " timed out after " & $timeoutMs & "ms")
  if not checkStatus(st):
    raise newException(IOError, "call " & tool & ": " & getErrorString(st))
  let r = decode($natsMsg_GetData(msg))
  natsMsg_Destroy(msg)
  if r.kind == ekError:
    raise newException(ValueError, r.error{"message"}.getStr("component error"))
  return r.args

proc cmdCatalog(nc: NatsConnection): int =
  if not refreshCatalog(nc):
    echo "cli: cannot read core catalog — is a harness up?"
    return 1
  if servingRoot.len > 0:
    let hash = if servingHash.len > 0: servingHash else: "unknown"
    echo "# harness: " & servingRoot & " @ " & hash
  if components.len == 0:
    echo "cli: catalog empty — is a harness up?"
    return 1
  for comp, tools in components:
    echo comp & ": " & (if tools.len > 0: tools.join(", ") else: "(no tools)")
  return 0

proc cmdCall(nc: NatsConnection,
             tool, argsStr: string, timeoutMs: int): int =
  var args = newJObject()
  if argsStr.len > 0:
    try:
      args = argsStr.parseJson()
    except CatchableError as e:
      echo "cli: bad JSON args: " & e.msg
      return 2
  if not waitForTool(nc, tool, 60):
    echo "cli: no component provides tool '" & tool & "' (within 60s)"
    return 1
  try:
    let r = callTool(nc, tool, args, timeoutMs)
    echo $r
  except CatchableError as e:
    echo "cli: " & e.msg
    return 1
  return 0

proc cmdInstall(nc: NatsConnection, repoRef: string): int =
  ## plugin_install, then wait for every spawned service component to
  ## register. Interactive components are verified by their successful build.
  var repo = repoRef
  var version = ""
  let at = repo.rfind('@')
  if at > 0:
    version = repo[at + 1 .. ^1]
    repo = repo[0 ..< at]
  echo "cli: installing " & repo & (if version.len > 0: "@" & version else: "")
  if not waitForComponent(nc, "plugins", 60):
    echo "cli: FAIL — plugins component never registered"
    return 1
  var inst: JsonNode
  try:
    inst = callTool(nc, "plugin_install", %*{"repo": repo, "version": version},
                    600_000)
  except CatchableError as e:
    echo "cli: plugin_install failed: " & e.msg
    return 1
  echo "cli: plugin_install -> " & $inst
  if not inst{"ok"}.getBool(false):
    # plugin_install refused as a whole (no component could be installed —
    # e.g. a spawn whose registration core rejected). Name the reason(s)
    # before the marker, so a CI log says why instead of only that it did.
    let why = inst{"error"}.getStr("plugin_install failed")
    echo "cli: FAIL — " & why
    let comps = inst{"components"}
    if comps != nil and comps.kind == JArray:
      for c in comps:
        let name = c{"name"}.getStr("")
        let err = c{"error"}.getStr("")
        if name.len > 0 and err.len > 0:
          echo "cli: FAIL — " & name & ": " & err
    echo "cli: INSTALL FAILED"
    return 1
  var failed = 0
  for c in inst{"components"}:
    let name = c{"name"}.getStr("")
    if name.len == 0: continue
    if c{"interactive"}.getBool(false):
      if c{"built"}.getStr("").len == 0:
        echo "cli: FAIL — " & name & " was not built: " &
             c{"error"}.getStr("unknown error")
        inc failed
      else:
        echo "cli: " & name & " built at " & c{"binary"}.getStr("") &
             " (interactive; start manually)"
      continue
    if not c{"spawned"}.getBool(false):
      echo "cli: FAIL — " & name & " not spawned: " &
           c{"error"}.getStr("unknown error")
      inc failed
      continue
    if waitForComponent(nc, name, 60):
      echo "cli: " & name & " registered (" &
           $components.getOrDefault(name).len & " tools)"
    else:
      echo "cli: FAIL — " & name & " never registered after spawn"
      inc failed
  if failed > 0:
    echo "cli: INSTALL FAILED"
    return 1
  echo "cli: INSTALL OK"
  return 0

type
  RunOptions = object
    ## The headless driver's inputs (docs/MANUAL.md "Headless turns").
    prompt*: string
    sessionId*: string
    root*: string
    bus*: string
    cwd*: string
    provider*: string
    model*: string
    thinking*: string
    approvalsMode*: string
    exportPath*: string
    exportRequested*: bool
    quiet*: bool
    own*: bool
    timeoutMs*: int
    cancelGraceMs*: int
    mcpSpecs*: seq[JsonNode]   ## --mcp/--mcp-file declarations, applied first
    mcpTimeoutMs*: int

var runCancel = false

proc runUsage() =
  echo "usage: cli run [options] <prompt>"
  echo ""
  echo "Drives exactly one conversation turn and reports it as NDJSON on stdout"
  echo "(diagnostics go to stderr). Attaches to the harness serving this binary's"
  echo "runtime home, or starts one for --root when none answers — never attaches"
  echo "to an unrelated home bus (docs/MANUAL.md \"Headless turns\", issue #124)."
  echo ""
  echo "  --prompt <text>        the turn's content (or the trailing argument)"
  echo "  --session <id>         continue a persisted conversation (default: new id)"
  echo "  --root <dir>           runtime home to own/attach (default: this clone)"
  echo "  --bus <url>            attach to an explicit bus instead of discovery"
  echo "  --own                  start a harness for --root even when one answers"
  echo "  --cwd <dir>            conversation workspace"
  echo "  --provider <name>      conversation provider pin"
  echo "  --model <name>         conversation model override"
  echo "  --thinking <effort>    low|medium|high|max"
  echo "  --approvals <mode>     ask (default) | auto — this conversation's gate"
  echo "  --mcp <json>           declare an MCP server to register before the first"
  echo "                         turn (repeatable). Passed to mcp_add/mcp_edit as-is;"
  echo "                         use ${NAME} references for secrets — the store keeps"
  echo "                         the placeholder and the bridge resolves it, and this"
  echo "                         driver never prints a value"
  echo "  --mcp-file <path>      JSON file with an array of such declarations"
  echo "  --mcp-timeout <secs>   per-server registration budget (default 120)"
  echo "  --export[=<path>]      also write the complete canonical transcript"
  echo "  --quiet                suppress event lines (the result line is always printed)"
  echo "  --timeout <secs>       per-turn budget (default 3600)"
  echo "  --cancel-grace <secs>  how long a cancel waits for the turn to settle (30)"
  echo ""
  echo "Output, one JSON object per line, in order:"
  echo "  {\"type\":\"start\", sessionId, bus, root, owned, servingRoot, caller}"
  echo "  {\"type\":\"event\", subject, data}        every ev.session.<id>.* frame"
  echo "  {\"type\":\"approval\", tool, sessionId, verdict, bootstrap?}"
  echo "  {\"type\":\"mcp\", name, action, ready, component?, tools?, credentials?, warning?, error?}"
  echo "  {\"type\":\"result\", sessionId, turnId, outcome, reply, turnError, usage}"
  echo "  {\"type\":\"export\", path, messages}"
  echo "  {\"type\":\"error\", message}"
  echo ""
  echo "Exit codes: 0 a successful turn, 1 a turn that did not succeed (cancelled,"
  echo "budget or limit exhausted, error), 2 a usage error, 3 a startup/protocol"
  echo "failure (no harness, no answer, export impossible)."

proc onRunSignal(sig: cint) {.noconv.} =
  ## SIGINT/SIGTERM ask for a cancellation: the polling loop publishes the
  ## __cancel control (the documented turn abort) and waits a bounded grace
  ## for the turn to settle and persist.
  runCancel = true

proc ndjson(node: JsonNode) =
  stdout.writeLine($node)
  stdout.flushFile()

proc note(msg: string) =
  stderr.writeLine("cli run: " & msg)
  stderr.flushFile()

proc abortRun(msg: string, sessionId = ""): int =
  ## A startup/protocol failure: the reason must reach a *stdout* consumer —
  ## an orchestrator reads NDJSON, not our stderr — and the exit code says the
  ## stack never ran a turn.
  ndjson(%*{"type": "error", "sessionId": sessionId, "message": msg})
  note(msg)
  3

proc coreRootOf(nc: NatsConnection, timeoutMs = 1_000): string =
  ## The harness root of the core answering this connection ("" when none).
  ## The clone is the home of an instance: a driver attaches only to a bus
  ## whose core serves its own runtime home.
  try:
    let data = callEnvelope("catalog", %*{"op": "list"}).encode()
    var msg: ptr natsMsg
    if natsConnection_Request(addr msg, nc.conn, "svc.core.call".cstring,
                              data.cstring, data.len.cint,
                              timeoutMs.int64) != NATS_OK:
      return ""
    let r = decode($natsMsg_GetData(msg))
    natsMsg_Destroy(msg)
    if r.kind != ekResult: return ""
    return r.args{"root"}.getStr("")
  except CatchableError:
    return ""

proc discoverRoot(url: string): string =
  ## Root served on an already-known bus ("" when nobody answers).
  try:
    var probe = connect(url)
    defer: probe.close()
    return coreRootOf(probe, 1_500)
  except CatchableError:
    return ""

proc spawnCoreFor(root, bus: string): Process =
  ## Start the harness that OWNS `root`. NIF_AUTOSTART=1 is the UI-detached
  ## lifecycle: the core exits by itself once its last interactive client
  ## (this driver) departs, so the owned stack cleans itself up.
  let coreBin = root / "var" / "bin" / "niffler"
  if not fileExists(coreBin):
    raise newException(IOError,
      "no harness running and core binary missing: " & coreBin &
      " — build it with `make build`, or point --root at a checkout that has one")
  var env = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs(): env[k] = v
  env["NIF_ROOT"] = root
  env["NIF_AUTOSTART"] = "1"
  # An explicit bus target travels with the child: the harness we own must
  # serve the same bus (and runtime home) this driver was pointed at.
  if bus.len > 0: env["NIF_NATS_URL"] = bus
  startProcess(coreBin, workingDir = root, env = env,
               options = {poUsePath, poDaemon})

proc clientPublish(nc: NatsConnection, name: string) =
  ## Register as an interactive client: this is what keeps the harness we
  ## spawned alive for the whole turn (an autostarted core exits after its
  ## boot grace when no client ever arrives) and what routes this turn's
  ## approval questions to us instead of nowhere.
  nc.publish("reg.publish", $(%*{"name": name, "version": "0.1.0",
                                 "pid": getCurrentProcessId(),
                                 "tools": newJArray(), "client": true}))

proc isSuccess(turn: JsonNode): bool =
  turn != nil and turn{"error"} == nil and
    turn{"outcome"}.getStr("") == "success" and
    turn{"turnError"}.getStr("").len == 0

proc exportTranscript(nc: NatsConnection, convId, path: string): int =
  ## Write the complete canonical transcript through the store's cursor paging
  ## (never the trimmed provider projection): one NDJSON record per stored
  ## message, in order, paging with `after` until the store says no more.
  if not refreshCatalog(nc):
    raise newException(IOError, "cannot read the catalog")
  if toolIndex.getOrDefault("list").len == 0:
    raise newException(IOError, "no store is serving this harness")
  createDir(path.parentDir())
  let f = open(path, fmWrite)
  defer: f.close()
  var after = ""
  result = 0
  while true:
    var args = %*{"kind": "message", "idPrefix": convId & ":",
                  "limit": 1000}
    if after.len > 0: args["after"] = %after
    let page = callTool(nc, "list", args, 60_000)
    let items = page{"items"}
    if items != nil and items.kind == JArray:
      for item in items:
        f.writeLine($(%*{"id": item{"id"}.getStr(""),
                         "message": item{"value"}}))
        inc result
    let hasMore = page{"hasMore"}.getBool(false)
    let nextAfter = page{"nextAfter"}.getStr("")
    if not hasMore or nextAfter.len == 0 or nextAfter == after:
      break
    after = nextAfter

let envRefRe = re"""\$\{([A-Za-z_][A-Za-z0-9_]*)\}"""

type
  Bootstrap = object
    ## The MCP bootstrap window (`cli run --mcp`). It exists because a
    ## declared server has to be registered BEFORE the conversation's first
    ## turn (that turn freezes the direct toolset), which means the driver
    ## makes calls outside a turn — and those calls provoke approval
    ## questions that only the driver can answer.
    nc: NatsConnection
    caller: string
    declared: seq[string]        ## server names the command line declared
    directed: ptr natsSubscription
    broadcast: ptr natsSubscription

proc envRefNames(node: JsonNode): seq[string] =
  ## The credential NAMES a declaration references as ${NAME} (env values,
  ## headers, url). Values are never read, echoed or resolved here: the store
  ## keeps the placeholder and the bridge resolves it at connect time, so a
  ## secret never reaches the transcript, the store, or this driver's output.
  var seen = initHashSet[string]()
  var found: seq[string] = @[]
  proc scan(s: string) =
    if s.len == 0: return
    for m in findAll(s, envRefRe):
      let name = m[2 ..< m.len - 1]
      # containsOrIncl answers "already contained" — the FIRST sighting is the
      # one to report, so the name is added when it was NOT already seen.
      if not seen.containsOrIncl(name): found.add(name)
  for field in ["env", "headers"]:
    let m = node{field}
    if m != nil and m.kind == JObject:
      # .pairs, not `items`: std/json's items iterator is JArray-only, so a
      # two-variable loop over a JObject must say so explicitly.
      for key, value in m.pairs: scan(value.getStr(""))
  scan(node{"url"}.getStr(""))
  result = found

proc noteMcp(name, action: string, payload: JsonNode) =
  ## One NDJSON line per declared server. Only names, counters and credential
  ## REFERENCES are ever printed — never a declaration's values.
  var ev = %*{"type": "mcp", "name": name, "action": action}
  for key in ["ready", "component", "tools", "warning", "error", "enabled"]:
    if payload != nil and payload{key} != nil: ev[key] = payload{key}
  if payload != nil and payload{"credentials"} != nil:
    ev["credentials"] = payload{"credentials"}
  ndjson(ev)

proc approveOrDeny(b: Bootstrap, payload: JsonNode, bootstrap: bool) =
  ## Answer one approval question. Inside the bootstrap window the operator's
  ## own command line IS the approval — but only for exactly what it declared
  ## (the manager call for that server and the bridge spawn it implies); a
  ## turn's questions are denied, because a headless driver cannot ask a human
  ## (the harness's fail-closed rule, made visible as a `verdict: deny` line).
  let tool = payload{"tool"}.getStr("")
  var grant = false
  if bootstrap:
    let declaredName = payload{"args"}{"name"}.getStr("")
    case tool
    of "mcp_add", "mcp_edit": grant = declaredName in b.declared
    of "spawn", "kill":
      # The manager's bridge lifecycle: a fresh registration spawns the
      # bridge, a refresh kills the old one first. `remove` is deliberately
      # NOT in here — a --mcp declaration creates or refreshes, never deletes.
      grant = declaredName.startsWith("mcp-") and
              declaredName[4 .. ^1] in b.declared
    else: grant = false
  let id = payload{"id"}.getStr("")
  b.nc.publish("ev.approval.reply", Envelope(v: 1, id: newId(), kind: ekEvent,
    payload: %*{"id": id, "ack": true}).encode())
  b.nc.publish("ev.approval.reply", Envelope(v: 1, id: newId(), kind: ekEvent,
    payload: %*{"id": id, "ok": grant}).encode())
  let verdict = if grant: "grant" else: "deny"
  var ev = %*{"type": "approval", "tool": tool,
              "sessionId": payload{"sessionId"}.getStr(""),
              "verdict": verdict}
  if bootstrap: ev["bootstrap"] = %true
  ndjson(ev)

proc serviceApprovals(b: Bootstrap, bootstrap: bool): int =
  ## Drain and answer every pending question on both lanes. The broadcast lane
  ## matters because the manager's own `core.spawn` carries no caller: core
  ## offers that question to any attached interactive client, which is exactly
  ## what the driver is during bootstrap.
  var msg: ptr natsMsg
  for sub in [b.directed, b.broadcast]:
    if sub == nil: continue
    while natsSubscription_NextMsg(addr msg, sub, 0) == NATS_OK:
      let raw = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      try:
        b.approveOrDeny(decode(raw).payload, bootstrap)
        inc result
      except CatchableError:
        discard

proc callCore(b: Bootstrap, tool: string, args: JsonNode,
              timeoutMs: int): JsonNode =
  ## One component call through the `invoke` gateway on svc.core.call, while
  ## servicing approvals: a bootstrap dispatch is itself gated (mcp_add/mcp_edit
  ## are approval: always) and spawns the bridge through a second gated call.
  ## `invoke` — not a direct svc.<component>.call — is what keeps the gate,
  ## the schema check and the on-demand reachability rules in the path; that is
  ## the whole point of bootstrapping through the harness instead of around it.
  let inbox = "_INBOX.cli-mcp." & newId()
  var replySub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr replySub, b.nc.conn,
                                                  inbox.cstring)):
    return %*{"error": "cannot subscribe " & inbox}
  defer: natsSubscription_Destroy(replySub)
  let data = callEnvelope("invoke",
                          %*{"tool": tool, "arguments": args},
                          b.caller).encode()
  if not checkStatus(natsConnection_PublishRequest(b.nc.conn,
                                                   "svc.core.call".cstring,
                                                   inbox.cstring, data.cstring,
                                                   data.len.cint)):
    return %*{"error": "cannot publish " & tool}
  let deadline = epochTime() + timeoutMs.float / 1000.0
  var msg: ptr natsMsg
  while epochTime() < deadline:
    discard b.serviceApprovals(true)
    if natsSubscription_NextMsg(addr msg, replySub, 20) == NATS_OK:
      let raw = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      try:
        let r = decode(raw)
        return if r.kind == ekError:
                 %*{"error": r.error{"message"}.getStr("component error")}
               else: r.args
      except CatchableError as e:
        return %*{"error": "undecodable reply: " & e.msg}
  %*{"error": "the harness did not answer " & tool & " within " &
               $(timeoutMs div 1000) & "s"}

proc waitBridge(nc: NatsConnection, name: string,
                deadline: float): tuple[ready: bool, tools: int] =
  ## Readiness is membership in core's accepted catalog, not a spawn reply:
  ## the bridge registers itself (and its MCP tools) once the server answers.
  let component = "mcp-" & name
  while epochTime() < deadline:
    if refreshCatalog(nc, 2_000) and components.hasKey(component):
      return (true, components.getOrDefault(component).len)
    sleep(250)
  (false, 0)

proc bootstrapMcp(b: Bootstrap, specs: seq[JsonNode],
                  timeoutMs: int): int =
  ## Register every declared server and wait for its bridge. Returns 0, or the
  ## startup exit code when a declared server could not be made ready — a
  ## silently thinner toolset is exactly the failure this exists to prevent.
  if not waitForComponent(b.nc, "mcp", 20):
    for spec in specs:
      noteMcp(spec{"name"}.getStr(""), "none",
              %*{"enabled": true,
                 "error": "no mcp component is registered on this harness " &
                          "(add it to the manifest and `make build`, or " &
                          "core.spawn it)"})
    return 3
  var existing = initHashSet[string]()
  try:
    let listing = b.callCore("mcp_servers", %*{}, 60_000)
    for key in ["servers", "items"]:
      let arr = listing{key}
      if arr != nil and arr.kind == JArray:
        for item in arr:
          let n = item{"name"}.getStr("")
          if n.len > 0: existing.incl(n)
  except CatchableError:
    discard
  var failed = false
  for spec in specs:
    let name = spec{"name"}.getStr("")
    let credentials = spec.envRefNames()
    let action = if existing.contains(name): "mcp_edit" else: "mcp_add"
    var report = %*{"credentials": %credentials}
    let res = b.callCore(action, spec, timeoutMs)
    if res{"error"} != nil or not res{"ok"}.getBool(false):
      report["error"] = %(if res{"error"} != nil: res{"error"}.getStr("")
                          else: "mcp " & action & " failed")
      noteMcp(name, action, report)
      failed = true
      continue
    if res{"warning"} != nil: report["warning"] = res{"warning"}
    if spec{"enabled"} != nil and not spec{"enabled"}.getBool(true):
      # A parked declaration: stored, no probe, no bridge — readiness is
      # deliberately false, and that is not a failure.
      report["ready"] = %false
      report["enabled"] = %false
      noteMcp(name, action, report)
      continue
    let ready = waitBridge(b.nc, name,
                           epochTime() + timeoutMs.float / 1000.0)
    report["ready"] = %ready.ready
    report["component"] = %("mcp-" & name)
    report["tools"] = %ready.tools
    if not ready.ready:
      report["error"] = %("the bridge for " & name &
        " did not register within " & $(timeoutMs div 1000) & "s")
      noteMcp(name, action, report)
      failed = true
      continue
    noteMcp(name, action, report)
  if failed: 3 else: 0

proc cmdRun(opts: RunOptions): int =
  let rtRoot = if opts.root.len > 0: opts.root else: harnessRoot()
  let explicitBus = if opts.bus.len > 0: opts.bus else: getEnv("NIF_NATS_URL")
  var bus = ""
  var owned = false
  if explicitBus.len > 0 and not opts.own:
    bus = explicitBus
  elif not opts.own:
    # Discovery: attach only to a core serving OUR runtime home.
    let disc = rtRoot / "var" / "nats-url"
    if fileExists(disc):
      let u = readFile(disc).strip()
      if u.len > 0 and discoverRoot(u) == rtRoot:
        bus = u
  if bus.len == 0:
    var child: Process = nil
    try:
      child = spawnCoreFor(rtRoot, explicitBus)
    except CatchableError as e:
      return abortRun(e.msg)
    owned = true
    note("starting a harness for " & rtRoot & " (owned; it exits when this driver leaves)")
    let deadline = epochTime() + 30.0
    while bus.len == 0 and epochTime() < deadline:
      if child.peekExitCode() != -1:
        return abortRun("the spawned harness exited immediately (code " &
                        $child.peekExitCode() & ") — see " & rtRoot /
                        "var" / "logs")
      let disc = rtRoot / "var" / "nats-url"
      if fileExists(disc):
        let u = readFile(disc).strip()
        if u.len > 0 and discoverRoot(u) == rtRoot:
          bus = u
      if bus.len == 0: sleep(200)
    if bus.len == 0:
      return abortRun("the harness started for " & rtRoot &
                      " did not answer within 30s")

  var nc: NatsConnection
  try:
    nc = connect(bus)
  except CatchableError as e:
    return abortRun("cannot connect to " & bus & ": " & e.msg)
  var closed = false
  proc hangUp() =
    if closed: return
    closed = true
    nc.close()
  defer: hangUp()

  let servingRoot = coreRootOf(nc, 5_000)
  if servingRoot.len == 0:
    return abortRun("no harness answers on " & bus)
  if servingRoot != rtRoot and explicitBus.len == 0:
    return abortRun("refusing to attach: " & bus & " is served by " &
                    servingRoot & ", not " & rtRoot &
                    " — pass --bus to attach deliberately")
  if servingRoot != rtRoot:
    note("WARNING attaching to a harness of " & servingRoot & " (" & rtRoot & ")")

  let sid = if opts.sessionId.len > 0: opts.sessionId else: "cli-" & newId()
  let caller = "cli-run-" & $getCurrentProcessId()
  var declared: seq[string] = @[]
  for spec in opts.mcpSpecs: declared.add(spec{"name"}.getStr(""))
  # Owned mode registers as an interactive client for the whole run (it is what
  # keeps the harness we started alive); attach mode registers only for the
  # bootstrap window, and only when there is something to bootstrap: the
  # manager's own `core.spawn` is offered to any attached client, and being one
  # must not change how the harness gates everybody else's questions.
  var clientUp = false
  proc ensureClient() =
    if clientUp: return
    clientPublish(nc, caller)
    clientUp = true
    sleep(50)
  proc dropClient() =
    if not clientUp: return
    nc.publish("reg.depart", $(%*{"name": caller,
                                   "pid": getCurrentProcessId()}))
    clientUp = false
    sleep(50)
  if owned: ensureClient()
  var startLine = %*{"type": "start", "sessionId": sid, "bus": bus,
                     "root": rtRoot, "servingRoot": servingRoot,
                     "owned": owned, "caller": caller}
  if declared.len > 0: startLine["mcp"] = %declared
  ndjson(startLine)

  when defined(posix):
    discard signal(SIGINT, onRunSignal)
    discard signal(SIGTERM, onRunSignal)

  let safeSid = sanitizeSessionId(sid)
  let evSubject = "ev.session." & safeSid & ".>"
  let apprSubject = "svc.approval." & caller & ".request"
  let steerSubjectStr = "svc.session." & safeSid & ".steer"
  var evSub: ptr natsSubscription
  var replySub: ptr natsSubscription
  if not checkStatus(natsConnection_SubscribeSync(addr evSub, nc.conn,
                                                  evSubject.cstring)):
    return abortRun("cannot subscribe " & evSubject)
  defer: natsSubscription_Destroy(evSub)
  var boot = Bootstrap(nc: nc, caller: caller, declared: declared)
  if not checkStatus(natsConnection_SubscribeSync(addr boot.directed, nc.conn,
                                                  apprSubject.cstring)):
    return abortRun("cannot subscribe " & apprSubject)
  defer: natsSubscription_Destroy(boot.directed)
  if declared.len > 0:
    if not checkStatus(natsConnection_SubscribeSync(addr boot.broadcast,
                                                    nc.conn,
                                                    "ev.approval.request".cstring)):
      return abortRun("cannot subscribe ev.approval.request")
    defer: natsSubscription_Destroy(boot.broadcast)
    ensureClient()
    let rc = bootstrapMcp(boot, opts.mcpSpecs, opts.mcpTimeoutMs)
    if rc != 0:
      dropClient()
      return rc
    if not owned: dropClient()
  let inbox = "_INBOX.cli-run." & newId()
  if not checkStatus(natsConnection_SubscribeSync(addr replySub, nc.conn,
                                                  inbox.cstring)):
    return abortRun("cannot subscribe " & inbox)
  defer: natsSubscription_Destroy(replySub)

  var args = %*{"sessionId": sid, "content": opts.prompt}
  if opts.cwd.len > 0: args["cwd"] = %opts.cwd
  if opts.provider.len > 0: args["provider"] = %opts.provider
  if opts.model.len > 0: args["model"] = %opts.model
  if opts.thinking.len > 0: args["thinking"] = %opts.thinking
  if opts.approvalsMode.len > 0: args["approvals"] = %opts.approvalsMode
  let data = callEnvelope("session", args, caller).encode()
  if not checkStatus(natsConnection_PublishRequest(nc.conn,
                                                   "svc.core.call".cstring,
                                                   inbox.cstring, data.cstring,
                                                   data.len.cint)):
    return abortRun("cannot publish the turn", sid)

  var turnReply: JsonNode = nil
  var cancelSent = false
  var cancelDeadline = 0.0
  let deadline = epochTime() + opts.timeoutMs.float / 1000.0
  var msg: ptr natsMsg
  while turnReply == nil:
    # conversation events first: nothing the turn emits is lost
    while natsSubscription_NextMsg(addr msg, evSub, 0) == NATS_OK:
      let subject = $natsMsg_GetSubject(msg)
      let payload = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      try:
        let env = decode(payload)
        if not opts.quiet:
          ndjson(%*{"type": "event", "subject": subject, "data": env.payload})
      except CatchableError:
        discard
    # approval questions: answer so a gated call FAILS FAST (deny) instead of
    # stalling a headless turn until the gate's timeout. `--approvals auto`
    # never asks in the first place, and the bootstrap window (already closed
    # by now) is the only place this driver ever grants.
    discard boot.serviceApprovals(false)
    if natsSubscription_NextMsg(addr msg, replySub, 20) == NATS_OK:
      let payload = $natsMsg_GetData(msg)
      natsMsg_Destroy(msg)
      try:
        let r = decode(payload)
        turnReply = if r.kind == ekError:
                      %*{"error": r.error{"message"}.getStr("component error")}
                    else: r.args
      except CatchableError as e:
        turnReply = %*{"error": "undecodable reply: " & e.msg}
      break
    if runCancel and not cancelSent:
      cancelSent = true
      cancelDeadline = epochTime() + opts.cancelGraceMs.float / 1000.0
      note("cancellation requested — aborting the turn")
      nc.publish(steerSubjectStr,
        Envelope(v: 1, id: newId(), kind: ekEvent,
                 payload: %*{"__cancel": true}).encode())
    if cancelSent and epochTime() > cancelDeadline:
      turnReply = %*{"error": "cancelled: the turn did not settle within the " &
                              $opts.cancelGraceMs & "ms grace period"}
      break
    if epochTime() > deadline:
      turnReply = %*{"error": "the turn did not finish within " &
                              $opts.timeoutMs & "ms"}
      break

  if turnReply == nil or turnReply{"error"} != nil:
    let message = if turnReply == nil: "no reply from the harness"
                  else: turnReply{"error"}.getStr("unknown error")
    ndjson(%*{"type": "error", "sessionId": sid, "message": message})
    if owned: dropClient()
    return 3

  # Export AFTER the turn settles: the transcript must contain the turn that
  # just ran, including a cancelled or failed one.
  if opts.exportRequested:
    let path = if opts.exportPath.len > 0: opts.exportPath
               else: rtRoot / "var" / "exports" / (safeSid & ".jsonl")
    try:
      let count = exportTranscript(nc, sid, path)
      ndjson(%*{"type": "export", "sessionId": sid, "path": path,
                "messages": count})
    except CatchableError as e:
      if owned: dropClient()
      return abortRun("transcript export failed: " & e.msg, sid)

  ndjson(%*{"type": "result", "sessionId": sid,
            "turnId": turnReply{"turnId"}.getStr(""),
            "outcome": turnReply{"outcome"}.getStr(""),
            "reply": turnReply{"reply"}.getStr(""),
            "turnError": turnReply{"turnError"}.getStr(""),
            "usage": turnReply{"usage"}})
  let ok = isSuccess(turnReply)
  if owned:
    # Leave the client registry clean: the harness we started exits on its own
    # once its last interactive client is gone (that is the owned-stack
    # cleanup, and it touches nothing we did not start).
    dropClient()
    note("owned harness will exit once idle (" & rtRoot & ")")
  if ok: 0 else: 1

proc usage() =
  echo "usage: cli [--timeout <secs>] <catalog|call|wait|install|run> ..."
  echo "  catalog                                   list components and tools"
  echo "  call <tool> '<json args>'                 dispatch a tool call"
  echo "  wait <component> [<secs>]                 wait for registration"
  echo "  install <repo>[@<ref>]                    plugin_install + verify"
  echo "  run [options] <prompt>                    headless turn, NDJSON on stdout"
  echo "                                            (cli run --help for the options)"

proc main() =
  var p = initOptParser()
  var positional: seq[string] = @[]
  var timeoutMs = 30_000
  var flags = initTable[string, string]()
  var switches = initTable[string, bool]()
  var mcpDecls: seq[string] = @[]   # --mcp is repeatable, so not a table entry
  var mcpFiles: seq[string] = @[]
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      positional.add(p.key)
    of cmdLongOption, cmdShortOption:
      case p.key
      of "timeout", "t":
        var val = p.val
        if val.len == 0:
          # Space-separated form (`--timeout 5`): parseopt leaves val empty
          # and the value arrives as the next token — consume it here, so
          # the documented spelling works and "5" never lands in the
          # positional command arguments (A567).
          p.next()
          if p.kind == cmdArgument:
            val = p.key
          else:
            echo "cli: --timeout needs a value (use --timeout=<secs>)"
            quit(2)
        try: timeoutMs = val.parseInt() * 1000
        except ValueError:
          echo "cli: bad --timeout value: " & val
          quit(2)
      of "mcp", "mcp-file":
        var val = p.val
        if val.len == 0:
          p.next()
          if p.kind == cmdArgument: val = p.key
          else:
            echo "cli: --" & p.key & " needs a value (use --" & p.key & "=<v>)"
            quit(2)
        if p.key == "mcp": mcpDecls.add(val)
        else: mcpFiles.add(val)
      of "session", "root", "bus", "cwd", "provider", "model",
         "thinking", "approvals", "prompt", "cancel-grace", "export",
         "mcp-timeout":
        # `cli run` options (docs/MANUAL.md "Headless turns"). `--export` is
        # the one optional-value flag: bare, it writes the default path.
        var val = p.val
        if val.len == 0 and p.key != "export" and p.kind == cmdLongOption:
          p.next()
          if p.kind == cmdArgument: val = p.key
          else:
            echo "cli: --" & p.key & " needs a value (use --" & p.key & "=<v>)"
            quit(2)
        flags[p.key] = val
      of "quiet", "own", "help", "h":
        switches[p.key] = true
      else:
        echo "cli: unknown option --" & p.key
        quit(2)
  if positional.len == 0:
    usage()
    quit(2)

  loadDotEnv(".env", rootDir() / ".env")

  # `cli run` owns or attaches to its own bus, so it never shares the plain
  # request/reply connection the other commands use.
  if positional[0] == "run":
    if switches.getOrDefault("help") or switches.getOrDefault("h"):
      runUsage()
      quit(0)
    var opts = RunOptions(quiet: switches.getOrDefault("quiet"),
                          own: switches.getOrDefault("own"),
                          timeoutMs: 3_600_000, cancelGraceMs: 30_000,
                          mcpTimeoutMs: 120_000,
                          exportRequested: flags.hasKey("export"))
    # --mcp / --mcp-file declarations: every one is validated here, BEFORE any
    # harness work, so a typo costs a usage error instead of a half-bound
    # bootstrap. Values are passed through untouched (they may hold ${NAME}
    # references; the driver never resolves or prints them).
    for raw in mcpDecls:
      try:
        let node = parseJson(raw)
        if node.kind != JObject or node{"name"}.getStr("").len == 0:
          echo "cli: --mcp needs a JSON object with a non-empty \"name\""
          quit(2)
        opts.mcpSpecs.add(node)
      except CatchableError as e:
        echo "cli: --mcp is not valid JSON: " & e.msg
        quit(2)
    for path in mcpFiles:
      if not fileExists(path):
        echo "cli: --mcp-file: no such file: " & path
        quit(2)
      try:
        let node = parseJson(readFile(path))
        let arr = if node.kind == JArray: node else: node{"servers"}
        if arr == nil or arr.kind != JArray:
          echo "cli: --mcp-file: expected a JSON array (or {\"servers\": [...]})"
          quit(2)
        for spec in arr:
          if spec.kind != JObject or spec{"name"}.getStr("").len == 0:
            echo "cli: --mcp-file: every entry needs a non-empty \"name\""
            quit(2)
          opts.mcpSpecs.add(spec)
      except CatchableError as e:
        echo "cli: --mcp-file: cannot read " & path & ": " & e.msg
        quit(2)
    var duplicate = initHashSet[string]()
    for spec in opts.mcpSpecs:
      if duplicate.containsOrIncl(spec{"name"}.getStr("")):
        echo "cli: --mcp declares server '" & spec{"name"}.getStr("") &
             "' twice"
        quit(2)
    if flags.hasKey("mcp-timeout"):
      try: opts.mcpTimeoutMs = parseInt(flags["mcp-timeout"]) * 1000
      except ValueError:
        echo "cli: bad --mcp-timeout value: " & flags["mcp-timeout"]
        quit(2)
    for key in ["root", "bus", "cwd", "provider", "model", "thinking",
                "approvals", "session", "export"]:
      if not flags.hasKey(key): continue
      case key
      of "root": opts.root = flags[key]
      of "bus": opts.bus = flags[key]
      of "cwd": opts.cwd = flags[key]
      of "provider": opts.provider = flags[key]
      of "model": opts.model = flags[key]
      of "thinking": opts.thinking = flags[key]
      of "approvals": opts.approvalsMode = flags[key]
      of "session": opts.sessionId = flags[key]
      of "export": opts.exportPath = flags[key]
      else: discard
    if flags.hasKey("prompt"):
      opts.prompt = flags["prompt"]
    elif positional.len > 1:
      opts.prompt = positional[1 .. ^1].join(" ")
    if flags.hasKey("cancel-grace"):
      try: opts.cancelGraceMs = parseInt(flags["cancel-grace"]) * 1000
      except ValueError:
        echo "cli: bad --cancel-grace value: " & flags["cancel-grace"]
        quit(2)
    if timeoutMs != 30_000:
      # --timeout is the turn budget for `run` (seconds)
      opts.timeoutMs = timeoutMs
    if opts.approvalsMode.len > 0 and
        opts.approvalsMode notin ["ask", "auto"]:
      echo "cli: --approvals takes ask or auto"
      quit(2)
    if opts.prompt.len == 0:
      echo "cli: run needs a prompt (positional or --prompt)"
      runUsage()
      quit(2)
    quit(cmdRun(opts))

  let url = resolveBusUrl()
  var nc: NatsConnection
  try:
    nc = connect(url)
  except CatchableError:
    echo "cli: cannot connect to " & url & " — is the harness running?"
    quit(1)
  case positional[0]
  of "catalog":
    quit(cmdCatalog(nc))
  of "call":
    if positional.len < 2:
      usage(); quit(2)
    let argsStr = if positional.len >= 3: positional[2] else: ""
    quit(cmdCall(nc, positional[1], argsStr, timeoutMs))
  of "wait":
    if positional.len < 2:
      usage(); quit(2)
    let secs = block:
      # A non-numeric positional is a usage error, not a crash (A568): the
      # unguarded parseInt used to die with an uncaught ValueError.
      if positional.len >= 3:
        try: parseInt(positional[2])
        except ValueError:
          echo "cli: wait: seconds must be a number, got '" &
               positional[2] & "'"
          usage()
          quit(2)
      else: 60
    if waitForComponent(nc, positional[1], secs):
      echo "cli: " & positional[1] & " registered"
      quit(0)
    echo "cli: " & positional[1] & " not registered within " & $secs & "s"
    quit(1)
  of "install":
    if positional.len < 2:
      usage(); quit(2)
    quit(cmdInstall(nc, positional[1]))
  else:
    echo "cli: unknown command '" & positional[0] & "'"
    usage()
    quit(2)

when isMainModule:
  main()
