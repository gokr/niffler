## cli component — drive the harness from a terminal or a script.
##
## A standalone bus client (like console): subscribes to reg.* to keep a
## live catalog of components and the tools they register at runtime, and
## can dispatch tool calls request/reply over the bus. No tools of its own,
## not spawned by core — run it on demand while a harness is up:
##
##   ./var/bin/cli catalog                        # components + tools
##   ./var/bin/cli call <tool> '<json args>'      # dispatch, print result
##   ./var/bin/cli wait <component> [<secs>]      # wait for registration
##   ./var/bin/cli install <repo>[@<ref>]         # plugin_install + verify
##
## Every command exits 0 on success, non-zero on failure — CI-friendly.
## The bus defaults to nats://127.0.0.1:4222, override with NIF_NATS_URL.

import std/[json, os, parseopt, strutils, tables, times]
import natswrapper
import envelope
import dotenv

var components = initTable[string, seq[string]]()  ## component -> tools
var toolIndex = initTable[string, string]()        ## tool -> component

proc handleReg(subject, data: string) =
  var node: JsonNode
  try:
    node = data.parseJson()
  except CatchableError:
    return
  let name = node{"name"}.getStr("")
  if name.len == 0: return
  if subject == "reg.publish":
    var tools: seq[string] = @[]
    let ts = node{"tools"}
    if ts != nil:
      for t in ts:
        let tname = t{"name"}.getStr("")
        if tname.len == 0: continue
        tools.add(tname)
        toolIndex[tname] = name
    components[name] = tools
  elif subject == "reg.depart":
    for t in components.getOrDefault(name):
      if toolIndex.getOrDefault(t) == name:
        toolIndex.del(t)
    components.del(name)

proc seedCatalog(nc: NatsConnection) =
  ## The catalog only sees registrations that happen after we connect.
  ## Ask core for the current component→tools mapping so a cli started
  ## against an already-running harness still knows everything.
  let data = callEnvelope("catalog", %*{"op": "components"}).encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn, "svc.core.call".cstring,
                                  data.cstring, data.len.cint, 5_000 * 1_000_000)
  if st != NATS_OK: return
  let r = decode($natsMsg_GetData(msg))
  natsMsg_Destroy(msg)
  if r.kind != ekResult or r.args{"components"} == nil: return
  for name, tools in r.args{"components"}:
    var ts: seq[string] = @[]
    if tools != nil:
      for t in tools:
        let tname = t.getStr("")
        if tname.len == 0: continue
        ts.add(tname)
        toolIndex[tname] = name
    components[name] = ts

proc pump(sub: ptr natsSubscription) =
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, sub, 1)
    if st == NATS_TIMEOUT: break
    if not checkStatus(st): break
    let subject = $natsMsg_GetSubject(msg)
    let data = $natsMsg_GetData(msg)
    natsMsg_Destroy(msg)
    handleReg(subject, data)

proc waitForComponent(nc: NatsConnection, sub: ptr natsSubscription,
                      comp: string, secs: int): bool =
  let deadline = epochTime() + secs.float
  while epochTime() < deadline:
    pump(sub)
    if components.hasKey(comp): return true
    seedCatalog(nc)  # covers registrations we missed (races at startup)
    if components.hasKey(comp): return true
    sleep(200)
  pump(sub)
  return components.hasKey(comp)

proc waitForTool(nc: NatsConnection, sub: ptr natsSubscription,
                 tool: string, secs: int): bool =
  let deadline = epochTime() + secs.float
  while epochTime() < deadline:
    pump(sub)
    if toolIndex.hasKey(tool): return true
    seedCatalog(nc)  # covers registrations we missed (races at startup)
    if toolIndex.hasKey(tool): return true
    sleep(200)
  pump(sub)
  return toolIndex.hasKey(tool)

proc callTool(nc: NatsConnection, tool: string, args: JsonNode,
              timeoutMs: int): JsonNode =
  ## Dispatch a tool call to whatever component provides it. The catalog
  ## must have seen the registration (waitForTool) before calling.
  let comp = toolIndex.getOrDefault(tool)
  if comp.len == 0:
    raise newException(ValueError, "no component provides tool '" & tool & "'")
  let data = callEnvelope(tool, args).encode()
  var msg: ptr natsMsg
  let st = natsConnection_Request(addr msg, nc.conn,
    ("svc." & comp & ".call").cstring, data.cstring, data.len.cint,
    timeoutMs.int64 * 1_000_000)
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

proc cmdCatalog(sub: ptr natsSubscription): int =
  pump(sub)
  if components.len == 0:
    echo "cli: catalog empty — is a harness up?"
    return 1
  for comp, tools in components:
    echo comp & ": " & (if tools.len > 0: tools.join(", ") else: "(no tools)")
  return 0

proc cmdCall(nc: NatsConnection, sub: ptr natsSubscription,
             tool, argsStr: string, timeoutMs: int): int =
  var args = newJObject()
  if argsStr.len > 0:
    try:
      args = argsStr.parseJson()
    except CatchableError as e:
      echo "cli: bad JSON args: " & e.msg
      return 2
  if not waitForTool(nc, sub, tool, 60):
    echo "cli: no component provides tool '" & tool & "' (within 60s)"
    return 1
  try:
    let r = callTool(nc, tool, args, timeoutMs)
    echo $r
  except CatchableError as e:
    echo "cli: " & e.msg
    return 1
  return 0

proc cmdInstall(nc: NatsConnection, sub: ptr natsSubscription,
                repoRef: string): int =
  ## plugin_install, then wait for every spawned component to register —
  ## the end-to-end "does this package work" check.
  var repo = repoRef
  var version = ""
  let at = repo.rfind('@')
  if at > 0:
    version = repo[at + 1 .. ^1]
    repo = repo[0 ..< at]
  echo "cli: installing " & repo & (if version.len > 0: "@" & version else: "")
  if not waitForComponent(nc, sub, "plugins", 60):
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
    if not c{"spawned"}.getBool(false):
      echo "cli: FAIL — " & name & " not spawned: " &
           c{"error"}.getStr("unknown error")
      inc failed
      continue
    if waitForComponent(nc, sub, name, 60):
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

  loadDotEnv(".env", getEnv("NIF_ROOT", ".") / ".env")
  let url = getEnv("NIF_NATS_URL", "nats://127.0.0.1:4222")
  var nc = connect(url)
  var sub: ptr natsSubscription
  let st = natsConnection_SubscribeSync(addr sub, nc.conn, "reg.>".cstring)
  if not checkStatus(st):
    echo "cli: subscribe reg.>: " & getErrorString(st)
    quit(1)
  seedCatalog(nc)

  case positional[0]
  of "catalog":
    quit(cmdCatalog(sub))
  of "call":
    if positional.len < 2:
      usage(); quit(2)
    let argsStr = if positional.len >= 3: positional[2] else: ""
    quit(cmdCall(nc, sub, positional[1], argsStr, timeoutMs))
  of "wait":
    if positional.len < 2:
      usage(); quit(2)
    let secs = if positional.len >= 3: parseInt(positional[2]) else: 60
    if waitForComponent(nc, sub, positional[1], secs):
      echo "cli: " & positional[1] & " registered"
      quit(0)
    echo "cli: " & positional[1] & " not registered within " & $secs & "s"
    quit(1)
  of "install":
    if positional.len < 2:
      usage(); quit(2)
    quit(cmdInstall(nc, sub, positional[1]))
  else:
    echo "cli: unknown command '" & positional[0] & "'"
    usage()
    quit(2)

when isMainModule:
  main()
