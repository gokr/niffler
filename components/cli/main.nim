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
##
## Every command exits 0 on success, non-zero on failure — CI-friendly.
## The bus comes from NIF_NATS_URL, then the harness's var/nats-url
## discovery file, then nats://127.0.0.1:4222.

import std/[json, os, parseopt, strutils, tables, times, monotimes]
import natswrapper
import envelope
import dotenv
import subjects

var components = initTable[string, seq[string]]()  ## component -> tools
var componentPids = initTable[string, seq[int]]() ## accepted instances
var toolIndex = initTable[string, string]()        ## tool -> component

proc resolveBusUrl(): string =
  ## NIF_NATS_URL wins; otherwise follow the harness's discovery file so a
  ## randomly-port bus still answers, defaulting to the canonical 4222
  ## (SDK's resolveNatsUrl — the same order every client follows).
  resolveNatsUrl()

proc refreshCatalog(nc: NatsConnection, timeoutMs = 5_000, instances = false): bool =
  ## Core owns registration acceptance. Replace all indexes on every read;
  ## a failed read must not leave stale entries available as proof of success.
  components.clear()
  toolIndex.clear()
  componentPids.clear()
  let op = if instances: "snapshot" else: "components"
  let data = callEnvelope("catalog", %*{"op": op}).encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn, "svc.core.call".cstring,
                                  data.cstring, data.len.cint, timeoutMs.int64)
  if st != NATS_OK: return false
  defer: natsMsg_Destroy(msg)
  try:
    let r = decode($natsMsg_GetData(msg))
    var snapshot = r.args{"components"}
    if r.kind != ekResult or snapshot == nil: return false
    var pids = initTable[string, seq[int]]()
    if instances:
      if snapshot.kind != JArray: return false
      let entries = snapshot
      snapshot = newJObject()
      for entry in entries:
        let name = entry{"name"}.getStr("")
        if name.len == 0 or entry{"pids"} == nil or
           entry{"pids"}.kind != JArray or entry{"tools"} == nil or
           entry{"tools"}.kind != JArray: return false
        var ids: seq[int] = @[]
        for pid in entry["pids"]:
          if pid.kind != JInt or pid.getInt() <= 0: return false
          ids.add(pid.getInt())
        pids[name] = ids
        snapshot[name] = newJArray()
        for tool in entry["tools"]:
          if tool{"name"} == nil: return false
          snapshot[name].add(tool["name"])
    if snapshot.kind != JObject: return false
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
    componentPids = pids
    components = accepted
    toolIndex = owners
    return true
  except CatchableError:
    return false

proc waitForRegistration(nc: NatsConnection, name: string, secs: int,
                         isTool = false, expectedPids: seq[int] = @[]): bool =
  ## Poll the authoritative snapshot; raw reg.* never grants membership.
  ## Bound each request by the remaining wait. A zero-second wait performs
  ## one bounded snapshot read, without a final unconfirmed cache lookup.
  let deadline = getMonoTime() + initDuration(seconds = max(0, secs))
  while true:
    let remaining = (deadline - getMonoTime()).inMilliseconds
    let timeoutMs = if secs <= 0: 5_000
                    else: int(max(1'i64, min(5_000'i64, remaining)))
    if refreshCatalog(nc, timeoutMs, instances = expectedPids.len > 0):
      if isTool:
        if toolIndex.hasKey(name): return true
      elif components.hasKey(name):
        var matched = true
        for pid in expectedPids:
          if pid notin componentPids.getOrDefault(name): matched = false
        if matched: return true
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
  ## register its returned process IDs. Interactive components are verified
  ## by their successful build.
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
    var expectedPids: seq[int] = @[]
    let ids = c{"pids"}
    if ids != nil and ids.kind == JArray:
      for pid in ids:
        if pid.kind != JInt or pid.getInt() <= 0:
          expectedPids.setLen(0)
          break
        expectedPids.add(pid.getInt())
    if expectedPids.len == 0:
      echo "cli: FAIL — " & name & " spawn returned no valid instance IDs"
      inc failed
      continue
    if waitForRegistration(nc, name, 60, expectedPids = expectedPids):
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

proc usage() =
  echo "usage: cli [--timeout <secs>] <catalog|call|wait|install> ..."
  echo "  catalog                                   list components and tools"
  echo "  call <tool> '<json args>'                 dispatch a tool call"
  echo "  wait <component> [<secs>]                 wait for registration"
  echo "  install <repo>[@<ref>]                    plugin_install + verify"

proc main() =
  var p = initOptParser()
  var positional: seq[string] = @[]
  var timeoutMs = 30_000
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdArgument:
      positional.add(p.key)
    of cmdLongOption, cmdShortOption:
      case p.key
      of "timeout", "t":
        try: timeoutMs = p.val.parseInt() * 1000
        except ValueError:
          echo "cli: bad --timeout value: " & p.val
          quit(2)
      else:
        echo "cli: unknown option --" & p.key
        quit(2)
  if positional.len == 0:
    usage()
    quit(2)

  loadDotEnv(".env", rootDir() / ".env")
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
    let secs = if positional.len >= 3: parseInt(positional[2]) else: 60
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
