## bash component — the classic first tool. Bootstrap-shipped with the harness.
##
## The agent's normal path to self-extension: write source files with bash,
## compile with builder, spawn with core.

import std/[json, osproc]
import niffler/sdk

let comp = newComponent("bash", "0.1.0")

const maxOutputBytes = 200_000
  ## Generous but bounded: unbounded output risks blowing past NATS/LLM
  ## context limits with no warning. When output exceeds this, capBytes
  ## keeps the head and tail (most commands' interesting bits are at one
  ## end or the other) and says exactly how much was cut, so the model can
  ## re-run a narrower command (grep/head/tail/wc) instead of silently
  ## losing data.

comp.tool(%*{"approval": "always", "timeoutMs": 60000,
              "workspace": {"cwdField": "cwd"}}):
  proc bash(command: string, timeoutMs: int = 30000,
            cwd: string = ""): JsonNode =
    ## Execute a shell command via bash -c. Your general-purpose interface
    ## to the machine: builds, tests, processes, piping, git mutations,
    ## binary inspection. Returns combined stdout/stderr and the exit code
    ## of the last command; on timeout the process is killed (exit 124).
    ## Output over 200KB is capped (head + tail kept) with a cut marker —
    ## narrow the command (grep/head/tail/wc) rather than assume you saw
    ## everything. Prefer dedicated tools where they exist: read/read_many
    ## for file content (pageable, caps huge lines), edit/write for
    ## changing files, git_* tools (discover on the git component) for
    ## status/diff/log/show/blame — approval-free, capped output. Before
    ## hand-rolling a network/API integration with curl, check the
    ## ecosystem: plugin_search (packages) and skill_list (Agent Skills)
    ## may already provide typed tools for it.
    ## - command: The shell command line to run (bash -c)
    ## - timeoutMs: Kill the command after this many ms (default 30000)
    ## - cwd: Working directory (defaults to the active conversation workspace)
    let scoped = if cwd.len > 0:
                   "cd -- " & quoteShell(cwd) & " && " & command
                 else: command
    let (code, captured) = runCmd(scoped, timeoutMs)
    var output = captured
    if code == 124:
      output = "[timed out after " & $timeoutMs & "ms]\n" & captured
    return %*{"exit_code": code,
              "output": capBytes(output, maxOutputBytes,
                                 "narrow the command (grep/head/tail/wc) for the missing part")}

comp.run()
