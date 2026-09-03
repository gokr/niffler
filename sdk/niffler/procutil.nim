## Process + output utilities shared by every component that shells out.
##
## Extracted from six components that each grew the same hard-won
## implementation notes:
## - osproc's waitForExit(timeout) SIGKILLs the child itself and returns
##   137, so the timeout branch would never fire — poll peekExitCode and
##   own the kill (exit code 124 on timeout).
## - piped output deadlocks chatty children (the OS pipe buffer fills and
##   nobody drains it before waitForExit returns) — combined output goes
##   to a temp file instead, which has no such limit.
## - output is capped before it travels as a tool result (a JSON envelope
##   must never blow the conversation): head + tail with an exact marker,
##   and byte tails snapped to UTF-8 boundaries so a multi-byte character
##   (CJK in compiler output, etc.) never poisons the JSON envelope.

import std/[os, osproc, posix, sequtils, strutils, times]

type
  RunResult* = tuple[code: int, output: string]

var callCounter = 0
  ## Calls are serialized (single-threaded SDK poll loop), so a plain
  ## counter is enough to keep temp-file names unique across calls.

proc readCapture(tmpPath: string): string =
  try:
    if fileExists(tmpPath):
      result = readFile(tmpPath)
  finally:
    if fileExists(tmpPath):
      try: removeFile(tmpPath)
      except CatchableError: discard

proc killGroup(pid: Pid, sig: cint) =
  ## Signal the command's whole process group. The forked child made itself
  ## the group leader via setpgid(0, 0), so a negative-pid kill reaches the
  ## bash wrapper AND every descendant (a bare kill(pid) would orphan
  ## grandchildren — `sleep 100 &` keeps running after bash dies).
  discard posix.kill(-pid, sig)

proc runCmd*(cmd: string, timeoutMs: int = 120_000,
             cancelled: proc(): bool = nil): RunResult =
  ## Run `cmd` via bash -c and return its exit code plus the combined
  ## stdout+stderr, captured through a temp file (pipes deadlock chatty
  ## children). The command runs as the leader of its own process group, so
  ## a timeout or cancellation kills the whole tree, not just the bash
  ## wrapper. On timeout the exit code is 124; when the optional `cancelled`
  ## probe turns true (checked every 50ms) it is 130. Output is whatever the
  ## command produced before dying.
  inc callCounter
  let tmpPath = getTempDir() /
    ("niffler-run-" & $getCurrentProcessId() & "-" & $callCounter & ".out")
  # Wrapped in a subshell so the redirection covers the whole command
  # (incl. `;`/`&&`-chains), not just its last statement.
  let wrapped = "( " & cmd & " ) > " & quoteShell(tmpPath) & " 2>&1"
  let argv = allocCStringArray(["bash", "-c", wrapped])
  defer: deallocCStringArray(argv)
  let pid = posix.fork()
  if pid == 0:
    # Child: become a process-group leader BEFORE exec (no race with the
    # parent's kill), then exec the command. execvp resolves bash via PATH;
    # exitnow is _exit — no Nim teardown in the forked child.
    discard posix.setpgid(0, 0)
    discard posix.execvp("bash", argv)
    posix.exitnow(127)
  if pid < 0:
    raise newException(IOError,
      "fork failed for: " & cmd[0 ..< min(cmd.len, 80)])
  result.code = -1
  let deadline = epochTime() + timeoutMs.float / 1000.0
  var status: cint = 0
  var killedByCancel = false
  while epochTime() < deadline:
    # NOTE: osproc's waitForExit(timeout) SIGKILLs the child itself and
    # returns 137 — poll waitpid(WNOHANG) and own the kill instead.
    let r = posix.waitpid(pid, status, WNOHANG)
    if r == pid:
      result.code =
        if WIFEXITED(status): WEXITSTATUS(status).int
        else: 128 + WTERMSIG(status).int  # died by signal, on its own
      break
    if cancelled != nil and cancelled():
      killedByCancel = true
      break
    sleep(50)
  if result.code == -1:
    killGroup(pid, SIGTERM)
    var reaped = false
    for i in 0 ..< 20:  # up to ~1s of grace for SIGTERM
      let r = posix.waitpid(pid, status, WNOHANG)
      if r == pid: reaped = true; break
      sleep(50)
    if not reaped:
      killGroup(pid, SIGKILL)
      discard posix.waitpid(pid, status, 0)
    result.code = if killedByCancel: 130 else: 124
  result.output = readCapture(tmpPath)

proc runArgv*(exe: string, args: seq[string], timeoutMs: int = 120_000): RunResult =
  ## runCmd for a fixed executable + argv: every element is quoteShell'd,
  ## so arguments (patterns, refs, paths) travel byte-for-byte — the shell
  ## only joins words. Nothing ever needs escaping by the caller.
  runCmd(exe & " " & args.mapIt(quoteShell(it)).join(" "), timeoutMs)

proc pluralize(label: string, n: int): string =
  ## Naive last-word plural handling for the cap markers: "result lines"
  ## with n=1 becomes "result line". Good enough for our fixed labels.
  if n == 1:
    if label[^1] == 's': label[0 ..< label.len - 1] else: label
  elif label[^1] == 's': label
  else: label & "s"

proc capBytes*(s: string, maxBytes: int,
               hint = "narrow the command for the missing part"): string =
  ## Cap s to maxBytes keeping head + tail (most commands' interesting
  ## bits are at one end or the other) with a marker saying exactly how
  ## much was cut, so the model can re-run a narrower query.
  if s.len <= maxBytes: return s
  let headLen = maxBytes div 2
  let tailLen = maxBytes - headLen
  let omitted = s.len - maxBytes
  result = s[0 ..< headLen] &
    "\n\n[... truncated " & $omitted & " of " & $s.len &
    " bytes (capped at " & $maxBytes & ") — " & hint & " ...]\n\n" &
    s[s.len - tailLen ..< s.len]

proc capLines*(s: string, maxLines: int, label = "result lines",
               hint = "raise the cap or narrow the pattern"): string =
  ## Keep the first maxLines lines of s; drop the tail with an exact
  ## marker. `label` names what a line is ("result lines", "lines",
  ## "paths") for the marker text.
  if s.len == 0: return s
  var lines = s.split('\n')
  if lines[^1].len == 0: lines.setLen(lines.len - 1)  # trailing-newline artifact
  if lines.len <= maxLines: return s
  let dropped = lines.len - maxLines
  result = lines[0 ..< maxLines].join("\n") &
    "\n\n[... " & $dropped & " more " & pluralize(label, dropped) &
    " — " & hint & " ...]\n"

proc tailBytes*(s: string, n: int): string =
  ## Last n bytes of s, snapped forward to a UTF-8 boundary so a
  ## multi-byte character is never split into invalid UTF-8 — a broken
  ## rune would poison the JSON envelope downstream. Prefixed with "…".
  if s.len <= n: return s
  var start = s.len - n
  while start > 0 and (s[start].uint8 and 0xC0) == 0x80:
    inc start  # skip continuation bytes: start at the rune's first byte
  return "…" & s[start .. ^1]
