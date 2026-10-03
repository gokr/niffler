## t_cli_run — the native headless turn driver (`cli run`, issue #124).
##
## Contract under test (docs/MANUAL.md "Headless turns"):
## - it attaches to the harness serving its runtime home (or owns one for
##   --root), reports the turn as NDJSON on stdout with diagnostics on stderr,
##   and prints exactly one authoritative result line;
## - `--session` continues a persisted conversation (append-only continuation);
## - `--export` writes the COMPLETE canonical transcript through the store's
##   cursor paging, not the trimmed provider projection;
## - SIGTERM/SIGINT cancels the live turn through the documented __cancel
##   control and the driver still reports a result;
## - a startup/protocol failure is bounded and exits non-zero;
## - an owned stack cleans itself up when the driver leaves.

import std/[json, os, osproc, streams, strtabs, strutils, times]
import natsnim
import helpers

type
  CliRun = object
    code: int
    output: string
    lines: seq[JsonNode]
  Probe = object
    sandbox: TestSandbox
    server: Process
    nc: NatsConnection
    core: Process

proc startCli(cliBin, root, bus: string, args: seq[string],
              extra: seq[(string, string)] = @[]): Process =
  ## Start `cli run` with a signal-able handle (tests/helpers runCli merges
  ## stderr into stdout and gives no way to interrupt the child).
  var env = newStringTable(modeCaseSensitive)
  for (k, v) in envPairs(): env[k] = v
  env["NIF_ROOT"] = root
  # ALWAYS set, even empty: the ambient environment of a suite running inside
  # a live harness carries NIF_NATS_URL, and an inherited value would make
  # every "attach by discovery" case silently drive the developer's own
  # harness (helpers.startComponent scrubs the same way).
  env["NIF_NATS_URL"] = bus
  for (k, v) in extra: env[k] = v
  startProcess(cliBin, args = @args, env = env,
               options = {poUsePath, poStdErrToStdOut})

proc waitCli(process: var Process, timeoutMs = 180_000): CliRun =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  result.code = -1
  while epochTime() < deadline:
    result.code = process.peekExitCode()
    if result.code != -1: break
    sleep(50)
  if result.code == -1:
    process.terminate()
    sleep(300)
    if process.running(): process.kill()
    result.code = 124
  result.output = process.outputStream.readAll()
  process.close()
  for line in result.output.splitLines():
    let s = line.strip()
    if s.len == 0 or s[0] != '{': continue
    try: result.lines.add(parseJson(s))
    except CatchableError: discard

proc runCliOnce(cliBin, root, bus: string, args: seq[string],
                extra: seq[(string, string)] = @[],
                timeoutMs = 180_000): CliRun =
  var process = startCli(cliBin, root, bus, args, extra)
  waitCli(process, timeoutMs)

proc js(node: JsonNode): string =
  ## Safe rendering for failure details: indexing a nil JsonNode is a crash,
  ## and a failed call legitimately answers {\"error\": ...} instead of the shape
  ## a check expects.
  if node == nil: return "null"
  $node

proc jsonField(node: JsonNode, key: string): JsonNode =
  if node == nil or node.kind != JObject: return nil
  node{key}

proc firstOf(lines: seq[JsonNode], kind: string): JsonNode =
  for line in lines:
    if line{"type"}.getStr("") == kind: return line

proc lastOf(lines: seq[JsonNode], kind: string): JsonNode =
  for line in lines:
    if line{"type"}.getStr("") == kind: result = line

proc waitComponent(nc: NatsConnection, name: string, secs = 25): bool =
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil: return true
    sleep(200)
  false

proc storeMessages(nc: NatsConnection, convId: string): seq[JsonNode] =
  let page = call(nc, "store", "list",
                  %*{"kind": "message", "idPrefix": convId & ":",
                     "limit": 1000}, 30_000)
  result = @[]
  if page{"items"} == nil: return
  for item in page{"items"}: result.add(item{"value"})

proc startProbe(sandbox: TestSandbox, tag: string,
                extra: seq[(string, string)]): Probe =
  let (server, url) = startNats()
  result.sandbox = sandbox
  result.server = server
  result.nc = waitConnect(url)
  result.core = startComponent(sandbox.sandboxBin("niffler"), url,
                               root = sandbox.root, extra = extra,
                               logFile = sandbox.root / "var" / "test-logs" /
                                         "core-" & tag & ".log")
  doAssert waitComponent(result.nc, "store"), tag & ": store did not register"
  doAssert waitComponent(result.nc, "llm"), tag & ": llm did not register"

proc stopProbe(p: var Probe) =
  if p.core != nil:
    p.core.terminate()
    sleep(1200)
    if p.core.running(): p.core.kill()
    p.core.close()
  if p.server != nil: stopServer(p.server)
  p.nc.close()

proc newRunSandbox(tag: string): TestSandbox =
  result = newCoreSandbox(tag, ["store", "bash", "llm"])
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  discard fixtureBin(result, "llm", repoRoot / "tests" / "mock_llm.nim",
                     prebuiltName = "fixture-mock-llm")

proc newMcpSandbox(tag: string): TestSandbox =
  ## A sandbox that can bootstrap MCP servers: the manager, its bridge and a
  ## dependency-free stdio MCP server fixture.
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  result = newCoreSandbox(tag, ["store", "bash", "llm", "mcp"])
  discard fixtureBin(result, "llm", repoRoot / "tests" / "mock_llm.nim",
                     prebuiltName = "fixture-mock-llm")
  copyFileWithPermissions(repoRoot / "var" / "bin" / "mcp-bridge",
                          result.sandboxBin("mcp-bridge"))
  discard fixtureBin(result, "mcp-fixture",
                     repoRoot / "tests" / "fixtures" / "mcp_server.nim",
                     prebuiltName = "fixture-mcp-server")

proc frozenDirectTools(nc: NatsConnection, convId: string): seq[string] =
  ## The conversation's frozen direct toolset (the store doc the request
  ## prefix is built from) — what a bootstrap must be registered BEFORE.
  let doc = call(nc, "store", "get",
                 %*{"kind": "session", "id": convId & ":tools"}, 15_000)
  result = @[]
  if jsonField(doc, "value") == nil: return
  let direct = jsonField(jsonField(doc, "value"), "direct")
  if direct == nil or direct.kind != JArray: return
  for schema in direct:
    let name = schema{"name"}.getStr("")
    if name.len > 0: result.add(name)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for name in ["niffler", "session", "store-sqlite", "bash", "cli"]:
    if not fileExists(repoRoot / "var" / "bin" / name):
      fail("missing " & name & " binary — run `make build` first")
      quit(1)

  # -------------------------------------------------------------------------
  # 1. attached mode: the NDJSON stream, continuation, transcript export.
  block attached:
    let sandbox = newRunSandbox("cli-run")
    let root = sandbox.root
    let cliBin = sandbox.sandboxBin("cli")
    defer: removeDir(root)
    var p = startProbe(sandbox, "cli-run",
                       @[("NIF_AUTO_APPROVE", "0"), ("NIF_AUTO_CONTINUE", "0"),
                         ("NIF_MOCK_ROUNDS", "2"),
                         ("NIF_MOCK_USAGE_DETAILS", "1"),
                         ("NIF_MOCK_TOOLCMD", "true")])
    defer: p.stopProbe()

    let first = runCliOnce(cliBin, root, "",
                           @["run", "--root=" & root, "say hello"])
    check("cli run exits 0 on a successful turn", first.code == 0,
          "code=" & $first.code & "\n" & first.output)
    let start1 = firstOf(first.lines, "start")
    check("run announces conversation, bus, home and ownership",
          start1 != nil and start1{"sessionId"}.getStr("").len > 0 and
          start1{"bus"}.getStr("").len > 0 and
          start1{"root"}.getStr("") == root and
          not start1{"owned"}.getBool(true) and
          start1{"servingRoot"}.getStr("") == root, $start1)
    let result1 = lastOf(first.lines, "result")
    check("run prints one authoritative result line",
          result1 != nil and
          result1{"outcome"}.getStr("") == "success" and
          result1{"turnId"}.getStr("").len > 0 and
          result1{"reply"}.getStr("").len > 0 and
          result1{"usage"}{"providerResponses"}.getInt(0) == 3,
          $result1)
    check("start is the first line and result the last",
          first.lines.len > 2 and first.lines[0]{"type"}.getStr("") == "start" and
          first.lines[^1]{"type"}.getStr("") == "result", $first.lines.len)
    var eventSubjects: seq[string] = @[]
    for line in first.lines:
      if line{"type"}.getStr("") == "event":
        eventSubjects.add(line{"subject"}.getStr(""))
    check("the turn's events stream as NDJSON",
          eventSubjects.len > 0 and eventSubjects[0].startsWith("ev.session."),
          $eventSubjects.len)
    var approvalLines = 0
    for line in first.lines:
      if line{"type"}.getStr("") == "approval":
        inc approvalLines
        check("a gated call is answered (denied) instead of stalling",
              line{"verdict"}.getStr("") == "deny" and
              line{"tool"}.getStr("").len > 0, $line)
    check("the headless driver answers the gate it cannot ask a human",
          approvalLines > 0, $first.output)
    let sid = start1{"sessionId"}.getStr("")

    # --- continuation ------------------------------------------------------
    let before = storeMessages(p.nc, sid).len
    let second = runCliOnce(cliBin, root, "",
                            @["run", "--root=" & root, "--quiet",
                              "--session=" & sid, "and again"])
    check("a continued session exits 0", second.code == 0,
          "code=" & $second.code & "\n" & second.output)
    let start2 = firstOf(second.lines, "start")
    let result2 = lastOf(second.lines, "result")
    check("continuation keeps the conversation and reports only its own turn",
          start2{"sessionId"}.getStr("") == sid and
          result2{"outcome"}.getStr("") == "success" and
          result2{"usage"}{"providerResponses"}.getInt(0) == 3 and
          result2{"turnId"}.getStr("") != result1{"turnId"}.getStr(), $result2)
    check("--quiet suppresses event lines",
          firstOf(second.lines, "event") == nil, $second.output)
    check("continuation appended to the canonical transcript",
          storeMessages(p.nc, sid).len > before, $before)

    # --- transcript export -------------------------------------------------
    let exportPath = root / "var" / "exports" / "transcript.jsonl"
    let third = runCliOnce(cliBin, root, "",
                           @["run", "--root=" & root, "--quiet",
                             "--session=" & sid, "--export=" & exportPath,
                             "one more"])
    check("the export run exits 0", third.code == 0,
          "code=" & $third.code & "\n" & third.output)
    let exportLine = lastOf(third.lines, "export")
    check("run reports the exported path and message count",
          exportLine != nil and exportLine{"path"}.getStr("") == exportPath and
          exportLine{"messages"}.getInt(0) > 0, $exportLine)
    var exported = 0
    var exportedRoles: seq[string] = @[]
    if fileExists(exportPath):
      for line in readFile(exportPath).splitLines():
        let s = line.strip()
        if s.len == 0: continue
        inc exported
        try:
          exportedRoles.add(parseJson(s){"message"}{"role"}.getStr(""))
        except CatchableError:
          discard
    check("the export is the complete canonical transcript",
          exported == storeMessages(p.nc, sid).len and
          "tool" in exportedRoles and "assistant" in exportedRoles and
          "user" in exportedRoles,
          "exported=" & $exported & " stored=" &
            $storeMessages(p.nc, sid).len & " roles=" & exportedRoles.join(","))

  # -------------------------------------------------------------------------
  # 2. cancellation: SIGTERM aborts the live turn and still reports a result.
  block cancelled:
    let sandbox = newRunSandbox("cli-run-cancel")
    let root = sandbox.root
    let cliBin = sandbox.sandboxBin("cli")
    let marker = root / "var" / "turn-was-running"
    defer: removeDir(root)
    # NIF_AUTO_APPROVE=1: this case is about cancellation, not the gate — the
    # scripted bash call must actually run (and sleep) for a live turn.
    var p = startProbe(sandbox, "cli-run-cancel",
                       @[("NIF_AUTO_APPROVE", "1"),
                         ("NIF_MOCK_ROUNDS", "2"),
                         ("NIF_MOCK_TOOLCMD",
                          "touch " & quoteShell(marker) & " && sleep 8")])
    defer: p.stopProbe()

    var child = startCli(cliBin, root, "",
                         @["run", "--root=" & root, "--quiet",
                           "--cancel-grace=20", "cancel me"])
    # Interrupt only once the turn is demonstrably live (the scripted bash
    # call left its marker): a cancel that arrives before the turn starts is
    # dropped by design (it would be a cancel for a future turn).
    var seen = false
    let markerDeadline = epochTime() + 60.0
    while epochTime() < markerDeadline and child.peekExitCode() == -1:
      if fileExists(marker):
        seen = true
        break
      sleep(50)
    check("the turn reached its tool call before the interrupt", seen)
    if seen: child.terminate()
    let cut = waitCli(child, 60_000)
    check("a cancelled turn is reported and exits 1", cut.code == 1,
          "code=" & $cut.code & "\n" & cut.output)
    let cutResult = lastOf(cut.lines, "result")
    check("the cancelled result carries the outcome and turnError",
          cutResult != nil and
          cutResult{"outcome"}.getStr("") == "cancelled" and
          cutResult{"turnError"}.getStr("").contains("cancelled") and
          cutResult{"usage"}{"providerResponses"}.getInt(0) >= 1, $cutResult)

  # -------------------------------------------------------------------------
  # 3. failures are bounded and non-zero: no harness anywhere.
  block failure:
    let sandbox = newRunSandbox("cli-run-fail")
    let root = sandbox.root
    let cliBin = sandbox.sandboxBin("cli")
    defer: removeDir(root)
    let dead = runCliOnce(cliBin, root, "nats://127.0.0.1:1",
                          @["run", "--root=" & root, "--bus=nats://127.0.0.1:1",
                            "hello"], timeoutMs = 60_000)
    check("an unreachable harness exits 3 with an error line",
          dead.code == 3 and lastOf(dead.lines, "error") != nil,
          "code=" & $dead.code & "\n" & dead.output)
    let noPrompt = runCliOnce(cliBin, root, "", @["run", "--root=" & root])
    check("a missing prompt is a bounded usage error",
          noPrompt.code == 2, "code=" & $noPrompt.code & "\n" & noPrompt.output)
    let badApprovals = runCliOnce(cliBin, root, "",
                                  @["run", "--approvals=maybe", "hello"])
    check("an unknown approval mode is refused",
          badApprovals.code == 2, "code=" & $badApprovals.code)

  # -------------------------------------------------------------------------
  # 4. owned mode: the driver starts a harness for its runtime home and the
  #    stack cleans itself up when it leaves.
  block owned:
    let sandbox = newRunSandbox("cli-run-own")
    let root = sandbox.root
    let cliBin = sandbox.sandboxBin("cli")
    defer: removeDir(root)
    let (server, url) = startNats()
    defer: stopServer(server)
    var nc = waitConnect(url)
    defer: nc.close()

    # --own starts the harness for --root on the bus we name; the child core
    # inherits NIF_AUTOSTART_IDLE_S=1, so it retires promptly on its own.
    let own = runCliOnce(cliBin, root, url,
                         @["run", "--root=" & root, "--bus=" & url, "--own",
                           "--quiet", "owned turn"],
                         extra = @[("NIF_AUTOSTART_IDLE_S", "1"),
                                   ("NIF_MOCK_ROUNDS", "1"),
                                   ("NIF_MOCK_TOOLCMD", "true")],
                         timeoutMs = 120_000)
    check("an owned harness drives the turn and exits 0", own.code == 0,
          "code=" & $own.code & "\n" & own.output)
    let ownStart = firstOf(own.lines, "start")
    let ownResult = lastOf(own.lines, "result")
    check("the start line reports the owned stack",
          ownStart != nil and ownStart{"owned"}.getBool(false) and
          ownStart{"servingRoot"}.getStr("") == root and
          ownResult{"outcome"}.getStr("") == "success", $ownStart)
    var gone = false
    let goneDeadline = epochTime() + 40.0
    while epochTime() < goneDeadline:
      let probe = call(nc, "core", "catalog", %*{"op": "list"}, 2_000)
      if probe{"error"} != nil or probe{"root"}.getStr("") != root:
        gone = true
        break
      sleep(500)
    check("the owned stack exits once the driver departs", gone,
          "core still answers after 40s")

  # -------------------------------------------------------------------------
  # 5. MCP bootstrap: declared servers are registered (and ready) BEFORE the
  #    first turn freezes the direct toolset, credentials stay indirect, and
  #    the driver's own gate answers only what it declared.
  block mcp:
    let sandbox = newMcpSandbox("cli-run-mcp")
    let root = sandbox.root
    let cliBin = sandbox.sandboxBin("cli")
    let fixture = sandbox.sandboxBin("mcp-fixture")
    let token = "s3cr3t-mcp-token"
    defer: removeDir(root)
    # NIF_AUTO_APPROVE=0: the gate is LIVE, so the bootstrap only works because
    # the driver answers its own declared calls (mcp_add + the bridge spawn)
    # and nothing else.
    var p = startProbe(sandbox, "cli-run-mcp",
                       @[("NIF_AUTO_APPROVE", "0"), ("NIF_AUTO_CONTINUE", "0"),
                         ("NIF_MOCK_ROUNDS", "1"), ("NIF_MOCK_TOOLCMD", "true"),
                         ("NIF_CLI_MCP_TOKEN", token)])
    defer: p.stopProbe()
    check("the MCP manager registered", waitComponent(p.nc, "mcp"))

    let decl = """{"name":"fixture","type":"stdio","command":"@FIXTURE_BIN@",
  "env":{"FIXTURE_TOKEN":"${NIF_CLI_MCP_TOKEN}"},"expose":"direct"}"""
      .replace("@FIXTURE_BIN@", fixture)
    # Explicit budgets: a bridge bootstrap spawns a component (and, for a real
    # server, an npx/uvx child), which is the slowest thing this test does —
    # a loaded CI runner needs minutes where a warm laptop needs seconds.
    let first = runCliOnce(cliBin, root, "",
                           @["run", "--root=" & root, "--quiet",
                             "--mcp-timeout=240", "--mcp=" & decl,
                             "list your tools"], timeoutMs = 420_000)
    check("a declared MCP server drives the turn", first.code == 0,
          "code=" & $first.code & "\n" & first.output)
    let mcpLine = firstOf(first.lines, "mcp")
    check("the mcp line reports the registered, ready bridge",
          mcpLine != nil and mcpLine{"name"}.getStr("") == "fixture" and
          mcpLine{"action"}.getStr("") == "mcp_add" and
          mcpLine{"ready"}.getBool(false) and
          mcpLine{"component"}.getStr("") == "mcp-fixture" and
          mcpLine{"tools"}.getInt(0) >= 4, $mcpLine)
    check("the mcp line reports how long registration took",
          mcpLine{"durationMs"} != nil and
          mcpLine{"durationMs"}.getInt(-1) >= 0, js(mcpLine))
    check("the declaration's credential NAMES are reported, never a value",
          mcpLine{"credentials"}{0}.getStr("") == "NIF_CLI_MCP_TOKEN" and
          not first.output.contains(token), $mcpLine)
    var mcpIdx = -1
    var resultIdx = -1
    for i, line in first.lines:
      if line{"type"}.getStr("") == "mcp" and mcpIdx < 0: mcpIdx = i
      if line{"type"}.getStr("") == "result": resultIdx = i
    check("bootstrap runs before the turn",
          mcpIdx >= 0 and resultIdx > mcpIdx and
          first.lines[resultIdx]{"outcome"}.getStr("") == "success",
          "mcp@" & $mcpIdx & " result@" & $resultIdx)
    # The driver granted exactly its own declarations (and did so visibly).
    var granted: seq[string] = @[]
    var denied: seq[string] = @[]
    for line in first.lines:
      if line{"type"}.getStr("") != "approval": continue
      if line{"verdict"}.getStr("") == "grant":
        granted.add(line{"tool"}.getStr(""))
      elif line{"bootstrap"}.getBool(false):
        denied.add(line{"tool"}.getStr(""))
    check("the gate granted the declared manager call and its bridge spawn",
          "mcp_add" in granted and "spawn" in granted and granted.len == 2 and
          denied.len == 0,
          "granted=" & $granted & " denied=" & $denied)
    let sid = firstOf(first.lines, "start"){"sessionId"}.getStr("")
    check("the bridge's tools were in the snapshot the first turn froze",
          "mcp_fixture_echo" in frozenDirectTools(p.nc, sid),
          $frozenDirectTools(p.nc, sid))
    # Credential indirection: the store keeps the placeholder, the bridge
    # resolves it from its own environment at connect time.
    let record = call(p.nc, "store", "get", %*{"kind": "mcp", "id": "fixture"},
                      15_000)
    let storedEnv = jsonField(jsonField(record, "value"), "env")
    check("the store keeps the ${NAME} placeholder, never the secret",
          jsonField(storedEnv, "FIXTURE_TOKEN").getStr("") ==
            "${NIF_CLI_MCP_TOKEN}" and not js(record).contains(token),
          js(storedEnv))
    let listing = call(p.nc, "mcp", "mcp_servers", %*{}, 15_000)
    var envKeys: seq[string] = @[]
    var listed = ""
    let servers = jsonField(listing, "servers")
    if servers != nil and servers.kind == JArray and servers.len > 0:
      listed = js(servers[0])
      let keys = jsonField(servers[0], "envKeys")
      if keys != nil and keys.kind == JArray:
        for k in keys: envKeys.add(k.getStr(""))
    check("the manager listing redacts the value and names the key",
          not js(listing).contains(token) and "FIXTURE_TOKEN" in envKeys,
          listed)

    # --- resume: the same declaration is re-applied (refresh), and the frozen
    #     toolset keeps the bridge's tools.
    let second = runCliOnce(cliBin, root, "",
                            @["run", "--root=" & root, "--quiet",
                              "--mcp-timeout=240", "--session=" & sid,
                              "--mcp=" & decl, "use the fixture tool"],
                            timeoutMs = 420_000)
    check("a resumed run re-applies the declaration", second.code == 0,
          "code=" & $second.code & "\n" & second.output)
    let editLine = firstOf(second.lines, "mcp")
    check("an existing server is refreshed through mcp_edit",
          editLine != nil and editLine{"action"}.getStr("") == "mcp_edit" and
          editLine{"ready"}.getBool(false) and
          not second.output.contains(token), $editLine)
    check("the resumed conversation still carries the bridge's tools",
          "mcp_fixture_echo" in frozenDirectTools(p.nc, sid),
          $frozenDirectTools(p.nc, sid))

    # --- a declaration that cannot come up is a startup failure, not a
    #     silently thinner toolset.
    let bad = runCliOnce(cliBin, root, "",
                         @["run", "--root=" & root, "--quiet",
                           "--mcp-timeout=20",
                           "--mcp={\"name\":\"broken\",\"type\":\"stdio\"," &
                           "\"command\":\"/nonexistent/mcp-server\"}",
                           "hello"])
    check("a server that cannot start fails the run", bad.code == 3,
          "code=" & $bad.code & "\n" & bad.output)
    let badLine = firstOf(bad.lines, "mcp")
    check("the failure names the server and the reason",
          badLine != nil and badLine{"name"}.getStr("") == "broken" and
          not badLine{"ready"}.getBool(false) and
          badLine{"error"}.getStr("").len > 0 and
          lastOf(bad.lines, "result") == nil, js(badLine))

    # --- malformed declarations are usage errors, before any harness work.
    let badJson = runCliOnce(cliBin, root, "",
                             @["run", "--mcp={not json}", "hello"])
    check("a malformed --mcp is a usage error", badJson.code == 2,
          "code=" & $badJson.code)
    let noName = runCliOnce(cliBin, root, "",
                            @["run", "--mcp={\"command\":\"x\"}", "hello"])
    check("a declaration without a name is refused", noName.code == 2,
          "code=" & $noName.code)

  report("CLI-RUN")

main()
