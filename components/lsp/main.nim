## lsp component — language-server intelligence behind one generic seam.
##
## One tool, `lsp`, exposes seven read-only operations (diagnostics,
## goToDefinition, findReferences, goToImplementation, hover, documentSymbol,
## workspaceSymbol) against any configured stdio language server. The component knows no
## languages: which
## server handles which file extension is **data** — the registry at
## `$XDG_CONFIG_HOME/niffler-lsp/servers.json` (override path:
## `NIF_LSP_REGISTRY`), with sane defaults built in. Adding language X is a
## config entry (or an `lsp_registry add` call the agent can make itself);
## the model-facing tool surface never changes (AGENTS.md invariant:
## language-agnostic core).
##
## Design follows the dsh/Octo analysis in docs/research/OCTOFRIEND-STEAL.md:
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

import std/[algorithm, json, monotimes, os, osproc, posix, sequtils, streams, strutils, tables, times]
import std/syncio
import natsnim
import niffler/sdk
import roots
import subjects   # sanitizeSessionId: the async diagnostics lane is per conversation

const
  MAX_LOCATIONS = 100          # rendered locations before an omission marker
  MAX_RESULT_CHARS = 16000     # rendered result cap (incl. truncation metadata)
  MAX_INSTANCES = 8            # live language-server processes (LRU evicted)
  DIAG_SETTLE_MS = 1500        # quiet period after the first diagnostics push
  QUERY_TIMEOUT_MS = 60000     # per-operation budget (inside the 90s tool cap)
  INIT_TIMEOUT_MS = 30000      # initialize handshake budget
  STDERR_TAIL = 4096           # stderr tail kept for error messages

const OPERATIONS = ["diagnostics", "documentSymbol", "workspaceSymbol",
                    "goToDefinition", "findReferences",
                    "goToImplementation", "hover", "warmup"]

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
  requires: seq[string]               # runtimes that must resolve ("java")
  cheap: bool                         # trivial to index — does not take a
                                      # heavy warm slot (see warmWorkspace)

proc defaultServers(): seq[ServerConf] =
  ## Sane defaults; all optional (absent binary → clear E_LSP_UNAVAILABLE).
  ## Nim defaults to nimtortoise (github.com/music-theories/nimtortoise): all
  ## three nimsuggest-based servers publish diagnostics only on save, and the
  ## component save-echoes after didOpen — but nimlangserver additionally
  ## never publishes for loose files (its "Found diagnostics file={}" bug),
  ## while nimtortoise answered every check in the live sweep. The old
  ## default remains user-registry-selectable by name.
  let defs = [
    ("gopls", @["gopls"], {".go": "go"}.toTable),
    ("nimtortoise", @["nimtortoise"], {".nim": "nim", ".nims": "nim"}.toTable),
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
    ("jdtls", @["jdtls"], {".java": "java"}.toTable),
    ("intelephense", @["intelephense", "--stdio"],
     {".php": "php", ".phtml": "php"}.toTable),
    ("solargraph", @["solargraph", "stdio"],
     {".rb": "ruby", ".rake": "ruby", ".ru": "ruby",
      ".gemspec": "ruby"}.toTable),
    ("csharp-ls", @["csharp-ls"], {".cs": "csharp"}.toTable),
  ]
  for (name, cmd, exts) in defs:
    result.add(ServerConf(name: name, command: cmd, extensions: exts))
  # Runtime dependencies and warm-cost class are *data*, like the rest of the
  # registry. `requires` is what makes a configured-but-unrunnable server
  # (jdtls with no JRE on PATH — seen live: "FileNotFoundError: 'java'")
  # report itself instead of being spawned, dying and wasting a warm slot.
  # `cheap` marks servers that index nothing: bash-language-server warms in
  # milliseconds, so it must not compete with the language the task is
  # written in for the (small) heavy-server budget.
  for conf in result.mitems:
    case conf.name
    of "jdtls": conf.requires = @["java"]
    of "csharp-ls": conf.requires = @["dotnet"]
    of "bash-language-server": conf.cheap = true
    else: discard

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
  let cheapN = node{"cheap"}
  let cheap = cheapN != nil and cheapN.kind == JBool and cheapN.getBool(false)
  var requires: seq[string]
  let reqN = node{"requires"}
  if reqN != nil and reqN.kind == JArray:
    for t in reqN:
      if t.kind == JString and t.getStr("").len > 0: requires.add(t.getStr(""))
  result = ServerConf(name: name, command: cmd, extensions: exts,
                      initializationOptions: node{"initializationOptions"},
                      requires: requires, cheap: cheap)

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

# ---------------------------------------------------------------------------
# Async diagnostics service (triggered by the edit tool)
#
# An edit must never wait for a language server: a cold rust-analyzer/jdtls
# needs minutes to index, and making each edit wait produced 39 useless 25s
# stalls in one ten-cell bench run — every one of them answered "server busy or
# still indexing", i.e. nothing. Instead the request is queued, acknowledged at
# once, and the rendered result is published to the conversation's
# svc.session.<id>.diag subject when the server finally answers. Core's runner
# drains it (pumpDiag) and appends it as append-only history — the same lane
# the repomap uses for svc.session.<id>.map.
type DiagJob = object
  session, path, rel, uri, languageId, text: string
  conf: ServerConf
  root: string
  first, last: int      # the edit's changed lines (0 = whole file)
  gen: int              # supersession counter for (session, path)
  t0: float             # queued at (TTL guard against ancient jobs)

const
  DIAG_IDLE_MS = 250            # idle tick: one job per tick, pump stays responsive
  DIAG_ASYNC_BUDGET_MS = 8_000  # per job: enough for a warm server, not a cold one
  DIAG_JOB_TTL_SECS = 600.0     # a conversation that moved on is not waited for
  DIAG_CONTEXT_LINES = 3        # diagnostics just outside the edit still matter
  DIAG_ASYNC_MAX_LINES = 8      # cap on in-range diagnostics delivered per edit

var gDiagJobs: seq[DiagJob] = @[]
var gDiagGen = initTable[string, int]()

proc diagKey(session, path: string): string = session & "\x1f" & path

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

proc clientCaps(): JsonNode =
  ## Client capabilities declared at initialize. Deliberately minimal — only
  ## what this component actually honors — but never empty: servers gate
  ## features on what the client declares, and an empty blob makes
  ## typescript-language-server skip its entire diagnostic push (it never
  ## even asks workspace/configuration). Declaring only supported features
  ## keeps servers from relying on anything we will not do (no file
  ## watching, no dynamic registration, no edits).
  %*{
    "textDocument": {
      "synchronization": {"didSave": true},
      "publishDiagnostics": {"relatedInformation": true, "versionSupport": true},
      "hover": {"contentFormat": ["markdown", "plaintext"]},
      "definition": {},
      "implementation": {},
      "references": {}
    },
    "workspace": {"configuration": true, "workspaceFolders": true}
  }

proc sendMsg(h: Instance, obj: JsonNode) =
  let s = $obj
  let frame = "Content-Length: " & $s.len & "\r\n\r\n" & s
  try:
    h.p.inputStream.write(frame)
    h.p.inputStream.flush()
  except CatchableError as e:
    fail("E_LSP_PROTOCOL", "write to '" & h.name & "' failed: " & e.msg & h.stderrHint())


proc answerServerRequest(h: Instance, frame: JsonNode) =
  ## Reply to a server→client request so gate-keeping servers are never left
  ## waiting: typescript-language-server publishes no diagnostics until its
  ## workspace/configuration request is answered. The only meaningful reply
  ## is configuration — one empty settings object per item (server defaults);
  ## everything else (client/registerCapability, window/workDoneProgress/
  ## create, …) gets a null result, the legal "not supported" that unblocks
  ## the server without promising behavior the component does not have.
  let resultNode =
    if frame{"method"}.getStr("") == "workspace/configuration":
      var arr = newJArray()
      let asked = frame{"params"}{"items"}
      let n = if asked != nil and asked.kind == JArray: asked.len else: 0
      for _ in 0 ..< n:
        arr.add(newJObject())
      arr
    else: newJNull()
  h.sendMsg(%*{"jsonrpc": "2.0", "id": frame{"id"}, "result": resultNode})

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
        var frame: JsonNode
        try: frame = parseJson(body)
        except ValueError as e:
          fail("E_LSP_PROTOCOL", "malformed JSON from '" & h.name & "': " & e.msg)
        # A server→client request must be answered or the server may stall
        # its whole push pipeline; swallow it here so no caller has to know.
        if frame{"method"} != nil and frame{"id"} != nil:
          h.answerServerRequest(frame)
          continue
        return frame
    let remaining = inMilliseconds(deadline - getMonoTime())
    if remaining <= 0:
      if quiet: return nil
      fail("E_LSP_TIMEOUT", "no response from '" & h.name & "' within " &
           $timeoutMs & "ms (server may still be indexing — retry)" &
           h.stderrHint())
    if not pump(h, min(remaining, 250)):
      # A pump slice only means "no bytes in this 250ms window" — servers that
      # run a lint subprocess (bash-language-server + shellcheck) or index a
      # big module legitimately stay silent far longer. Keep waiting until
      # the caller's real deadline; the slice size exists so stderr keeps
      # draining, not as a timeout. (A dead server is still caught instantly:
      # pump raises E_LSP_PROTOCOL on stdout EOF.)
      continue


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
      h.answerServerRequest(frame)

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

proc missingRuntime(conf: ServerConf): string =
  ## The first declared runtime dependency that does not resolve, or "".
  ## Declared as `requires` data so a configured-but-unrunnable server is
  ## reported instead of spawned and left to die on its own (jdtls with no
  ## JRE): the caller turns this into a clear error, and warmup does not
  ## spend a slot on it.
  for dep in conf.requires:
    if findExe(dep).len > 0: continue
    if resolveBinIn(dep, fallbackBinDirs(getHomeDir(), getEnv("NIF_LSP_BIN_DIRS"))).len > 0:
      continue
    return dep
  ""

proc getInstance(conf: ServerConf, root: string): Instance =
  var conf = conf                     # local: command[0] may be repathed below
  let k = instKey(conf.name, root)
  if gInstances.hasKey(k):
    let h = gInstances[k]
    if h.p != nil and h.p.running():
      return h
    h.dispose()                      # died since last use — drop and respawn
    gInstances.del(k)
  let missing = missingRuntime(conf)
  if missing.len > 0:
    fail("E_LSP_UNAVAILABLE", "language server '" & conf.name & "' needs '" &
         missing & "' on PATH — install it, or change the registry (" &
         registryPath() & ")")
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
    "capabilities": clientCaps()
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

proc opDiagnostics(h: Instance, uri, rel: string,
                   timeoutMs = QUERY_TIMEOUT_MS,
                   first = 0, last = 0): JsonNode =
  ## Wait for the first publishDiagnostics push, then a short quiet period
  ## for updates; no pull-diagnostics fallback in MVP.
  ##
  ## first/last (> 0) scope the delivered text to an edit's changed lines
  ## (± DIAG_CONTEXT_LINES, errors/warnings only, capped): the file may carry
  ## hundreds of pre-existing warnings, and the model only needs to know what
  ## its change broke. This is the same scoping edit used to render inline,
  ## now done on the structured diagnostics instead of re-parsing text.
  var latest: JsonNode = nil
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
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
         $timeoutMs & "ms — the server may still be indexing; retry" &
         h.stderrHint())
  let diags = latest{"diagnostics"}
  if diags == nil or diags.kind != JArray or diags.len == 0:
    return %*{"ok": true, "text": rel & ": no diagnostics — clean.", "count": 0}
  let sev = {1: "error", 2: "warning", 3: "info", 4: "hint"}.toTable
  var lines: seq[string]
  var inRange: seq[string]
  var errors = 0
  for d in diags:
    if d.kind != JObject: continue
    let s = d{"severity"}.getInt(3)
    if s == 1: inc errors
    let line0 = d{"range"}{"start"}{"line"}.getInt(0) + 1
    var ln = rel & ":" & $line0 & ":" &
             $(d{"range"}{"start"}{"character"}.getInt(0) + 1) & "  " &
             sev.getOrDefault(s, "info") & "  " & d{"message"}.getStr("")
    if d{"source"} != nil and d{"source"}.kind == JString:
      ln.add(" (" & d{"source"}.getStr("") & ")")
    if d{"code"} != nil and d{"code"}.kind in {JString, JInt}:
      let code = if d{"code"}.kind == JString: d{"code"}.getStr()
                 else: $d{"code"}.getInt()
      ln.add(" [" & code & "]")
    lines.add(ln)
    if first > 0 and s in {1, 2} and
        line0 >= first - DIAG_CONTEXT_LINES and
        line0 <= last + DIAG_CONTEXT_LINES and
        inRange.len < DIAG_ASYNC_MAX_LINES:
      inRange.add(ln)
  if first > 0:
    # Scoped (the async edit push): report what the change broke, not the
    # file's whole backlog.
    if inRange.len == 0:
      return %*{"ok": true, "count": 0, "errors": errors,
                "text": rel & ": " & $diags.len & " diagnostics (" & $errors &
                        " errors), none in the changed range — the lsp tool " &
                        "lists them all."}
    var scoped = rel & ": " & $inRange.len &
                 " diagnostics in the changed range"
    if diags.len > inRange.len:
      scoped.add(" (" & $diags.len & " in the file)")
    scoped.add("\n" & inRange.join("\n"))
    if inRange.len >= DIAG_ASYNC_MAX_LINES:
      scoped.add("\n  ... (capped — lsp diagnostics lists all)")
    return %*{"ok": true, "count": inRange.len, "errors": errors,
              "text": scoped}
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

const
  SYMBOL_KINDS = ["file", "module", "namespace", "package", "class",
    "method", "property", "field", "constructor", "enum", "interface",
    "function", "variable", "constant", "string", "number", "boolean",
    "array", "object", "key", "null", "enum member", "struct", "event",
    "operator", "type parameter"]   # LSP SymbolKind, 1-based

proc symbolKindLabel(k: JsonNode): string =
  let i = k.getInt(0)
  if i >= 1 and i <= SYMBOL_KINDS.len: SYMBOL_KINDS[i - 1] else: "symbol"

proc addFlatSymbolLines(nodes: JsonNode, defaultUri, root: string,
                        lines: var seq[string], total: var int) =
  ## Flat SymbolInformation[]/WorkspaceSymbol[] rendering — one-based,
  ## workspace-relative, cross-file (each entry carries its own location).
  ## Shared by documentSymbol's fallback form and workspaceSymbol (which
  ## only comes in flat forms). Nil-safe: WorkspaceSymbol may carry a
  ## location without a range (the resolve-later form).
  for s in nodes:
    if s.kind != JObject: continue
    let name = s{"name"}.getStr("")
    if name.len == 0: continue
    inc total
    let kind = symbolKindLabel(s{"kind"})
    var where = ""
    let loc = s{"location"}
    if loc != nil and loc.kind == JObject:
      let pos = loc{"range"}{"start"}
      if pos != nil:
        where = renderLocation(uriToPath(loc{"uri"}.getStr(defaultUri)), root,
                               pos{"line"}.getInt(0),
                               pos{"character"}.getInt(0))
      else:
        where = relPath(uriToPath(loc{"uri"}.getStr(defaultUri)), root)
    if where.len == 0: where = "(location pending)"
    lines.add(where & "  " & kind & "  " & name)

proc opDocumentSymbol(h: Instance, uri, rel, root: string): JsonNode =
  ## The file's outline: every symbol with kind, name and one-based position.
  ## Handles the hierarchical DocumentSymbol[] form (name/kind/range/children)
  ## and the deprecated flat SymbolInformation[] form (name/kind/location)
  ## some servers still return. Positions anchor at the name token
  ## (selectionRange) when the server provides one — the precise jump target.
  let raw = h.request("textDocument/documentSymbol",
      %*{"textDocument": {"uri": uri}}, QUERY_TIMEOUT_MS)
  if raw == nil or raw.kind != JArray or raw.len == 0:
    return %*{"ok": true, "text": rel & ": no symbols reported.", "count": 0}
  var lines: seq[string]
  var total = 0

  proc walk(nodes: JsonNode, depth: int) =
    if nodes == nil or nodes.kind != JArray: return
    for s in nodes:
      if s.kind != JObject: continue
      let name = s{"name"}.getStr("")
      if name.len == 0: continue
      inc total
      let kind = symbolKindLabel(s{"kind"})
      if s{"range"} != nil and s{"range"}.kind == JObject:
        # hierarchical DocumentSymbol — all symbols live in the queried file
        let sel = s{"selectionRange"}{"start"}
        let pos = if sel != nil and sel.kind == JObject: sel
                  else: s{"range"}{"start"}
        lines.add("  ".repeat(depth) & rel & ":" &
                  $(pos{"line"}.getInt(0) + 1) & ":" &
                  $(pos{"character"}.getInt(0) + 1) & "  " & kind & "  " & name)
        walk(s{"children"}, depth + 1)
      elif s{"location"} != nil and s{"location"}.kind == JObject:
        # deprecated flat SymbolInformation — location may leave the file
        let loc = s{"location"}
        let pos = loc{"range"}{"start"}
        lines.add("  ".repeat(depth) &
                  renderLocation(uriToPath(loc{"uri"}.getStr(uri)), root,
                                 pos{"line"}.getInt(0),
                                 pos{"character"}.getInt(0)) &
                  "  " & kind & "  " & name)
  walk(raw, 0)
  if lines.len == 0:
    return %*{"ok": true, "text": rel & ": no symbols reported.", "count": 0}
  var outText = lines[0 ..< min(lines.len, MAX_LOCATIONS)].join("\n")
  if lines.len > MAX_LOCATIONS:
    outText.add("\n... and " & $(lines.len - MAX_LOCATIONS) &
                " more — use goToDefinition/findReferences on a known symbol instead")
  %*{"ok": true, "text": capText(outText), "count": total}

proc opWorkspaceSymbol(h: Instance, root: string, query: string): JsonNode =
  ## Repo-wide symbol search — the addon op that rides the server's own
  ## in-RAM workspace index (built at initialize; warmup gives it a head
  ## start). We send a fuzzy query and render flat WorkspaceSymbol[]/
  ## SymbolInformation[] cross-file. An empty query lists all symbols the
  ## server is willing to return (most cap it); MAX_LOCATIONS caps the rest.
  let raw = h.request("workspace/symbol", %*{"query": query}, QUERY_TIMEOUT_MS)
  let q = if query.len > 0: " '" & query & "'" else: ""
  if raw == nil or raw.kind != JArray or raw.len == 0:
    return %*{"ok": true, "text": "No symbols match" & q & ".", "count": 0}
  var lines: seq[string]
  var total = 0
  addFlatSymbolLines(raw, "", root, lines, total)
  if lines.len == 0:
    return %*{"ok": true, "text": "No symbols match" & q & ".", "count": 0}
  var outText = lines[0 ..< min(lines.len, MAX_LOCATIONS)].join("\n")
  if lines.len > MAX_LOCATIONS:
    outText.add("\n... and " & $(lines.len - MAX_LOCATIONS) &
                " more — narrow the query")
  %*{"ok": true, "text": capText(outText), "count": total}

# ---------------------------------------------------------------------------
# workspace warmup — census + pre-start (ev.workspace.opened)

const
  WARM_MAX_FILES = 5000        # census stops counting past this
  WARM_BUDGET_SECS = 2.0       # census wall-clock budget
  WARM_MAX_SERVERS = 2         # heavy servers pre-started per workspace
  WARM_MAX_CHEAP = 1           # cheap (non-indexing) servers, own budget
  WARM_MAX_TOTAL = 4           # ceiling on pre-started processes
  WARM_CHEAP_MIN_FILES = 2     # a lone .sh is not worth a process
  WARM_SKIP_DIRS = ["node_modules", "vendor", "dist", "build", "target",
                    "__pycache__", ".venv", "venv", "nimcache", "obj",
                    ".gradle", ".next", ".cache", ".tox", "site-packages"]

proc intEnv(name: string, dflt: int): int =
  let v = getEnv(name, "")
  if v.len == 0: return dflt
  try: result = parseInt(v)
  except CatchableError: result = dflt


proc census(root: string): seq[tuple[ext: string, count: int]] =
  ## Bounded extension census of a workspace (any directory — a conversation
  ## workspace need not be a git repo). Hidden and known-junk dirs are
  ## skipped; a file cap and wall-clock budget keep huge trees O(budget).
  var counts = initCountTable[string]()
  var seen = 0
  let deadline = epochTime() + WARM_BUDGET_SECS
  var stack = @[root]
  while stack.len > 0 and seen < WARM_MAX_FILES and epochTime() < deadline:
    let dir = stack.pop()
    for kind, path in walkDir(dir, checkDir = true):
      let name = splitFile(path).name
      if name.len > 0 and name[0] == '.':
        continue
      case kind
      of pcDir:
        if path.lastPathPart.toLowerAscii() in WARM_SKIP_DIRS: continue
        stack.add(path)
      of pcFile:
        let ext = splitFile(path).ext.toLowerAscii()
        if ext.len > 1:
          counts.inc(ext)
          inc seen
      else: discard
  counts.sort()
  for ext, count in counts:
    result.add((ext, count))

proc warmWorkspace(wsRoot: string): JsonNode =
  ## Pre-start language-server instances for the workspace's most prevalent
  ## languages, so the first real query doesn't pay cold-start mid-turn.
  ## Initialize is cheap (seconds); the server keeps indexing in its own
  ## process afterwards — by the time the model's first edit lands, a server
  ## warmed at session start has had the whole conversation since.
  let reg = loadRegistry()
  let langs = census(wsRoot)
  # Two cost classes. A *heavy* server indexes the whole workspace (gopls,
  # rust-analyzer, jdtls, clangd, pyright), so they stay capped at a couple
  # per workspace. A *cheap* one costs nothing to have running
  # (bash-language-server), and on a repo full of .sh files it used to take
  # one of those two slots away from the language the task is written in —
  # it now gets its own (smaller) budget and never displaces a heavy pick.
  let heavyMax = intEnv("NIF_LSP_WARM_MAX", WARM_MAX_SERVERS)
  let cheapMax = intEnv("NIF_LSP_WARM_CHEAP", WARM_MAX_CHEAP)
  let totalMax = intEnv("NIF_LSP_WARM_TOTAL", WARM_MAX_TOTAL)
  var heavy, cheap: seq[tuple[conf: ServerConf, count: int]]
  var seenNames: seq[string]
  for (ext, count) in langs:
    let conf = serverFor(reg, ext)
    if conf.name.len == 0 or conf.name in seenNames: continue
    seenNames.add(conf.name)
    if conf.cheap:
      if count >= WARM_CHEAP_MIN_FILES: cheap.add((conf, count))
    elif heavy.len < heavyMax:
      heavy.add((conf, count))
  # Heavy picks first: they need the head start. Cheap picks fill whatever is
  # left of the total process budget.
  let cheapRoom = max(0, min(cheapMax, totalMax - heavy.len))
  let picked = heavy & cheap[0 ..< min(cheap.len, cheapRoom)]
  var warmed, skipped: seq[string]
  for p in picked:
    let miss = missingRuntime(p.conf)
    if miss.len > 0:
      skipped.add(p.conf.name & " (needs '" & miss & "')")
      continue
    try:
      discard getInstance(p.conf, wsRoot)  # reuses a live instance if any
      warmed.add(p.conf.name)
    except CatchableError as e:
      skipped.add(p.conf.name & " (" & e.msg & ")")
  var langList: JsonNode = newJArray()
  for (ext, count) in langs[0 ..< min(langs.len, 5)]:
    langList.add(%*{"ext": ext, "files": count})
  %*{"ok": true, "workspace": wsRoot, "languages": langList,
     "warmed": warmed, "skipped": skipped}

# ---------------------------------------------------------------------------
# tool handlers

proc hLsp(c: Component, args: JsonNode): JsonNode =
  if args == nil or args.kind != JObject:
    fail("E_BAD_SHAPE", "lsp request must be an object")
  let op = args{"operation"}.getStr("")
  if op notin OPERATIONS:
    fail("E_BAD_SHAPE", "\"operation\" must be one of: " & OPERATIONS.join(", "))
  if op == "warmup":
    # Directory-based, not file-based: census the workspace and pre-start
    # servers for its most prevalent languages. The core also fires this
    # automatically on ev.workspace.opened; the op exists so callers (and
    # tests) can trigger or re-run the same path explicitly.
    var wsRoot = args{"workspaceRoot"}.getStr("")
    if wsRoot.len == 0: wsRoot = args{"path"}.getStr("")
    if wsRoot.len == 0:
      fail("E_BAD_SHAPE", "warmup requires \"workspaceRoot\" (or \"path\")")
    if not wsRoot.isAbsolute(): wsRoot = rootDir() / wsRoot
    if not dirExists(wsRoot):
      fail("E_BAD_SHAPE", "warmup workspace root does not exist: " & wsRoot)
    return warmWorkspace(wsRoot)
  let pathN = args{"path"}
  if pathN == nil or pathN.kind != JString or pathN.getStr("").len == 0:
    fail("E_BAD_SHAPE", "lsp requires a non-empty \"path\" string")
  if op notin ["diagnostics", "documentSymbol", "workspaceSymbol"]:
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
  # The declared workspace set (core injects __workspace for tools that declare
  # the workspace policy): the trees this conversation considers its own — the
  # workspace, its git worktrees, same-origin sibling checkouts. A file living
  # in one of them is indexed as *that* tree, which is what gives a sibling
  # checkout its own root and its own server instance instead of "outside the
  # workspace". This is private per-call data: nothing here renders into a
  # prompt or a tool schema, so a worktree appearing mid-conversation costs no
  # cache miss.
  var declaredRoots: seq[string]
  let decl = args{"__workspace"}{"roots"}
  if decl != nil and decl.kind == JArray:
    for r in decl:
      let s = normalizeRoot(r.getStr(""))
      if s.len > 0: declaredRoots.add(s)
  if not explicitRoot:
    for r in declaredRoots:
      if r != workspaceRoot and inside(r, path):
        workspaceRoot = r            # the tree this file actually belongs to
        break

  # Scope is a *bound*, not an equality. An agent works in several checkouts,
  # git worktrees and plain directories at once (this harness's own bench
  # edits whole worktree copies), and refusing to look at a file because it
  # lives outside the conversation's workspace means no diagnostics for that
  # edit — a refusal the edit tool swallows as "no server configured", so the
  # model cannot even tell it happened. A file inside the workspace (or inside
  # a declared root) keeps that root, so its warm servers are reused; a file
  # outside every known tree is indexed under its OWN marker-derived root, the
  # rule nested repos inside the workspace already used. What remains is the
  # guard that matters — never hand a server an unbounded tree — so the
  # filesystem root and the home directory are refused with a message naming
  # the fix.
  let conversationWorkspace = rootDir()
  let outsideWorkspace = not inside(conversationWorkspace, path)
  if not inside(workspaceRoot, path):
    let derived = deriveRootUnbounded(path,
      rootMarkersForExt(splitFile(path).ext.toLowerAscii()))
    var derivedRoot = if derived.len == 0: "/" else: derived
    var home = getHomeDir()
    while home.len > 1 and home[^1] == '/': home = home[0 .. ^2]
    if derivedRoot == "/" or derivedRoot == home:
      fail("E_LSP_SCOPE", "refusing to index " & derivedRoot & " for " &
           pathN.getStr() & " — the file carries no project marker, so the " &
           "root would be the whole filesystem (or your home); pass " &
           "\"workspaceRoot\" naming the project root")
    workspaceRoot = derivedRoot
  if not fileExists(path):
    fail("E_NOT_FOUND", "File not found: " & pathN.getStr())
  var text: string
  try: text = readFile(path)
  except CatchableError as e:
    fail("E_LSP_PROTOCOL", "could not read " & pathN.getStr() & ": " & e.msg)
  if '\0' in text[0 ..< min(8192, text.len)]:
    fail("E_NOT_TEXT", pathN.getStr() & " looks binary — language servers are for text")

  let ext = splitFile(path).ext.toLowerAscii()
  if not explicitRoot and not outsideWorkspace:
    # No root asked for: derive the nearest module root from the file
    # instead of handing the server the whole harness clone (which makes
    # gopls index every nested Go module before it answers). An
    # out-of-workspace file already got its own root above — deriveRoot never
    # leaves the workspace, so re-deriving here would undo it.
    workspaceRoot = deriveRoot(path, workspaceRoot, rootMarkersForExt(ext))
  let conf = serverFor(loadRegistry(), ext)
  if conf.name.len == 0:
    fail("E_LSP_UNAVAILABLE",
         "no language server configured for " &
         (if ext.len == 0: pathN.getStr() & " (no file extension)"
          else: "'" & ext & "'") &
         " — add one with the lsp_registry tool (or edit " & registryPath() & ")")

  # Async mode (the edit tool's trigger): answer now, work later. Nothing is
  # started or waited for here — the idle seam below does the waiting, so a
  # cold server cannot delay the edit that asked.
  if op == "diagnostics" and args{"async"}.getBool(false):
    let sessionId = args{"session"}.getStr("")
    if sessionId.len == 0:
      fail("E_BAD_SHAPE", "async diagnostics need \"session\" (the " &
           "conversation id) — the result is delivered back on " &
           "svc.session.<id>.diag")
    let key = diagKey(sessionId, path)
    let gen = gDiagGen.getOrDefault(key, 0) + 1
    gDiagGen[key] = gen
    var kept: seq[DiagJob]
    for j in gDiagJobs:
      if diagKey(j.session, j.path) != key: kept.add(j)
    kept.add(DiagJob(session: sessionId, conf: conf, root: workspaceRoot,
                     path: path, rel: relPath(path, workspaceRoot),
                     uri: pathToUri(path),
                     languageId: conf.extensions[ext], text: text,
                     first: args{"first"}.getInt(0),
                     last: args{"last"}.getInt(0),
                     gen: gen, t0: epochTime()))
    gDiagJobs = kept
    return %*{"ok": true, "pending": true, "count": 0,
              "text": relPath(path, workspaceRoot) &
                ": diagnostics requested — they arrive as a message when " &
                "the language server answers."}

  let h = getInstance(conf, workspaceRoot)
  if not openCloseOk(h.caps):
    fail("E_LSP_UNSUPPORTED", "language server '" & conf.name &
         "' does not support transient textDocument/didOpen")
  if op != "diagnostics":
    var capKey: string
    case op
    of "goToDefinition": capKey = "definitionProvider"
    of "goToImplementation": capKey = "implementationProvider"
    of "findReferences": capKey = "referencesProvider"
    of "documentSymbol": capKey = "documentSymbolProvider"
    of "workspaceSymbol": capKey = "workspaceSymbolProvider"
    else: capKey = "hoverProvider"
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
    # All three Nim servers (nimlangserver, nimlsp, nimtortoise — all built
    # on nimsuggest) publish diagnostics only after a save, never on
    # didOpen/didChange; the transient lifecycle above never saves, so the
    # settle loop below times out at 60s even though nimsuggest found the
    # errors. Echoing the just-opened bytes as didSave is a no-op for
    # open-push servers (pyright, clangd, bash) and unlocks save-push ones;
    # the settle loop keeps whichever push lands last.
    h.notify("textDocument/didSave", %*{"textDocument": {"uri": uri},
                                       "text": text})
    var reply: JsonNode
    case op
    of "diagnostics": reply = opDiagnostics(h, uri, relPath(path, workspaceRoot))
    of "documentSymbol":
      reply = opDocumentSymbol(h, uri, relPath(path, workspaceRoot), workspaceRoot)
    of "workspaceSymbol":
      reply = opWorkspaceSymbol(h, workspaceRoot, args{"query"}.getStr(""))
    of "hover":
      reply = opHover(h, uri, args{"line"}.getInt() - 1,
                      args{"character"}.getInt() - 1, workspaceRoot)
    else:
      reply = opLocations(h, op, uri, args{"line"}.getInt() - 1,
                          args{"character"}.getInt() - 1, workspaceRoot)
    h.notify("textDocument/didClose", %*{"textDocument": {"uri": uri}})
    if outsideWorkspace and reply != nil and reply.kind == JObject:
      # Name the tree the answer came from: the caller is working outside the
      # conversation workspace, so its relative paths would otherwise be
      # ambiguous (which checkout is src/x.go in?).
      reply["workspaceRoot"] = %workspaceRoot
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
    # Runtime dependency and warm-cost class ride along, so an agent adding a
    # server can state what it needs and whether it indexes anything — the
    # same data the built-in defaults carry (see defaultServers).
    if args{"requires"} != nil:
      user[name]["requires"] = args{"requires"}
    if args{"cheap"} != nil:
      user[name]["cheap"] = args{"cheap"}
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

discard comp.on("ev.workspace.opened") do (c: Component, subject: string,
                                          payload: JsonNode):
  # Core announces every conversation workspace (any directory — a
  # conversation workspace need not be a git repo) at bootstrap and resume.
  # Fire-and-forget from core's side; we census and pre-start servers here
  # so the first real lsp query later in the conversation hits warm
  # instances instead of paying cold-start mid-turn.
  let ws = payload{"workspace"}.getStr("")
  if ws.len == 0 or not dirExists(ws): return
  try:
    let r = warmWorkspace(ws)
    var parts: seq[string]
    for w in r{"warmed"}: parts.add(w.getStr("") & " ready")
    for s in r{"skipped"}: parts.add(s.getStr(""))
    if parts.len > 0:
      c.log("info", "workspace warmup: " & parts.join(", "))
    # Readiness announcement — fire-and-forget (UIs can show which servers
    # came up; tests assert on it).
    try:
      publish(c.nc, "ev.lsp.warm",
        Envelope(v: 1, id: newId(), kind: ekEvent,
                 payload: %*{"workspace": ws, "warmed": r{"warmed"},
                             "skipped": r{"skipped"}}).encode())
    except CatchableError:
      discard
  except CatchableError as e:
    c.log("info", "workspace warmup failed: " & e.msg)

discard comp.onDrain do (c: Component):
  for h in gInstances.values:
    h.dispose()
  gInstances.clear()

discard comp.tool("lsp", toolSchema(%*{
  "operation": {"type": "string", "enum": OPERATIONS,
                "description": "diagnostics, documentSymbol (file outline — every symbol with kind, name and one-based position), workspaceSymbol (repo-wide symbol search on the server's index — give a fuzzy \"query\"; the server needs a moment to build its index after warmup), goToDefinition, findReferences, goToImplementation, hover, or warmup (pre-start servers for a workspace's languages)"},
  "path": {"type": "string",
           "description": "File to query (inside the conversation workspace); for warmup, a directory — with workspaceRoot taking precedence"},
  "query": {"type": "string",
            "description": "Fuzzy symbol-name query for workspaceSymbol (empty = all, server-dependent)"},
  "line": {"type": "integer", "minimum": 1,
           "description": "One-based line at the cursor (required except for diagnostics and documentSymbol)"},
  "character": {"type": "integer", "minimum": 1,
                "description": "One-based UTF-16 character offset within the line; an off-symbol position may return no results (required except for diagnostics and documentSymbol)"},
  "workspaceRoot": {"type": "string",
                    "description": "Optional workspace root. Omit it and the server's root is derived from the file (nearest go.mod/package.json/Cargo.toml/...); a relative value resolves against the harness root"}
}, @["operation", "path"],
  "Query a language server for precise, semantic code intelligence. Prefer grep/read for ordinary navigation; use lsp when textual matches are ambiguous, or before an edit needs exact ground truth: diagnostics shows compiler/lint errors for a file (no test run needed), documentSymbol maps an unfamiliar file's outline (names, kinds, positions) so a big file can be read selectively, workspaceSymbol finds where a symbol is defined across the whole workspace without grep noise, goToDefinition/findReferences/goToImplementation resolve symbols text search cannot, hover gives type documentation. Positions are one-based line and character (UTF-16). The server's root defaults to the file's nearest module marker, and a server command missing from PATH is also looked for in ~/go/bin and ~/.nimble/bin. findReferences always includes the declaration. Falls back with a clear error when no language server is configured for the file's extension."),
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
  "initializationOptions": {"description": "Optional initialize options passed to the server (add)"},
  "requires": {"type": "array", "items": {"type": "string"},
               "description": "Optional runtime binaries the server needs (add), e.g. [\"java\"] — when one is missing the server is reported as skipped instead of being spawned"},
  "cheap": {"type": "boolean",
            "description": "Optional: the server indexes nothing (add), so warmup gives it its own budget instead of a heavy-server slot"}
}, @[],
  "Mutate the language-server registry: which server binary handles which file extension. add takes {name, command (string or argv array), extensions: {\".ext\": \"languageId\"}} and overrides a built-in of the same name; remove deletes a user entry. Takes effect on the next lsp call. Use when a file's extension has no language server configured — if the binary exists on PATH, adding it here is all that's needed. Writing the registry (approval-gated); list with lsp_servers."),
  hLspRegistry,
  %*{"timeoutMs": 10000, "onDemand": true, "approval": "always"})

# ---------------------------------------------------------------------------
# self test (docs/WIRE.md) — /doctor fans out to this

type StFixture = tuple[good, bad, hover: string,
                       extras: seq[tuple[path, content: string]],
                       hoverLine, hoverCol: int]

proc stFixtures(): Table[string, StFixture] =
  ## Live-probe fixtures per extension, ported from the manual sweep that
  ## validated the servers on real workspaces: good file must report 0
  ## diagnostics and answer hover at the marked (one-based) spot; broken
  ## file must report errors. Extensions without an entry (and whole
  ## servers whose only extensions are unknown) get an initialize-only
  ## probe — the canonical extension of a server covers it.
  result = {
    ".go": ("good/main.go", "bad/main.go", "hover/main.go",
      @[("go.mod", "module sweepgo\n\ngo 1.21\n")], 5, 6),
    ".nim": ("good.nim", "bad.nim", "hover.nim", @[], 1, 6),
    ".ts": ("good.ts", "bad.ts", "hover.ts", @[], 1, 10),
    ".py": ("good.py", "bad.py", "hover.py", @[], 1, 5),
    ".rs": ("src/main.rs", "src/broken.rs", "src/hover.rs",
      @[("Cargo.toml", "[package]\nname = \"selftest\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")], 1, 8),
    ".c": ("good.c", "bad.c", "hover.c", @[], 3, 5),
    ".cpp": ("good.cpp", "bad.cpp", "hover.cpp", @[], 3, 5),
    ".sh": ("good.sh", "bad.sh", "hover.sh", @[], 5, 2),
    ".java": ("Good.java", "Bad.java", "Hover.java", @[], 2, 16),
    ".cs": ("Good.cs", "Bad.cs", "Hover.cs",
      @[("selftest.csproj", "<Project Sdk=\"Microsoft.NET.Sdk\">\n  <PropertyGroup>\n    <TargetFramework>net8.0</TargetFramework>\n  </PropertyGroup>\n</Project>\n")], 2, 16),
  }.toTable

proc stGoFile(): string =
  """package main

import "fmt"

func add2(a, b int) int { return a + b }

func main() { fmt.Println(add2(40, 2)) }
"""

proc stBadGoFile(): string =
  """package main

func main() { fmt.Println(undefined_symbol + 1) }
"""

proc stFile(ext, kind: string): string =
  ## kind: "good" | "bad" | "hover" — fixture sources per extension. The
  ## hover file is a separate never-saved document: bash-language-server's
  ## hover context dies on didSave, and save-push servers must not have
  ## their good-file save delayed behind a hover settle.
  case ext
  of ".go":
    result = if kind == "bad": stBadGoFile() else: stGoFile()
  of ".nim":
    result = if kind == "bad":
      "proc add2(a, b: int): int =\n  a + b\n\necho undeclared_xyz + 1\n"
    else:
      "proc add2(a, b: int): int =\n  a + b\n\necho add2(40, 2)\n"
  of ".ts":
    result = if kind == "bad":
      "const value: number = \"not a number\";\nconsole.log(missingSymbol);\n"
    else:
      "function add2(a: number, b: number): number { return a + b }\nconsole.log(add2(40, 2));\n"
  of ".py":
    result = if kind == "bad":
      "def f() -> int:\n    return undefined_name\n"
    else:
      "def add2(a: int, b: int) -> int:\n    return a + b\n\nprint(add2(40, 2))\n"
  of ".rs":
    result = case kind
    of "bad": "fn main() { println!(\"{}\", undefined_symbol + 1); }\n"
    of "hover": "pub fn add2(a: i64, b: i64) -> i64 { a + b }\n"
    else: "fn add2(a: i64, b: i64) -> i64 { a + b }\n\nfn main() { println!(\"{}\", add2(40, 2)); }\n"
  of ".c", ".cpp":
    result = if kind == "bad":
      "int main(void) { return undefined_symbol + 1; }\n"
    else:
      "#include <stdio.h>\n\nint add2(int a, int b) { return a + b; }\n\nint main(void) { printf(\"%d\\n\", add2(40, 2)); return 0; }\n"
  of ".sh":
    result = case kind
    of "bad":
      "greet() {\n  echo \"hello $name\"\n  if [ \"$1\" = \"x\" ]; then\n}\n\ngreet\n"
    of "hover":
      # hover answers at the command-position call (5,2); user-function
      # definitions and direct builtins resolve to null hover here
      "add2() {\n  echo $(( $1 + $2 ))\n}\n\nadd2 40 2\necho done\n"
    else:
      "add2() {\n  echo $(( $1 + $2 ))\n}\n\nadd2 40 2\n"
  of ".java":
    result = case kind
    of "bad":
      "public class Bad {\n    public static void main(String[] args) { System.out.println(undefined_symbol); }\n}\n"
    of "hover":
      "public class Hover {\n    static int add2(int a, int b) { return a + b; }\n}\n"
    else:
      "public class Good {\n    static int add2(int a, int b) { return a + b; }\n    public static void main(String[] args) { System.out.println(add2(40, 2)); }\n}\n"
  of ".cs":
    result = case kind
    of "bad":
      "static class Broken {\n    static int Nope() { return undefined_symbol + 1; }\n}\n"
    of "hover":
      "static class HoverCalc {\n    static int Add2(int a, int b) { return a + b; }\n}\n"
    else:
      "static class Calc {\n    static int Add2(int a, int b) { return a + b; }\n    static void Main() { System.Console.WriteLine(Add2(40, 2)); }\n}\n"
  else:
    result = ""

proc hLspSelfTest(c: Component, args: JsonNode): JsonNode =
  ## Component self test (docs/WIRE.md). quick (default): registry loads and
  ## every configured server's binary resolves (PATH + fallback dirs).
  ## deep: live end-to-end — boot each configured server against throwaway
  ## fixtures (the same ones the manual sweep used): initialize, clean file
  ## reports 0 diagnostics, hover answers, broken file reports errors.
  let deep = args{"deep"}.getBool(false)
  var checks = newJArray()
  var allOk = true
  let t0all = epochTime()

  proc check(name: string, ok: bool, detail: string, ms: int) =
    if not ok: allOk = false
    checks.add(%*{"name": name, "ok": ok, "detail": detail, "ms": ms})

  var reg: Table[string, ServerConf]
  try:
    reg = loadRegistry()
  except CatchableError as e:
    check("registry", false, e.msg, 0)
    return %*{"ok": false, "summary": "registry does not load: " & e.msg,
              "checks": checks}
  var userOverrides = 0
  let regPath = registryPath()
  if fileExists(regPath):
    try:
      let u = parseJson(readFile(regPath))
      if u.kind == JObject: userOverrides = u.len
    except CatchableError: discard
  check("registry", true,
        $reg.len & " server(s) configured" &
        (if userOverrides > 0: " (" & $userOverrides & " user override(s))" else: ""),
        int((epochTime() - t0all) * 1000))

  proc resolve(conf: ServerConf): string =
    ## mirror getInstance's resolution: PATH, then the fallback dirs
    let bin = conf.command[0]
    if bin.contains('/'):
      return (if fileExists(bin): bin else: "")
    let onPath = findExe(bin)
    if onPath.len > 0: return onPath
    resolveBinIn(bin, fallbackBinDirs(getHomeDir(), getEnv("NIF_LSP_BIN_DIRS")))

  var names: seq[string]
  for name in reg.keys: names.add(name)
  names.sort()

  if not deep:
    for name in names:
      let t0 = epochTime()
      let exe = resolve(reg[name])
      let exts = toSeq(reg[name].extensions.keys).join(" ")
      if exe.len > 0:
        check(name & ": binary", true, exe & " (" & exts & ")",
              int((epochTime() - t0) * 1000))
      else:
        check(name & ": binary", false,
              "not found on PATH or fallback dirs — make install-lsp, or " &
              "fix the registry (" & registryPath() & ")",
              int((epochTime() - t0) * 1000))
    return %*{"ok": allOk,
              "summary": $reg.len & " server(s), " &
                (if allOk: "all binaries resolve (quick — pass deep for live probes)"
                 else: "some binaries missing"),
              "checks": checks}

  # deep: live probe per server
  let budget = epochTime() + 110.0   # inside /doctor's 120s fan-out timeout
  let callMs = 15_000
  var probed = 0
  var stCounter = 0
  for name in names:
    let conf = reg[name]
    let t0 = epochTime()
    if epochTime() > budget - 20.0:
      check(name & ": skipped", false, "self-test budget exhausted", 0)
      continue
    let exe = resolve(conf)
    if exe.len == 0:
      check(name & ": binary", false,
            "not found on PATH or fallback dirs — make install-lsp, or " &
            "fix the registry (" & registryPath() & ")",
            int((epochTime() - t0) * 1000))
      continue
    # fixture: the server's extensions sorted, first one with live fixtures
    var exts: seq[string]
    for e in conf.extensions.keys: exts.add(e)
    exts.sort()
    var fixtureExt = ""
    for e in exts:
      if stFixtures().hasKey(e):
        fixtureExt = e
        break
    if fixtureExt.len == 0:
      # initialize-only probe: server spawns and completes the handshake
      inc stCounter
      let tmp = getTempDir() / ("niffler-lsp-selftest-" & $int(epochTime() * 1000) &
                                "-" & $stCounter)
      createDir(tmp)
      var okInit = false; var detail = ""
      try:
        discard getInstance(conf, tmp)
        okInit = true; detail = "initialize handshake answered"
      except CatchableError as e:
        detail = e.msg
      finally:
        let k = instKey(conf.name, tmp)
        if gInstances.hasKey(k):
          gInstances[k].dispose()
          gInstances.del(k)
        try: removeDir(tmp)
        except CatchableError: discard
      check(name & ": initialize", okInit, detail, int((epochTime() - t0) * 1000))
      continue

    # live probe: clean diagnostics + hover + broken diagnostics
    inc stCounter
    let tmp = getTempDir() / ("niffler-lsp-selftest-" & $int(epochTime() * 1000) &
                              "-" & $stCounter)
    createDir(tmp)
    let fx = stFixtures()[fixtureExt]
    let goodDir = splitFile(tmp / fx.good).dir
    let badDir = splitFile(tmp / fx.bad).dir
    let hoverDir = splitFile(tmp / fx.hover).dir
    if goodDir.len > 0: createDir(goodDir)
    if badDir.len > 0 and badDir != goodDir: createDir(badDir)
    if hoverDir.len > 0 and hoverDir != goodDir and hoverDir != badDir:
      createDir(hoverDir)
    writeFile(tmp / fx.good, stFile(fixtureExt, "good"))
    writeFile(tmp / fx.bad, stFile(fixtureExt, "bad"))
    writeFile(tmp / fx.hover, stFile(fixtureExt, "hover"))
    for extra in fx.extras:
      writeFile(tmp / extra.path, extra.content)
    var serverChecks = 0; var serverFails = 0
    try:
      let h = getInstance(conf, tmp)
      let goodUri = pathToUri(tmp / fx.good)
      let badUri = pathToUri(tmp / fx.bad)
      let hoverUri = pathToUri(tmp / fx.hover)
      # clean diagnostics first, listeners up before pushes can land:
      # open-push servers publish on didOpen, save-push (all nimsuggest-
      # based) on didSave — the settle loop catches either
      h.notify("textDocument/didOpen", %*{"textDocument": {
        "uri": goodUri, "languageId": conf.extensions[fixtureExt],
        "version": 1, "text": stFile(fixtureExt, "good")}})
      h.notify("textDocument/didSave", %*{"textDocument": {"uri": goodUri},
                                          "text": stFile(fixtureExt, "good")})
      block cleanCheck:
        let t1 = epochTime()
        try:
          let d = opDiagnostics(h, goodUri, fx.good, callMs)
          let n = d{"count"}.getInt(-1)
          let ok = d{"ok"}.getBool(false) and n == 0
          if ok: inc serverChecks
          else: inc serverFails
          check(name & ": clean-diagnostics", ok,
                (if ok: "0 diagnostics" else: d{"text"}.getStr("")),
                int((epochTime() - t1) * 1000))
        except CatchableError as e:
          inc serverFails
          check(name & ": clean-diagnostics", false, e.msg,
                int((epochTime() - t1) * 1000))
      block hoverCheck:
        # hover on a separate never-saved document: bash-language-server's
        # hover context dies on didSave (even across close/re-open), and
        # open-push servers publish their good-file push while we would
        # otherwise be sleeping — a fresh open here needs a moment for the
        # server's async analysis to attach symbol info
        let t1 = epochTime()
        var hover = ""
        try:
          h.notify("textDocument/didOpen", %*{"textDocument": {
            "uri": hoverUri, "languageId": conf.extensions[fixtureExt],
            "version": 1, "text": stFile(fixtureExt, "hover")}})
          sleep(2500)
          hover = normalizeHover(h.request("textDocument/hover",
            %*{"textDocument": {"uri": hoverUri},
               "position": {"line": fx.hoverLine - 1,
                            "character": fx.hoverCol - 1}}, callMs))
          h.notify("textDocument/didClose", %*{"textDocument": {"uri": hoverUri}})
          let ok = hover.len > 0
          if ok: inc serverChecks
          else: inc serverFails
          check(name & ": hover", ok,
                (if ok: hover[0 ..< min(hover.len, 80)] else: "no hover information"),
                int((epochTime() - t1) * 1000))
        except CatchableError as e:
          inc serverFails
          check(name & ": hover", false, e.msg, int((epochTime() - t1) * 1000))
      block brokenCheck:
        let t1 = epochTime()
        try:
          h.notify("textDocument/didOpen", %*{"textDocument": {
            "uri": badUri, "languageId": conf.extensions[fixtureExt],
            "version": 1, "text": stFile(fixtureExt, "bad")}})
          h.notify("textDocument/didSave", %*{"textDocument": {"uri": badUri},
                                              "text": stFile(fixtureExt, "bad")})
          let d = opDiagnostics(h, badUri, fx.bad, callMs)
          let n = d{"count"}.getInt(0)
          let ok = d{"ok"}.getBool(false) and n > 0
          if ok: inc serverChecks
          else: inc serverFails
          check(name & ": broken-diagnostics", ok,
                (if ok: $n & " error(s) flagged" else: d{"text"}.getStr("no diagnostics — server broken?")),
                int((epochTime() - t1) * 1000))
        except CatchableError as e:
          inc serverFails
          check(name & ": broken-diagnostics", false, e.msg,
                int((epochTime() - t1) * 1000))
      h.notify("textDocument/didClose", %*{"textDocument": {"uri": goodUri}})
      h.notify("textDocument/didClose", %*{"textDocument": {"uri": badUri}})
    except CatchableError as e:
      inc serverFails
      check(name & ": initialize", false, e.msg, int((epochTime() - t0) * 1000))
    finally:
      let k = instKey(conf.name, tmp)
      if gInstances.hasKey(k):
        gInstances[k].dispose()
        gInstances.del(k)
      try: removeDir(tmp)
      except CatchableError: discard
    if serverFails == 0 and serverChecks > 0:
      inc probed
  let probedWord = if deep: $probed & " server(s) probed live" else: ""
  return %*{"ok": allOk,
            "summary": $reg.len & " server(s) configured, " & probedWord &
              (if allOk: " — all green" else: " — failures above"),
            "checks": checks}

proc publishDiag(c: Component, job: DiagJob, text: string) =
  ## Hand a finished check back to the conversation that asked for it.
  ## Fire-and-forget: a conversation that has since ended has no subscriber,
  ## and a diagnostic nobody reads must never fail anything.
  let subject = "svc.session." & sanitizeSessionId(job.session) & ".diag"
  try:
    publish(c.nc, subject, Envelope(v: 1, id: newId(), kind: ekEvent,
      payload: %*{"conversationId": job.session, "path": job.rel,
                  "text": text}).encode())
  except CatchableError:
    discard

# The wait a synchronous edit used to pay happens here instead: in the SDK's
# idle seam, on the main thread, serialized like a handler — which is why this
# needs no thread and no lock. One job per tick keeps the pump responsive.
discard comp.onIdle(DIAG_IDLE_MS) do (c: Component):
  if gDiagJobs.len == 0: return
  let job = gDiagJobs[0]
  gDiagJobs.delete(0)
  if epochTime() - job.t0 > DIAG_JOB_TTL_SECS: return
  if job.gen != gDiagGen.getOrDefault(diagKey(job.session, job.path), 0):
    return                       # superseded: a newer edit re-queued this file
  var text: string
  let k = instKey(job.conf.name, job.root)
  try:
    let h = getInstance(job.conf, job.root)   # normally already warm (warmup)
    if not openCloseOk(h.caps):
      text = job.rel & ": '" & job.conf.name &
             "' cannot answer diagnostics (no transient didOpen support)."
    else:
      h.notify("textDocument/didOpen", %*{"textDocument": {
        "uri": job.uri, "languageId": job.languageId, "version": 1,
        "text": job.text}})
      h.notify("textDocument/didSave", %*{"textDocument": {"uri": job.uri},
                                          "text": job.text})
      let r = opDiagnostics(h, job.uri, job.rel, DIAG_ASYNC_BUDGET_MS,
                            job.first, job.last)
      text = r{"text"}.getStr("")
      h.notify("textDocument/didClose", %*{"textDocument": {"uri": job.uri}})
  except LspFailure as e:
    if gInstances.hasKey(k):   # poisoned frame buffer: never reuse the instance
      gInstances[k].dispose()
      gInstances.del(k)
    text = job.rel & ": " & e.msg &
           " — the lsp tool can retry once the server has finished indexing."
  except CatchableError as e:
    text = job.rel & ": " & e.msg
  if text.len > 0: publishDiag(c, job, text)

discard comp.selfTest(hLspSelfTest)

comp.run()
