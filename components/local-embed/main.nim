## Optional supervised local embedding runtime. Enable with core.spawn, never
## manifest autostart. Install weights first with make install-embed.
import std/[os, osproc, json, times]
import niffler/[sdk, procutil]

let c = newComponent("local-embed", "0.1.0")
var child: Process
var state = "absent"
var retryAt = 0.0
let root = getEnv("NIF_ROOT", getCurrentDir())

c.tool(%*{"effect": "read"}):
  proc local_embed_status(): JsonNode =
    ## Launcher state only; embed through the configured provider to verify readiness.
    %*{"state": state, "endpoint": "http://127.0.0.1:" &
       getEnv("NIF_EMBED_PORT", "18100") & "/v1",
       "childPid": (if child == nil: 0 else: child.processID)}

discard c.onIdle(1000) do (comp: Component):
  if child != nil:
    if child.peekExitCode() == -1: return
    child.close()
    child = nil
    state = "failed"
    retryAt = epochTime() + 30.0
    return
  if epochTime() < retryAt: return
  let dir = getEnv("NIF_EMBED_DIR", root / "var/embed")
  if not fileExists(dir / "runner/llama-server"): return
  var command = "exec "
  when defined(linux):
    let wrapper = pdeathsigSetprivPath()
    if wrapper.len == 0:
      state = "missing-pdeathsig-wrapper"
      return
    command.add quoteShell(wrapper) & " --pdeathsig TERM "
  createDir(root / "var/logs")
  command.add "bash " & quoteShell(root / "scripts/embed-server.sh") &
    " >> " & quoteShell(root / "var/logs/local-embed-runtime.log") & " 2>&1"
  child = startProcess("/bin/sh", args = ["-c", command], options = {poUsePath})
  state = "running-readiness-unverified"

discard c.onDrain do (comp: Component):
  if child != nil:
    if child.running():
      child.terminate()
      if child.waitForExit(3000) == -1: child.kill()
    child.close()
    child = nil

c.run()
