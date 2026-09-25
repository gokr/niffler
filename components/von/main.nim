## von — supervised launcher for the Von decision runtime behind the jev
## component. Deliberately NOT in the manifest: enabling it is a persisted
## core.spawn record (make von-up), so the supervisor manages this process
## like any component — PDEATHSIG, restart policy, drain — while the heavy
## Python runtime stays an opt-in child. The launcher never exits while
## enabled; it starts Von only when the venv binary exists and supervises
## that child with kernel-enforced cleanup (setpriv --pdeathsig, same
## wrapper the supervisor itself uses). A Von already serving at the
## endpoint (started by hand, or by a previous launcher life) is adopted,
## never double-started.
##
## Env (inherited from the harness):
##   NIF_VON_BIN     path to the von binary (default var/jev-venv/bin/von)
##   NIF_VON_ARGS    full argv, whitespace-split (default: serve --model
##                   NIF_VON_MODEL --host NIF_VON_HOST --port NIF_VON_PORT)
##   NIF_VON_MODEL   default von-1.1
##   NIF_VON_DEVICE  default cpu
##   NIF_VON_HOST    default 127.0.0.1
##   NIF_VON_PORT    default 8000
##   NIF_VON_POLL_MS idle interval (default 1000)
##   NIF_VON_BACKOFF_MAX_S  restart backoff cap (default 60)

import std/[httpclient, json, os, osproc, strutils, times, uri]
import niffler/sdk

let binPath = getEnv("NIF_VON_BIN", getCurrentDir() / "var" / "jev-venv" / "bin" / "von").strip()
let argsEnv = getEnv("NIF_VON_ARGS", "").strip()
let model = getEnv("NIF_VON_MODEL", "von-1.1").strip()
let device = getEnv("NIF_VON_DEVICE", "cpu").strip()
let host = getEnv("NIF_VON_HOST", "127.0.0.1").strip()
let port = getEnv("NIF_VON_PORT", "8000").strip()
let pollMs = max(parseInt(getEnv("NIF_VON_POLL_MS", "1000")), 100)
let backoffMaxS = parseFloat(getEnv("NIF_VON_BACKOFF_MAX_S", "60")).max(1.0)

proc endpoint(): string = "http://" & host & ":" & port & "/v1/systemone"

let comp = newComponent("von", "0.1.0")

var state = if fileExists(binPath): "starting" else: "absent"
var stateSince = epochTime()
var child: Process
var backoffS = 5.0
var backoffUntil = 0.0
var announced: seq[string] = @[]

proc say(level: string, msg: string, ctx: JsonNode = nil) =
  if msg notin announced:
    announced.add(msg)
    comp.log(level, "von launcher: " & msg, ctx)

proc probeServing(): bool =
  ## Any HTTP answer at the endpoint counts as a Von being served — the
  ## launcher adopts it. No answer: connection refused/timeout → false.
  try:
    let client = newHttpClient("niffler-von/0.1", timeout = 1500,
                               maxRedirects = 0)
    defer: client.close()
    client.headers = newHttpHeaders({"Content-Type": "application/json"})
    discard client.request(endpoint(), httpMethod = HttpGet)
    true
  except CatchableError:
    false

proc spawnVon() =
  ## Start the venv binary under setpriv --pdeathsig (kernel-enforced child
  ## cleanup: if this launcher dies — even SIGKILL — the kernel SIGTERMs Von,
  ## so a 5 GB model process can never outlive its supervisor). Mirrors the
  ## supervisor's own wrapper; falls back to a plain child when setpriv is
  ## absent (then SIGTERM/SIGKILL of the launcher can orphan Von).
  var args: seq[string]
  if argsEnv.len > 0: args = argsEnv.splitWhitespace()
  else: args = @["serve", "--model", model, "--host", host, "--port", port]
  var cmd = "exec "
  when defined(linux):
    let sp = findExe("setpriv")
    if sp.len > 0: cmd.add(quoteShell(sp) & " --pdeathsig TERM ")
    else: say("warn", "setpriv missing — Von cleanup falls back to non-kernel")
  cmd.add(quoteShell(binPath))
  for a in args: cmd.add(" " & quoteShell(a))
  let logDir = getEnv("NIF_LOGFILE_DIR", getCurrentDir() / "var" / "logs")
  createDir(logDir)
  cmd.add(" >> " & quoteShell(logDir / "von-runtime.log") & " 2>&1")
  child = startProcess("/bin/sh", args = ["-c", cmd],
                       workingDir = getCurrentDir(), options = {poUsePath})
  state = "starting"
  stateSince = epochTime()
  say("info", "starting Von: " & binPath & " " & args.join(" "))

proc tick() =
  if child != nil:
    if child.peekExitCode() == -1:
      # Child alive: probe for readiness (Von can load weights for minutes)
      # and graduate "starting" → "serving" without ever double-starting.
      if probeServing():
        if state != "serving":
          state = "serving"
          stateSince = epochTime()
          backoffS = 5.0
          backoffUntil = 0.0
          say("info", "Von serving at " & endpoint())
      return
    let code = child.peekExitCode()
    child.close()
    child = nil
    backoffS = min(backoffS * 2.0, backoffMaxS)
    backoffUntil = epochTime() + backoffS
    state = "failed"
    stateSince = epochTime()
    say("warn", "Von exited (code " & $code & ") — restart in " &
                $int(backoffS) & "s")
    return
  if probeServing():
    if state != "serving":
      state = "serving"
      stateSince = epochTime()
      backoffS = 5.0
      backoffUntil = 0.0
    say("info", "Von answering at " & endpoint() &
                " (adopted, not restarted)")
    return
  if epochTime() < backoffUntil: return
  if not fileExists(binPath):
    if state != "absent":
      state = "absent"
      stateSince = epochTime()
    say("warn", "Von binary missing at " & binPath &
                " — run `make install-jev`; re-checking on the idle seam")
    return
  spawnVon()

comp.tool(%*{"effect": "read", "parallel": true}):
  proc von_status(): JsonNode =
    ## Read-only launcher status: state is "starting" (Von loading weights —
    ## the first load can take minutes and downloads the model), "serving"
    ## (the endpoint answers — jev is usable), "absent" (venv binary missing;
    ## run `make install-jev`), or "failed" (Von exited; the launcher retries
    ## with capped backoff). Adopted means a Von was already running when the
    ## launcher started. Poll this after spawn/enable before relying on
    ## jev_suggest/jev_recommend.
    let pid = getCurrentProcessId()
    %*{"ok": true, "state": state, "endpoint": endpoint(), "binary": binPath,
       "model": model, "device": device, "childPid": (if child != nil: child.processID else: 0),
       "selfPid": pid, "stateSeconds": int(epochTime() - stateSince),
       "backoffSeconds": int(max(backoffUntil - epochTime(), 0.0)),
       "note": "advisory status; jev calls are the real probe"}

discard comp.onIdle(pollMs) do (c: Component):
  tick()

discard comp.onDrain do (c: Component):
  if child != nil:
    try:
      if child.running():
        child.terminate()
        var waited = 0.0
        while child.running() and waited < 3.0:
          sleep(50)
          waited += 0.05
        if child.running(): child.kill()
    except CatchableError:
      discard
    try: child.close()
    except CatchableError: discard
    child = nil
  c.log("info", "von launcher: draining — Von child stopped")

comp.run()
