## The sandbox launcher: probe, plan and run.
##
## A helper executable, not a NATS component (SANDBOX-PLAN §3). Two commands:
##
##   niffler-sandbox probe            report the backend this host can enforce
##   niffler-sandbox run  <request>   exec argv under the requested guard
##
## Reporting contract (SANDBOX-ROUTE.md §4): the backend is one of `bwrap`
## (writes and reads confined — the full promise), `landlock` (writes confined,
## **reads unconfined** — degraded, and said so) or a refusal. There is no
## silent fallback: a host that cannot apply what was asked for runs nothing.
##
## The probe tests a *forbidden operation*, never `/bin/true` — a launcher that
## starts commands but confines nothing must not read as healthy.

import std/[os, strutils, json, osproc, posix]
import policy
import landlock

const
  NifflerBwrap = "bwrap"
  EnvBackend = "NIF_SANDBOX_BACKEND"

type
  ProbeResult = object
    backend: Backend
    abi: int
    detail: string
    usable: bool

proc bwrapPath(): string =
  ## Resolve bubblewrap. `NIF_BWRAP` overrides for tests; otherwise PATH.
  let override = getEnv("NIF_BWRAP", "").strip()
  if override.len > 0:
    return (if fileExists(override): override else: "")
  findExe(NifflerBwrap)

proc bwrapProbe(binPath: string): string =
  ## "" when bubblewrap can actually confine, else the reason. This is the
  ## native equivalent of codex's user-namespace probe: Ubuntu 23.10+ AppArmor
  ## refuses `userns` to unconfined programs, so `bwrap` being present on PATH
  ## says nothing about whether it works.
  if binPath.len == 0:
    return "bubblewrap (bwrap) is not installed"
  let (outp, rc) = execCmdEx(quoteShell(binPath) & " --unshare-user --unshare-net" &
    " --ro-bind / / /bin/true 2>&1")
  if rc != 0:
    let msg = outp.strip()
    if msg.contains("uid map") or msg.contains("No permissions to create a new namespace") or
       msg.contains("RTM_NEWADDR") or msg.contains("RTM_NEWLINK"):
      return "bubblewrap cannot create a user namespace (AppArmor?) — " & msg
    return "bubblewrap probe failed: " & msg
  ""

proc doProbe(): ProbeResult =
  ## Prefer bubblewrap (the full promise), fall back to Landlock *only* by
  ## explicit decision, and report honestly either way.
  result.abi = landlockAbi()
  let forced = getEnv(EnvBackend, "").strip().toLowerAscii()
  let bwrap = bwrapPath()
  let bwrapWhy = bwrapProbe(bwrap)
  if forced == "landlock":
    result.backend = bkLandlock
    result.usable = result.abi >= 1
    result.detail = if result.usable:
      "Landlock ABI " & $result.abi & " (forced): writes confined, reads unconfined"
    else: "Landlock ABI unavailable and bubblewrap was not requested"
    return
  if bwrapWhy.len == 0:
    result.backend = bkWrap
    result.usable = true
    result.detail = "bubblewrap: writes and reads confined"
    return
  if result.abi >= 1 and (forced == "landlock" or getEnv("NIF_SANDBOX_ALLOW_DEGRADED", "") == "1"):
    result.backend = bkLandlock
    result.usable = true
    result.detail = "Landlock ABI " & $result.abi &
      " (degraded: writes confined, reads UNCONFINED) — bubblewrap unusable: " & bwrapWhy
    return
  result.backend = bkNone
  result.usable = false
  result.detail = bwrapWhy & "; Landlock ABI " & $result.abi &
    " (set NIF_SANDBOX_ALLOW_DEGRADED=1 to accept writes-only confinement)"

proc bwrapArgv(binPath: string, req: LaunchRequest): seq[string] =
  ## Assemble the bubblewrap invocation. The workspace is mounted writable at
  ## its own absolute path (so paths inside the command mean the same thing as
  ## outside — what every shelf harness does), everything else read-only, and
  ## each mask is bound over with /dev/null.
  result = @[binPath]
  result.add "--new-session"
  result.add "--die-with-parent"
  result.add "--unshare-user"
  result.add "--unshare-pid"
  result.add "--unshare-ipc"
  result.add "--unshare-net"  # no bus: closes the component-bypass path
  result.add "--ro-bind"; result.add "/"; result.add "/"
  result.add "--dev"; result.add "/dev"
  result.add "--proc"; result.add "/proc"
  for r in req.extraRoots:
    result.add "--bind"; result.add r; result.add r
  result.add "--bind"; result.add req.workspace; result.add req.workspace
  for m in req.masks:
    # Bind /dev/null over the secret so it reads empty and cannot be written.
    result.add "--ro-bind"; result.add "/dev/null"; result.add m
  result.add "--chdir"; result.add effectiveDir(req)
  result.add "--"
  result.add req.argv

proc runWithLandlock(req: LaunchRequest): int

proc runRequest(req: LaunchRequest): int =
  ## Apply the requested guard and exec. Returns the command's exit status, or
  ## refuses (exit 125) with a reason on stderr — never runs unguarded.
  let why = validate(req)
  if why.len > 0:
    stderr.writeLine "niffler-sandbox: refusing to launch: " & why
    return 125
  let probe = doProbe()
  case probe.backend
  of bkWrap:
    let binPath = bwrapPath()
    let argv = bwrapArgv(binPath, req)
    var args: seq[string]
    for i in 1 ..< argv.len: args.add argv[i]
    try:
      let p = startProcess(argv[0], args = args, options = {poParentStreams})
      return waitForExit(p)
    except CatchableError as e:
      stderr.writeLine "niffler-sandbox: cannot start bubblewrap: " & e.msg
      return 125
  of bkLandlock:
    stderr.writeLine "niffler-sandbox: " & probe.detail
    return runWithLandlock(req)
  of bkNone:
    stderr.writeLine "niffler-sandbox: no usable backend — " & probe.detail
    return 125

proc runWithLandlock(req: LaunchRequest): int =
  ## Fork, tighten the child with Landlock, exec. The parent stays unrestricted
  ## so it can report the child's status (that is the point of the fork).
  when defined(linux):
    let pid = fork()
    if pid < 0:
      stderr.writeLine "niffler-sandbox: fork failed"
      return 125
    if pid == 0:
      # Child: install the restriction, then exec. Any failure here must not
      # fall through to an unguarded exec.
      var readable: seq[string]
      for d in ["/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc", "/proc", "/dev"]:
        if dirExists(d): readable.add d
      let why = restrictWriteTo(@[req.workspace] & req.extraRoots, readable)
      if why.len > 0:
        stderr.writeLine "niffler-sandbox: " & why
        quit(125)
      let dir = effectiveDir(req)
      if dir.len > 0: discard chdir(dir)
      var argv = allocCStringArray(req.argv)
      discard execvp(argv[0], argv)
      stderr.writeLine "niffler-sandbox: cannot exec " & req.argv[0]
      quit(125)
    var status: cint
    discard waitpid(pid, status, 0)
    if WIFEXITED(status): return WEXITSTATUS(status)
    return 125
  else:
    stderr.writeLine "niffler-sandbox: Landlock is Linux-only"
    return 125

proc parseRequest(args: seq[string]): LaunchRequest =
  ## `run --workspace DIR [--cwd DIR] [--allow DIR]... [--mask PATH]...
  ##  -- CMD ARG...`
  var i = 0
  while i < args.len:
    case args[i]
    of "--workspace":
      inc i
      if i < args.len: result.workspace = canonicalExisting(args[i])
    of "--cwd":
      inc i
      if i < args.len: result.cwd = canonicalExisting(args[i])
    of "--allow":
      inc i
      if i < args.len: result.extraRoots.add args[i]
    of "--mask":
      inc i
      if i < args.len: result.masks.add args[i]
    of "--":
      inc i
      while i < args.len:
        result.argv.add args[i]
        inc i
      break
    else: discard
    inc i
  if result.cwd.len == 0 and result.workspace.len > 0:
    result.cwd = result.workspace

proc main() =
  let params = commandLineParams()
  if params.len == 0:
    stderr.writeLine "usage: niffler-sandbox probe | run --workspace DIR -- CMD..."
    quit(2)
  case params[0]
  of "probe":
    let p = doProbe()
    echo $(%*{"backend": $p.backend, "usable": p.usable,
              "landlockAbi": p.abi, "detail": p.detail})
    quit(if p.usable: 0 else: 1)
  of "run":
    quit(runRequest(parseRequest(params[1 .. ^1])))
  else:
    stderr.writeLine "niffler-sandbox: unknown command " & params[0]
    quit(2)

when isMainModule:
  main()
