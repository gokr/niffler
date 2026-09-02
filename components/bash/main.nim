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
    ## Execute a shell command via bash -c. This is your general-purpose
    ## interface to the machine: files, git, builds, tests, processes,
    ## network. Use it for any task no existing tool covers, and prefer it
    ## over writing a new component whenever one command or a short script
    ## suffices. Returns the combined stdout/stderr and the exit code of
    ## the last command; on timeout the process is killed and exit_code is
    ## 124. Output over 200KB is capped (head + tail kept) with a marker
    ## showing exactly how many bytes were cut — narrow the command
    ## (grep/head/tail/wc) rather than assume you saw everything.
    ## For READING text file content prefer the edit component's read tool
    ## over `cat`: it is pageable and caps huge lines (bash cat shows
    ## everything at once). For GIT inspection (status, diffs, history,
    ## attribution) prefer the read-only git tools git_status/git_diff/
    ## git_log/git_show/git_blame over git here: approval-free, fixed
    ## flags, capped output. For CHANGING files prefer the edit and write
    ## tools. Use bash only for what the dedicated tools cannot serve
    ## (piping, ranges, binary inspection, whole-file generation).
    ## Before hand-rolling a network/API integration with curl, check the
    ## ecosystem first: invoke plugin_search on the plugins component
    ## (third-party packages) and skill_list (Agent Skills) — an existing
    ## package may already cover the task, and installing it gives real
    ## typed tools instead of ad-hoc shell parsing.
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
