## Example 3 — hybrid: mechanical program + exploratory subagent.
##
## The program does the deterministic parts itself (loop, aggregation) and
## delegates the judgment-heavy part to a subagent via agent_run. The
## subagent gets its own context and tool loop; only its final reply enters
## this program. A subagent CANNOT spawn further subagents (x-harness.noSpawn
## denies it at dispatch).
##
## Run by the model as one fabric tool call:
##   code = <the program below>,
##   strings = {"scope": "components/fabric", "question": "Which bridge frame
##              types does the executor emit?"}

import fabricguest

# mechanical part: list the fabric sources (cheap, deterministic)
let files = callTool("bash", jobj(
  jpair("command", jesc("ls " & stringArg("scope")))))

# judgment part: delegate to a fresh session; only the reply comes back
let agent = callTool("agent_run", jobj(
  jpair("task", jesc(stringArg("question") & "\n\nScope: " & stringArg("scope") &
                     "\nFiles: " & files)),
  jpair("timeoutMs", jnum(300000))))

finish(jobj(
  jpair("files", jesc(files)),
  jpair("agentReply", jesc(agent))))
