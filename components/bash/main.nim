## bash component — the classic first tool. Bootstrap-shipped with the harness.
##
## The agent's normal path to self-extension: write source files with bash,
## compile with builder, spawn with core.

import std/[json, os, osproc, times]
import niffler/sdk

let comp = newComponent("bash", "0.1.0")

proc runWithTimeout(command: string, timeoutMs: int): tuple[code: int, output: string] =
  ## Run a command, kill it on timeout. NOTE: osproc's waitForExit(timeout)
  ## SIGKILLs the child itself and returns 137 — the timeout branch would
  ## never fire — so poll peekExitCode and own the kill.
  var p = startProcess("bash", args = ["-c", command], options = {poUsePath})
  result.code = -1
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while epochTime() < deadline:
    result.code = p.peekExitCode()
    if result.code != -1: break
    sleep(50)
  if result.code == -1:
    p.terminate()
    sleep(200)
    if p.running(): p.kill()
    result.code = 124
  p.close()

const maxOutputBytes = 200_000
  ## Generous but bounded: unbounded output risks blowing past NATS/LLM
  ## context limits with no warning. When output exceeds this, keep the
  ## head and tail (most commands' interesting bits are at one end or the
  ## other) and say exactly how much was cut, so the model can re-run a
  ## narrower command (grep/head/tail/wc) instead of silently losing data.

proc capOutput(output: string): string =
  let totalLen = output.len
  if totalLen <= maxOutputBytes: return output
  let headLen = maxOutputBytes div 2
  let tailLen = maxOutputBytes - headLen
  let omitted = totalLen - maxOutputBytes
  result = output[0 ..< headLen] &
    "\n\n[... truncated " & $omitted & " of " & $totalLen &
    " bytes (output capped at " & $maxOutputBytes &
    ") — narrow the command (grep/head/tail/wc) for the missing part ...]\n\n" &
    output[totalLen - tailLen ..< totalLen]

var callCounter = 0
  ## Bash calls are serialized (single-threaded SDK poll loop), so a plain
  ## counter is enough to keep temp-file names unique across calls.

comp.tool:
  proc bash(command: string, timeoutMs: int = 30000): JsonNode =
    ## Execute a shell command via bash -c. This is your general-purpose
    ## interface to the machine: files, git, builds, tests, processes,
    ## network. Use it for any task no existing tool covers, and prefer it
    ## over writing a new component whenever one command or a short script
    ## suffices. Returns the combined stdout/stderr and the exit code of
    ## the last command; on timeout the process is killed and exit_code is
    ## 124. Output over 200KB is capped (head + tail kept) with a marker
    ## showing exactly how many bytes were cut — narrow the command
    ## (grep/head/tail/wc) rather than assume you saw everything.
    ## For READING text file content prefer the hashline-edit read tool
    ## over `cat`: it returns hash anchors per line, is pageable, and
    ## integrates with its replace tool (bash cat shows no anchors, so a
    ## later replace can only guess). Use bash for cat only when read
    ## cannot serve (e.g. piping, ranges, binary inspection, or files
    ## read rejects).
    ## - command: The shell command line to run (bash -c)
    ## - timeoutMs: Kill the command after this many ms (default 30000)
    inc callCounter
    let tmpPath = getTempDir() /
      ("niffler-bash-" & $getCurrentProcessId() & "-" & $callCounter & ".out")
    # Redirect the whole command's combined stdout+stderr to a real file
    # instead of capturing a pipe: osproc's own waitForExit docs warn that
    # piped output can fill the OS buffer and deadlock the child forever if
    # nobody drains it before waitForExit returns — exactly what happens
    # here for any command producing more than one pipe-buffer's worth of
    # output (commonly ~64KB) before exiting. A file has no such limit, so
    # fast-but-chatty commands never get wrongly killed and marked timed
    # out. Wrapped in a subshell so the redirection covers the whole
    # command (incl. `;`/`&&`-chains), not just its last statement.
    let wrapped = "( " & command & " ) > " & quoteShell(tmpPath) & " 2>&1"
    let (code, _) = runWithTimeout(wrapped, timeoutMs)
    var output = ""
    if code == 124:
      output = "[timed out after " & $timeoutMs & "ms]\n"
    try:
      if fileExists(tmpPath):
        output = output & readFile(tmpPath)
    finally:
      if fileExists(tmpPath):
        try: removeFile(tmpPath)
        except CatchableError: discard
    return %*{"exit_code": code, "output": capOutput(output)}

comp.tools[^1].schema["x-harness"] = %*{"approval": "always", "timeoutMs": 60000}
comp.run()
