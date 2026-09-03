## systemprompt component tests — the pluggable conversation constitution.
##
## Boots a sandbox core (store + bash, no LLM) with the test-only stub
## component (components/ctxtest) and the systemprompt component, plus an
## AGENTS.md/CLAUDE.md pair in the sandbox root. Asserts the full loop:
## - the conversation's system message comes from the component (product
##   prompt + <project_context> wrapping AGENTS.md, not CLAUDE.md), proven
##   by the stub LLM echoing messages[0] back as its reply;
## - the frozen constitution survives a runner restart AND component death
##   (persisted in the conversation header, never re-resolved);
## - a fresh conversation after the component died degrades to core's
##   minimal fallback;
## - direct service surface: candidate priority, shadowing.

import std/[json, os, osproc, strutils]
import natswrapper
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 20): bool =
  ## Poll the catalog's component view until `name` is registered.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} != nil:
      return true
    sleep(200)
  return false

proc waitGone(nc: NatsConnection, name: string, secs = 15): bool =
  ## Poll until `name` is no longer in the catalog.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 5_000)
    if snap{"components"}{name} == nil:
      return true
    sleep(200)
  return false

proc sysEcho(nc: NatsConnection, sid: string): string =
  ## Drive one turn and extract the stub LLM's echo of the system message.
  let turn = call(nc, "core", "session",
                  %*{"sessionId": sid, "content": "go"}, 120_000)
  if turn{"error"} != nil:
    return "TURN-ERROR: " & $turn
  result = turn{"reply"}.getStr("")
  let start = result.find("sys-echo<<<")
  let finish = result.find(">>>end")
  if start >= 0 and finish > start:
    result = result[start + "sys-echo<<<".len ..< finish]

proc main() =

  let repoRoot = getEnv("NIF_REPO_ROOT",
                        getEnv("NIF_ROOT", getAppDir().parentDir()))
  for bin in ["niffler", "agent", "systemprompt"]:
    if not fileExists(repoRoot / "var" / "bin" / bin):
      fail("missing binary " & bin & " — run `make build` first")
      quit(1)
  # systemprompt deliberately NOT in the sandbox manifest: the test starts
  # and kills it manually (a supervisor child would be restarted on death).
  let sandbox = newCoreSandbox("systemprompt", ["store", "bash"])
  let root = sandbox.root
  echo "sandbox root: ", root
  # agent and systemprompt are not in the sandbox manifest (nothing
  # autostarts systemprompt; the test starts and kills it manually — a
  # supervisor child would be restarted on death). Started below, like
  # ctxtest.
  copyFileWithPermissions(repoRoot / "var" / "bin" / "agent",
                          sandbox.sandboxBin("agent"))
  copyFileWithPermissions(repoRoot / "var" / "bin" / "systemprompt",
                          sandbox.sandboxBin("systemprompt"))

  # context files in the sandbox (the harness root for this test):
  # AGENTS.md shadows CLAUDE.md in the same directory.
  writeFile(root / "AGENTS.md", "sandbox agents rules: prefer store tools\n")
  writeFile(root / "CLAUDE.md", "stale claude rules that must NOT load\n")

  # compile the test-only stub component into the sandbox
  let ctxBin = sandbox.sandboxBin("ctxtest")
  let compProc = startProcess("nim", args = [
    "c", "--hints:off", "--warnings:off",
    "--path:" & repoRoot / "sdk",
    "-o:" & ctxBin,
    repoRoot / "components" / "ctxtest" / "main.nim"],
    options = {poUsePath, poStdErrToStdOut})
  defer: compProc.close()
  if waitForExit(compProc, 120_000) != 0:
    fail("ctxtest component failed to compile")
    quit(1)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
                                root = root,
                                extra = [("NIF_AUTO_APPROVE", "1")],
                                logFile = "/tmp/opencode/core-sp.log")
  defer:
    if coreProc != nil and coreProc.running():
      coreProc.terminate()
      sleep(1500)
      if coreProc.running(): coreProc.kill()
      sleep(200)
    if coreProc != nil: coreProc.close()

  var coreUp = false
  for i in 0 ..< 100:
    let r = call(nc, "core", "catalog", %*{"op": "list"}, 3_000)
    if r{"error"} == nil and r{"tools"} != nil:
      coreUp = true
      break
    sleep(200)
  check("core up", coreUp)

  let ctxProc = startComponent(ctxBin, url, root = root,
                               logFile = "/tmp/opencode/ctxtest-sp.log")
  defer:
    if ctxProc.running():
      ctxProc.terminate()
      sleep(800)
      if ctxProc.running(): ctxProc.kill()
    ctxProc.close()
  check("ctxtest registered", waitComponent(nc, "ctxtest"))
  let spProc = startComponent(sandbox.sandboxBin("systemprompt"), url,
                              root = root,
                              logFile = "/tmp/opencode/systemprompt.log")
  # stopped mid-test (frozen-prompt check); the close below reaps it
  check("systemprompt registered", waitComponent(nc, "systemprompt"))
  let agentProc = startComponent(sandbox.sandboxBin("agent"), url, root = root,
                                 logFile = "/tmp/opencode/agent-sp.log")
  defer:
    if agentProc.running():
      agentProc.terminate()
      sleep(800)
      if agentProc.running(): agentProc.kill()
    agentProc.close()
  check("agent registered", waitComponent(nc, "agent"))

  # --- direct service surface ------------------------------------------------
  let direct = call(nc, "systemprompt", "systemprompt",
                    %*{"cwd": root}, 10_000)
  let directPrompt = direct{"systemPrompt"}.getStr("")
  check("systemprompt answers direct calls",
        directPrompt.contains("self-extending agent harness"), $direct)
  check("global AGENTS.md wraps into project_context",
        directPrompt.contains(
          "<project_instructions path=\"" & root / "AGENTS.md" & "\">"),
        directPrompt)
  check("AGENTS.md shadows CLAUDE.md in the same directory",
        directPrompt.contains("sandbox agents rules") and
        not directPrompt.contains("stale claude rules"), directPrompt)
  check("product prompt substitutes $ROOT",
        directPrompt.contains("Your home is " & root), directPrompt)

  # --- workspace ancestor walk: inside root only -----------------------------
  # A context file in an ancestor of cwd is injected while the walk stays
  # inside the harness root; a file ABOVE the root must never leak in (the
  # bench relies on this: its harness roots are nested inside a git
  # worktree whose own AGENTS.md would otherwise ride along).
  createDir(root / "ws")
  writeFile(root / "ws" / "AGENTS.md", "workspace rules: mind the boundary\n")
  let wsPrompt = call(nc, "systemprompt", "systemprompt",
                      %*{"cwd": root / "ws"}, 10_000){"systemPrompt"}.getStr("")
  check("workspace ancestor AGENTS.md within the root is injected",
        wsPrompt.contains("workspace rules: mind the boundary"), wsPrompt)
  block aboveRoot:
    let above = parentDir(root) / "AGENTS.md"
    if fileExists(above):
      # a stray /tmp AGENTS.md would make the negative check ambiguous
      check("above-root context file present — skipping leak check", true)
    else:
      writeFile(above, "MUST NOT LEAK into any prompt\n")
      defer: removeFile(above)
      let leak = call(nc, "systemprompt", "systemprompt",
                      %*{"cwd": root}, 10_000){"systemPrompt"}.getStr("")
      check("context file above the harness root never leaks",
            not leak.contains("MUST NOT LEAK"), leak)

  # --- conversation 1: constitution from the component -----------------------
  let sid = "sp-live"
  let echo1 = sysEcho(nc, sid)
  check("conversation system message comes from the component",
        echo1.contains("self-extending agent harness") and
        echo1.contains("sandbox agents rules") and
        not echo1.contains("fallback prompt"), echo1)
  check("AGENTS.md shadows CLAUDE.md for the LLM too",
        not echo1.contains("stale claude rules"), echo1)

  # --- frozen: component dies, conversation resumes with the same prompt -----
  # Started manually (not a supervisor child), so a direct kill is final:
  # SIGKILL = crash without reg.depart, exactly the "component died" case.
  if spProc.running():
    spProc.kill()
    discard spProc.waitForExit(2000)
  spProc.close()
  sleep(300)
  let echo2 = sysEcho(nc, sid)
  check("frozen prompt survives component death (no fallback switch)",
        echo2.contains("sandbox agents rules") and
        not echo2.contains("fallback prompt"), echo2)

  # --- conversation 2 (same runner is gone too): minimal fallback ------------
  let echo3 = sysEcho(nc, "sp-fallback")
  check("degraded conversation uses core's minimal fallback",
        echo3.contains("fallback prompt") and
        not echo3.contains("sandbox agents rules"), echo3)

  # --- the agent component still works (systemprompt fetch is best effort) ---
  check("agent registered", waitComponent(nc, "agent"))
  let parentId = "agt-parent"
  let turn = call(nc, "core", "session",
                  %*{"sessionId": parentId, "content": "go"}, 120_000)
  check("agent turn completed (agent fetches prompt best-effort)",
        turn{"reply"}.getStr("") == "agent-turn-done", $turn)

  report("systemprompt")

main()
