## bash component — the classic first tool. Bootstrap-shipped with the harness.
##
## The agent's normal path to self-extension: write source files with bash,
## compile with builder, spawn with core.

import std/[json, os, osproc, streams]
import niffler/sdk

let comp = newComponent("bash", "0.1.0")

comp.tool:
  proc bash(command: string, timeoutMs: int = 30000): JsonNode =
    ## Execute a shell command via bash -c. This is your general-purpose
    ## interface to the machine: files, git, builds, tests, processes,
    ## network. Use it for any task no existing tool covers, and prefer it
    ## over writing a new component whenever one command or a short script
    ## suffices. Returns the combined stdout/stderr and the exit code of
    ## the last command; on timeout the process is killed and exit_code is
    ## 124.
    ## - command: The shell command line to run (bash -c)
    ## - timeoutMs: Kill the command after this many ms (default 30000)
    var p = startProcess("bash", args = ["-c", command],
                         options = {poUsePath, poStdErrToStdOut})
    var code = p.waitForExit(timeoutMs)
    var output = ""
    if code == -1:
      # timeout: terminate, give it a moment, then kill
      p.terminate()
      sleep(200)
      if p.running(): p.kill()
      code = 124
      output = "[timed out after " & $timeoutMs & "ms]\n"
    output = output & p.outputStream.readAll()
    p.close()
    return %*{"exit_code": code, "output": output}

comp.tools[^1].schema["x-harness"] = %*{"approval": "always", "timeoutMs": 60000}
comp.run()
