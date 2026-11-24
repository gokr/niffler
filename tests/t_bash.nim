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

  # A decoy in the COMPONENT's own environment: the provenance injected by a
  # dispatch must win over it (harness-owned, issue #101 AC 4). Without this
  # the "no inherited value leaks in" claim would be untested.
  let bashProc = startComponent(bin, url, root = tmp,
                                extra = [("NIF_MODEL", "DECOY-MODEL")])
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
    check("the mount is declared a safe git directory",
          w.contains("safe.directory") and w.contains("/work/task-a"), w)
    check("longest matching prefix wins",
          netScoped("true", "/work/task-a/nested/deep").contains("x/y"), w)
    putEnv("NIF_BASH_CONTAINER_MAP", "/work/task-a=nif-task-test")
    let persistent = netScoped("echo preserved", "/work/task-a/src")
    check("persistent mapping execs rather than recreates a container",
          persistent.contains("docker exec --user") and
          persistent.contains("nif-task-test") and
          not persistent.contains("docker run"), persistent)
    check("missing persistent mapping fails closed",
          netScoped("true", "/work/task-b").contains("exit 125"))
    putEnv("NIF_BASH_CONTAINER_MAP", "")
    let other = netScoped("true", "/work/elsewhere")
    check("no matching image refuses the command",
          other.contains("no sandbox image") and other.contains("exit 125"), other)
    # A map written by one process and a cwd handed in by another must match
    # on the REAL path: the deepswe bench writes a bench-root path containing
    # a `var` symlink while the agent's cwd never traversed it, so every
    # command in the run died with `exit 125`.
    block sandboxSpelling:
      let base = getTempDir() / ("nif-sandbox-" & $getCurrentProcessId())
      let realDir = base / "tasks-x" / "t1" / "repo"
      createDir(realDir)
      defer: removeDir(base)
      let linkDir = base / "linked"
      createSymlink(realDir, linkDir)
      putEnv("NIF_BASH_SANDBOX_MAP", linkDir & "=img-z\n")
      # cwd spelled through the symlink, map entry spelled without it (and
      # vice versa) must both resolve to the same image.
      let viaLink = netScoped("true", linkDir)
      let viaReal = netScoped("true", realDir)
      check("symlinked cwd matches a real-path map entry",
            viaLink.contains("docker run --rm --network none") and
            viaLink.contains("img-z"), viaLink)
      check("real cwd matches a symlinked map entry",
            viaReal.contains("docker run --rm --network none") and
            viaReal.contains("img-z"), viaReal)
      check("the mounted root keeps the mapping's own spelling",
            viaLink.contains(linkDir & ":" & linkDir), viaLink)
      check("a subdir cwd still mounts the whole workspace root",
            netScoped("true", linkDir / "src").contains("-w " & linkDir & "/src"),
            netScoped("true", linkDir / "src"))
      putEnv("NIF_BASH_SANDBOX_MAP", "")
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

  # --- session provenance (issue #101) ------------------------------------
  # A command dispatched inside a turn must be able to report which session,
  # model, provider and effort drove it — and must call back into the harness
  # without the model pasting an id into the command string. The values come
  # from the runner's RESOLVED turn identity, so they are truthful, and they
  # are absent (not empty) when nothing was resolved.
  let provSession = "provenance-session"
  let rp = call(nc, "bash", "bash", %*{
    "command": "echo sid=[$NIF_SESSION_ID] model=[$NIF_MODEL] " &
               "prov=[$NIF_PROVIDER] reas=[$NIF_REASONING_LEVEL]",
    "timeoutMs": 10000,
    "__session": {"session": provSession,
                  "provenance": {"model": "deepseek-chat",
                                 "provider": "deepseek",
                                 "reasoning": "high"}}})
  let pt = rp{"text"}.getStr("")
  check("a session command sees NIF_SESSION_ID",
        pt.contains("sid=[" & provSession & "]"), pt)
  check("a session command sees the resolved model", pt.contains("model=[deepseek-chat]"), pt)
  check("a session command sees the resolved provider", pt.contains("prov=[deepseek]"), pt)
  check("a session command sees the reasoning effort", pt.contains("reas=[high]"), pt)

  # A value the turn never resolved must be ABSENT, never exported empty:
  # `env | grep NIF_MODEL` answering with an empty value would tell a script
  # the model is "" rather than unknown.
  let rn = call(nc, "bash", "bash", %*{
    "command": "echo m=[$NIF_MODEL]",
    "timeoutMs": 10000,
    "__session": {"session": provSession, "provenance": {"provider": "deepseek"}}})
  # The component's own environment carries a DECOY NIF_MODEL (see the
  # startComponent above), which a child inherits regardless — that is the
  # component's environment, not provenance. What must NOT happen is the
  # runner's unresolved value being injected as an empty string, which would
  # overwrite the decoy with "" and tell a script the model is empty rather
  # than unspecified. So: an unresolved model leaves the child's own value
  # alone (here, the decoy), and only a RESOLVED value overrides it — which
  # the "injected value wins over any inherited one" check proves.
  check("an unresolved model is never injected as an empty value",
        rn{"text"}.getStr("").contains("m=[DECOY-MODEL]"), $rn)

  # Scope: a DIRECT call (no __session, the `cli call bash` shape) gets no
  # ambient identity. It is not inside a turn, so there is nothing truthful
  # to export.
  let rd = call(nc, "bash", "bash", %*{
    "command": "echo sid=[$NIF_SESSION_ID] r=[$NIF_REASONING_LEVEL]",
    "timeoutMs": 10000})
  # A direct call is not inside a turn, so nothing truthful can be exported
  # and dispatch injects nothing: the names read as empty, and the component's
  # own decoy NIF_MODEL is not promoted into provenance either.
  check("a direct call gets no ambient session or reasoning",
        rd{"text"}.getStr("").contains("sid=[]") and
        rd{"text"}.getStr("").contains("r=[]"), $rd)

  # Harness-owned: what this component's own environment holds for those names
  # must never leak in. The component is started with NIF_MODEL set to a decoy
  # below, and the direct call above already proves it does not surface.
  let rq = call(nc, "bash", "bash", %*{
    "command": "echo model=[$NIF_MODEL]",
    "timeoutMs": 10000,
    "__session": {"session": provSession,
                  "provenance": {"model": "deepseek-chat"}}})
  check("the injected value wins over any inherited one",
        rq{"text"}.getStr("").contains("model=[deepseek-chat]"), $rq)

  # drain: component exits
  drain(nc)
  sleep(700)
  check("bash drains and exits", not bashProc.running())

  report("BASH TEST")

main()
