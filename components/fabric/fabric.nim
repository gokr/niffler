## fabric component — programmable tool calling (docs/FABRIC.md Phase 2).
##
## One tool, `fabric`: the LLM writes a Nim program (guest) that orchestrates
## tool calls; only the program's finish() value enters the conversation.
## This component owns the bus side: it spawns the fabric-exec child per
## program, serves the child's bridge requests over framed stdio, and routes
## every nested call through the session proxy (svc.session.<id>.tool) so
## approval, budgets and audit apply exactly as for direct tool calls.
## The child holds no credentials and no NATS connection.

import std/[json, os, osproc, posix, selectors, streams, strtabs,
            strutils, times]
import natswrapper
import niffler/sdk

let comp = newComponent("fabric", "0.1.0")

const maxResultChars = 50_000
  ## the conversation sees at most this many chars of the program's value;
  ## oversized results land in var/fabric-artifacts/<run>.json (mode 0600)
  ## and the path is returned instead.

proc sanitizeSessionId(s: string): string =
  ## Mirror of the runner's subject sanitization (core/conversation.nim).
  for c in s:
    result.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: c else: '-')

const bannedTokens = ["staticExec", "staticRead", "gorge", "slurp",
                      "importc", "osproc", "natswrapper", "std/os",
                      "std/net", "std/selectors"]
  ## source lint: auditable policy, not a sandbox claim (docs/FABRIC.md,
  ## threat model). The VM itself also refuses FFI and gorge magics (the
  ## executor is built without -d:nimcore).

proc lint(code: string): string =
  for b in bannedTokens:
    if code.contains(b):
      return "program rejected: '" & b & "' is not allowed in fabric programs"
  return ""

proc readFramed(fd: cint, deadline: float, sel: Selector[cint]): string =
  ## One \\n-terminated line from the child, honoring the deadline. Raw fd
  ## reads with our own buffering — osproc's Stream may over-read past the
  ## line, which would desync select() (the bash-component lesson).
  var buf = ""
  while true:
    let idx = buf.find('\n')
    if idx >= 0:
      result = buf[0 ..< idx]
      buf = buf[idx + 1 .. ^1]
      return
    let left = int((deadline - epochTime()) * 1000.0)
    if left <= 0:
      raise newException(CatchableError, "fabric-exec timed out")
    let ready = sel.select(min(left, 200))
    if ready.len == 0:
      continue
    var chunk: array[4096, char]
    let n = posix.read(fd, addr chunk[0], 4096)
    if n <= 0:
      raise newException(CatchableError, "fabric-exec closed its output")
    for i in 0 ..< n:
      buf.add(chunk[i])

proc writeLineTo(p: Process, line: string) =
  p.inputStream.write(line & "\n")
  p.inputStream.flush()

proc runExecutor(subject, lease, code: string, strings: JsonNode,
                 maxCalls, timeoutMs: int): JsonNode =
  ## Spawn the executor, serve its bridge, return the tool result.
  let bin = getAppDir() / "fabric-exec"
  if not fileExists(bin):
    return %*{"error": "fabric-exec binary missing — run `make build`"}
  let runId = newId()
  let errFile = getTempDir() / ("niffler-fabric-exec-" & runId & ".err")
  var env = newStringTable(modeCaseSensitive)
  env["PATH"] = getEnv("PATH")
    # deliberately no NIF_* vars: the child has no bus and no credentials
  # stdout stays the framing pipe; stderr goes to a file so guest compile
  # errors (the embedded VM prints and quits) become actionable diagnostics
  let sh = "exec " & quoteShell(bin) & " 2> " & quoteShell(errFile)
  let p = startProcess("/bin/sh", args = ["-c", sh], env = env,
                       options = {poUsePath})
  defer:
    if fileExists(errFile):
      try: removeFile(errFile)
      except CatchableError: discard
  proc diag(msg: string): JsonNode =
    ## Failure result with the guest's compiler/quit output as diagnostics.
    let e = if fileExists(errFile): readFile(errFile).strip()
            else: ""
    result = %*{"error": msg}
    if e.len > 0:
      let capped = if e.len > 4000: e[e.len - 4000 .. ^1] else: e
      result["diagnostics"] = %capped
  var sel = newSelector[cint]()
  sel.registerHandle(p.outputHandle.SocketHandle, {Read}, p.outputHandle.cint)
  let deadline = epochTime() + timeoutMs.float / 1000.0
  var resultJ = JsonNode(nil)
  try:
    p.inputStream.write($(%*{"code": code, "strings": strings}) & "\n")
    p.inputStream.flush()
    var calls = 0
    while resultJ == nil:
      let line = readFramed(p.outputHandle.cint, deadline, sel)
      let j = parseJson(line)
      case j{"t"}.getStr("")
      of "log":
        comp.emit("ev.fabric.log", %*{"s": j{"s"}.getStr("")})
      of "req":
        inc calls
        var resp: JsonNode
        if calls > maxCalls:
          resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": false,
                    "error": "maxCalls budget exceeded (" & $maxCalls & ")"}
        else:
          var toolArgs: JsonNode
          try:
            toolArgs = parseJson(j{"argsJson"}.getStr("{}"))
            if toolArgs.kind != JObject:
              toolArgs = %*{"_value": toolArgs}
          except CatchableError:
            toolArgs = %*{}
          toolArgs["__session"] = %*{"lease": lease}
          try:
            let env = callEnvelope(j{"tool"}.getStr(""), toolArgs, "fabric")
            let r = comp.requestEnvelope(subject, env, 120_000)
            if r.kind == ekResult:
              resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": true,
                        "result": $r.args}
            else:
              resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": false,
                        "error": r.error{"message"}.getStr("call failed")}
          except CatchableError as e:
            resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": false,
                      "error": e.msg}
        p.writeLineTo($resp)
      of "result":
        resultJ = j
      else:
        discard  # unknown frame: ignore, keep pumping
  except CatchableError as e:
    if resultJ == nil:
      try:
        p.terminate()
      except CatchableError: discard
      return diag(e.msg)
  if resultJ == nil:
    try: p.terminate()
    except CatchableError: discard
    sel.unregister(p.outputHandle)
    sel.close()
    return diag("fabric program timed out after " & $timeoutMs & "ms")
  sel.unregister(p.outputHandle)
  sel.close()
  if p.running():
    p.terminate()
  p.close()
  return resultJ

proc storeArtifact(runId: string, value: string): string =
  ## Oversized results: mode-0600 file under var/fabric-artifacts (the one
  ## documented trusted-host exception — everything else crosses the bridge).
  let dir = getEnv("NIF_ROOT", ".") / "var" / "fabric-artifacts"
  try:
    createDir(dir)
  except CatchableError: discard
  let path = dir / (runId & ".json")
  writeFile(path, value)
  setFilePermissions(path, {fpUserRead, fpUserWrite})
  return path

# low-level registration: the handler needs the raw __session injection
let fabSchema = toolSchema(%*{
  "code": {"type": "string",
           "description": "A complete Nim program importing fabricguest. Orchestrate tool calls (callTool), compute on the results, and return ONE value with finish(...). Only the finish value reaches this conversation; everything else stays in the sandbox. Give either code or name, not both."},
  "name": {"type": "string",
           "description": "Run a stored program from the model-curated library (store kind 'fabricprog') instead of passing code. Save programs with the store's put tool; list what exists with store list. A stored program that stabilizes should graduate into a real component via builder + core spawn."},
  "strings": {"type": "object",
              "description": "Optional key/value entries readable via stringArg(key) — pass big payloads (file contents, long prompts) here instead of inside code"},
  "timeoutMs": {"type": "integer",
                "description": "Kill the program after this many ms (default 240000)"},
  "maxCalls": {"type": "integer",
               "description": "Budget: reject tool calls beyond this count (default 200)"}
}, required = @[],
   description = "Write and run a Nim program that drives Niffler tools itself. WHEN TO USE — direct loop: one step, or each result changes the plan; fabric: mechanical, known-shape work (sequential fan-out, search-then-read distillation, big intermediate data that must never enter the conversation, edit-then-verify in one program, polling loops) — writing the program IS the thinking; agent_run: exploratory subtasks needing per-step judgment in a fresh context; hybrid: fabric programs may call agent_run. HOW — the program imports fabricguest (read components/fabric/fabricguest/fabricguest.nim — it is the typed API) and worked examples live in components/fabric/examples/. Call tools with callTool(tool, jobj(jpair(name, value))) using jesc/jnum/jbool helpers; big payloads go through the strings argument and stringArg(key). Every call crosses the approval gate and counts against maxCalls. Only finish()'s value reaches the conversation — compute, filter, distill inside the program. Guests must not import os/osproc/net; the program is human-approved as a whole (bash's trust class).")
fabSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 300_000,
                            "sessionContext": true, "onDemand": true}
discard comp.tool("fabric", fabSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let sess = toolArgs{"__session"}{"session"}.getStr("")
    let lease = toolArgs{"__session"}{"lease"}.getStr("")
    if sess.len == 0 or lease.len == 0:
      return %*{"error": "fabric needs a live session context"}
    var code = toolArgs{"code"}.getStr("")
    let name = toolArgs{"name"}.getStr("")
    if code.len > 0 and name.len > 0:
      return %*{"error": "fabric takes either code or name, not both"}
    if code.len == 0:
      if name.len == 0:
        return %*{"error": "fabric needs code or name"}
      # program library: fetch the stored source (the model curates it
      # via the store's put/get/list — fabric only runs it)
      var stored: JsonNode
      try:
        stored = comp.request("store", "get",
          %*{"kind": "fabricprog", "id": name}, 10_000)
      except CatchableError:
        stored = nil
      if stored == nil or stored{"value"}{"code"}.getStr("").len == 0:
        var known: seq[string] = @[]
        try:
          let lst = comp.request("store", "list",
            %*{"kind": "fabricprog", "limit": 50}, 10_000)
          for it in lst{"items"}:
            known.add(it{"id"}.getStr(""))
        except CatchableError: discard
        var hint = ""
        if known.len > 0: hint = " Known programs: " & known.join(", ")
        return %*{"error": "no stored program named '" & name & "'." & hint}
      code = stored{"value"}{"code"}.getStr("")
    let lintMsg = lint(code)
    if lintMsg.len > 0:
      return %*{"error": lintMsg}
    let subject = "svc.session." & sanitizeSessionId(sess) & ".tool"
    let runId = newId()
    let maxCalls = toolArgs{"maxCalls"}.getInt(200)
    let timeoutMs = toolArgs{"timeoutMs"}.getInt(240_000)
    let stringsJ = if toolArgs{"strings"} != nil: toolArgs{"strings"}
                   else: newJObject()
      # nil JsonNode in %* SIGSEGVs at toUgly (AGENTS.md: never assume keys)
    let r = runExecutor(subject, lease, code, stringsJ, maxCalls, timeoutMs)
    if r{"error"} != nil:
      return r
    if r{"ok"}.getBool(false):
      let value = r{"value"}.getStr("")
      var parsed: JsonNode
      try:
        parsed = parseJson(value)
      except CatchableError:
        parsed = %value
      let rendered = $parsed
      if rendered.len > maxResultChars:
        let path = storeArtifact(runId, rendered)
        return %*{"ok": true,
                  "value": rendered[0 ..< maxResultChars] &
                    "\n[... truncated — full result at " & path & " ...]",
                  "artifactPath": path}
      return %*{"ok": true, "value": parsed}
    return %*{"ok": false, "diagnostics": r{"diagnostics"}.getStr("failed")})

comp.run()
