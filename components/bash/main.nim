## bash component — the classic first tool. Bootstrap-shipped with the harness.
##
## The agent's normal path to self-extension: write source files with bash,
## compile with builder, spawn with core.

import std/[json, os, osproc, streams]
import niffler/sdk

let comp = newComponent("bash", "0.1.0")

comp.tool:
  proc bash(command: string, timeoutMs: int = 30000): JsonNode =
    ## Run a command in bash; returns exit code and combined stdout/stderr.
    ## - command: Shell command to run
    ## - timeoutMs: Timeout in ms (default 30000)
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
