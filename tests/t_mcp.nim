## MCP integration — manager CRUD over the store, bridge spawning with
## core.spawn args, catalog participation (discover/invoke onDemand tools),
## lazy sessions, tool-contract drift (server-push list_changed), and
## removal. The fixture MCP server (tests/fixtures/mcp_server.nim) is a
## dependency-free stdio MCP implementation compiled into the sandbox.

import std/[json, os, osproc, streams, strtabs, strutils, times]
when defined(nifflerNimNats):
  # Pure-Nim client (github.com/gokr/natsnim), aliased to `natswrapper` so every
  # call site below stays byte-identical. Enabled with
  #   make build NIMFLAGS='-d:nifflerNimNats --path:$HOME/git/natsnim/src'
  # See docs/research/NATSNIM.md.
  import natsnim as natswrapper
else:
  import natswrapper
import helpers

proc waitForRegistration(nc: NatsConnection, name: string, timeoutMs = 20_000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    let snap = call(nc, "core", "catalog", %*{"op": "snapshot"}, 3_000)
    if snap != nil and snap.kind == JObject and snap{"components"} != nil:
      for comp in snap{"components"}:
        if comp{"name"}.getStr("") == name:
          return true
    sleep(150)
  return false

proc waitForNoComponent(nc: NatsConnection, name: string, timeoutMs = 15_000): bool =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    let snap = call(nc, "core", "catalog", %*{"op": "snapshot"}, 3_000)
    var found = false
    if snap != nil and snap.kind == JObject and snap{"components"} != nil:
      for comp in snap{"components"}:
        if comp{"name"}.getStr("") == name:
          found = true
    if not found:
      return true
    sleep(150)
  return false

proc discoverHints(nc: NatsConnection, component: string): JsonNode =
  call(nc, "core", "discover", %*{"component": component}, 5_000)

proc toolsInHints(res: JsonNode): seq[string] =
  # Component-scoped discover returns {"component": {...}}; query-scoped
  # returns {"components": [...]}. Handle both.
  var comps: JsonNode
  if res == nil or res.kind != JObject:
    return
  if res{"component"} != nil:
    comps = %[res{"component"}]
  else:
    comps = res{"components"}
  if comps == nil:
    return
  for comp in comps:
    for group in ["direct", "onDemand"]:
      if comp{group} == nil:
        continue
      for item in comp{group}:
        result.add(item{"name"}.getStr(""))

proc hasTool(nc: NatsConnection, component, tool: string): bool =
  tool in toolsInHints(discoverHints(nc, component))

# startMockRegistry compiles + runs tests/fixtures/mock_registry.nim and
# returns the process and the port it announced (first stdout line).
proc startMockRegistry(repoRoot, root: string): (Process, int) =
  let bin = root / "var" / "mock-registry"
  let (outp, code) = execCmdEx(
    "nim c --hints:off --warnings:off -o:" & quoteShell(bin) & " " &
    quoteShell(repoRoot / "tests" / "fixtures" / "mock_registry.nim"),
    options = {poUsePath})
  if code != 0 or not fileExists(bin):
    echo outp
    fail("mock registry did not compile")
    report("MCP TEST")
  let p = startProcess(bin, options = {poStdErrToStdOut, poUsePath})
  var line = ""
  var ch: char
  try:
    # Read the announced port char by char until newline (Stream API).
    while true:
      ch = p.outputStream.readChar()
      if ch == '\n' or ch == '\0':
        break
      line.add(ch)
  except CatchableError:
    discard
  let port = parseInt(line)
  return (p, port)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for binary in ["niffler", "session", "store", "mcp", "mcp-bridge", "cli"]:
    if not fileExists(repoRoot / "var" / "bin" / binary):
      fail("missing " & binary & " binary — run `make build` first")
  if failures > 0:
    report("MCP TEST")

  # Compile the fixture server into the sandbox (std-only Nim).
  let sandbox = newCoreSandbox("mcp", ["store", "mcp"])
  let root = sandbox.root
  defer: removeDir(root)
  copyFileWithPermissions(repoRoot / "var" / "bin" / "mcp-bridge",
                          sandbox.sandboxBin("mcp-bridge"))
  let fixtureBin = root / "var" / "mcp-fixture"
  let compileCmd = "nim c --hints:off --warnings:off -o:" & quoteShell(fixtureBin) &
                   " " & quoteShell(repoRoot / "tests" / "fixtures" / "mcp_server.nim")
  let (output, code) = execCmdEx(compileCmd, options = {poUsePath})
  if code != 0 or not fileExists(fixtureBin):
    echo output
    fail("fixture MCP server did not compile — run tests/fixtures/mcp_server.nim by hand")
    report("MCP TEST")

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  # Mock official MCP Registry for mcp_search: a tiny HTTP responder on a
  # localhost port; the manager reads NIF_MCP_REGISTRY_URL.
  let (mockRegistry, registryPort) = startMockRegistry(repoRoot, root)
  defer: stopProcess(mockRegistry, 500)
  # NIF_AUTO_APPROVE=1: mcp_add/mcp_remove are approval-gated and invoke of
  # the approval-tagged fixture tool must not block a headless test.
  let coreProcess = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                   extra = [("NIF_AUTO_APPROVE", "1"),
                                            ("NIF_MCP_REGISTRY_URL", "http://127.0.0.1:" & $registryPort)])
  defer: stopProcess(coreProcess, 1500)

  check("mcp manager registered", waitForRegistration(nc, "mcp"))

  # --- add: validate, store, spawn -----------------------------------------
  let added = call(nc, "mcp", "mcp_add", %*{
    "name": "fixture", "type": "stdio", "command": fixtureBin,
    "env": {"FIXTURE_SECRET": "s3cr3t"},
    "timeoutMs": 15000,
  }, 60_000)
  check("mcp_add ok", added{"ok"}.getBool(false), $added)
  check("mcp_add found the fixture tools",
        added{"toolCount"}.getInt(0) == 4, $added)

  check("bridge registered as mcp-fixture", waitForRegistration(nc, "mcp-fixture"))

  # Bridge announces the cached contract: prefixed, on-demand hints.
  let names = toolsInHints(discoverHints(nc, "mcp-fixture"))
  check("bridge tools are prefixed and on-demand",
        "mcp_fixture_echo" in names and "mcp_fixture_fail" in names and
        "mcp_fixture_mutate_tools" in names, $names)

  # --- discover: schema shape ----------------------------------------------
  let schema = call(nc, "core", "discover",
                    %*{"component": "mcp-fixture", "tools": ["mcp_fixture_echo"]}, 5_000)
  let echoSchema = schema{"tools"}{0}
  check("discover returns the full schema",
        echoSchema{"name"}.getStr("") == "mcp_fixture_echo" and
        echoSchema{"schema"}{"type"}.getStr("") == "object" and
        echoSchema{"schema"}{"x-harness"}{"onDemand"}.getBool(false), $schema)

  # --- invoke: lazy session, first call connects ----------------------------
  let invoked = call(nc, "core", "invoke",
                     %*{"tool": "mcp_fixture_echo",
                        "arguments": {"message": "hello"}}, 30_000)
  check("invoke runs the MCP tool",
        invoked{"text"}.getStr("") == "echo: hello", $invoked)

  let failed = call(nc, "core", "invoke",
                    %*{"tool": "mcp_fixture_fail", "arguments": {}}, 30_000)
  check("MCP tool errors surface as errors",
        failed{"error"}.getStr("").contains("boom"), $failed)

  # --- cancellation: cancel.mcp-fixture aborts the in-flight MCP call -------
  # The slow tool sleeps 8s. cli routes tool calls verbatim to
  # svc.<comp>.call, so __session reaches the bridge exactly as published —
  # core overwrites it on the core-dispatch path (x-harness.sessionId owns
  # that key), which is what keeps unattributed callers from spoofing a
  # session. The cancel event carries the same sessionId the runner injects.
  let cliBin = repoRoot / "var" / "bin" / "cli"
  let slowArgs = "mcp_fixture_slow {\"ms\":8000,\"__session\":{\"session\":\"cancel-probe\"}}"
  var cliEnv = newStringTable()
  cliEnv["NIF_NATS_URL"] = url
  cliEnv["NIF_ROOT"] = root
  cliEnv["PATH"] = getEnv("PATH")
  let slowCall = startProcess(cliBin, args = @["call"] & slowArgs.split(' ', maxsplit = 1),
                              env = cliEnv, options = {poStdErrToStdOut, poUsePath})
  sleep(1200)  # the MCP call is now sleeping inside the bridge
  let cancelStart = epochTime()
  nc.publish("cancel.mcp-fixture",
    "{\"v\":1,\"id\":\"cancel-probe\",\"kind\":\"event\",\"payload\":" &
    $(%*{"sessionId": "cancel-probe", "tool": "mcp_fixture_slow", "ts": epochTime()}) & "}")
  discard slowCall.waitForExit(10_000)
  let slowOutput = slowCall.outputStream.readAll()
  let slowDuration = epochTime() - cancelStart
  check("cancel event aborts the in-flight MCP tool call",
        slowDuration < 6.0 and slowOutput.contains("context canceled"),
        "took " & $slowDuration & "s: " & slowOutput[0 ..< min(slowOutput.len, 300)])
  slowCall.close()

  # --- resources: list + read through the bridge ---------------------------
  let listed = call(nc, "core", "invoke",
                    %*{"tool": "mcp_fixture_resources", "arguments": {"op": "list"}}, 30_000)
  check("mcp resources list reachable",
        listed != nil and listed{"count"}.getInt == 1 and
        ($listed{"resources"}).contains("doc://readme"), $listed)
  let read = call(nc, "core", "invoke",
                  %*{"tool": "mcp_fixture_resources",
                     "arguments": {"op": "read", "uri": "doc://readme"}}, 30_000)
  check("mcp resources read returns content",
        read != nil and ($read{"contents"}).contains("fixture readme contents"),
        $read)

  # --- prompts: slash command registered + hidden prompt tool renders ------
  let catalog = call(nc, "core", "catalog", %*{"op": "snapshot"}, 10_000)
  var slashFound, promptToolFound = false
  if catalog != nil and catalog.kind == JObject:
    for comp in catalog{"components"}:
      if comp{"name"}.getStr("") != "mcp-fixture":
        continue
      for cmd in comp{"slash"}:
        if cmd{"name"}.getStr("") == "mcp-fixture-greet":
          slashFound = true
      for tool in comp{"tools"}:
        if tool{"name"}.getStr("") == "mcp_fixture_prompt":
          promptToolFound = true
  check("drift: prompt registered as slash command", slashFound, $catalog)
  check("prompt tool registered (hidden)", promptToolFound, $catalog)
  let rendered = call(nc, "mcp-fixture", "mcp_fixture_prompt",
                      %*{"name": "greet", "arguments": {"name": "Ada"}}, 30_000)
  let renderedText = $rendered
  check("prompt renders the template",
        renderedText.contains("greet") and renderedText.contains("Ada"), renderedText)
  let promptRecord = call(nc, "store", "get",
                          %*{"kind": "mcp", "id": "fixture"}, 5_000)
  var promptCached = false
  for p in promptRecord{"value"}{"prompts"}:
    if p{"name"}.getStr("") == "greet":
      promptCached = true
  check("prompt templates cached in the store", promptCached, $promptRecord)

  # --- mcp_search: registry browse (mocked base URL) -----------------------
  let search = call(nc, "mcp", "mcp_search", %*{"query": "github"}, 20_000)
  check("mcp_search returns registry entries",
        search{"ok"}.getBool(false) and search{"count"}.getInt(0) >= 1, $search)
  check("mcp_search marks installable entries",
        search{"entries"}{0}{"installable"}.getBool(false), $search)

  # --- mcp_servers: listing redacts secrets ---------------------------------
  let listing = call(nc, "mcp", "mcp_servers", %*{}, 15_000)
  check("mcp_servers lists the record", listing{"count"}.getInt(0) == 1, $listing)
  check("mcp_servers shows live bridge state",
        listing{"servers"}{0}{"live"}.getBool(false) and
        listing{"servers"}{0}{"bridge"}{"connected"}.getBool(false), $listing)
  check("mcp_servers redacts env values",
        not ($listing).contains("s3cr3t") and
        listing{"servers"}{0}{"envKeys"}{0}.getStr("") == "FIXTURE_SECRET", $listing)

  # --- drift: server pushes tools/list_changed ------------------------------
  discard call(nc, "core", "invoke",
               %*{"tool": "mcp_fixture_mutate_tools", "arguments": {}}, 30_000)
  # The bridge detects the changed contract, persists the fresh listing and
  # restarts (supervisor backoff); the new tool becomes discoverable.
  var driftOk = false
  let driftDeadline = epochTime() + 30.0
  while epochTime() < driftDeadline:
    if hasTool(nc, "mcp-fixture", "mcp_fixture_extra_tool"):
      driftOk = true
      break
    sleep(300)
  check("drift: restarted bridge announces the new tool", driftOk)
  let driftedRecord = call(nc, "store", "get",
                           %*{"kind": "mcp", "id": "fixture"}, 5_000)
  var hasExtra = false
  for t in driftedRecord{"value"}{"tools"}:
    if t{"name"}.getStr("") == "extra_tool":
      hasExtra = true
  check("drift: fresh tool listing persisted", hasExtra, $driftedRecord)

  # --- edit: re-validate and respawn ----------------------------------------
  let edited = call(nc, "mcp", "mcp_edit",
                    %*{"name": "fixture", "approval": "always"}, 60_000)
  check("mcp_edit ok", edited{"ok"}.getBool(false), $edited)
  let editedRecord = call(nc, "store", "get",
                          %*{"kind": "mcp", "id": "fixture"}, 5_000)
  check("mcp_edit persisted the approval",
        editedRecord{"value"}{"approval"}.getStr("") == "always", $editedRecord)
  check("edited bridge re-registered", waitForRegistration(nc, "mcp-fixture"))

  # --- spawn args persisted for boot restore --------------------------------
  let compRecord = call(nc, "store", "get",
                        %*{"kind": "component", "id": "mcp-fixture"}, 5_000)
  check("spawn args persisted",
        compRecord{"value"}{"args"}{0}.getStr("") == "--server" and
        compRecord{"value"}{"args"}{1}.getStr("") == "fixture", $compRecord)

  # --- remove ---------------------------------------------------------------
  let removed = call(nc, "mcp", "mcp_remove", %*{"name": "fixture"}, 30_000)
  check("mcp_remove ok", removed{"ok"}.getBool(false), $removed)
  check("bridge left the catalog", waitForNoComponent(nc, "mcp-fixture"))
  let gone = call(nc, "store", "get", %*{"kind": "mcp", "id": "fixture"}, 5_000)
  check("record deleted", gone{"error"}.getStr("").len > 0, $gone)

  # --- stdio guard: no orphaned MCP servers, ever ---------------------------
  # A dedicated fixture copy runs under its own guard; SIGKILLing the guard
  # must reap the server via the kernel's PDEATHSIG (not just cooperative
  # cleanup), because a SIGKILLed process runs no handlers.
  let guardFixture = root / "var" / "guard-fixture"
  copyFileWithPermissions(fixtureBin, guardFixture)
  let fifo = root / "var" / "guard-fifo"
  discard execCmdEx("mkfifo " & quoteShell(fifo))
  let guardCmd = "exec 3<> " & quoteShell(fifo) & "; exec " &
                 quoteShell(sandbox.sandboxBin("mcp-bridge")) &
                 " --stdio-guard " & quoteShell(guardFixture)
  let guardProc = startProcess("/bin/bash", args = ["-c", guardCmd],
                               options = {poStdErrToStdOut, poUsePath})
  defer: stopProcess(guardProc, 500)
  var guardUp = false
  for i in 0 ..< 100:
    let (outp, code) = execCmdEx("pgrep -x guard-fixture")
    if code == 0 and outp.len > 0:
      guardUp = true
      break
    sleep(100)
  check("guard launched the MCP server subprocess", guardUp)
  # SIGKILL the guard (exec'd bash pid == bridge pid).
  discard execCmdEx("kill -9 " & $guardProc.processID)
  var guardReaped = false
  for i in 0 ..< 50:
    let (outp, code) = execCmdEx("pgrep -x guard-fixture")
    if code != 0 or outp.len == 0:
      guardReaped = true
      break
    sleep(100)
  check("SIGKILLed guard leaves no orphaned MCP server", guardReaped)

  # --- adding a broken server fails cleanly ---------------------------------
  let badAdd = call(nc, "mcp", "mcp_add", %*{
    "name": "broken", "type": "stdio",
    "command": "/nonexistent/mcp-server-binary",
  }, 60_000)
  check("mcp_add rejects an unusable server",
        badAdd{"error"}.getStr("").len > 0, $badAdd)
  let badRecord = call(nc, "store", "get", %*{"kind": "mcp", "id": "broken"}, 5_000)
  check("failed add leaves no record", badRecord{"error"}.getStr("").len > 0, $badRecord)

  report("MCP TEST")

when isMainModule:
  main()
