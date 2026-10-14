## Opt-in bash guard exercised through the actual component's NATS contract.
import std/[json, os, osproc, strutils, times]
import natsnim
import helpers

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  let root = tempRoot("bash-guard")
  defer: removeDir(root)
  let a = root / "a"
  let b = root / "b"
  createDir(a)
  createDir(b)
  writeFile(a / "secret", "SECRET-A")
  writeFile(b / "secret", "SECRET-B")
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  let child = startComponent(repo / "var/bin/bash", url, root = root,
    extra = @[("NIF_BASH_SANDBOX", "on"),
              ("NIF_BASH_SANDBOX_MASKS", "secret"),
              ("NIF_SANDBOX_ALLOW_DEGRADED", ""),
              ("NIF_SANDBOX_BACKEND", ""),
              ("NIF_OPENAI_API_KEY", "SENTINEL-KEY")])
  defer:
    if child.running(): child.terminate()
    discard child.waitForExit(2000)
    child.close()
  check("guarded bash registers", waitRegistered(nc, "bash"))
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
    let outside = run(a, "echo escaped > " & quoteShell(b / "outside"))
    check("second conversation workspace not writable", not fileExists(b / "outside"), $outside)
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
