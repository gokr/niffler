## fabric component — programmable tool calling (docs/research/FABRIC.md Phase 2).
##
## One tool, `fabric`: the LLM writes a Nim program (guest) that orchestrates
## tool calls; only the program's finish() value enters the conversation.
## This component owns the bus side: it spawns the fabric-exec child per
## program, serves the child's bridge requests over framed stdio, and routes
## every nested call through the session proxy (svc.session.<id>.tool) so
## approval, budgets and audit apply exactly as for direct tool calls.
## The child holds no credentials and no NATS connection.

import std/[algorithm, json, monotimes, os, osproc, posix, selectors, streams,
            strtabs, strutils, tables, times]
import natswrapper
import niffler/sdk
import framing

let comp = newComponent("fabric", "0.1.0")

const
  maxResultChars = 50_000
  ## the conversation sees at most this many chars of the program's value;
  ## oversized results land in var/fabric-artifacts/<run>.json (mode 0600)
  ## and the path is returned instead.
  maxCodeBytes = 256_000
  maxStringsEntries = 128
  maxStringsBytes = 2_000_000
  maxCallsLimit = 1_000
  maxTimeoutMs = 300_000
  maxLogEvents = 1_000
  maxLogBytes = 1_000_000
  maxArtifactFiles = 100
  maxArtifactBytes = 100_000_000'i64
  artifactMaxAgeSeconds = 7 * 24 * 60 * 60
  maxSelectedTools = 16
  forbiddenSelectedTools = ["fabric", "agent", "chat", "session", "invoke",
                            "session_prepare"]

const bannedTokens = ["staticExec", "staticRead", "gorge", "slurp",
                      "importc", "osproc", "natswrapper", "std/os",
                      "std/net", "std/selectors"]
  ## source lint: auditable policy, not a sandbox claim (docs/research/FABRIC.md,
  ## threat model). The VM itself also refuses FFI and gorge magics (the
  ## executor is built without -d:nimcore).

proc lint(code: string): string =
  for b in bannedTokens:
    if code.contains(b):
      return "program rejected: '" & b & "' is not allowed in fabric programs"
  return ""

proc writeLineTo(p: Process, line: string) =
  p.inputStream.write(line & "\n")
  p.inputStream.flush()

proc runExecutor(subject, lease, code: string, strings: JsonNode,
                 schemas: JsonNode, maxCalls, timeoutMs: int): JsonNode =
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
  var sel = newSelector[cint]()
  var selectorRegistered = false
  proc stopChild() =
    try:
      if p.running():
        p.terminate()
        discard p.waitForExit(1000)
      if p.running():
        p.kill()
        discard p.waitForExit(1000)
    except CatchableError:
      discard
  defer:
    if selectorRegistered:
      try: sel.unregister(p.outputHandle)
      except CatchableError: discard
    try: sel.close()
    except CatchableError: discard
    stopChild()
    try: p.close()
    except CatchableError: discard
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
  sel.registerHandle(p.outputHandle.SocketHandle, {Read}, p.outputHandle.cint)
  selectorRegistered = true
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  var resultJ = JsonNode(nil)
  var reader: FrameReader
  let selectedMode = schemas != nil
  var selected = initTable[string, JsonNode]()
  if selectedMode:
    for entry in schemas:
      selected[entry{"name"}.getStr("")] = entry
  try:
    var context = %*{"code": code, "strings": strings}
    if selectedMode: context["schemas"] = schemas
    p.inputStream.write($context & "\n")
    p.inputStream.flush()
    var calls = 0
    var logEvents = 0
    var logBytes = 0
    while resultJ == nil:
      let line = reader.readFrame(p.outputHandle.cint, deadline, sel)
      let j = parseJson(line)
      case j{"t"}.getStr("")
      of "log":
        let message = j{"s"}.getStr("")
        inc logEvents
        logBytes += message.len
        if logEvents > maxLogEvents or logBytes > maxLogBytes:
          return diag("fabric log budget exceeded")
        comp.emit("ev.fabric.log", %*{"s": message})
      of "req":
        inc calls
        let tool = j{"tool"}.getStr("")
        var resp: JsonNode
        if calls > maxCalls:
          resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": false,
                    "error": "maxCalls budget exceeded (" & $maxCalls & ")"}
        elif selectedMode and not selected.hasKey(tool):
          resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": false,
                    "error": "tool '" & tool & "' is not selected for this Fabric run"}
        else:
          var toolArgs: JsonNode
          try:
            toolArgs = parseJson(j{"argsJson"}.getStr(""))
            if toolArgs.kind != JObject:
              raise newException(ValueError, "tool arguments must be a JSON object")
          except CatchableError as e:
            resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": false,
                      "error": "invalid argsJson: " & e.msg}
            p.writeLineTo($resp)
            continue
          let remainingMs = (deadline - getMonoTime()).inMilliseconds.int
          if remainingMs <= 0:
            return diag("fabric-exec timed out")
          toolArgs["__session"] = %*{"lease": lease,
                                      "remainingMs": remainingMs}
          if selectedMode:
            let pin = selected[tool]
            toolArgs["__session"]["catalog"] = %*{
              "component": pin{"component"}.getStr(""),
              "version": pin{"version"}.getStr(""),
              "fingerprint": pin{"fingerprint"}.getStr("")}
          try:
            let env = callEnvelope(tool, toolArgs, "fabric")
            let r = comp.requestEnvelope(subject, env, remainingMs)
            if r.kind == ekResult:
              resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": true,
                        "result": $r.args}
            else:
              resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": false,
                        "error": r.error{"message"}.getStr("call failed")}
          except CatchableError as e:
            resp = %*{"t": "resp", "id": j{"id"}.getStr(""), "ok": false,
                      "error": e.msg}
        let responseLine = $resp
        if responseLine.len > maxFrameBytes:
          p.writeLineTo($(%*{"t": "resp", "id": j{"id"}.getStr(""),
                              "ok": false,
                              "error": "tool response exceeds frame budget"}))
        else:
          p.writeLineTo(responseLine)
      of "result":
        resultJ = j
      else:
        discard  # unknown frame: ignore, keep pumping
  except CatchableError as e:
    if resultJ == nil:
      stopChild()
      return diag(e.msg)
  if resultJ == nil:
    stopChild()
    return diag("fabric program timed out after " & $timeoutMs & "ms")
  return resultJ

proc cleanupArtifacts(dir: string, incomingBytes: int64) =
  ## Expire old files, then evict oldest entries until the retained set fits.
  var files: seq[tuple[path: string, modified: times.Time, size: int64]]
  let cutoff = getTime() - initDuration(seconds = artifactMaxAgeSeconds)
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    try:
      let modified = getLastModificationTime(path)
      if modified < cutoff:
        removeFile(path)
      else:
        files.add((path, modified, getFileSize(path)))
    except CatchableError:
      discard
  files.sort(proc(a, b: auto): int = cmp(a.modified, b.modified))
  var retainedBytes = incomingBytes
  var retainedFiles = files.len
  for file in files: retainedBytes += file.size
  var first = 0
  while first < files.len and
      (retainedFiles >= maxArtifactFiles or
       retainedBytes > maxArtifactBytes):
    try:
      removeFile(files[first].path)
      retainedBytes -= files[first].size
      dec retainedFiles
    except CatchableError:
      discard
    inc first
  if retainedFiles >= maxArtifactFiles or retainedBytes > maxArtifactBytes:
    raise newException(ValueError, "fabric artifact quota cannot be reclaimed")

proc writePrivateFile(path, value: string) =
  ## O_EXCL plus mode 0600 avoids a world-readable creation window.
  let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL,
                      Mode(0o600))
  if fd < 0:
    raiseOSError(osLastError(), path)
  var complete = false
  defer:
    discard posix.close(fd)
    if not complete:
      try: removeFile(path)
      except CatchableError: discard
  var written = 0
  while written < value.len:
    let count = posix.write(fd, unsafeAddr value[written], value.len - written)
    if count <= 0:
      raiseOSError(osLastError(), path)
    written += count
  complete = true

proc storeArtifact(runId: string, value: string): string =
  ## Oversized results: mode-0600 file under var/fabric-artifacts (the one
  ## documented trusted-host exception — everything else crosses the bridge).
  let dir = rootVarDir("fabric-artifacts")
  try:
    createDir(dir)
  except CatchableError: discard
  if value.len.int64 > maxArtifactBytes:
    raise newException(ValueError, "fabric result exceeds artifact quota")
  cleanupArtifacts(dir, value.len.int64)
  let path = dir / (runId & ".json")
  writePrivateFile(path, value)
  return path

# low-level registration: the handler needs the raw __session injection
let fabSchema = toolSchema(%*{
  "code": {"type": "string",
           "maxLength": maxCodeBytes,
           "description": "A complete Nim program importing fabricguest. Orchestrate tool calls (callTool), compute on the results, and return ONE value with finish(...). Only the finish value reaches this conversation; everything else stays in the trusted guest process. Give either code or name, not both."},
  "name": {"type": "string",
           "description": "Run a stored program from the model-curated library (store kind 'fabricprog') instead of passing code. Save programs with the store's put tool; list what exists with store list. A stored program that stabilizes should graduate into a real component via builder + core spawn."},
  "strings": {"type": "object",
              "maxProperties": maxStringsEntries,
              "additionalProperties": {"type": "string"},
              "description": "Optional key/value entries readable via stringArg(key) — pass big payloads (file contents, long prompts) here instead of inside code"},
  "tools": {"type": "array", "items": {"type": "string"},
            "maxItems": maxSelectedTools,
            "description": "Optional exact tool allowlist for pinned typed mode. callTool rejects names outside this set."},
  "timeoutMs": {"type": "integer",
                "minimum": 1, "maximum": maxTimeoutMs,
                "description": "Kill the program after this many ms (default 240000)"},
  "maxCalls": {"type": "integer",
               "minimum": 1, "maximum": maxCallsLimit,
               "description": "Budget: reject tool calls beyond this count (default 200)"}
}, required = @[],
   description = "Write and run a Nim program that drives Niffler tools itself. WHEN TO USE — direct loop: one step, or each result changes the plan; fabric: mechanical, known-shape work (sequential fan-out, search-then-read distillation, big intermediate data that must never enter the conversation, edit-then-verify in one program, polling loops) — writing the program IS the thinking; agent_run: exploratory subtasks needing per-step judgment in a fresh context; hybrid: fabric programs may call agent_run. HOW — the program imports fabricguest and worked examples live in components/fabric/examples/. Call tools with callTool(tool, jobj(jpair(name, value))) using jesc/jnum/jbool helpers; pass tools to pin an execution allowlist and its schemas. Big payloads go through strings and stringArg(key). Give either code or name — name runs a stored program from the model-curated library. Every call crosses the approval gate and counts against maxCalls. Only finish()'s value reaches the conversation. Guests must not import os/osproc/net; the program is human-approved as a whole (bash's trust class).")
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
    if code.len > maxCodeBytes:
      return %*{"error": "fabric code exceeds " & $maxCodeBytes & " bytes"}
    let lintMsg = lint(code)
    if lintMsg.len > 0:
      return %*{"error": lintMsg}
    let subject = sessionToolSubject(sess)
    let runId = newId()
    let maxCalls = toolArgs{"maxCalls"}.getInt(200)
    if maxCalls <= 0 or maxCalls > maxCallsLimit:
      return %*{"error": "maxCalls must be in 1.." & $maxCallsLimit}
    let outerRemainingMs = toolArgs{"__session"}{"remainingMs"}.getInt(0)
    let requestedTimeoutMs = toolArgs{"timeoutMs"}.getInt(240_000)
    if requestedTimeoutMs <= 0 or requestedTimeoutMs > maxTimeoutMs:
      return %*{"error": "timeoutMs must be in 1.." & $maxTimeoutMs}
    if outerRemainingMs <= 0:
      return %*{"error": "fabric execution deadline expired"}
    let timeoutMs = min(requestedTimeoutMs, outerRemainingMs)
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    let stringsJ = if toolArgs{"strings"} != nil: toolArgs{"strings"}
                   else: newJObject()
      # nil JsonNode in %* SIGSEGVs at toUgly (AGENTS.md: never assume keys)
    if stringsJ.kind != JObject:
      return %*{"error": "strings must be an object"}
    if stringsJ.len > maxStringsEntries:
      return %*{"error": "strings exceeds " & $maxStringsEntries & " entries"}
    var stringsBytes = 0
    for key, value in stringsJ:
      if value.kind != JString:
        return %*{"error": "strings." & key & " must be a string"}
      stringsBytes += key.len + value.getStr().len
      if stringsBytes > maxStringsBytes:
        return %*{"error": "strings exceeds " & $maxStringsBytes & " bytes"}
    var schemas: JsonNode
    let requestedTools = toolArgs{"tools"}
    if requestedTools != nil:
      if requestedTools.kind != JArray or requestedTools.len == 0 or
          requestedTools.len > maxSelectedTools:
        return %*{"error": "tools must contain 1.." & $maxSelectedTools &
                           " tool names"}
      for node in requestedTools:
        let name = node.getStr("")
        if node.kind != JString or name.len == 0:
          return %*{"error": "tools entries must be non-empty strings"}
        if name in forbiddenSelectedTools:
          return %*{"error": "tool '" & name &
                             "' is not reachable from Fabric"}
      let snapshotMs = (deadline - getMonoTime()).inMilliseconds.int
      if snapshotMs <= 0:
        return %*{"error": "fabric execution deadline expired"}
      try:
        let snapshot = c.request("core", "catalog",
          %*{"op": "schemas", "tools": requestedTools},
          min(10_000, snapshotMs))
        schemas = snapshot{"tools"}
        if schemas == nil or schemas.kind != JArray:
          return %*{"error": "catalog returned an invalid schema snapshot"}
      except CatchableError as e:
        return %*{"error": "cannot pin Fabric tool schemas: " & e.msg}
    let executionMs = (deadline - getMonoTime()).inMilliseconds.int
    if executionMs <= 0:
      return %*{"error": "fabric execution deadline expired"}
    let r = runExecutor(subject, lease, code, stringsJ, schemas, maxCalls,
                        executionMs)
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
        var path: string
        try:
          path = storeArtifact(runId, rendered)
        except CatchableError as e:
          return %*{"error": "cannot retain Fabric result: " & e.msg}
        return %*{"ok": true,
                  "value": rendered[0 ..< maxResultChars] &
                    "\n[... truncated — full result at " & path & " ...]",
                  "artifactPath": path}
      return %*{"ok": true, "value": parsed}
    return %*{"ok": false, "diagnostics": r{"diagnostics"}.getStr("failed")})

comp.run()
