## bash component — the classic first tool. Bootstrap-shipped with the harness.
##
## The agent's normal path to self-extension: write source files with bash,
## compile with builder, spawn with core.

import std/[json, os, osproc, sequtils, strutils, times]
import natsnim
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
# Budgets, in one place. Three different clocks are in play: the component's
# own kill timer (timeoutMs, reported as exit 124 with the output captured so
# far), the caller's parameter, and core's wait for this call
# (x-harness.timeoutMs). They must not race: the inner timer is capped below
# core's wait so a slow command reports itself instead of core giving up on it
# (a core-side timeout throws the captured output away).
const
  BASH_DEFAULT_TIMEOUT_MS = 120_000  # a plain `make`/`cargo build` must fit
  BASH_MAX_TIMEOUT_MS = 570_000      # inner cap: 30s under core's wait below
  BASH_CALL_TIMEOUT_MS = 600_000     # core waits this long for a bash call

let bashSchema = toolSchema(%*{
  "command": {"type": "string",
              "description": "The command line to run"},
  "timeoutMs": {"type": "integer",
                "description": "Kill after this many ms (default 120000, max 570000). Raise it for a slow build instead of splitting the command; exit 124 with the output so far means it hit this."},
  "run_in_background": {"type": "boolean",
    "description": "Start as a background process instead of blocking: returns an id immediately (no timeout applies). Long-running commands — servers, watchers, databases. Poll incremental output with process_poll (drain semantics: each poll returns only what was appended since the last one; filter regex supported, tail re-reads raw), stop with process_kill."},
  "cwd": {"type": "string",
          "description": "Working directory (default: workspace)"}
}, required = @["command"],
  description = "Run a shell command (bash -c). The shell starts in the conversation's workspace (the repository root), so paths can be relative and `cd` to it is unnecessary; each call gets a fresh shell, so a `cd` never persists — use cwd or an absolute path to work elsewhere. One call has a budget (default 120s, up to 570s); a slower command is killed with exit 124, and anything that should outlive the call (servers, watchers, long builds) belongs in run_in_background — it returns an id at once and keeps running across turns, polled with process_poll and stopped with process_kill.")
bashSchema["x-harness"] = %*{"approval": "always",
                             "timeoutMs": BASH_CALL_TIMEOUT_MS,
                             "sessionId": true,
                             "workspace": %*{"cwdField": "cwd"}}
discard comp.tool("bash", bashSchema,
  proc(c: Component, toolArgs: JsonNode): JsonNode =
    let sessionId = toolArgs{"__session"}{"session"}.getStr("")
    if sessionId.len > 0 and wasCancelled(sessionId):
      return %*{"text": "(exit 130 — cancelled by request)",
                "exit_code": 130, "cancelled": true}
    let command = toolArgs{"command"}.getStr("")
    # The caller's budget, clamped: an absurd value must not outlive core's
    # wait for this call (the component's exit-124 report carries the output;
    # a core-side timeout would not).
    let timeoutMs = min(max(toolArgs{"timeoutMs"}.getInt(BASH_DEFAULT_TIMEOUT_MS), 1000),
                        BASH_MAX_TIMEOUT_MS)
    let cwd = toolArgs{"cwd"}.getStr("")
    if toolArgs{"run_in_background"}.getBool(false):
      # thin producer: the processes component spawns, owns, drains and
      # reaps — bash never blocks on (or orphans) a long-running child.
      try:
        var startArgs = %*{"command": command}
        if cwd.len > 0: startArgs["workdir"] = %cwd
        # Hand the owning conversation to the registry: processes publishes
        # the exit notice there, so a finished background job reaches the
        # conversation instead of waiting to be polled (it owns the child,
        # so it is the only one that can notice).
        if sessionId.len > 0: startArgs["session"] = %sessionId
        let resp = c.request("processes", "process_start", startArgs, 15000)
        var payload = resp
        payload["text"] = %("Started in background as " &
          resp{"id"}.getStr("") & " (" & resp{"label"}.getStr("") & ") — " &
          "poll incremental output with process_poll {id: \"" &
          resp{"id"}.getStr("") & "\"}, stop with process_kill.")
        return payload
      except CatchableError as e:
        return %*{"error": "[E_BACKGROUND] could not start the background " &
          "process (is the processes component running?): " & e.msg &
          " — run the command synchronously instead."}
    let scoped = if cwd.len > 0:
                   "cd -- " & quoteShell(cwd) & " || exit $?\n" & command
                 else: command
    let (code, captured) = runCmd(scoped, timeoutMs,
      proc(): bool = drainCancels(sessionId))
    var full = captured
    # hard capture bound: beyond this even the spill file is cut
    if full.len > maxCaptureBytes:
      full = capBytes(full, maxCaptureBytes,
        "re-run a narrower command (grep/head/tail/wc) for the missing part")
    var payload = %*{"exit_code": code, "cancelled": code == 130}
    var status = "(exit " & $code
    if code == 124: status.add(" — timed out after " & $timeoutMs &
      "ms; raise timeoutMs for a slow build, or use run_in_background for work that outlives a call")
    elif code == 130: status.add(" — cancelled by request")
    elif code == 126: status.add(" — found but not executable; run it via an interpreter, e.g. bash ./script.sh")
    status.add(")")
    var text = status & "\n"
    # transcript cap: spill the full capture and keep only head+tail in
    # the conversation; the model pages the rest with read (offset/limit).
    if full.len > transcriptCapBytes:
      let spillPath = spillOutput(full, sessionId)
      if spillPath.len > 0:
        payload["spill"] = %*{"path": spillPath,
                             "bytes": full.len,
                             "lines": full.countLines()}
        text.add("[full output: " & $full.len & " bytes, " &
                 $full.countLines() & " lines → " & spillPath &
                 " — page through it with read (offset/limit)]\n")
        text.add(capBytes(full, transcriptCapBytes,
          "full output saved to " & spillPath &
          " — page through it with read (offset/limit)"))
      else:
        text.add(capBytes(full, transcriptCapBytes,
          "re-run a narrower command (grep/head/tail/wc) for the missing part"))
    else:
      text.add(full)
    payload["text"] = %text
    return payload)

discard comp.selfTest(proc(c: Component, args: JsonNode): JsonNode =
  ## Self test (docs/WIRE.md): exercise the component's real exec path
  ## (process-group leader, temp-file capture, timeout kill) on a trivial
  ## command, plus the timeout machinery at a 1s budget. `deep` accepted,
  ## same probes — there is nothing deeper to run.
  var checks = newJArray()
  var allOk = true
  let t0 = epochTime()

  proc check(name: string, ok: bool, detail: string, t1: float) =
    if not ok: allOk = false
    checks.add(%*{"name": name, "ok": ok, "detail": detail,
                  "ms": int((epochTime() - t1) * 1000)})

  block execPath:
    let t1 = epochTime()
    let (code, outp) = runCmd("echo doctor-ok", 10_000)
    check("exec", code == 0 and "doctor-ok" in outp,
          (if code == 0: "echo answered via the real runCmd path (exit 0)" else:
            "exit " & $code & ": " & outp[0 ..< min(outp.len, 80)]), t1)
  block timeout:
    let t1 = epochTime()
    let (code, _) = runCmd("sleep 30", 1_000)
    check("timeout kill", code == 124,
          (if code == 124: "1s budget killed a 30s sleep (exit 124, tree reaped)" else:
            "expected exit 124, got " & $code), t1)
  return %*{"ok": allOk,
            "summary": (if allOk: "exec + timeout-kill paths green" else: "failures above"),
            "checks": checks})

comp.run()
