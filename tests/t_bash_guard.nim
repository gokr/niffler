## Opt-in bash guard exercised through the actual component's NATS contract.
import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers
when defined(posix): import std/posix

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  let root = tempRoot("bash-guard")
  defer: removeDir(root)
  let a = root / "a"
  let b = root / "b"
  createDir(a)
  createDir(b)
  writeFile(a / "secret", "SECRET-A")
  writeFile(a / ".niffler-write-probe", "USER-FILE-MUST-SURVIVE")
  writeFile(b / "secret", "SECRET-B")
  # A secret OUTSIDE both workspaces: the strong case. The confined command
  # cannot create aliases there, so masking is a real boundary.
  let outsideSecret = root / "outside-secret"
  writeFile(outsideSecret, "OUTSIDE-SECRET")
  putEnv("NIF_BASH_SANDBOX_MASKS", "secret\n" & outsideSecret)
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let child = startComponent(repo / "var/bin/bash", url, root = root,
    extra = @[("NIF_BASH_SANDBOX", "on"),
              ("NIF_BASH_SANDBOX_MASKS", "secret\n" & outsideSecret),
              ("NIF_SANDBOX_ALLOW_DEGRADED", ""),
              ("NIF_SANDBOX_BACKEND", ""),
              ("NIF_OPENAI_API_KEY", "SENTINEL-KEY")])
  defer:
    if child.running(): child.terminate()
    discard child.waitForExit(2000)
    child.close()
  check("guarded bash registers", waitRegistered(nc, "bash"))
  let status = call(nc, "bash", "bash_sandbox_status", %*{})
  check("status distinguishes configured from applied",
    status{"enabled"}.getBool(false) and status{"state"}.getStr("") == "configured", $status)
  check("status warns about attestation limits",
    status{"text"}.getStr("").contains("actual-launch"), $status)
  proc run(ws, cmd: string, timeout = 10000): JsonNode =
    call(nc, "bash", "bash", %*{"command": cmd, "cwd": ws,
      "timeoutMs": timeout, "__workspace": {"root": ws}}, 15000)
  let probe = execCmdEx(quoteShell(repo / "var/bin/niffler-sandbox") & " probe < /dev/null")
  if probe.exitCode != 0:
    let refusal = run(a, "touch marker")
    check("unavailable backend starts no user command", not fileExists(a / "marker"), $refusal)
    echo "SKIP: full guard enforcement — " & probe.output
  else:
    for ws in [a, b, a]:
      let result = run(ws, "printf okay > marker; cat secret; printf '%s' \"${NIF_OPENAI_API_KEY-unset}\"")
      check("workspace write succeeds", fileExists(ws / "marker"), $result)
      check("configured secret is masked", not ($result).contains("SECRET-"), $result)
      check("provider environment is absent", result{"text"}.getStr("").contains("unset"), $result)
      # The launcher attests AFTER the command, so the verdict cannot be
      # forged by the command's own exit code.
      check("launcher attests to enforced policy",
            result{"sandbox"}{"state"}.getStr("") == "applied", $result)
      check("attestation names the backend",
            result{"sandbox"}{"backend"}.getStr("") == "bwrap", $result)
    check("policy probe preserves existing user file",
      readFile(a / ".niffler-write-probe") == "USER-FILE-MUST-SURVIVE")
    let large = run(a, "for i in $(seq 1 20000); do echo guarded-line-$i; done", 20000)
    let spill = large{"spill"}{"path"}.getStr("")
    check("guard preserves output spilling", spill.len > 0 and fileExists(spill), $large)
    if spill.len > 0 and fileExists(spill):
      check("trusted parent retains full output",
        readFile(spill).contains("guarded-line-10000") and
        large{"text"}.getStr("").contains("truncated"), spill)
    when defined(posix):
      # Independent process publishes cancellation while the serialized handler
      # is occupied. A fresh connection avoids sharing inherited NATS state.
      let publisher = fork()
      doAssert publisher >= 0
      if publisher == 0:
        sleep(1000)
        var bus = waitConnect(url)
        let notice = Envelope(v: 1, id: newId(), kind: ekEvent,
          payload: %*{"sessionId": "guard-cancel", "tool": "bash", "ts": epochTime()}).encode()
        discard natsConnection_Publish(bus.conn, "cancel.bash", notice.cstring, notice.len.cint)
        discard natsConnection_Flush(bus.conn)
        bus.close()
        exitnow(0)
      let cancelled = call(nc, "bash", "bash", %*{
        "command": "sleep 3; touch cancelled-late", "cwd": a, "timeoutMs": 10000,
        "__workspace": {"root": a}, "__session": {"session": "guard-cancel"}}, 15000)
      var status: cint
      discard waitpid(publisher, status, 0)
      check("guard preserves cancellation outcome",
        cancelled{"exit_code"}.getInt(0) == 130 and cancelled{"cancelled"}.getBool(false), $cancelled)
      sleep(2500)
      check("cancelled child does not survive", not fileExists(a / "cancelled-late"))
    let exit125 = run(a, "exit 125")
    check("command exit 125 is not mislabelled as a failed policy",
      exit125{"exit_code"}.getInt(0) == 125 and
      exit125{"sandbox"}{"state"}.getStr("") == "applied", $exit125)
    let outside = run(a, "echo escaped > " & quoteShell(b / "outside"))
    check("second conversation workspace not writable", not fileExists(b / "outside"), $outside)
    # MEASURED: an in-workspace mask is not a weaker hiding mechanism for a
    # guarded command — reads, copies and deletes of it all FAIL, and the host
    # file survives. An earlier draft asserted the command could copy the secret
    # away; the measurement disproved it. What must be reported instead is
    # SCOPE: the mask covers only commands launched through this guard.
    for ws in [a, b]:
      let masked = run(ws, "cat secret; cp secret stolen 2>/dev/null; rm -f secret; echo done")
      check("an in-workspace mask blocks reads, copies and deletes",
        not fileExists(ws / "stolen") and fileExists(ws / "secret") and
        not ($masked).contains("SECRET-"), $masked)
      check("the result states the mask's scope limit",
        masked{"sandbox"}{"inWorkspaceMasks"}.getBool(false) and
        masked{"sandbox"}{"note"}.getStr("").contains("only to commands launched through the guard"), $masked)
    if outsideSecret.len > 0:
      let outsideRun = call(nc, "bash", "bash", %*{
        "command": "cat " & quoteShell(outsideSecret), "cwd": a, "timeoutMs": 10000,
        "__workspace": {"root": a}}, 15000)
      check("an outside secret is genuinely unreadable",
        not ($outsideRun).contains("OUTSIDE-SECRET"), $outsideRun)
      # The scope flag is PER LAUNCH: this launch also masks an in-workspace
      # path, so it is correctly set. Asserting it absent here would be wrong.
      check("the scope flag reflects any in-workspace mask in the launch",
        outsideRun{"sandbox"}{"inWorkspaceMasks"}.getBool(false), $outsideRun)
    let timed = run(a, "sleep 3; touch late", 1000)
    check("guard preserves timeout outcome", timed{"exit_code"}.getInt(0) == 124, $timed)
    sleep(2500)
    check("timed-out child does not survive", not fileExists(a / "late"))
  let noRoot = call(nc, "bash", "bash", %*{"command": "true"})
  check("guard refuses missing authoritative root", noRoot{"exit_code"}.getInt(0) == 125, $noRoot)
  let bg = call(nc, "bash", "bash", %*{"command": "true", "run_in_background": true,
    "__workspace": {"root": a}})
  check("unsupported guarded background call refuses", bg{"exit_code"}.getInt(0) == 125, $bg)
  report("BASH GUARD TEST")
main()
