## bash component — the classic first tool. Bootstrap-shipped with the harness.
##
## The agent's normal path to self-extension: write source files with bash,
## compile with builder, spawn with core.

import std/[json, osproc, sequtils, times]
import natswrapper
import niffler/sdk

let comp = newComponent("bash", "0.1.0")

const maxOutputBytes = 200_000
  ## Generous but bounded: unbounded output risks blowing past NATS/LLM
  ## context limits with no warning. When output exceeds this, capBytes
  ## keeps the head and tail (most commands' interesting bits are at one
  ## end or the other) and says exactly how much was cut, so the model can
  ## re-run a narrower command (grep/head/tail/wc) instead of silently
  ## losing data.

# --- cancellation side-channel ----------------------------------------------
# When a session turn is cancelled while its bash command runs, the runner
# publishes cancel.bash {sessionId, tool, ts} (core/dispatch.nim). This
# component's serialized pump is blocked inside the handler while a command
# runs, so the kill decision happens here: the handler polls this
# subscription from runCmd's wait loop via the `cancelled` probe. A fresh
# cancel for another session is stashed, not dropped — that session's
# request may still be queued behind the running command, and when it is
# picked up the handler skips it instead of executing a dead turn's work.

const cancelFreshSeconds = 30.0
var cancelSub: ptr natsSubscription
var cancelledSessions: seq[tuple[sessionId: string, at: float]]

proc drainCancels(mySession: string): bool =
  ## Poll the cancel.bash subscription (non-blocking). Returns true when a
  ## fresh cancel targets mySession — the caller kills its command group.
  if cancelSub == nil:
    let st = natsConnection_SubscribeSync(addr cancelSub, comp.nc.conn,
                                          "cancel.bash")
    if not checkStatus(st): return false
  var cancelled = false
  while true:
    var msg: ptr natsMsg
    let st = natsSubscription_NextMsg(addr msg, cancelSub, 0)
    if not checkStatus(st): break  # NATS_TIMEOUT = no message: done draining
    var payload = newJObject()
    try:
      let env = decode($natsMsg_GetData(msg))
      if env.kind == ekEvent and env.payload != nil: payload = env.payload
    except CatchableError:
      discard
    natsMsg_Destroy(msg)
    let sid = payload{"sessionId"}.getStr("")
    let ts = payload{"ts"}.getFloat(0.0)
    if sid.len == 0 or epochTime() - ts > cancelFreshSeconds: continue
    if mySession.len > 0 and sid == mySession: cancelled = true
    else: cancelledSessions.add((sessionId: sid, at: ts))
  cancelledSessions.keepItIf(epochTime() - it.at <= cancelFreshSeconds)
  cancelled

proc wasCancelled(sessionId: string): bool =
  ## True when a fresh cancel for sessionId was stashed earlier — its
  ## request was queued behind another session's command when the cancel
  ## arrived, so the work must be skipped, not run.
  cancelledSessions.keepItIf(epochTime() - it.at <= cancelFreshSeconds)
  for it in cancelledSessions:
    if it.sessionId == sessionId: return true
  false

# Low-level registration (not the `comp.tool:` macro): the handler needs the
# raw args — x-harness "sessionId" makes the runner inject
# {__session: {session}} as private context so cancels can be matched.
let bashSchema = toolSchema(%*{
  "command": {"type": "string",
              "description": "The shell command line to run (bash -c)"},
  "timeoutMs": {"type": "integer",
                "description": "Kill the command after this many ms (default 30000)"},
  "cwd": {"type": "string",
          "description": "Working directory (defaults to the active conversation workspace)"}
}, required = @["command"],
  description = "Execute a shell command via bash -c — builds, tests, piping, git mutations, process inspection. Returns combined stdout/stderr and the last command's exit code; on timeout the process tree is killed (124), on turn cancel (130). Output over 200KB is capped (head+tail kept, cut marker shown) — re-run a narrower command (grep/head/tail/wc) for the missing part. Prefer dedicated tools for file work and repo state: read/read_many, edit/write, files, grep, git_* (discover on the git component).")
bashSchema["x-harness"] = %*{"approval": "always", "timeoutMs": 60_000,
                             "sessionId": true,
                             "workspace": %*{"cwdField": "cwd"}}
discard comp.tool("bash", bashSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let sessionId = toolArgs{"__session"}{"session"}.getStr("")
    if sessionId.len > 0 and wasCancelled(sessionId):
      return %*{"exit_code": 130, "cancelled": true,
                "output": "[cancelled by request]\n"}
    let command = toolArgs{"command"}.getStr("")
    let timeoutMs = toolArgs{"timeoutMs"}.getInt(30_000)
    let cwd = toolArgs{"cwd"}.getStr("")
    let scoped = if cwd.len > 0:
                   "cd -- " & quoteShell(cwd) & " && " & command
                 else: command
    let (code, captured) = runCmd(scoped, timeoutMs,
      proc(): bool = drainCancels(sessionId))
    var output = captured
    if code == 124:
      output = "[timed out after " & $timeoutMs & "ms]\n" & captured
    elif code == 130:
      output = "[cancelled by request]\n" & captured
    return %*{"exit_code": code,
              "cancelled": code == 130,
              "output": capBytes(output, maxOutputBytes,
                                 "narrow the command (grep/head/tail/wc) for the missing part")})

comp.run()
