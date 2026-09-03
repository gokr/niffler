## bash component — the classic first tool. Bootstrap-shipped with the harness.
##
## The agent's normal path to self-extension: write source files with bash,
## compile with builder, spawn with core.

import std/[json, os, osproc, sequtils, strutils, times]
import natswrapper
import niffler/sdk

let comp = newComponent("bash", "0.1.0")

const maxCaptureBytes = 2_000_000
  ## Hard bound on what one command's output may produce. The capture is
  ## spilled to a temp file (never an envelope); beyond this even the
  ## spill is cut (head + tail with a marker).
const transcriptCapBytes = 12_000
  ## Transcript cap: what rides the conversation history. When output
  ## exceeds this, the full capture is spilled to a temp file and the
  ## transcript gets head+tail plus the spill path — the model can page
  ## through the full output with the read tool (offset/limit) instead of
  ## paying for it up front, and the transcript stays append-only.

var spillCounter = 0
  ## Serialized by the single-threaded poll loop; keeps spill file names
  ## unique per process.

proc spillOutput(output: string, sessionId: string): string =
  ## Write the full capture to var/toolout/<session>/ so the model can
  ## page through it with the read tool. Ephemeral: files older than one
  ## hour are swept on each spill; var/ is disposable runtime state.
  let root = getEnv("NIF_ROOT")
  let base = if root.len > 0: root / "var" else: getTempDir()
  var safe = ""
  for c in (if sessionId.len > 0: sessionId else: "direct"):
    safe.add((if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: c else: '_'))
  let dir = base / "toolout" / safe
  try:
    createDir(dir)
    # sweep: a one-hour TTL keeps the dir bounded across long sessions
    for kind, path in walkDir(dir):
      if kind == pcFile:
        try:
          if epochTime() - getLastModificationTime(path).toUnixFloat() > 3600.0:
            removeFile(path)
        except CatchableError:
          discard
    inc spillCounter
    let path = dir / ($getCurrentProcessId() & "-" & $epochTime().int &
                      "-" & $spillCounter & ".out")
    writeFile(path, output)
    result = path
  except CatchableError:
    result = ""

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
  description = "Execute a shell command via bash -c — builds, tests, piping, git mutations, process inspection. Returns combined stdout/stderr and the last command's exit code; on timeout the process tree is killed (124), on turn cancel (130). Output over ~12KB is spilled to a temp file (result.spill.path) and the result keeps only head+tail with a marker — page through the full output with read (offset/limit) on that path instead of assuming you saw everything. Prefer dedicated tools for file work and repo state: read/read_many, edit/write, files, grep, git_* (discover on the git component).")
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
    var full = captured
    if code == 124:
      full = "[timed out after " & $timeoutMs & "ms]\n" & captured
    elif code == 130:
      full = "[cancelled by request]\n" & captured
    # hard capture bound: beyond this even the spill file is cut
    if full.len > maxCaptureBytes:
      full = capBytes(full, maxCaptureBytes,
        "re-run a narrower command (grep/head/tail/wc) for the missing part")
    var result = %*{"exit_code": code, "cancelled": code == 130}
    # transcript cap: spill the full capture and keep only head+tail in
    # the conversation; the model pages the rest with read (offset/limit).
    if full.len > transcriptCapBytes:
      let spillPath = spillOutput(full, sessionId)
      if spillPath.len > 0:
        result["spill"] = %*{"path": spillPath,
                              "bytes": full.len,
                              "lines": full.countLines()}
        result["output"] = %capBytes(full, transcriptCapBytes,
          "full output saved to " & spillPath &
          " — page through it with read (offset/limit)")
      else:
        result["output"] = %capBytes(full, transcriptCapBytes,
          "re-run a narrower command (grep/head/tail/wc) for the missing part")
    else:
      result["output"] = %full
    return result)

comp.run()
