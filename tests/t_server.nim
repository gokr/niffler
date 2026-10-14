## Server lifecycle contract using fake systemd tools; never alters host services.
import std/[os, osproc, strutils]
import helpers

proc main() =
  when not defined(linux):
    echo "SERVER TEST PASSED (Linux only)"
    return
  let repo = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let root = tempRoot("server")
  defer: removeDir(root)
  let fake = root / "fake"
  let config = root / "config"
  createDir(fake)
  createDir(root / "var" / "bin")
  writeFile(root / "niffler.nimble", "# test root\n")
  writeFile(root / "var" / "bin" / "niffler", "#!/bin/sh\nexit 0\n")
  setFilePermissions(root / "var" / "bin" / "niffler", {fpUserRead, fpUserWrite, fpUserExec})
  let log = root / "calls"
  for name in ["systemctl", "journalctl", "loginctl"]:
    writeFile(fake / name, "#!/bin/sh\nprintf '%s\\n' \"" & name & " $*\" >> \"$SERVER_TEST_LOG\"\n" &
      (if name == "loginctl": "echo \"${SERVER_TEST_LINGER:-no}\"\n" else: "") &
      "exit \"${SERVER_TEST_FAIL:-0}\"\n")
    setFilePermissions(fake / name, {fpUserRead, fpUserWrite, fpUserExec})
  let oldPath = getEnv("PATH")
  let oldConfig = getEnv("XDG_CONFIG_HOME")
  defer:
    putEnv("PATH", oldPath)
    if oldConfig.len == 0: delEnv("XDG_CONFIG_HOME")
    else: putEnv("XDG_CONFIG_HOME", oldConfig)
    delEnv("SERVER_TEST_LOG")
    delEnv("SERVER_TEST_FAIL")
    delEnv("SERVER_TEST_LINGER")
  putEnv("PATH", fake & ":" & oldPath)
  putEnv("XDG_CONFIG_HOME", config)
  putEnv("SERVER_TEST_LOG", log)
  proc run(action: string): tuple[output: string, exitCode: int] =
    execCmdEx("bash " & quoteShell(repo / "scripts" / "server.sh") & " " & action & " " & quoteShell(root))
  let installed = run("install")
  check("service install succeeds with explicit root", installed.exitCode == 0, installed.output)
  check("linger warning is separate and actionable", "linger=no" in installed.output and "not guaranteed" in installed.output)
  var unitPath = ""
  for path in walkFiles(config / "systemd" / "user" / "*.service"): unitPath = path
  check("one scoped service generated", unitPath.len > 0)
  if unitPath.len == 0: report("SERVER TEST"); return
  let unit = readFile(unitPath)
  check("service forces isolated bus and persistent non-autoapproved core",
    "Environment=NIF_NATS_URL=\n" in unit and "Environment=NIF_NATS_SPAWN=1" in unit and
    "Environment=NIF_AUTOSTART=0" in unit and "Environment=NIF_AUTO_APPROVE=0" in unit and
    "WorkingDirectory=" & root in unit and "Environment=NIF_ROOT=" & root in unit)
  check("install enables but does not start", "--user enable" in readFile(log) and "--user start" notin readFile(log))
  check("idempotent install preserves unit", run("install").exitCode == 0 and readFile(unitPath) == unit)
  for action in ["start", "status", "logs", "stop"]:
    check("scoped " & action, run(action).exitCode == 0)
  check("logs use journal, no PID adoption", "journalctl --user -u niffler-" in readFile(log))
  putEnv("SERVER_TEST_FAIL", "1")
  check("manager errors propagate", run("start").exitCode != 0)
  delEnv("SERVER_TEST_FAIL")
  putEnv("SERVER_TEST_LINGER", "yes")
  check("linger enabled needs no warning", "not guaranteed" notin run("linger").output)
  writeFile(unitPath, "foreign installation\n")
  let before = readFile(log)
  check("conflicting install refuses overwrite", run("install").exitCode != 0 and readFile(unitPath) == "foreign installation\n")
  check("conflicting lifecycle refuses routing", run("stop").exitCode != 0)
  check("refusal never stops another service", readFile(log) == before & "systemctl --user show-environment\n")
  removeFile(unitPath)
  createSymlink(root / "niffler.nimble", unitPath)
  check("symlinked service refuses", run("install").exitCode != 0)
  let bootstrap = execCmdEx("cd " & quoteShell(repo) & " && bash scripts/bootstrap.sh --server --dry-run")
  check("server bootstrap adopts worktree", bootstrap.exitCode == 0 and "adopting this checkout" in bootstrap.output)
  check("server bootstrap omits TUI and extras", "would run: make install-tui" notin bootstrap.output and "would ask about optional" notin bootstrap.output)
  report("SERVER TEST")

main()
