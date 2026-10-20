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
  # The fakes answer unit state from the environment so `persist` can be driven
  # through every readiness combination without touching a real service manager.
  const systemctlStub = """#!/bin/sh
printf '%s\n' "systemctl $*" >> "$SERVER_TEST_LOG"
case "$*" in
  *" is-enabled "*) echo "${SERVER_TEST_ENABLED:-enabled}" ;;
  *" is-active "*) echo "${SERVER_TEST_ACTIVE:-active}" ;;
  *" show "*) echo "${SERVER_TEST_RESTART:-always}" ;;
esac
exit "${SERVER_TEST_FAIL:-0}"
"""
  writeFile(fake / "systemctl", systemctlStub)
  setFilePermissions(fake / "systemctl", {fpUserRead, fpUserWrite, fpUserExec})
  for name in ["journalctl", "loginctl"]:
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
    delEnv("SERVER_TEST_ENABLED")
    delEnv("SERVER_TEST_ACTIVE")
    delEnv("SERVER_TEST_RESTART")
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
  # A resident server comes back from a crash or a stray kill; only an explicit
  # stop (which systemd never restarts) leaves it down.
  check("service restarts on any exit, not just failure",
    "Restart=always\n" in unit and "Restart=on-failure" notin unit)
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
  # A unit from an older scripts/server.sh must be refreshable — that is the
  # only way a changed contract (a new restart policy, a new Environment=
  # line) reaches an already-provisioned instance, since install refuses it.
  removeFile(unitPath)
  putEnv("SERVER_TEST_LINGER", "no")
  let fresh = run("install")
  check("refresh baseline install", fresh.exitCode == 0, fresh.output)
  let current = readFile(unitPath)
  writeFile(unitPath, current.replace("Restart=always", "Restart=on-failure"))
  check("install refuses a stale contract", run("install").exitCode != 0)
  let stale = run("persist")
  check("persist reports the stale unit and how to fix it",
    stale.exitCode != 0 and "unit=stale" in stale.output and "server.sh refresh" in stale.output, stale.output)
  putEnv("SERVER_TEST_LOG", log)
  writeFile(log, "")
  let refreshed = run("refresh")
  check("refresh replaces a stale unit", refreshed.exitCode == 0 and readFile(unitPath) == current, refreshed.output)
  let refreshLog = readFile(log)
  check("refresh stops the old process and never starts one",
    "--user stop niffler-" in refreshLog and "--user start" notin refreshLog, refreshLog)
  check("refresh keeps the unit enabled", "--user enable niffler-" in refreshLog, refreshLog)
  check("refresh is idempotent", run("refresh").exitCode == 0 and readFile(unitPath) == current)
  writeFile(unitPath, "foreign installation\n")
  check("refresh refuses a unit it did not write", run("refresh").exitCode != 0 and readFile(unitPath) == "foreign installation\n")
  removeFile(unitPath)
  check("refresh without a unit points at install", "run install" in run("refresh").output)
  # Readiness: the report must never claim persistence it cannot prove (host
  # boot policy is invisible from inside the guest), and must name each fix.
  discard run("install")
  putEnv("SERVER_TEST_LINGER", "yes")
  let ready = run("persist")
  check("persist is green only with linger, an enabled active unit and restart=always",
    ready.exitCode == 0 and "guest-side persistence OK" in ready.output, ready.output)
  check("persist never claims boot survival from inside the guest",
    "boot=" in ready.output and "NOT persistent" notin ready.output, ready.output)
  # The stale restart policy is the exact defect this contract exists for: a
  # clean exit (stray SIGTERM) left the instance dead under on-failure.
  putEnv("SERVER_TEST_RESTART", "on-failure")
  let weak = run("persist")
  check("persist flags a restart policy that drops a clean exit",
    weak.exitCode != 0 and "does not survive a clean exit" in weak.output, weak.output)
  putEnv("SERVER_TEST_RESTART", "always")
  for kind in [("SERVER_TEST_ENABLED", "disabled"), ("SERVER_TEST_ACTIVE", "inactive")]:
    putEnv(kind[0], kind[1])
    let down = run("persist")
    check("persist flags a " & kind[1] & " unit", down.exitCode != 0 and kind[1] in down.output and "NOT persistent yet" in down.output, down.output)
    putEnv(kind[0], (if kind[0] == "SERVER_TEST_ENABLED": "enabled" else: "active"))
  putEnv("SERVER_TEST_LINGER", "no")
  let notReady = run("persist")
  check("persist fails without linger and names the fix",
    notReady.exitCode != 0 and "NOT persistent yet" in notReady.output and "loginctl enable-linger" in notReady.output, notReady.output)
  putEnv("SERVER_TEST_LINGER", "yes")
  let bootstrap = execCmdEx("cd " & quoteShell(repo) & " && bash scripts/bootstrap.sh --server --dry-run")
  check("server bootstrap adopts worktree", bootstrap.exitCode == 0 and "adopting this checkout" in bootstrap.output)
  check("server bootstrap omits TUI and extras", "would run: make install-tui" notin bootstrap.output and "would ask about optional" notin bootstrap.output)
  let setup = execCmdEx("cd " & quoteShell(repo) & " && make -n setup NIF_SERVER=1")
  check("server setup omits optional Node", setup.exitCode == 0 and
    "install-node; do" notin setup.output and "install-go ; do" in setup.output,
    setup.output)
  # Explicit remote client options must never start a local core, even when
  # the selected client exits unsuccessfully. Preserve this former Python check.
  let wrapperRoot = root / "wrapper"
  let binaries = wrapperRoot / "var" / "bin"
  createDir(binaries)
  for name in ["tui", "cli", "niffler"]:
    let body = if name == "tui": "exit 7" else: "echo forbidden; exit 1"
    writeFile(binaries / name, "#!/bin/sh\n" & body & "\n")
    setFilePermissions(binaries / name, {fpUserRead, fpUserWrite, fpUserExec})
  let oldRoot = getEnv("NIF_ROOT")
  putEnv("NIF_ROOT", wrapperRoot)
  for option in ["--instance=worker", "--instance-probe=worker", "--instance-import=receipt"]:
    let result = execCmdEx("bash " & quoteShell(repo / "scripts/niffler-tui.in") &
      " " & quoteShell(option))
    check("remote wrapper bypasses local autostart: " & option,
      result.exitCode == 7 and "forbidden" notin result.output, result.output)
  if oldRoot.len == 0: delEnv("NIF_ROOT")
  else: putEnv("NIF_ROOT", oldRoot)
  report("SERVER TEST")

main()
