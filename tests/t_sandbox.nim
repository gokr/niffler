## Sandbox launcher contract: policy validation, backend honesty, enforcement.
##
## Two layers, deliberately separated:
##   - pure checks of policy.nim (always run, no privileges needed)
##   - real enforcement checks (run only where a backend is genuinely usable, and
##     skip WITH A REASON otherwise — an all-skipped run must never look green)
##
## This is not a NATS test: the launcher is a helper binary, not a component.

import std/[os, osproc, strutils, json]
import ../sandbox/policy

var failures = 0
var skipped = 0

proc check(name: string, ok: bool, detail = "") =
  if ok: echo "OK: ", name
  else:
    inc failures
    echo "FAIL: ", name, (if detail.len > 0: " — " & detail else: "")

proc skip(name, why: string) =
  inc skipped
  echo "SKIP: ", name, " — ", why

proc launcher(root: string): string =
  result = root / "var" / "bin" / "niffler-sandbox"

proc runLauncher(bin: string, args: seq[string],
                 env: seq[(string, string)] = @[]): tuple[code: int, output: string] =
  var cmd = ""
  for (k, v) in env: cmd.add k & "=" & quoteShell(v) & " "
  cmd.add quoteShell(bin)
  for a in args: cmd.add " " & quoteShell(a)
  # stdin redirected: the launcher must never read the caller's terminal.
  let (outp, rc) = execCmdEx(cmd & " < /dev/null 2>&1")
  (rc, outp)

proc pureChecks() =
  ## policy.nim is pure path/argv logic — no privileges, no spawning.
  let ws = getTempDir() / "sb-policy"
  createDir(ws)
  defer: removeDir(ws)

  var req = LaunchRequest(workspace: ws, argv: @["true"])
  check("a plain request validates", req.validate().len == 0, req.validate())
  check("effective dir defaults to the workspace",
        req.effectiveDir() == ws, req.effectiveDir())

  var noWs = LaunchRequest(argv: @["true"])
  check("no workspace is refused", noWs.validate().len > 0, noWs.validate())

  var noCmd = LaunchRequest(workspace: ws)
  check("no command is refused", noCmd.validate().len > 0, noCmd.validate())

  var missing = LaunchRequest(workspace: ws / "nope", argv: @["true"])
  check("a nonexistent workspace is refused",
        missing.validate().len > 0, missing.validate())

  var outside = LaunchRequest(workspace: ws, cwd: getEnv("HOME"), argv: @["true"])
  check("a cwd outside the workspace is refused",
        outside.validate().len > 0, outside.validate())

  var granted = LaunchRequest(workspace: ws, cwd: getTempDir(), argv: @["true"],
                              extraRoots: @[getTempDir()])
  check("a granted root admits a cwd outside the workspace",
        granted.validate().len == 0, granted.validate())

  # A sibling whose name shares a prefix must NOT read as inside.
  var prefix = LaunchRequest(workspace: ws, cwd: ws & "-elsewhere", argv: @["true"])
  check("a prefix-sibling directory is outside (no '/ws-other' confusion)",
        prefix.validate().len > 0, prefix.validate())

proc enforcementChecks(root: string) =
  let bin = launcher(root)
  if not fileExists(bin):
    skip("enforcement", "launcher not built at " & bin)
    return
  let base = getTempDir() / "sb-enforce"
  removeDir(base)
  createDir(base / "ws")
  createDir(base / "outside")
  defer: removeDir(base)
  writeFile(base / "ws" / ".env", "TOP-SECRET\n")
  writeFile(base / "outside" / "b.txt", "outside\n")

  # 1. The probe must describe THIS host truthfully.
  let (pcode, pout) = runLauncher(bin, @["probe"])
  var backend = "none"
  try:
    let j = parseJson(pout.strip())
    backend = j{"backend"}.getStr("none")
    check("probe emits a machine-readable backend",
          j{"backend"}.getStr("").len > 0, pout)
    check("probe reports the Landlock ABI from the kernel, not the version",
          j{"landlockAbi"}.getInt(-1) >= 0, pout)
  except CatchableError:
    check("probe output is valid JSON", false, pout)
  check("probe exit status matches usability",
        (pcode == 0) == (backend != "none"), pout)

  # 2. Refusal is the default when nothing can confine.
  if backend == "none":
    let (rc, outp) = runLauncher(bin, @["run", "--workspace", base / "ws",
                                        "--", "rm", "-rf", base / "outside"])
    check("with no backend, the command is refused (exit 125)", rc == 125, outp)
    check("the refusal names the reason", outp.contains("no usable backend"), outp)
    check("a refused launch really ran nothing",
          fileExists(base / "outside" / "b.txt"), outp)
    skip("write confinement", "no usable backend on this host")
    skip("masking", "no usable backend on this host")
    return

  # 3. Write confinement — the core promise of the degraded backend too.
  let script = "echo inside > " & (base / "ws" / "a.txt") &
    " 2>/dev/null && echo WROTE-INSIDE; " &
    "echo outside > " & (base / "outside" / "b.txt") & " 2>/dev/null && echo WROTE-OUTSIDE; " &
    "true"  # the deliberate denial above must not decide the exit status
  var env: seq[(string, string)] = @[]
  if backend == "landlock":
    # Reads are unconfined under Landlock; the checks below must not claim
    # otherwise, so say so in the test output rather than pretending.
    echo "note: landlock backend — writes confined, reads UNCONFINED (degraded)"
  let (ecode, eout) = runLauncher(bin,
    @["run", "--workspace", base / "ws", "--", "bash", "-c", script], env)
  check("the command ran", ecode == 0, eout)
  check("a write inside the workspace succeeds", eout.contains("WROTE-INSIDE"), eout)
  check("a write outside the workspace is denied",
        not (eout.contains("WROTE-OUTSIDE") and
             readFile(base / "outside" / "b.txt").contains("outside")), eout)
  check("the outside file is untouched",
        readFile(base / "outside" / "b.txt") == "outside\n", eout)

  # 4. Descendants inherit the restriction (a child shell must not escape).
  let child = "bash -c 'echo child > " & (base / "outside" / "c.txt") & " 2>/dev/null || echo CHILD-DENIED'"
  let (ccode, cout) = runLauncher(bin,
    @["run", "--workspace", base / "ws", "--", "bash", "-c", child])
  check("a grandchild inherits the restriction", cout.contains("CHILD-DENIED"), cout)
  check("the grandchild wrote nothing outside",
        not fileExists(base / "outside" / "c.txt"), cout)

  # 5. Masking: only the full-promise backend can hide an in-tree secret.
  let maskArgs = @["run", "--workspace", base / "ws", "--mask",
                   base / "ws" / ".env", "--", "bash", "-c",
                   "cat " & (base / "ws" / ".env") & " 2>/dev/null || echo MASKED"]
  let (mcode, mout) = runLauncher(bin, maskArgs)
  if backend == "bwrap":
    check("the full-promise backend hides the masked secret",
          not mout.contains("TOP-SECRET"), mout)
  else:
    check("the degraded backend refuses requested secret masks",
          mcode == 125 and not mout.contains("TOP-SECRET"), mout)
    skip("secret masking", "landlock has no deny rule (SANDBOX-ROUTE.md §2)")

  # 6. The self-check must have TEETH: a backend that starts commands but
  #    confines nothing must be refused, not attested. This is the bug an
  #    earlier probe had — it wrote to `/`, which fails unsandboxed too, so a
  #    backend that did nothing passed. A fake bwrap that claims availability
  #    and then runs the command unguarded must fail the check.
  let fake = base / "fake-bwrap"
  writeFile(fake, "#!/usr/bin/env python3\n" &
    "import sys, os\n" &
    "a = sys.argv[1:]\n" &
    "if '/bin/true' in a: sys.exit(0)\n" &
    "i = a.index('--') if '--' in a else 0\n" &
    "cmd = a[i+1:]\n" &
    "os.execvp(cmd[0], cmd) if cmd else sys.exit(0)\n")
  setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
  var fakeEnv = "NIF_BWRAP=" & quoteShell(fake)
  let statusPath = base / "fake-status.json"
  let (fout, fcode) = execCmdEx(fakeEnv & " " & quoteShell(bin) &
    " run --workspace " & quoteShell(base / "ws") &
    " --status-file " & quoteShell(statusPath) & " -- echo SHOULD-NOT-RUN < /dev/null 2>&1")
  check("a non-confining backend is refused, not attested",
        fcode == 125 and not fout.contains("SHOULD-NOT-RUN"), fout)
  var fakeApplied = ""
  if fileExists(statusPath):
    try: fakeApplied = $parseJson(readFile(statusPath)){"policyChecked"}.getBool(true)
    except CatchableError: discard
  check("the refusal records applied:false", fakeApplied == "false", fout)

proc main() =
  let root = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  pureChecks()
  enforcementChecks(root)
  if skipped > 0:
    echo "Skipped ", skipped, " check(s) — see the reasons above"
  if failures > 0:
    echo "SANDBOX TEST FAILED: ", failures, " failure(s)"
    quit(1)
  echo "SANDBOX TEST PASSED"

main()
