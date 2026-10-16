## Write-arbitration end-to-end: the dispatch gate refuses a real edit.
##
## t_locks proves the lock table's own contract over the bus. This proves the
## other half — that core's dispatch gate actually consults it, and that a
## refusal reaches the MODEL as a normal tool result naming the holder (never a
## crash, never a silent unguarded write).
##
## The "other conversation" is a lease taken directly over the bus, which is
## exactly what another session runner's dispatch would have taken. A scripted
## mock LLM then asks for one real `edit` in that tree, so the refusal travels
## the whole path: runner -> dispatch gate -> locks -> tool result -> transcript.

import std/[json, os, osproc, strutils, times]
import natsnim
import helpers

proc compileMock(llmBin, repoRoot: string) =
  ## The mock llm stand-in (tests/mock_llm.nim) replaces the sandbox's copy:
  ## same component name, same hidden chat tool, no provider and no network.
  let (outp, rc) = execCmdEx("nim c --hints:off --path:" &
    quoteShell(repoRoot / "sdk") & " -o:" & quoteShell(llmBin) & " " &
    quoteShell(repoRoot / "tests" / "mock_llm.nim"))
  if rc != 0:
    fail("mock llm failed to compile: " & outp)
    report("ARBITRATION TEST")
    quit(1)

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  ## Poll the catalog's component view until `name` is registered (robust
  ## against fast registrations that precede a reg.publish subscription).
  for _ in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  false

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
    getEnv("NIF_ROOT", getAppDir().parentDir()))

  let sandbox = newCoreSandbox("arbitration", ["store", "edit", "locks", "llm", "fabric", "bash"])
  copyFileWithPermissions(repoRoot / "var" / "bin" / "fabric-exec",
                          sandbox.sandboxBin("fabric-exec"))
  let root = sandbox.root
  defer: removeDir(root)

  # The conversation workspace: one file the "other" conversation holds.
  createDir(root / "ws")
  writeFile(root / "ws" / "held.txt", "one\ntwo\nthree\n")

  compileMock(sandbox.sandboxBin("llm"), repoRoot)

  # One scripted round: an exact-match edit of the held file. The mock returns
  # this tool call, the gate judges it, and the second round's final answer
  # lets the turn close so the transcript exists to read.
  putEnv("NIF_MOCK_ROUNDS", "3")
  putEnv("NIF_MOCK_TOOLJSON", $(%*[{"name": "edit", "arguments": {
    "path": root / "ws" / "held.txt",
    "edits": [{"old_string": "two", "new_string": "TWO"}]}},
    {"name": "fabric", "arguments": {
      "tools": ["write"],
      "code": "import fabricguest\nfinish(callTool(\"write\", " &
        "\"{\\\"path\\\":\\\"nested.txt\\\",\\\"content\\\":\\\"nested-ok\\\"}\"))"}},
    {"name": "bash", "arguments": {"command": "sleep 4; printf writer-finished",
                                    "timeoutMs": 10000}}]))

  # A lease that outlives the turn, so the refusal is deterministic rather than
  # a race with turn timing.
  putEnv("NIF_LOCK_TTL_MS", "500")

  let (server, url) = startNats()
  defer: stopServer(server)

  let coreProc = startComponent(sandbox.sandboxBin("niffler"), url, root = root,
                                extra = @[("NIF_AUTO_APPROVE", "1"), ("NIF_BASH_SANDBOX_MAP", ""),
                                          ("NIF_BASH_NET", "")],
                                logFile = root / "core.log")
  defer:
    if coreProc.running(): coreProc.terminate()
    discard coreProc.waitForExit(2000)

  var nc = waitConnect(url)
  defer: nc.close()

  var up = false
  for _ in 0 ..< 80:
    let r = call(nc, "store", "list", %*{"kind": "conversation", "limit": 1}, 3000)
    if r{"ok"}.getBool(false) and waitComponent(nc, "locks", 1) and
        waitComponent(nc, "edit", 1) and waitComponent(nc, "llm", 1):
      up = true
      break
    sleep(250)
  if not up:
    fail("harness never came up")
    if fileExists(root / "core.log"):
      echo "--- core.log ---"
      echo readFile(root / "core.log")
    for name in ["locks", "edit", "llm", "store"]:
      let lf = root / "var" / "logs" / (name & ".log")
      if fileExists(lf):
        echo "--- " & name & ".log ---"
        echo readFile(lf)
    report("ARBITRATION TEST")
    quit(1)

  # The OTHER conversation holds the workspace (an opaque writer's root claim —
  # what bash's declaration produces). Nothing else in this test takes that
  # lease, so the edit below can only be refused by the gate consulting it.
  let held = call(nc, "locks", "lock_acquire",
                  %*{"root": root / "ws", "roots": [root / "ws"],
                     "paths": [root / "ws"], "sessionId": "conv-holder",
                     "tool": "bash", "callId": "holder-call", "ttlMs": 120000}, 10000)
  check("foreign conversation holds the workspace", held{"ok"}.getBool(false), $held)

  # Run a real turn in a different conversation; its edit must be refused.
  let turn = call(nc, "core", "session",
                  %*{"sessionId": "conv-rival", "content": "edit the held file",
                     "cwd": root / "ws"}, 60000)
  check("turn ran", turn{"ok"}.getBool(false) or turn{"status"}.getStr("") != "",
        $turn)

  # Read the transcript back: the tool result is the gate's verdict.
  var transcript = ""
  var sawBusy = false
  for _ in 0 ..< 40:
    let msgs = call(nc, "store", "list",
                    %*{"kind": "message", "idPrefix": "conv-rival:", "limit": 50},
                    5000)
    transcript = $msgs
    if transcript.contains("E_WRITE_BUSY"):
      sawBusy = true
      break
    sleep(500)

  check("the refused edit reaches the transcript as E_WRITE_BUSY", sawBusy,
        transcript[0 ..< min(700, transcript.len)])
  if sawBusy:
    check("the refusal names the holder conversation",
          transcript.contains("conv-holder"),
          transcript[0 ..< min(700, transcript.len)])

  # The file must be untouched: a refusal is a refusal, not a partial write.
  check("the held file was not modified",
        readFile(root / "ws" / "held.txt") == "one\ntwo\nthree\n",
        readFile(root / "ws" / "held.txt"))

  # Freeing the workspace unblocks the same operation — the lock blocks, it
  # does not poison.
  discard call(nc, "locks", "lock_release", %*{"leaseId": "conv-holder:holder-call"})
  let after = call(nc, "locks", "lock_acquire",
                   %*{"root": root / "ws", "roots": [root / "ws"],
                      "paths": [root / "ws"], "sessionId": "conv-after",
                      "tool": "edit", "callId": "after-call"}, 10000)
  check("released workspace is claimable again", after{"ok"}.getBool(false), $after)

  discard call(nc, "locks", "lock_release", %*{"leaseId": "conv-after:after-call"})
  let nestedTurn = call(nc, "core", "session", %*{
    "sessionId": "conv-nested", "content": "exercise nested writer",
    "cwd": root / "ws"}, 120000)
  check("nested Fabric write succeeds without self-conflict",
    fileExists(root / "ws" / "nested.txt"), $nestedTurn)
  if fileExists(root / "ws" / "nested.txt"):
    check("nested write produced expected bytes",
      readFile(root / "ws" / "nested.txt") == "nested-ok")

  # Start a real slow writer via another client. A short operator TTL must not
  # expire its claim while the command is still executing.
  let slow = startComponent(sandbox.sandboxBin("cli"), url, root = root,
    args = ["--timeout=120", "call", "session", $(%*{
      "sessionId": "conv-long", "content": "long writer",
      "cwd": root / "ws"})], logFile = root / "slow-client.log")
  defer:
    if slow.running(): slow.terminate()
    discard slow.waitForExit(2000)
    slow.close()
  var writerLease: JsonNode
  let until = epochTime() + 60.0
  while epochTime() < until:
    let status = call(nc, "locks", "lock_status", %*{"sessionId": "conv-long"})
    let leases = status{"leases"}
    if leases != nil and leases.kind == JArray:
      for lease in leases:
        if lease{"tool"}.getStr("") == "bash": writerLease = lease
    if writerLease != nil: break
    sleep(50)
  if writerLease == nil:
    echo readFile(root / "slow-client.log")
    echo $(call(nc, "store", "list", %*{
      "kind": "message", "idPrefix": "conv-long:", "limit": 30}))
  check("long writer acquired a real dispatch claim", writerLease != nil)
  if writerLease != nil:
    check("dispatch lease outlives transport timeout",
      writerLease{"ttlMs"}.getInt(0) >= 600000, $writerLease)
    sleep(1000) # twice the operator TTL, still within the running command
    check("slow client still executing", slow.running())
    let contender = call(nc, "locks", "lock_acquire", %*{
      "root": root / "ws", "paths": [root / "ws" / "held.txt"],
      "sessionId": "conv-contender", "tool": "edit", "callId": "contender"})
    check("live writer remains exclusive past configured TTL",
      contender{"holder"}.getStr("") == "conv-long", $contender)
  discard slow.waitForExit(15000)
  let afterLong = call(nc, "locks", "lock_status", %*{"sessionId": "conv-long"})
  check("completed writer releases its dispatch claims",
    afterLong{"count"}.getInt(-1) == 0, $afterLong)

  # Harness-state arbitration (WRITE-ARBITRATION phase 2). plugins writes
  # $NIF_ROOT/var/plugins and var/bin — NOT the conversation workspace. Before
  # the harness claim shape existed these tools declared nothing, so the gate
  # fell back to the opaque workspace-root claim: for a client launched in a
  # project directory (NIF_ROOT != workspace) the real write went unguarded
  # while the claim covered an unrelated tree.
  #
  # This proves the claim PATH — which directory the gate is allowed to name —
  # at the locks contract level. A scripted turn cannot vary NIF_ROOT from the
  # workspace (both are the sandbox root here), so the old opaque spelling and
  # the new one would overlap and the assertion would pass either way; the
  # gate's own computation is covered by t_locks' pure checks instead.
  let harnessLease = call(nc, "locks", "lock_acquire", %*{
    "root": root / "var" / "plugins", "roots": [root / "var", root / "ws"],
    "paths": [root / "var" / "plugins"], "sessionId": "conv-installer",
    "tool": "plugin_install", "callId": "install-1", "ttlMs": 120000}, 10000)
  check("a harness-state claim is accepted under $NIF_ROOT/var",
        harnessLease{"ok"}.getBool(false), $harnessLease)

  # A second conversation installing a package is excluded — the collision the
  # phase-2 declarations exist to prevent.
  let secondInstall = call(nc, "locks", "lock_acquire", %*{
    "root": root / "var" / "plugins", "roots": [root / "var", root / "ws"],
    "paths": [root / "var" / "plugins"], "sessionId": "conv-installer2",
    "tool": "plugin_install", "callId": "install-2"}, 10000)
  check("a second conversation cannot install into var/plugins concurrently",
        not secondInstall{"ok"}.getBool(false) and
        secondInstall{"holder"}.getStr("") == "conv-installer", $secondInstall)

  # Disjoint harness state stays parallel: another var/ subtree is not blocked
  # by the plugins claim (striping, not a global lock).
  let otherHarness = call(nc, "locks", "lock_acquire", %*{
    "root": root / "var" / "models", "roots": [root / "var"],
    "paths": [root / "var" / "models"], "sessionId": "conv-models",
    "tool": "models_refresh", "callId": "models-1"}, 10000)
  check("disjoint harness state stays parallel",
        otherHarness{"ok"}.getBool(false), $otherHarness)
  discard call(nc, "locks", "lock_release",
               %*{"leaseId": "conv-models:models-1"})

  # The control plane is not claimable through this path at all — the fence
  # must refuse it, or a workspace write guard would appear to own the tree
  # the agent edits (SANDBOX-PLAN §6).
  let controlPlane = call(nc, "locks", "lock_acquire", %*{
    "root": root / "components", "roots": [root / "var"],
    "paths": [root / "components"], "sessionId": "conv-control",
    "tool": "plugin_install", "callId": "control-1"}, 10000)
  check("the harness control plane is refused by the fence",
        controlPlane{"error"}.getStr("").contains("E_WRITE_OUTSIDE"),
        $controlPlane)

  discard call(nc, "locks", "lock_release",
               %*{"leaseId": "conv-installer:install-1"})
  let freedHarness = call(nc, "locks", "lock_acquire", %*{
    "root": root / "var" / "plugins", "roots": [root / "var"],
    "paths": [root / "var" / "plugins"], "sessionId": "conv-installer2",
    "tool": "plugin_install", "callId": "install-3"}, 10000)
  check("released harness state is claimable again",
        freedHarness{"ok"}.getBool(false), $freedHarness)
  discard call(nc, "locks", "lock_release",
               %*{"leaseId": "conv-installer2:install-3"})

  report("ARBITRATION TEST")

main()
