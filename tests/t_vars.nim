## t_vars — runtime variables ($name / save_as): in-turn pipeline plumbing.
##
## Drives a real session turn through the scripted mock llm (NIF_MOCK_TOOLJSON)
## whose tool_calls pipeline through the edit component. Proves:
## - one message can pipeline: read saves `span`, edit interpolates it, both
##   calls in ONE assistant message, executed in order on the serial spine;
## - whole-value interpolation carries the captured bytes verbatim (the
##   exact-match sourcing property);
## - save_as twice in one message is refused with E_VAR_RACE (and the
##   second stage never executes);
## - an unset $ghost fails loud with E_NO_VAR;
## - the raw arguments stay in history (strict backends re-validate
##   tool_calls): the transcript still contains "$span", not the capture;
## - captures persist to the conversation header (vars) and survive there.

import std/[json, os, osproc, strutils, times]
import natsnim
import helpers

proc waitComponent(nc: NatsConnection, name: string, secs = 30): bool =
  ## Poll membership, including registrations that preceded subscription.
  for i in 0 ..< secs * 5:
    let snap = call(nc, "core", "catalog", %*{"op": "components"}, 1000)
    if snap{"components"}{name} != nil: return true
    sleep(200)

proc stopHard(p: var Process) =
  ## Terminate-then-kill, then close: leaked test children hold ports.
  if p != nil and p.running():
    p.terminate()
    sleep(800)
    if p.running(): p.kill()
    sleep(300)
  if p != nil: p.close()
  p = nil

proc listDocs(nc: NatsConnection, kind: string;
              prefix = ""): seq[JsonNode] =
  let r = call(nc, "store", "list",
    %*{"kind": kind, "idPrefix": prefix, "limit": 1000}, 10_000)
  if r{"items"} != nil:
    for item in r{"items"}: result.add(item)

proc main() =
  let repoRoot = getEnv("NIF_REPO_ROOT",
    getEnv("NIF_ROOT", getAppDir().parentDir()))
  for name in ["niffler", "session", "bash", "edit"]:
    if not fileExists(repoRoot / "var" / "bin" / name):
      fail("missing " & name & " binary — run `make build` first")
      quit(1)

  let sandbox = newCoreSandbox("vars", ["store", "bash", "llm", "edit"])
  let root = sandbox.root
  defer:
    if getEnv("NIF_TEST_KEEP") == "1":
      echo "kept test sandbox: " & root
    else:
      removeDir(root)
  var fixtureProc: Process
  defer: stopHard(fixtureProc)
  discard fixtureBin(sandbox, "llm", repoRoot / "tests" / "mock_llm.nim",
                     prebuiltName = "fixture-mock-llm")

  # The task workspace: f.txt is the pipeline's raw material.
  let work = root / "work"
  createDir(work)
  writeFile(work / "f.txt", "alpha span beta\n")
  createDir(work / "nested")
  writeFile(work / "nested" / "bulk.txt", "OldName\n")
  writeFile(work / "bulk.txt", "OldName\n")
  # A same-named installation-root file must never be selected.
  writeFile(root / "bulk.txt", "root-decoy\n")

  # Three scripted assistant messages drive one real turn:
  #  m1 — the pipeline plus literal-source safety in one ordered batch:
  #       read captures `span`; edit opts into resolution; a plain write
  #       carries `$HOME`/`$span` and must keep them verbatim;
  #  m2 — double capture is refused (E_VAR_RACE, second stage never runs),
  #       then an unset `$ghost` fails loud (E_NO_VAR).
  #  m3 — workspace globs through parallel reads and serial bulk mutations,
  #       including recursive and absolute patterns, then an alias edit.
  let script = %*[
    {"calls": [
      {"name": "read",
       "arguments": {"reads": [{"path": "f.txt"}],
                     "save_as": {"name": "span", "from": "content"}}},
      {"name": "edit",
       "arguments": {"path": "f.txt",
                     "edits": [{"old_string": "$span",
                                "new_string": "REPLACED"}],
                     "resolve_vars": true}},
      {"name": "write",
       "arguments": {"path": "g.txt",
                     "content": "echo $HOME then $span\n"}}]},
    {"calls": [
      {"name": "edit",
       "arguments": {"path": "f.txt",
                     "edits": [{"old_string": "REPLACED", "new_string": "A"}],
                     "save_as": "dup"}},
      {"name": "edit",
       "arguments": {"path": "f.txt",
                     "edits": [{"old_string": "A", "new_string": "B"}],
                     "save_as": "dup"}},
      {"name": "edit",
       "arguments": {"path": "f.txt",
                     "edits": [{"old_string": "$ghost", "new_string": "x"}],
                     "resolve_vars": true}}]},
    {"calls": [
      {"name": "read", "arguments": {"reads": [{"glob": "**/bulk.txt",
         "pattern": "OldName", "context": 0}]}},
      {"name": "read", "arguments": {"glob": "bulk.txt", "pattern": "OldName"}},
      {"name": "read", "arguments": {"reads": [{"glob": "nested/*.txt",
         "pattern": "OldName"}]}},
      {"name": "replace_across", "arguments": {"glob": "**/bulk.txt",
         "replace": [{"old": "OldName", "new": "NewName"}]}},
      {"name": "replace_across", "arguments": {"glob": "bulk.txt",
         "replace": [{"old": "NewName", "new": "FinalName"}]}},
      {"name": "replace_across", "arguments": {"glob": work / "nested/*.txt",
         "replace": [{"old": "NewName", "new": "FinalName"}]}},
      {"name": "edit", "arguments": {"path": "bulk.txt",
         "edits": [{"old": "FinalName", "new": "AliasDone"}]}}]}]

  let convId = "vars-" & $epochTime().int
  let extra = @[
    ("NIF_AUTO_APPROVE", "1"),
    ("NIF_MOCK_ROUNDS", "3"),
    ("NIF_MOCK_TOOLJSON", $script)]
  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()
  var coreProc = startComponent(sandbox.sandboxBin("niffler"), url,
    root = root, extra = extra,
    logFile = root / "var" / "test-logs" / "core-vars.log")
  defer: coreProc.stopHard()
  doAssert waitComponent(nc, "store"), "store did not register"
  doAssert waitComponent(nc, "llm"), "mock llm did not register"
  doAssert waitComponent(nc, "edit"), "edit did not register"

  let r = call(nc, "core", "session",
    %*{"sessionId": convId, "content": "run the pipeline", "cwd": work},
    240_000)
  check("turn with pipelined messages completes",
        r{"error"}.getStr("").len == 0 and
        (r{"ok"}.getBool(false) or r{"text"}.getStr("").len > 0),
        r{"error"}.getStr($r))

  check("stage 2 consumed the captured bytes verbatim (whole-value $span)",
        fileExists(work / "f.txt") and
        readFile(work / "f.txt") == "A",
        (if fileExists(work / "f.txt"): readFile(work / "f.txt")
         else: "f.txt missing"))

  check("relative bulk globs and edit aliases reach the conversation workspace",
        readFile(work / "bulk.txt") == "AliasDone\n" and
        readFile(work / "nested" / "bulk.txt") == "FinalName\n" and
        readFile(root / "bulk.txt") == "root-decoy\n")

  # Transcript: raw args preserved, loud failures visible.
  let msgs = listDocs(nc, "message", convId & ":")
  var rawArgsKept = false
  var raceRefused = false
  var missingRefused = false
  var selectReplies = 0
  for item in msgs:
    let m = item{"value"}
    if m == nil: continue
    let body = m{"content"}.getStr("")
    let calls = m{"tool_calls"}
    if calls != nil and calls.kind == JArray:
      for tc in calls:
        let a = tc{"function"}{"arguments"}.getStr("")
        if a.contains("$span"): rawArgsKept = true
    if body.contains("E_VAR_RACE"): raceRefused = true
    if body.contains("E_NO_VAR"): missingRefused = true
    if m{"name"}.getStr("") == "read" and body.contains("OldName"):
      inc selectReplies
  check("read globs resolve in reads and top-level sugar",
        selectReplies == 3, "select replies: " & $selectReplies)
  check("raw $span arguments stay in history for strict backends",
        rawArgsKept, "no tool_calls entry still contains $span")
  check("double capture in one message is refused with E_VAR_RACE",
        raceRefused, "no E_VAR_RACE in transcript")
  check("unset $ghost with resolve_vars fails loud with E_NO_VAR",
        missingRefused, "no E_NO_VAR in transcript")

  # The same variables-capable call made outside a turn must also keep `$`
  # literal: compatibility is per call, not an accident of the pipeline.
  let literal = call(nc, "edit", "write",
    %*{"path": root / "g2.txt", "content": "price $5 and $span\n"}, 10_000)
  check("plain tool call keeps shell/source $ literals untouched",
        literal{"bytes_written"}.getInt(0) > 0 and
        fileExists(root / "g2.txt") and
        readFile(root / "g2.txt") == "price $5 and $span\n",
        literal{"error"}.getStr($literal))

  # Header persistence: captures live in `vars`, never in the prompt.
  let r2 = call(nc, "store", "get",
    %*{"kind": "conversation", "id": convId}, 10_000)
  let header = r2{"value"}
  check("captures persist to the conversation header",
        header{"vars"}{"span"} != nil and header{"vars"}{"dup"} != nil,
        (if header == nil: "header missing: " & $r2 else: $header))

  report("VARS TEST")

main()
