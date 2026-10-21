## down-here contract: stop exactly this checkout's processes, nothing else.
##
## Regression: on macOS (no /proc) the script found no candidates and then
## crashed on an empty array (BSD `seq 0 -1` counts down), stopping nothing.
## Fake "binaries" are copies of this test binary in sleeper mode (macOS kills
## copies of its own system binaries), launched the way the real
## harness launches them: an operator core by absolute or relative path, a
## component carrying NIF_ROOT, a foreign clone's core, and a bench-style
## symlink farm whose exe resolves into our var/bin but whose argv[0] (and,
## on Linux, NIF_ROOT) names the farm.

import std/[os, osproc, posix, sequtils, strtabs, strutils]
import helpers

proc alive(p: Process): bool =
  posix.kill(Pid(p.processID), 0) == 0 and p.peekExitCode() == -1

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let base = tempRoot("down-here")
  defer: removeDir(base)
  let sleepBin = getAppFilename()
  let ours = base / "ours"
  let foreign = base / "foreign"
  let farm = base / "farm"
  for root in [ours, foreign, farm]: createDir(root / "var" / "bin")
  for name in ["niffler", "store"]:
    copyFile(sleepBin, ours / "var" / "bin" / name)
    setFilePermissions(ours / "var" / "bin" / name, {fpUserRead, fpUserWrite, fpUserExec})
  copyFile(sleepBin, foreign / "var" / "bin" / "niffler")
  setFilePermissions(foreign / "var" / "bin" / "niffler", {fpUserRead, fpUserWrite, fpUserExec})
  createSymlink(ours / "var" / "bin" / "niffler", farm / "var" / "bin" / "niffler")

  proc launch(argv0, cwd: string, root = ""): Process =
    var env = newStringTable()
    for k, v in envPairs():
      if k != "NIF_ROOT": env[k] = v
    if root.len > 0: env["NIF_ROOT"] = root
    startProcess(argv0, workingDir = cwd, args = ["sleeper"], env = env, options = {})

  let core = launch(ours / "var" / "bin" / "niffler", base)
  let relCore = launch("./var/bin/niffler", ours)
  let component = launch(ours / "var" / "bin" / "store", base, ours)
  let foreignCore = launch(foreign / "var" / "bin" / "niffler", base)
  let benchCore = launch(farm / "var" / "bin" / "niffler", base, farm)
  sleep(300)
  let all = [core, relCore, component, foreignCore, benchCore]
  defer:
    for p in all:
      if p.alive: p.kill()
      p.close()
  check("fixtures started", all.allIt(it.alive))

  let script = repo / "scripts" / "down-here.sh"
  let dry = execCmdEx("bash " & quoteShell(script) & " --dry-run " & quoteShell(ours))
  check("dry run succeeds and lists exactly ours",
        dry.exitCode == 0 and dry.output.contains("would stop 3 process(es)"), dry.output)
  check("dry run stops nothing", all.allIt(it.alive))

  let real = execCmdEx("bash " & quoteShell(script) & " " & quoteShell(ours))
  check("down-here succeeds", real.exitCode == 0, real.output)
  sleep(300)
  check("absolute-path core stopped", not core.alive, real.output)
  check("relative-path core stopped", not relCore.alive, real.output)
  check("component stopped", not component.alive, real.output)
  check("foreign clone's core survives", foreignCore.alive, real.output)
  check("bench symlink-farm core survives", benchCore.alive, real.output)

  let again = execCmdEx("bash " & quoteShell(script) & " " & quoteShell(ours))
  check("nothing left reports cleanly", again.exitCode == 0 and
        again.output.contains("nothing running"), again.output)
  report("DOWN HERE TEST")

if paramCount() >= 1 and paramStr(1) == "sleeper":
  sleep(300_000)
else:
  main()
