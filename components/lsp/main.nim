## lsp component — language-server intelligence behind one generic seam.
##
## One tool, `lsp`, exposes five read-only operations (diagnostics,
## goToDefinition, findReferences, goToImplementation, hover) against any
## configured stdio language server. The component knows no languages: which
## server handles which file extension is **data** — the registry at
## `$XDG_CONFIG_HOME/niffler-lsp/servers.json` (override path:
## `NIF_LSP_REGISTRY`), with sane defaults built in. Adding language X is a
## config entry (or an `lsp_registry add` call the agent can make itself);
## the model-facing tool surface never changes (AGENTS.md invariant:
## language-agnostic core).
##
## Design follows the dsh/Octo analysis in docs/OCTOFRIEND-STEAL.md:
## - transient document lifecycle per query: didOpen (current bytes) →
##   request → didClose; no file watching, no persistent sync state.
## - one server instance per (server, workspace root), queries serialized
##   per instance; any timeout or protocol error tears the instance down so
##   the next query starts fresh (a poisoned instance is never reused).
## - coordinates: the model sends one-based line/character (UTF-16 code
##   units, matching LSP); the wire is zero-based. Conversion happens at the
##   tool boundary only.
## - findReferences always includes the declaration (no caller flag to get
##   wrong).
## - result caps (100 locations / 16000 chars) with truncation metadata;
##   structured [E_LSP_*] errors so callers route on codes, not prose.
## - stderr from servers is drained (bounded tail) so chatty servers cannot
##   deadlock on a full pipe; the tail rides along on protocol errors.
##
## Read-only, approval-free, onDemand (discover/invoke — keeps the frozen
## toolset small; the description is the model's when-to-use guide).

import std/[algorithm, json, monotimes, os, osproc, posix, streams, strutils, tables, times]
import std/syncio
import niffler/sdk
import roots

const
  MAX_LOCATIONS = 100          # rendered locations before an omission marker
  MAX_RESULT_CHARS = 16000     # rendered result cap (incl. truncation metadata)
  MAX_INSTANCES = 8            # live language-server processes (LRU evicted)
  DIAG_SETTLE_MS = 1500        # quiet period after the first diagnostics push
  QUERY_TIMEOUT_MS = 60000     # per-operation budget (inside the 90s tool cap)
  INIT_TIMEOUT_MS = 30000      # initialize handshake budget
  STDERR_TAIL = 4096           # stderr tail kept for error messages

const OPERATIONS = ["diagnostics", "goToDefinition", "findReferences",
                    "goToImplementation", "hover"]

type LspFailure = object of ValueError
  ## Raised for [E_LSP_*] failures; the bus turns it into an error envelope.

proc fail(code, msg: string) {.noreturn.} =
  raise newException(LspFailure, "[" & code & "] " & msg)

# ---------------------------------------------------------------------------
# registry — language support is data, never code

type ServerConf = object
  name: string
  command: seq[string]
  extensions: Table[string, string]   # ".go" → "go"
  initializationOptions: JsonNode     # nil = none

proc defaultServers(): seq[ServerConf] =
  ## Sane defaults; all optional (absent binary → clear E_LSP_UNAVAILABLE).
  let defs = [
    ("gopls", @["gopls"], {".go": "go"}.toTable),
    ("nimlangserver", @["nimlangserver"], {".nim": "nim", ".nims": "nim"}.toTable),
    ("typescript-language-server",
     @["typescript-language-server", "--stdio"],
     {".ts": "typescript", ".tsx": "typescriptreact", ".mts": "typescript",
      ".cts": "typescript", ".js": "javascript", ".jsx": "javascriptreact",
      ".mjs": "javascript", ".cjs": "javascript"}.toTable),
    ("pyright", @["pyright-langserver", "--stdio"],
     {".py": "python", ".pyi": "python"}.toTable),
    ("rust-analyzer", @["rust-analyzer"], {".rs": "rust"}.toTable),
    ("clangd", @["clangd"],
     {".c": "c", ".h": "c", ".cpp": "cpp", ".cc": "cpp", ".cxx": "cpp",
      ".hpp": "cpp", ".hh": "cpp"}.toTable),
    ("bash-language-server", @["bash-language-server", "start"],
     {".sh": "shellscript", ".bash": "shellscript"}.toTable),
  ]
  for (name, cmd, exts) in defs:
    result.add(ServerConf(name: name, command: cmd, extensions: exts))

proc registryPath(): string =
  ## Where the user registry lives. NIF_LSP_REGISTRY overrides (tests,
  ## multi-harness setups); else XDG config.
  let env = getEnv("NIF_LSP_REGISTRY")
  if env.len > 0: return env
  let xdg = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config")
  return xdg / "niffler-lsp" / "servers.json"

proc parseConf(name: string, node: JsonNode): ServerConf =
  ## One registry entry. Command: array of argv tokens, or a plain string
  ## split on whitespace (commands are simple: no quoting support).
  if node == nil or node.kind != JObject:
    fail("E_LSP_REGISTRY", "server '" & name & "' entry must be an object")
  var cmd: seq[string]
  let cmdN = node{"command"}
  if cmdN == nil:
    fail("E_LSP_REGISTRY", "server '" & name & "' needs a \"command\"")
  if cmdN.kind == JArray:
    for t in cmdN:
      if t.kind != JString or t.getStr("").len == 0:
        fail("E_LSP_REGISTRY", "server '" & name & "' command tokens must be non-empty strings")
      cmd.add(t.getStr())
  elif cmdN.kind == JString:
    for t in cmdN.getStr("").split(Whitespace):
      if t.len > 0: cmd.add(t)
  if cmd.len == 0:
    fail("E_LSP_REGISTRY", "server '" & name & "' has an empty command")
  var exts = initTable[string, string]()
  let extN = node{"extensions"}
  if extN != nil and extN.kind == JObject:
    for k, v in extN:
      if k.len == 0 or not k.startsWith("."):
        fail("E_LSP_REGISTRY", "server '" & name & "': extension keys must start with '.' (got '" & k & "')")
      if v.kind != JString or v.getStr("").len == 0:
        fail("E_LSP_REGISTRY", "server '" & name & "': extension '" & k & "' needs a language id string")
      exts[k.toLowerAscii] = v.getStr()
  if exts.len == 0:
    fail("E_LSP_REGISTRY", "server '" & name & "' needs a non-empty \"extensions\" map")
  result = ServerConf(name: name, command: cmd, extensions: exts,
                      initializationOptions: node{"initializationOptions"})

proc loadRegistry(): Table[string, ServerConf] =
  ## Defaults, then the user file replaces entries by name. Re-read on every
  ## call: the file is tiny, and mid-conversation registry edits (agent,
  ## lsp_registry, the TUI picker) take effect on the next query.
  for conf in defaultServers():
    result[conf.name] = conf
  let path = registryPath()
  if not fileExists(path): return
  var doc: JsonNode
  try:
    doc = parseJson(readFile(path))
  except CatchableError as e:
    stderr.writeLine("lsp: ignoring registry " & path & ": " & e.msg)
    return
  if doc.kind != JObject:
    stderr.writeLine("lsp: ignoring registry " & path & ": top level must be an object")
    return
  for name, node in doc:
    try:
      result[name] = parseConf(name, node)
    except LspFailure as e:
      stderr.writeLine("lsp: ignoring registry entry: " & e.msg)

proc serverFor(registry: Table[string, ServerConf],
               ext: string): ServerConf =
  ## Deterministic lookup (sorted by name) when a hand-edited registry maps
  ## one extension to two servers.
  var names: seq[string]
  for name in registry.keys: names.add(name)
  sort(names)
  for name in names:
    if registry[name].extensions.hasKey(ext):
      return registry[name]

# ---------------------------------------------------------------------------
# URIs — file path ↔ file: URI (percent-encoded, per RFC 8089)

proc pathToUri(path: string): string =
  const safe = {'A'..'Z', 'a'..'z', '0'..'9', '/', '.', '_', '-', '~'}
  result = "file://"
  for c in path:
    if c in safe: result.add(c)
    else: result.add("%" & toHex(ord(c), 2))

proc uriToPath(u: string): string =
  var s = u
  if s.startsWith("file://"):
    s = s[7 ..^ 1]
    if s.startsWith("localhost/"): s = s["localhost".len ..^ 1]
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add(chr(parseHexInt(s[i + 1 .. i + 2])))
        i += 3
        continue
      except ValueError:
        discard
    result.add(s[i])
    inc i

proc sameUri(a, b: string): bool = uriToPath(a) == uriToPath(b)

# ---------------------------------------------------------------------------
# server instances — one process per (server, workspace), serialized queries

type Instance = ref object
  name: string
  root: string
  p: Process
  nextId: int
  caps: JsonNode             # initialize result.capabilities
  buf: string                # inbound frame buffer (partial frames)
  errTail: string            # last STDERR_TAIL bytes of server stderr
  created: MonoTime          # for LRU eviction

var gInstances = initOrderedTable[string, Instance]()

proc instKey(server, root: string): string = server & "\x1f" & root

proc dispose(h: Instance) =
  ## Kill the server process; safe to call twice.
  if h.p != nil:
    try:
      if h.p.running():
        h.p.terminate()
        sleep(50)
        if h.p.running(): h.p.kill()
    except CatchableError:
      discard
  try: h.p.close()
  except CatchableError: discard
  h.p = nil

proc evictIfNeeded() =
  if gInstances.len < MAX_INSTANCES: return
  var oldestKey = ""
  var oldest = MonoTime.high
  for k, h in gInstances:
    if h.created < oldest:
      oldest = h.created
      oldestKey = k
  if oldestKey.len > 0:
    gInstances[oldestKey].dispose()
    gInstances.del(oldestKey)

proc drainStderrOnce(h: Instance) =
  ## One non-blocking-ish drain per poll cycle so chatty servers never block
  ## on a full pipe. Keep a bounded tail for error messages. (The fd is a
  ## blocking pipe: exactly one read per POLLIN wake — poll said data is
  ## there, so this read cannot block.)
  var chunk: array[4096, char]
  let n = posix.read(errorHandle(h.p), addr chunk[0], chunk.len)
  if n <= 0: return
  let s = newString(n)
  copyMem(addr s[0], addr chunk[0], n)
  h.errTail &= s
  if h.errTail.len > STDERR_TAIL:
    h.errTail = h.errTail[^STDERR_TAIL ..^ 1]

proc stderrHint(h: Instance): string =
  if h.errTail.len == 0: return ""
  let lines = h.errTail.strip().split('\n')
  " — server stderr: " & lines[^1]

proc pump(h: Instance, timeoutMs: int): bool =
  ## Poll stdout (draining stderr on the way). Returns true when stdout has
  ## bytes, false on timeout. Raises E_LSP_PROTOCOL when the server died.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    var remaining = inMilliseconds(deadline - getMonoTime())
    if remaining <= 0: return false
    if remaining > 250: remaining = 250   # keep stderr draining + deadline checks
    var fds: array[2, TPollfd]
    fds[0].fd = outputHandle(h.p)
    fds[0].events = POLLIN
    fds[1].fd = errorHandle(h.p)
    fds[1].events = POLLIN
    let r = poll(addr fds[0], 2, cint(remaining))
    if r < 0:
      if osLastError().int == EINTR: continue
      fail("E_LSP_PROTOCOL", "poll on '" & h.name & "' failed: " & osErrorMsg(osLastError()))
    if (fds[1].revents and POLLIN) != 0:
      drainStderrOnce(h)
    if (fds[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
      var chunk: array[8192, char]
      let n = posix.read(outputHandle(h.p), addr chunk[0], chunk.len)
      if n < 0:
        if osLastError().int == EINTR: continue
        fail("E_LSP_PROTOCOL", "read from '" & h.name & "' failed: " & osErrorMsg(osLastError()))
      if n == 0:
        fail("E_LSP_PROTOCOL", "language server '" & h.name &
             "' closed the connection" & h.stderrHint())
      let s = newString(n)
      copyMem(addr s[0], addr chunk[0], n)
      h.buf.add(s)
      return true

proc readFrame(h: Instance, timeoutMs: int, quiet = false): JsonNode =
  ## One LSP frame (headers + JSON body), assembled across partial reads.
  ## quiet=true returns nil on timeout instead of raising (diagnostics settle).
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while true:
    let hdrEnd = h.buf.find("\r\n\r\n")
    if hdrEnd >= 0:
      var contentLen = -1
      for line in h.buf[0 ..< hdrEnd].split("\r\n"):
        let kv = line.split(":", 1)
        if kv.len == 2 and kv[0].strip().toLowerAscii() == "content-length":
          try: contentLen = parseInt(kv[1].strip())
          except ValueError: discard
      if contentLen < 0:
        fail("E_LSP_PROTOCOL", "frame from '" & h.name & "' has no Content-Length header")
      let total = hdrEnd + 4 + contentLen
      if h.buf.len >= total:
        let body = h.buf[hdrEnd + 4 ..< total]
        h.buf = h.buf[total ..^ 1]
        try: return parseJson(body)
        except ValueError as e:
          fail("E_LSP_PROTOCOL", "malformed JSON from '" & h.name & "': " & e.msg)
    let remaining = inMilliseconds(deadline - getMonoTime())
    if remaining <= 0:
      if quiet: return nil
      fail("E_LSP_TIMEOUT", "no response from '" & h.name & "' within " &
           $timeoutMs & "ms (server may still be indexing — retry)")
    if not pump(h, min(remaining, 250)):
      if quiet: return nil
      fail("E_LSP_TIMEOUT", "no response from '" & h.name & "' within " &
           $timeoutMs & "ms (server may still be indexing — retry)")

proc sendMsg(h: Instance, obj: JsonNode) =
  let s = $obj
  let frame = "Content-Length: " & $s.len & "\r\n\r\n" & s
  try:
    h.p.inputStream.write(frame)
    h.p.inputStream.flush()
  except CatchableError as e:
    fail("E_LSP_PROTOCOL", "write to '" & h.name & "' failed: " & e.msg & h.stderrHint())

proc request(h: Instance, meth: string, params: JsonNode,
             timeoutMs: int): JsonNode =
  ## One request/response round trip. Server notifications are skipped;
  ## server→client requests are answered politely so servers never block on
  ## us (gopls sends workspace/configuration right after initialize).
  inc h.nextId
  let id = h.nextId
  h.sendMsg(%*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params})
  while true:
    let frame = h.readFrame(timeoutMs)
    if frame{"id"}.getInt(-1) == id and
        (frame.hasKey("result") or frame.hasKey("error")):
      if frame{"error"} != nil:
        fail("E_LSP_PROTOCOL", meth & " failed on '" & h.name & "': " &
             frame{"error"}{"message"}.getStr("unknown server error") & h.stderrHint())
      return frame{"result"}
    if frame.hasKey("id") and frame.hasKey("method"):
      if frame{"method"}.getStr("") == "workspace/configuration":
        var items = newJArray()
        let asked = frame{"params"}{"items"}
        let n = if asked != nil and asked.kind == JArray: asked.len else: 0
        for i in 0 ..< n: items.add(newJObject())
        h.sendMsg(%*{"jsonrpc": "2.0", "id": frame["id"], "result": items})
      else:
        h.sendMsg(%*{"jsonrpc": "2.0", "id": frame["id"], "result": newJNull()})

proc notify(h: Instance, meth: string, params: JsonNode) =
  h.sendMsg(%*{"jsonrpc": "2.0", "method": meth, "params": params})

proc capOk(caps: JsonNode, key: string): bool =
  ## Capability advertised (true, or an options object — anything but
  ## absent/false).
  let n = caps{key}
  n != nil and n.kind != JNull and
    not (n.kind == JBool and n.getBool() == false)

proc openCloseOk(caps: JsonNode): bool =
  ## textDocumentSync may be a number (0 none, 1 full, 2 incremental) or an
  ## object with an openClose flag.
  let sync = caps{"textDocumentSync"}
  if sync == nil or sync.kind == JNull: return false
  if sync.kind == JInt: return sync.getInt() > 0
  if sync.kind == JObject:
    let oc = sync{"openClose"}
    return oc != nil and oc.kind == JBool and oc.getBool()
  return false

proc getInstance(conf: ServerConf, root: string): Instance =
  var conf = conf                     # local: command[0] may be repathed below
  let k = instKey(conf.name, root)
  if gInstances.hasKey(k):
    let h = gInstances[k]
    if h.p != nil and h.p.running():
      return h
    h.dispose()                      # died since last use — drop and respawn
    gInstances.del(k)
  if not conf.command[0].contains('/'):
    # PATH first, then the per-user install dirs (fix: gopls lives in
    # ~/go/bin, which a UI-autostarted harness's PATH routinely omits).
    let onPath = findExe(conf.command[0])
    let exe = if onPath.len > 0: onPath
              else: resolveBinIn(conf.command[0],
                                 fallbackBinDirs(getHomeDir(),
                                                 getEnv("NIF_LSP_BIN_DIRS")))
    if exe.len == 0:
      fail("E_LSP_UNAVAILABLE", "language server '" & conf.name &
           "' is configured but '" & conf.command[0] &
           "' was not found on PATH or in " &
           fallbackBinDirs(getHomeDir(), getEnv("NIF_LSP_BIN_DIRS")).join(", ") &
           " — install it, or change the registry (" & registryPath() & ")")
    conf.command[0] = exe
  evictIfNeeded()
  let h = Instance(name: conf.name, root: root, created: getMonoTime())
  try:
    h.p = startProcess(conf.command[0], workingDir = root,
                       args = conf.command[1 ..^ 1],
                       options = {poUsePath})
  except CatchableError as e:
    fail("E_LSP_UNAVAILABLE", "could not start '" & conf.name & "' (" &
         conf.command.join(" ") & "): " & e.msg)
  gInstances[k] = h
  var params = %*{
    "processId": nil,
    "rootUri": pathToUri(root),
    "workspaceFolders": [{"uri": pathToUri(root), "name": root.lastPathPart}],
    "capabilities": {}
  }
  if conf.initializationOptions != nil:
    params["initializationOptions"] = conf.initializationOptions
  try:
    let initResult = h.request("initialize", params, INIT_TIMEOUT_MS)
    h.caps = initResult{"capabilities"}
    h.notify("initialized", %*{})
  except LspFailure as e:
    h.dispose()
    gInstances.del(k)
    raise e
  return h

# ---------------------------------------------------------------------------
# result normalization + rendering

proc resolvePath(path, workspaceRoot: string): string =
  if path.isAbsolute(): path else: workspaceRoot / path

proc inside(root, path: string): bool =
  path == root or path.startsWith(root & "/")

proc relPath(path, root: string): string =
  if inside(root, path): path[(root.len + 1) ..^ 1] else: path

proc renderLocation(path, root: string, line, character: int): string =
  ## zero-based wire coordinates → one-based model-facing text
  relPath(path, root) & ":" & $(line + 1) & ":" & $(character + 1)

type Location = tuple[uri: string, line: int, character: int]

proc orElse(a, b: JsonNode): JsonNode =
  ## nil-safe coalesce
  if a != nil and a.kind != JNull: a else: b

proc normalizeLocations(raw: JsonNode): seq[Location] =
  ## definition: Location | Location[] | LocationLink[] | null
  if raw == nil or raw.kind == JNull: return
  var arr: JsonNode
  if raw.kind == JArray: arr = raw
  else: arr = %[raw]
  for item in arr:
    if item == nil or item.kind != JObject: continue
    if item{"targetUri"} != nil:
      # LocationLink
      let rng = orElse(item{"targetSelectionRange"}, item{"targetRange"})
      if rng != nil:
        result.add((item{"targetUri"}.getStr(""),
                   rng{"start"}{"line"}.getInt(0),
                   rng{"start"}{"character"}.getInt(0)))
    elif item{"uri"} != nil:
      result.add((item{"uri"}.getStr(""),
                  item{"range"}{"start"}{"line"}.getInt(0),
                  item{"range"}{"start"}{"character"}.getInt(0)))

proc normalizeHover(raw: JsonNode): string =
  ## hover: {contents: string | {kind, value} | [string|{kind, value}]} | null
  if raw == nil or raw.kind == JNull: return ""
  let contents = raw{"contents"}
  if contents == nil or contents.kind == JNull: return ""
  if contents.kind == JString: return contents.getStr()
  if contents.kind == JArray:
    var parts: seq[string]
    for c in contents:
      if c.kind == JString: parts.add(c.getStr())
      elif c{"value"} != nil: parts.add(c{"value"}.getStr())
    return parts.join("\n")
  if contents{"value"} != nil: return contents{"value"}.getStr()
  return ""

proc capText(s: string): string =
  if s.len <= MAX_RESULT_CHARS: return s
  s[0 ..< MAX_RESULT_CHARS] & "\n... [truncated at " & $MAX_RESULT_CHARS & " chars]"

# ---------------------------------------------------------------------------
# operations

proc opDiagnostics(h: Instance, uri, rel: string): JsonNode =
  ## Wait for the first publishDiagnostics push, then a short quiet period
  ## for updates; no pull-diagnostics fallback in MVP.
  var latest: JsonNode = nil
  let deadline = getMonoTime() + initDuration(milliseconds = QUERY_TIMEOUT_MS)
  while true:
    var waitMs = inMilliseconds(deadline - getMonoTime())
    if latest != nil: waitMs = min(waitMs, DIAG_SETTLE_MS)
    if waitMs <= 0: break
    let frame = h.readFrame(waitMs, quiet = true)
    if frame == nil: break
    if frame{"method"}.getStr("") == "textDocument/publishDiagnostics" and
        sameUri(frame{"params"}{"uri"}.getStr(""), uri):
      latest = frame{"params"}
  if latest == nil:
    fail("E_LSP_TIMEOUT", "no diagnostics for " & rel & " within " &
         $QUERY_TIMEOUT_MS & "ms — the server may still be indexing; retry")
  let diags = latest{"diagnostics"}
  if diags == nil or diags.kind != JArray or diags.len == 0:
    return %*{"ok": true, "text": rel & ": no diagnostics — clean.", "count": 0}
  let sev = {1: "error", 2: "warning", 3: "info", 4: "hint"}.toTable
  var lines: seq[string]
  var errors = 0
  for d in diags:
    if d.kind != JObject: continue
    let s = d{"severity"}.getInt(3)
    if s == 1: inc errors
    var ln = rel & ":" & $(d{"range"}{"start"}{"line"}.getInt(0) + 1) & ":" &
             $(d{"range"}{"start"}{"character"}.getInt(0) + 1) & "  " &
             sev.getOrDefault(s, "info") & "  " & d{"message"}.getStr("")
    if d{"source"} != nil and d{"source"}.kind == JString:
      ln.add(" (" & d{"source"}.getStr("") & ")")
    if d{"code"} != nil and d{"code"}.kind in {JString, JInt}:
      let code = if d{"code"}.kind == JString: d{"code"}.getStr()
                 else: $d{"code"}.getInt()
      ln.add(" [" & code & "]")
    lines.add(ln)
  let outText = capText(rel & ": " & $diags.len & " diagnostics (" &
                        $errors & " errors)\n" & lines.join("\n"))
  %*{"ok": true, "text": outText, "count": diags.len, "errors": errors}

proc opHover(h: Instance, uri: string, wireLine, wireChar: int,
             root: string): JsonNode =
  let hover = normalizeHover(h.request("textDocument/hover",
      %*{"textDocument": {"uri": uri}, "position": {"line": wireLine,
         "character": wireChar}}, QUERY_TIMEOUT_MS))
  if hover.len == 0:
    return %*{"ok": true, "text": "No hover information at " &
              renderLocation(uriToPath(uri), root, wireLine, wireChar) & "."}
  %*{"ok": true, "text": hover}

proc opLocations(h: Instance, op, uri: string, wireLine, wireChar: int,
                 root: string): JsonNode =
  var raw: JsonNode
  if op == "findReferences":
    raw = h.request("textDocument/references",
        %*{"textDocument": {"uri": uri},
           "position": {"line": wireLine, "character": wireChar},
           "context": {"includeDeclaration": true}}, QUERY_TIMEOUT_MS)
  else:
    let meth = if op == "goToDefinition": "textDocument/definition"
               else: "textDocument/implementation"
    raw = h.request(meth,
        %*{"textDocument": {"uri": uri},
           "position": {"line": wireLine, "character": wireChar}}, QUERY_TIMEOUT_MS)
  let locs = normalizeLocations(raw)
  if locs.len == 0:
    let noun = case op
               of "findReferences": "references found"
               of "goToDefinition": "definition found"
               else: "implementation found"
    let suffix = if op == "findReferences": " (declaration included)."
                 else: " at this position."
    return %*{"ok": true, "text": "No " & noun & suffix, "count": 0}
  var lines: seq[string]
  for l in locs[0 ..< min(locs.len, MAX_LOCATIONS)]:
    lines.add(renderLocation(uriToPath(l.uri), root, l.line, l.character))
  var outText = lines.join("\n")
  if locs.len > MAX_LOCATIONS:
    outText.add("\n... and " & $(locs.len - MAX_LOCATIONS) &
                " more — narrow the query (references on a more specific symbol)")
  %*{"ok": true, "text": capText(outText), "count": locs.len}

# ---------------------------------------------------------------------------
# tool handlers

proc hLsp(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    fail("E_BAD_SHAPE", "lsp request must be an object")
  let op = args{"operation"}.getStr("")
  if op notin OPERATIONS:
    fail("E_BAD_SHAPE", "\"operation\" must be one of: " & OPERATIONS.join(", "))
  let pathN = args{"path"}
  if pathN == nil or pathN.kind != JString or pathN.getStr("").len == 0:
    fail("E_BAD_SHAPE", "lsp requires a non-empty \"path\" string")
  if op != "diagnostics":
    let line = args{"line"}
    let character = args{"character"}
    if line == nil or line.kind != JInt or line.getInt() < 1:
      fail("E_BAD_SHAPE", "\"" & op & "\" requires a one-based \"line\" integer")
    if character == nil or character.kind != JInt or character.getInt() < 1:
      fail("E_BAD_SHAPE", "\"" & op & "\" requires a one-based \"character\" integer (UTF-16)")
  var workspaceRoot = args{"workspaceRoot"}.getStr("")
  # A direct bus caller may hand us a relative root (the core workspace
  # extension resolves `path` against the conversation workspace but leaves
  # a caller-supplied root alone, and dispatch-issued calls are not the only
  # way in). Resolve it against the harness root — the same base `path`
  # resolves against — so the scope check below compares like with like
  # instead of failing with "path is outside the workspace root".
  if workspaceRoot.len > 0 and not workspaceRoot.isAbsolute():
    workspaceRoot = rootDir() / workspaceRoot
  let explicitRoot = workspaceRoot.len > 0
  if workspaceRoot.len == 0: workspaceRoot = rootDir()
  if not dirExists(workspaceRoot):
    fail("E_BAD_SHAPE", "workspace root does not exist: " & workspaceRoot)
  let path = resolvePath(pathN.getStr(), workspaceRoot)
  for part in path.split({'/', '\\'}):
    if part == "..":
      fail("E_LSP_SCOPE", "path must not contain '..' components: " & pathN.getStr())
  if not inside(workspaceRoot, path):
    fail("E_LSP_SCOPE", "path is outside the workspace root (" & workspaceRoot & "): " & path)
  if not fileExists(path):
    fail("E_NOT_FOUND", "File not found: " & pathN.getStr())
  var text: string
  try: text = readFile(path)
  except CatchableError as e:
    fail("E_LSP_PROTOCOL", "could not read " & pathN.getStr() & ": " & e.msg)
  if '\0' in text[0 ..< min(8192, text.len)]:
    fail("E_NOT_TEXT", pathN.getStr() & " looks binary — language servers are for text")

  let ext = splitFile(path).ext.toLowerAscii()
  if not explicitRoot:
    # No root asked for: derive the nearest module root from the file
    # instead of handing the server the whole harness clone (which makes
    # gopls index every nested Go module before it answers).
    workspaceRoot = deriveRoot(path, workspaceRoot, rootMarkersForExt(ext))
  let conf = serverFor(loadRegistry(), ext)
  if conf.name.len == 0:
    fail("E_LSP_UNAVAILABLE", "no language server configured for '" & ext &
         "' — add one with the lsp_registry tool (or edit " & registryPath() & ")")

  let h = getInstance(conf, workspaceRoot)
  if not openCloseOk(h.caps):
    fail("E_LSP_UNSUPPORTED", "language server '" & conf.name &
         "' does not support transient textDocument/didOpen")
  if op != "diagnostics":
    let capKey = case op
                 of "goToDefinition": "definitionProvider"
                 of "goToImplementation": "implementationProvider"
                 of "findReferences": "referencesProvider"
                 else: "hoverProvider"
    if not capOk(h.caps, capKey):
      fail("E_LSP_UNSUPPORTED", "language server '" & conf.name &
           "' does not advertise " & capKey)
  let uri = pathToUri(path)
  let languageId = conf.extensions[ext]

  # transient doc lifecycle: any failure tears the instance down so the next
  # query starts fresh (a poisoned frame buffer or half-open document is
  # never reused)
  try:
    h.notify("textDocument/didOpen", %*{"textDocument": {
      "uri": uri, "languageId": languageId, "version": 1, "text": text}})
    var reply: JsonNode
    case op
    of "diagnostics": reply = opDiagnostics(h, uri, relPath(path, workspaceRoot))
    of "hover":
      reply = opHover(h, uri, args{"line"}.getInt() - 1,
                      args{"character"}.getInt() - 1, workspaceRoot)
    else:
      reply = opLocations(h, op, uri, args{"line"}.getInt() - 1,
                          args{"character"}.getInt() - 1, workspaceRoot)
    h.notify("textDocument/didClose", %*{"textDocument": {"uri": uri}})
    return reply
  except LspFailure:
    h.dispose()
    gInstances.del(instKey(conf.name, workspaceRoot))
    raise

proc atomicWrite(path, content: string) =
  createDir(path.parentDir())
  let tmp = path.parentDir / (".tmp-" & newId())
  var f = open(tmp, fmWrite)
  f.write(content)
  f.close()
  moveFile(tmp, path)

proc hLspServers(c: Component, args: JsonNode): JsonNode =
  ## List the merged registry — read-only, approval-free: pickers (TUI) and
  ## the model probe this before prompting a human.
  var servers = newJArray()
  let userPath = registryPath()
  var userNames: seq[string]
  if fileExists(userPath):
    try:
      let doc = parseJson(readFile(userPath))
      if doc.kind == JObject:
        for name in doc.keys: userNames.add(name)
    except CatchableError: discard
  var names: seq[string]
  for name in loadRegistry().keys: names.add(name)
  for name in sorted(names):
    let conf = loadRegistry()[name]
    var exts = newJObject()
    for ext, lang in conf.extensions: exts[ext] = %lang
    servers.add(%*{"name": name, "command": conf.command, "extensions": exts,
                   "source": (if name in userNames: "user" else: "builtin")})
  okResult(%*{"servers": servers, "path": userPath,
              "note": "add/remove via lsp_registry (approval-gated); built-ins are overridden by adding the same name"})

proc hLspRegistry(c: Component, args: JsonNode): JsonNode =
  ## Mutate the user registry: add (also overrides a built-in of the same
  ## name) and remove (user entries only). Approval-gated: persistent config
  ## write.
  let action = args{"action"}.getStr("add")
  case action
  of "add":
    let name = args{"name"}.getStr("")
    if name.len == 0 or not name.allCharsInSet({'a'..'z', '0'..'9', '-'}):
      fail("E_BAD_SHAPE", "\"add\" needs a \"name\" (lowercase letters, digits, hyphens)")
    var cmd: seq[string]
    let cmdN = args{"command"}
    if cmdN != nil and cmdN.kind == JArray:
      for t in cmdN: cmd.add(t.getStr(""))
    elif cmdN != nil and cmdN.kind == JString:
      for t in cmdN.getStr("").split(Whitespace):
        if t.len > 0: cmd.add(t)
    if cmd.len == 0 or cmd[0].len == 0:
      fail("E_BAD_SHAPE", "\"add\" needs a \"command\" (string or argv array)")
    let extN = args{"extensions"}
    if extN == nil or extN.kind != JObject or extN.len == 0:
      fail("E_BAD_SHAPE", "\"add\" needs \"extensions\": {\".ext\": \"languageId\"}")
    let merged = loadRegistry()
    for ext, lang in extN:
      if not ext.startsWith("."):
        fail("E_BAD_SHAPE", "extension keys must start with '.': " & ext)
      for other, conf in merged:
        if other != name and conf.extensions.hasKey(ext.toLowerAscii()):
          fail("E_LSP_CONFLICT", "extension '" & ext & "' is already mapped to '" &
               other & "' — remove that mapping first")
    var user: JsonNode
    let path = registryPath()
    if fileExists(path):
      try: user = parseJson(readFile(path))
      except ValueError as e:
        fail("E_LSP_REGISTRY", "registry " & path & " is not valid JSON: " & e.msg)
    if user == nil or user.kind != JObject: user = newJObject()
    user[name] = %*{"command": cmd, "extensions": extN}
    if args{"initializationOptions"} != nil:
      user[name]["initializationOptions"] = args{"initializationOptions"}
    atomicWrite(path, user.pretty() & "\n")
    okResult(%*{"added": name, "path": path,
                "note": "takes effect on the next lsp call"})
  of "remove":
    let name = args{"name"}.getStr("")
    if name.len == 0:
      fail("E_BAD_SHAPE", "\"remove\" needs a \"name\"")
    let path = registryPath()
    var user: JsonNode = newJObject()
    if fileExists(path):
      try: user = parseJson(readFile(path))
      except ValueError as e:
        fail("E_LSP_REGISTRY", "registry " & path & " is not valid JSON: " & e.msg)
    if user.kind == JObject and user.hasKey(name):
      user.delete(name)
      atomicWrite(path, user.pretty() & "\n")
      okResult(%*{"removed": name, "path": path})
    else:
      fail("E_LSP_UNAVAILABLE", "'" & name & "' is not in the user registry (" & path &
           ") — built-in defaults are overridden by re-adding the same name")
  else:
    fail("E_BAD_SHAPE", "\"action\" must be one of: add, remove")

# ---------------------------------------------------------------------------
# component

let comp = newComponent("lsp", "0.1.0")

discard comp.onDrain do (c: Component):
  for h in gInstances.values:
    h.dispose()
  gInstances.clear()

discard comp.tool("lsp", toolSchema(%*{
  "operation": {"type": "string", "enum": OPERATIONS,
                "description": "diagnostics, goToDefinition, findReferences, goToImplementation, or hover"},
  "path": {"type": "string",
           "description": "File to query (inside the conversation workspace)"},
  "line": {"type": "integer", "minimum": 1,
           "description": "One-based line at the cursor (required except for diagnostics)"},
  "character": {"type": "integer", "minimum": 1,
                "description": "One-based UTF-16 character offset within the line; an off-symbol position may return no results"},
  "workspaceRoot": {"type": "string",
                    "description": "Optional workspace root. Omit it and the server's root is derived from the file (nearest go.mod/package.json/Cargo.toml/...); a relative value resolves against the harness root"}
}, @["operation", "path"],
  "Query a language server for precise, semantic code intelligence. Prefer grep/read for ordinary navigation; use lsp when textual matches are ambiguous, or before an edit needs exact ground truth: diagnostics shows compiler/lint errors for a file (no test run needed), goToDefinition/findReferences/goToImplementation resolve symbols text search cannot, hover gives type documentation. Positions are one-based line and character (UTF-16). The server's root defaults to the file's nearest module marker, and a server command missing from PATH is also looked for in ~/go/bin and ~/.nimble/bin. findReferences always includes the declaration. Falls back with a clear error when no language server is configured for the file's extension."),
  hLsp,
  %*{"timeoutMs": 90000, "onDemand": true, "effect": "read",
     "workspace": {"pathFields": ["path"]}})

discard comp.tool("lsp_servers", toolSchema(%*{}, @[],
  "List configured language servers: name, launch command, extension map, and whether each entry is a user override or a built-in default. Read-only — use lsp_registry (add/remove) to change the registry, which takes effect on the next lsp call."),
  hLspServers,
  %*{"timeoutMs": 10000, "onDemand": true, "effect": "read"})

discard comp.tool("lsp_registry", toolSchema(%*{
  "action": {"type": "string", "enum": ["add", "remove"],
             "description": "add (or override a built-in of the same name), or remove a user entry"},
  "name": {"type": "string", "description": "Server name (add/remove)"},
  "command": {"description": "Server launch command (add): string (split on whitespace) or argv array, e.g. [\"gopls\"] or \"typescript-language-server --stdio\""},
  "extensions": {"type": "object",
                 "description": "Extension → LSP language id map (add), e.g. {\".go\": \"go\"}"},
  "initializationOptions": {"description": "Optional initialize options passed to the server (add)"}
}, @[],
  "Mutate the language-server registry: which server binary handles which file extension. add takes {name, command (string or argv array), extensions: {\".ext\": \"languageId\"}} and overrides a built-in of the same name; remove deletes a user entry. Takes effect on the next lsp call. Use when a file's extension has no language server configured — if the binary exists on PATH, adding it here is all that's needed. Writing the registry (approval-gated); list with lsp_servers."),
  hLspRegistry,
  %*{"timeoutMs": 10000, "onDemand": true, "approval": "always"})

comp.run()
