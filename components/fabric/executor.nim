## fabric-exec — per-program guest executor child (docs/research/FABRIC.md Phase 2).
##
## One process per program: embeds the Nim VM (compiler/nimeval), evaluates
## the guest program against the fabricguest bridge, and speaks a framed
## single-line JSON protocol on stdio:
##
##   parent -> child (stdin, one line):  {"code": ..., "strings": {...}}
##   child -> parent (stdout, lines):    {"t":"req","id","tool","argsJson"}
##                                       {"t":"log","s"}
##                                       {"t":"result","ok","value"|"diagnostics"}
##   parent -> child (stdin, per req):   {"t":"resp","id","ok","result"| "error"}
##
## The child holds NO NATS connection and NO credentials: every tool call
## crosses stdio to the fabric parent, which owns the bus and routes through
## the session proxy (approval, budgets, audit). Compiled WITHOUT -d:nimcore
## so the VM's gorge/staticExec magics die at runtime; guests are source-
## linted by the parent on top (governance posture, not a sandbox claim).
##
## Build: needs the compiler sources on the Nim search path (see Makefile):
##   nim c --path:sdk --path:<toolchain>/compiler -o:var/bin/fabric-exec executor.nim

import std/[json, os, posix, strutils, streams, tables]
import
  nimeval, llstream, vmdef, vm, options

const guestDir = currentSourcePath().parentDir() / "fabricguest"
  ## resolved at compile time; the executor is built in place (same
  ## assumption as every shipped component)

type FinishRequest = object of CatchableError
  ## raised by the native `finish` bridge; caught at top level as the result

var stdinFs = stdin
var callCount = 0
let stringsTable = cast[ptr Table[string, string]](
  alloc0(sizeof(Table[string, string])))
  ## raw-pointer global: the gcsafe native callbacks read it, and a plain
  ## GC'd global would trip Nim's gcsafe analysis in the callback type

proc emitLine(j: JsonNode) =
  stdout.writeLine($j)
  stdout.flushFile()

proc readResp(id: string): JsonNode =
  ## Read framed resp lines from the parent until ours arrives.
  while true:
    if stdinFs.endOfFile:
      raise newException(CatchableError, "fabric parent closed the pipe")
    let line = stdinFs.readLine()
    if line.len == 0: continue
    let j = parseJson(line)
    if j{"t"}.getStr("") == "resp" and j{"id"}.getStr("") == id:
      return j

when defined(linux):
  const
    rlimitCpu = cint(0)   # <sys/resource.h> values absent from Nim's posix
    rlimitNproc = cint(6)
    rlimitNofile = cint(7)
    rlimitAs = cint(9)
elif defined(macosx):
  const
    rlimitCpu = cint(0)
    rlimitAs = cint(5)
    rlimitNproc = cint(7)
    rlimitNofile = cint(8)

proc setLimit(resource: cint, value: int) =
  var lim: RLimit
  lim.rlim_cur = value
  lim.rlim_max = value
  discard setrlimit(resource, lim)

proc main =
  # resource cap before anything heavy: the VM's compile+eval allocation
  when defined(linux) or defined(macosx):
    setLimit(rlimitCpu, 300)
    setLimit(rlimitNproc, 0)
    setLimit(rlimitNofile, 64)
    setLimit(rlimitAs, 768 * 1024 * 1024)

  let ctx = parseJson(stdinFs.readLine())
  let code = ctx{"code"}.getStr("")
  if code.len == 0:
    emitLine(%*{"t": "result", "ok": false, "diagnostics": "empty program"})
    return
  for k, v in ctx{"strings"}:
    stringsTable[][k] = v.getStr("")

  let std = findNimStdLibCompileTime()
  let interp = createInterpreter("guest.nim",
    [std, std / "pure", std / "core", guestDir])
  # guest compile/semantic errors print to stderr and quit — the parent
  # captures stderr and surfaces it as diagnostics (no hook needed, and
  # registerErrorHook's ConfigRef collides with stdlib's options module)

  # --- the bridge: guest procs -> framed stdio -> fabric parent -> bus ---
  interp.implementRoutine("fabricguest", "fabricguest", "callTool",
    proc (a: VmArgs) {.gcsafe.} =
      inc callCount
      let id = $callCount
      emitLine(%*{"t": "req", "id": id,
                   "tool": a.getString(0), "argsJson": a.getString(1)})
      let resp = readResp(id)
      if resp{"ok"}.getBool(false):
        a.setResult(resp{"result"}.getStr(""))
      else:
        raise newException(CatchableError,
          "tool '" & a.getString(0) & "' failed: " &
          resp{"error"}.getStr("call failed")))

  interp.implementRoutine("fabricguest", "fabricguest", "finish",
    proc (a: VmArgs) {.gcsafe.} =
      raise newException(FinishRequest, a.getString(0)))

  interp.implementRoutine("fabricguest", "fabricguest", "logg",
    proc (a: VmArgs) {.gcsafe.} =
      emitLine(%*{"t": "log", "s": a.getString(0)}))

  interp.implementRoutine("fabricguest", "fabricguest", "stringArg",
    proc (a: VmArgs) {.gcsafe.} =
      a.setResult(stringsTable[].getOrDefault(a.getString(0), "")))

  try:
    interp.evalScript(llStreamOpen(code))
    emitLine(%*{"t": "result", "ok": false,
                "diagnostics": "program finished without calling finish()"})
  except FinishRequest as e:
    emitLine(%*{"t": "result", "ok": true, "value": e.msg})
  except CatchableError as e:
    emitLine(%*{"t": "result", "ok": false, "diagnostics": e.msg})

when isMainModule:
  main()
