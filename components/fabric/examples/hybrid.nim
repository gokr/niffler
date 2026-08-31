## Example 3 — hybrid: mechanical program + exploratory subagent.
##
## The program does the deterministic parts itself (loop, aggregation) and
## delegates the judgment-heavy part to a subagent via agent_run. The
## subagent gets its own context and tool loop; only its final reply enters
## this program. A subagent CANNOT spawn further subagents (x-harness.noSpawn
## denies it at dispatch).
##
## Run by the model as one fabric tool call:
##   tools = ["bash", "agent_run"], code = <the program below>,
##   strings = {"scope": "components/fabric", "question": "Which bridge frame
##              types does the executor emit?"}

import fabricguest

# mechanical part: list the fabric sources (cheap, deterministic)
let files = tools.bash(command = "ls " & stringArg("scope"))

# judgment part: delegate to a fresh session; only the reply comes back
let agent = tools.agent_run(
  task = stringArg("question") & "\n\nScope: " & stringArg("scope") &
         "\nFiles: " & $files,
  timeoutMs = 300000)

# the outer selected lease remains valid after the nested session-context call
let after = tools.bash(command = "echo lease-restored")

finish($(%*{"files": files, "agentReply": agent, "after": after}))
