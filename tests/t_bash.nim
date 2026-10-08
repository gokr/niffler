## bash component tests — bus contract: registration + tool behaviour.
##
## Spawns bash against a throwaway NATS and drives it with envelopes:
## exit codes, stderr capture, timeout kill, output cap, drain.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import niffler/procutil
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "bash"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)
  let tmp = tempRoot("bash")
  defer: removeDir(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  let bashProc = startComponent(bin, url, root = tmp)
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
  let out1 = r1{"text"}.getStr("")
  check("bash stdout", out1.contains("out"), $r1)
  check("bash stderr captured", out1.contains("err"), $r1)

  # exit code of the last command decides
  let r2 = call(nc, "bash", "bash",
                %*{"command": "false; echo done", "timeoutMs": 10000})
  check("bash last-command exit code", r2{"exit_code"}.getInt(-1) == 0, $r2)

  # heredoc without a trailing newline: the wrapper must not glue the
  # redirection onto the delimiter line (regression: silent exit 2)
  let rh = call(nc, "bash", "bash",
                %*{"command": "cat <<'EOF'\nheredoc body\nEOF", "timeoutMs": 10000})
  check("bash heredoc without trailing newline",
        rh{"exit_code"}.getInt(-1) == 0 and
        rh{"text"}.getStr("").contains("heredoc body"), $rh)

  # cwd param: the command runs in the given directory
  createDir(tmp / "sub")
  let r2b = call(nc, "bash", "bash",
                 %*{"command": "pwd", "timeoutMs": 10000, "cwd": tmp / "sub"})
  check("bash cwd param scopes the command",
        r2b{"exit_code"}.getInt(-1) == 0 and
        r2b{"text"}.getStr("").contains("sub"), $r2b)

  let marker = tmp / "must-not-run"
  let badCwd = call(nc, "bash", "bash",
    %*{"cwd": tmp / "missing", "command":
      "true; touch " & quoteShell(marker) & " || echo fallback"})
  check("failed cwd stops the entire compound command",
    badCwd{"exit_code"}.getInt(0) != 0 and not fileExists(marker), $badCwd)

  # timeout: killed, exit 124, marked in output — and the WHOLE command
  # tree dies (a bare wrapper kill would orphan the sleep 30; the group
  # kill must reach it, proven by pgrep finding no process)
  let t0 = epochTime()
  let r3 = call(nc, "bash", "bash",
                %*{"command": "sleep 30 && echo bashmarker-timeout",
                   "timeoutMs": 500}, 15_000)
  check("bash timeout exit 124", r3{"exit_code"}.getInt(-1) == 124, $r3)
  check("bash timeout marks output",
        r3{"text"}.getStr("").contains("timed out after"), $r3)
  check("bash timeout kills quickly", epochTime() - t0 < 10, $r3)
  sleep(400)  # an orphaned sleep would still be alive now
  check("bash timeout killed the command tree (no orphan)",
        not processExists("bashmarker-timeout"))

  # output cap: bash keeps head+tail with a truncation marker, and spills
  # the full capture to a temp file the read tool can page through
  let r4 = call(nc, "bash", "bash",
                %*{"command": "for i in $(seq 1 20000); do echo line-$i; done",
                   "timeoutMs": 20000}, 30_000)
  let out4 = r4{"text"}.getStr("")
  check("bash caps output", out4.len < 300_000 and
        out4.contains("truncated") and out4.contains("line-1") and
        out4.contains("line-20000"), "len=" & $out4.len)
  let spillPath = r4{"spill"}{"path"}.getStr("")
  check("bash spills oversized output", spillPath.len > 0 and
        fileExists(spillPath) and
        r4{"spill"}{"lines"}.getInt(0) in [20000, 20001],
        $r4{"spill"})
  check("spill file holds the middle the transcript lacks",
        readFile(spillPath).contains("line-10000") and
        not out4.contains("line-10000"), spillPath)
  check("spill path is under the toolout dir",
        spillPath.contains("var/toolout"), spillPath)

  # netScoped: no-network command execution (sdk/niffler/procutil.nim).
  # Map flavor (docker sandbox) is checked as strings — the docker
  # integration is the deepswe lane itself; the netns flavor is checked
  # end-to-end where unprivileged user namespaces exist.
  block netwrap:
    check("no wrap by default", netScoped("echo plain") == "echo plain")
    let mapVal = "/work/task-a=repo.test/img-a\n/work/task-a/nested=x/y\n/work/task-b=img-b"
    putEnv("NIF_BASH_SANDBOX_MAP", mapVal)
    let w = netScoped("echo hi", "/work/task-a/src")
    check("sandbox wrap mounts the WORKSPACE ROOT (subdir cwds keep the whole repo visible)",
          w.contains("docker run --rm --network none") and
          w.contains("/work/task-a:/work/task-a") and
          w.contains("-w /work/task-a/src"),
          w)
    check("longest matching prefix wins",
          netScoped("true", "/work/task-a/nested/deep").contains("x/y"), w)
    let other = netScoped("true", "/work/elsewhere")
    check("no matching image refuses the command",
          other.contains("no sandbox image") and other.contains("exit 125"), other)
    putEnv("NIF_BASH_SANDBOX_MAP", "")
    when defined(linux):
      putEnv("NIF_BASH_NET", "off")
      let wrapped = netScoped("cat /proc/net/route; echo local-ok")
      putEnv("NIF_BASH_NET", "")
      let probe = runCmd("unshare --net --map-root-user -- true", 5_000)
      if probe.code == 0:
        let r = runCmd(wrapped, 10_000)
        check("netns wrap still runs the command", r.output.contains("local-ok"),
              r.output)
        var routes = 0
        for line in r.output.splitLines():
          let t = line.strip()
          if t.len > 0 and not t.startsWith("Iface"): inc routes
        check("no routes out of the namespace", routes == 0, r.output)
      else:
        echo "NOTE: unprivileged user namespaces blocked here — netns wrap untestable"

  # drain: component exits
  drain(nc)
  sleep(700)
  check("bash drains and exits", not bashProc.running())

  report("BASH TEST")

main()
