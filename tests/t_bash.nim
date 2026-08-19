## bash component tests — bus contract: registration + tool behaviour.
##
## Spawns bash against a throwaway NATS and drives it with envelopes:
## exit codes, stderr capture, timeout kill, output cap, drain.

import std/[json, os, osproc, strutils, times]
import natswrapper
import envelope
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "bash"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)

  let (server, url) = startNats()
  var nc = waitConnect(url)

  let bashProc = startComponent(bin, url)
  defer:
    if bashProc.running():
      bashProc.terminate()
      sleep(200)
    bashProc.close()

  check("bash registers", waitRegistered(nc, "bash"))

  # basic execution: stdout, stderr and exit code
  let r1 = call(nc, "bash", "bash",
                %*{"command": "echo out; echo err >&2; exit 3", "timeoutMs": 10000})
  check("bash exit code", r1{"exit_code"}.getInt(-1) == 3, $r1)
  check("bash stdout", r1{"output"}.getStr("").contains("out"), $r1)
  check("bash stderr captured", r1{"output"}.getStr("").contains("err"), $r1)

  # exit code of the last command decides
  let r2 = call(nc, "bash", "bash",
                %*{"command": "false; echo done", "timeoutMs": 10000})
  check("bash last-command exit code", r2{"exit_code"}.getInt(-1) == 0, $r2)

  # timeout: killed, exit 124, marked in output
  let t0 = epochTime()
  let r3 = call(nc, "bash", "bash",
                %*{"command": "sleep 30", "timeoutMs": 500}, 15_000)
  check("bash timeout exit 124", r3{"exit_code"}.getInt(-1) == 124, $r3)
  check("bash timeout marks output",
        r3{"output"}.getStr("").contains("timed out after"), $r3)
  check("bash timeout kills quickly", epochTime() - t0 < 10, $r3)

  # output cap: bash keeps head+tail with a truncation marker
  let r4 = call(nc, "bash", "bash",
                %*{"command": "for i in $(seq 1 20000); do echo line-$i; done",
                   "timeoutMs": 20000}, 30_000)
  let out4 = r4{"output"}.getStr("")
  check("bash caps output", out4.len < 300_000 and
        out4.contains("truncated") and out4.contains("line-1") and
        out4.contains("line-20000"), "len=" & $out4.len)

  # drain: component exits
  drain(nc)
  sleep(700)
  check("bash drains and exits", not bashProc.running())

  server.terminate()
  server.close()
  nc.close()
  report("BASH TEST")

main()
