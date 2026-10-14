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

import std/[os, strutils, json, posix, tempfiles, monotimes, times]
import policy
import landlock
import ../sdk/niffler/procutil

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
  let (rc, outp) = runCmd(quoteShell(binPath) & " --unshare-user --unshare-net" &
    " --ro-bind / / /bin/true", 5000)
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
  # Keep the caller's process group so runCmd cancellation reaches bwrap.
  result.add "--cap-drop"; result.add "ALL"
  result.add "--clearenv"
  result.add "--setenv"; result.add "PATH"; result.add "/usr/bin:/bin"
  result.add "--setenv"; result.add "HOME"; result.add "/tmp"
  result.add "--setenv"; result.add "TMPDIR"; result.add "/tmp"
  result.add "--setenv"; result.add "LANG"; result.add "C.UTF-8"
  result.add "--die-with-parent"
  result.add "--unshare-user"
  result.add "--unshare-pid"
  result.add "--unshare-ipc"
  result.add "--unshare-net"  # no bus: closes the component-bypass path
  result.add "--ro-bind"; result.add "/"; result.add "/"
  result.add "--dev"; result.add "/dev"
  result.add "--proc"; result.add "/proc"
  result.add "--tmpfs"; result.add "/tmp"
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

proc writeStatus(req: LaunchRequest, backend: string, applied: bool) =
  ## Launcher-owned evidence, written by the TRUSTED parent after the sandbox
  ## has done its work — never by the confined command, which could otherwise
  ## forge it. An absent file means "no usable backend" and must read as
  ## unguarded, never as success.
  if req.statusFile.len == 0: return
  try:
    writeFile(req.statusFile,
              $(%*{"backend": backend, "applied": applied, "scope": "shell"}))
  except CatchableError:
    discard

proc verifyPrelude(req: LaunchRequest, probeDir, positiveDir: string): string =
  ## A shell prelude run INSIDE the same bwrap policy that will run the real
  ## command, doing forbidden things and requiring them to FAIL.
  ##
  ## SANDBOX-PLAN §3: a probe that only runs `/bin/true` proves nothing. It also
  ## warns that Unix permissions already deny some writes, so a negative test
  ## must use something the UNCONFINED process could actually do. An earlier
  ## version wrote to `/` — denied to a normal user with or without a sandbox —
  ## and therefore passed for a backend that confined nothing at all.
  result = "rc=0\n"
  # NEGATIVE: probeDir is created writable by us and sits OUTSIDE the
  # workspace, so an unsandboxed shell writes it happily; only a real mount
  # policy (read-only host root) denies it.
  result.add "( : > " & quoteShell(probeDir / "w") & " ) 2>/dev/null && rc=1\n"
  # NEGATIVE: every requested mask must read as EMPTY. That is what hidden
  # means; a non-empty read means the mask did not take effect.
  for m in req.masks:
    result.add "[ -s " & quoteShell(m) & " ] && rc=1\n"
  # POSITIVE control: the workspace MUST remain writable. Without this, a
  # backend that denied everything would look like perfect confinement.
  result.add "( : > " & quoteShell(positiveDir / "w") &
             " ) 2>/dev/null || rc=1\n"
  result.add "printf 'niffler-verify:%s' \"$rc\"\n"

proc runBwrap(req: LaunchRequest): int =
  ## Bootstrap in the ACTUAL command sandbox, acknowledge on fd 3, close it,
  ## then exec user argv. Stdout, stderr and command exit codes carry no evidence.
  ## The system bwrap and /bin/sh bootstrap are trusted; this is not attestation
  ## against a malicious replacement backend or arbitrary same-user host code.
  let probeDir = createTempDir("niffler-verify-", "", "/var/tmp")
  defer: removeDir(probeDir)
  let positiveDir = createTempDir(".niffler-verify-", "", req.workspace)
  defer: removeDir(positiveDir)
  var bootstrap = req
  let checks = verifyPrelude(req, probeDir, positiveDir)
  const marker = "NIFSANDBOX-OK"
  bootstrap.argv = @["/bin/sh", "-c",
    checks.replace("printf 'niffler-verify:%s' \"$rc\"\n",
      "[ \"$rc\" -eq 0 ] || exit 125\n" &
      "printf '" & marker & "\\n' || exit 125\nexec \"$@\"\n"),
    "niffler-bootstrap"] & req.argv
  let argv = bwrapArgv(bwrapPath(), bootstrap)
  # The acknowledgement rides a private stdout pipe rather than an extra fd:
  # this bwrap has no --preserve-fds, and the marker is unforgeable anyway
  # because ONLY the pre-exec bootstrap can be the first writer. The parent
  # consumes the marker line, then forwards the command's real output unchanged.
  var outPipe: array[2, cint]
  if pipe(outPipe) != 0:
    writeStatus(req, "bwrap", false)
    return 125
  let pid = fork()
  if pid < 0:
    discard close(outPipe[0])
    discard close(outPipe[1])
    writeStatus(req, "bwrap", false)
    return 125
  if pid == 0:
    discard close(outPipe[0])
    if dup2(outPipe[1], STDOUT_FILENO) < 0: exitnow(125)
    if outPipe[1] != STDOUT_FILENO: discard close(outPipe[1])
    let cargv = allocCStringArray(argv)
    discard execv(cargv[0], cargv)
    exitnow(125)
  discard close(outPipe[1])
  var ackBuf: array[256, char]
  var ackLen = 0
  var acknowledged = false
  var sawNewline = false
  let deadline = getMonoTime() + initDuration(milliseconds = 5000)
  while ackLen < ackBuf.len:
    if getMonoTime() > deadline: break
    var pollFd = TPollfd(fd: outPipe[0], events: POLLIN)
    if poll(addr pollFd, 1, 200) <= 0: continue
    let n = posix.read(outPipe[0], addr ackBuf[ackLen], 1)
    if n == 1:
      if ackBuf[ackLen] == '\n':
        sawNewline = true
        break
      inc ackLen
      continue
    if n == 0: break
    if osLastError().int32 notin [EAGAIN, EINTR]: break
  if sawNewline:
    var got = newString(ackLen)
    for k in 0 ..< ackLen: got[k] = ackBuf[k]
    acknowledged = got == marker
  # Anything after the newline is the command's own output and is forwarded
  # untouched; the remainder of the stream follows until EOF. Nothing is
  # prepended or reordered, so the command's byte stream is unchanged.
  var forward: array[65536, char]
  while true:
    let n = posix.read(outPipe[0], addr forward[0], forward.len)
    if n <= 0: break
    var off = 0
    while off < n:
      let w = posix.write(STDOUT_FILENO, addr forward[off], n - off)
      if w <= 0: break
      off += w
  discard close(outPipe[0])
  # Record immediately: a subsequent cancellation must not erase startup truth.
  writeStatus(req, "bwrap", acknowledged)
  if not acknowledged:
    stderr.writeLine "niffler-sandbox: bootstrap did not acknowledge policy; refusing"
    discard kill(pid, SIGKILL)
  var status: cint
  while waitpid(pid, status, 0) < 0:
    if osLastError().int32 != EINTR: return 125
  if not acknowledged: return 125
  if WIFEXITED(status): return WEXITSTATUS(status)
  if WIFSIGNALED(status): return 128 + WTERMSIG(status)
  125

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
    return runBwrap(req)
  of bkLandlock:
    if req.masks.len > 0:
      stderr.writeLine "niffler-sandbox: refusing requested masks: Landlock cannot enforce them"
      writeStatus(req, "landlock", false)
      return 125
    stderr.writeLine "niffler-sandbox: " & probe.detail
    let code = runWithLandlock(req)
    # No startup acknowledgement from the restricted child yet.
    writeStatus(req, "landlock", false)
    return code
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
      if i < args.len: result.extraRoots.add canonicalExisting(args[i])
    of "--mask":
      inc i
      if i < args.len: result.masks.add canonicalMask(args[i])
    of "--status-file":
      inc i
      if i < args.len: result.statusFile = args[i]
    of "--":
      inc i
      while i < args.len:
        result.argv.add args[i]
        inc i
      break
    else:
      raise newException(SandboxError, "unknown launch argument: " & args[i])
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
    try:
      quit(runRequest(parseRequest(params[1 .. ^1])))
    except CatchableError as e:
      stderr.writeLine "niffler-sandbox: refusing launch: " & e.msg
      quit(125)
  else:
    stderr.writeLine "niffler-sandbox: unknown command " & params[0]
    quit(2)

when isMainModule:
  main()
