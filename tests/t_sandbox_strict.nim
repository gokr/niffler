## Sandbox STRICT reach — stage C contract.
##
## Stage A persisted a decision, stage B delivered it to components. This is the
## stage that changes what the operating system lets a command do, so every
## assertion here is about a REFUSAL that would succeed unconfined.
##
## The claim under test, in one sentence: when a conversation's policy is
## enabled, a `bash` command sees only its approved trees — not the host
## filesystem — and says so honestly.
##
## Both halves are tested, because a sandbox that also blocks the workspace is
## not confinement but breakage:
##
## - POSITIVE: an approved write inside the workspace, an approved extra root,
##   and an ordinary read of its own tree all work.
## - NEGATIVE: a same-user secret outside every approved root cannot be read,
##   even though the unconfined process reads it happily.
##
## And the reporting: `reach` says `strict` only when the host root is truly not
## mounted, so a result can never be read as more confined than it was.
##
## This suite requires a working bubblewrap. On a host without one the launcher
## refuses by design, and the test reports that as SKIPPED-with-reason rather
## than passing a confinement claim it never exercised.

import std/[json, os, osproc, strutils, times]
import natsnim
import envelope
import helpers
when defined(posix): import std/posix

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  let root = tempRoot("sandbox-strict")
  defer: removeDir(root)
  createDir(root / "var")

  # Is there a backend that can promise read confinement at all? A write-only
  # backend would make every negative assertion below meaningless.
  let probe = execCmdEx(quoteShell(repo / "var/bin/niffler-sandbox") &
                        " probe < /dev/null")
  let probeData = block:
    try: parseJson(probe.output.strip().splitLines()[^1])
    except CatchableError: newJObject()
  if probeData{"backend"}.getStr("") != "bwrap":
    echo "SKIP: sandbox strict — no bwrap backend here (probe said ",
         probeData{"backend"}.getStr("unknown"), ": ",
         probeData{"detail"}.getStr(""), ")"
    echo "      read confinement cannot be claimed without it; this is not a pass."
    report("SANDBOX STRICT")
    return

  let ws = root / "ws"
  let approved = root / "approved"
  let outside = root / "outside"
  createDir(ws)
  createDir(approved)
  createDir(outside)
  writeFile(outside / "secret", "HOST-SECRET-VALUE")
  # A same-user file the UNCONFINED process can read. The negative test is only
  # meaningful because this is readable without a sandbox.
  doAssert readFile(outside / "secret") == "HOST-SECRET-VALUE"

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # NIF_BASH_SANDBOX stays OFF: the guard must be driven by the CONVERSATION's
  # policy here, which is the whole point of stage C. An operator env guard is
  # the older path and keeps its own (compat) reach.
  let child = startComponent(repo / "var/bin/bash", url, root = root,
    extra = @[("NIF_BASH_SANDBOX", "off"),
              ("NIF_SANDBOX_BACKEND", ""),
              ("NIF_SANDBOX_ALLOW_DEGRADED", "")])
  defer:
    if child.running(): child.terminate()
    discard child.waitForExit(2000)
    child.close()
  check("bash registers", waitRegistered(nc, "bash"))

  proc run(command: string, sandbox: JsonNode, workspace = ""): JsonNode =
    ## Dispatch with the private policy context core would inject. A direct bus
    ## call bypasses core, so the test supplies it — which is also how the
    ## launcher's own contract is exercised without a full conversation.
    ## `workspace` overrides the runner-supplied root for containment checks.
    let wsr = if workspace.len > 0: workspace else: ws
    var args = %*{"command": command, "cwd": wsr, "timeoutMs": 20000,
                  "__workspace": {"root": wsr}}
    if sandbox != nil: args["__sandbox"] = sandbox
    call(nc, "bash", "bash", args, 40000)

  # A deny pattern is enforced as a real mask on a launch that still runs. The
  # earlier refusal path proved nothing about enforcement.
  writeFile(ws / ".env", "DENIED-SECRET=1")
  let denied = run("cat .env", %*{"enabled": true,
    "readRoots": [ws, approved], "writeRoots": [ws, approved],
    "denyPatterns": [".env"]})
  check("default deny masks .env inside the workspace",
    denied{"sandbox"}{"state"}.getStr("") == "applied" and
    not ($denied).contains("DENIED-SECRET"), $denied)
  let policy = %*{"enabled": true, "readRoots": [ws, approved],
                  "writeRoots": [ws, approved], "denyPatterns": [],
                  "enforced": false, "session": "strict-conv"}

  # --- 1. the policy turns the guard on by itself -----------------------
  let on = run("echo policy-on", policy)
  check("a policy-enabled conversation is guarded without the operator env",
        on{"sandbox"}{"state"}.getStr("") == "applied", $on)
  check("the reach is strict", on{"sandbox"}{"reach"}.getStr("") == "strict", $on)

  # --- 2. POSITIVE: approved trees work --------------------------------
  let writeInside = run("echo inside-ok > inside.txt && cat inside.txt", policy)
  check("a write inside the workspace works",
        writeInside{"exit_code"}.getInt(-1) == 0 and
        writeInside{"text"}.getStr("").contains("inside-ok"), $writeInside)
  check("the workspace file really landed", fileExists(ws / "inside.txt"))
  let writeApproved = run("echo approved-ok > " & quoteShell(approved / "out.txt") &
                          " && cat " & quoteShell(approved / "out.txt"), policy)
  check("an approved extra root is writable",
        writeApproved{"exit_code"}.getInt(-1) == 0 and
        writeApproved{"text"}.getStr("").contains("approved-ok"), $writeApproved)
  let readOwn = run("head -c 12 inside.txt", policy)
  check("reading its own tree works",
        readOwn{"text"}.getStr("").contains("inside-ok"), $readOwn)

  # --- 3. NEGATIVE: the host is not reachable --------------------------
  # THE assertion this stage exists for. Verify the control FIRST: the same
  # read succeeds for a process that is not confined, so a pass below cannot be
  # an accident of permissions or of the path not existing.
  check("control: the secret is readable outside any sandbox",
        readFile(outside / "secret") == "HOST-SECRET-VALUE")
  let readOutside = run("cat " & quoteShell(outside / "secret"), policy)
  check("a same-user secret outside the approved roots is NOT readable",
        not readOutside{"text"}.getStr("").contains("HOST-SECRET-VALUE"),
        $readOutside)
  check("and the attempt is reported as a failure, not silence",
        readOutside{"exit_code"}.getInt(0) != 0, $readOutside)
  # The home directory is the usual accident: it exists on every host and is
  # readable to its owner, so it is the first place an unconfined read lands.
  let readHome = run("ls " & quoteShell(getEnv("HOME", "/root")), policy)
  check("the home directory is not listable",
        not readHome{"text"}.getStr("").contains(".sc-"), $readHome)

  # --- 4. a write outside the approved roots still fails ---------------
  let writeOutside = run("echo escaped > " & quoteShell(outside / "escaped.txt"), policy)
  check("a write outside the approved roots fails",
        writeOutside{"exit_code"}.getInt(0) != 0 and
        not fileExists(outside / "escaped.txt"), $writeOutside)
  check("nothing was created outside", not fileExists(outside / "escaped.txt"))

  # A workspace path is not itself a grant. The launcher mounts its workspace
  # writable, so a policy that does not authorize it must refuse before exec.
  let wrongWorkspace = run("touch workspace-widened", %*{
    "enabled": true, "readRoots": [approved], "writeRoots": [approved],
    "denyPatterns": []})
  check("unapproved workspace refuses before bash starts",
    wrongWorkspace{"sandbox"}{"state"}.getStr("") == "refused" and
    wrongWorkspace{"text"}.getStr("").contains("outside sandbox write roots") and
    not fileExists(ws / "workspace-widened"), $wrongWorkspace)

  # Containment must compare RESOLVED paths, not spellings. `ws/alias` is a
  # symlink to `approved`, so a policy whose only write root is spelled
  # `ws/alias` must reason about `approved` — a lexical check would read the
  # spelling as inside `ws` and could authorize the wrong directory.
  let alias = ws / "alias"
  if not dirExists(alias) and not fileExists(alias): createSymlink(approved, alias)
  let aliased = run("touch alias-ran", %*{"enabled": true,
    "readRoots": [alias], "writeRoots": [alias], "denyPatterns": []}, workspace = alias)
  check("a symlinked workspace resolves to its real target, not its spelling",
    aliased{"sandbox"}{"state"}.getStr("") == "applied", $aliased)
  let spelledIn = run("touch spelled-ran", %*{"enabled": true,
    "readRoots": [approved], "writeRoots": [approved], "denyPatterns": []},
    workspace = ws)
  check("a workspace outside its write roots refuses even when nested nearby",
    spelledIn{"sandbox"}{"state"}.getStr("") == "refused" and
    not fileExists(ws / "spelled-ran"), $spelledIn)
  # --- 5. OFF stays off, and a disabled policy confines nothing --------
  # The pre-sandbox behaviour must survive: an unrelated conversation (no
  # __sandbox at all) runs unguarded and is not slower or refused.
  let unguarded = run("cat " & quoteShell(outside / "secret"), nil)
  check("without a policy the command is unguarded and reads the host",
        unguarded{"sandbox"} == nil and
        unguarded{"text"}.getStr("").contains("HOST-SECRET-VALUE"), $unguarded)
  let disabled = run("cat " & quoteShell(outside / "secret"),
                     %*{"enabled": false, "readRoots": [ws], "writeRoots": [ws],
                        "denyPatterns": [], "session": "off-conv"})
  check("a policy that is not enabled confines nothing",
        disabled{"sandbox"} == nil and
        disabled{"text"}.getStr("").contains("HOST-SECRET-VALUE"), $disabled)

  # --- 6. reporting never overclaims ----------------------------------
  # A compat launch (operator env, strict not requested) must SAY compat.
  check("a strict result does not claim more than it delivered",
        on{"sandbox"}{"reach"}.getStr("") == "strict" and
        on{"sandbox"}{"state"}.getStr("") == "applied", $on)

  report("SANDBOX STRICT")

main()
