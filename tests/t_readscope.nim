## Read-scope contract: masked paths must not reach the model through a READER.
##
## The shell guard hides a masked path from sandboxed commands (a mount bind).
## An in-process reader has no mount namespace, so the seam is a shared policy
## module (`sdk/niffler/readscope.nim`) that `read` and `grep` consult. This
## test drives the real components over NATS rather than calling the module, so
## it fails if a future reader forgets to consult the policy.
##
## Two shapes, because they are different failures:
##   1. DIRECT  — the model names the masked file. Argument-level refusal.
##   2. TRAVERSAL — a search rooted at the workspace reaches the file without
##      naming it. Argument checks cannot see this; the result must be filtered.
import std/[json, os, osproc, strutils, tables, times]
import natsnim
import helpers

proc okAnswer(r: JsonNode, what: string): bool =
  ## An absence assertion ("does not contain X") passes trivially when the call
  ## itself failed or the tool never registered. Every reader check below first
  ## proves the tool actually answered, so a green run means the policy worked
  ## rather than that nothing ran.
  if r.hasKey("error"):
    fail(what & ": the tool did not answer — " & $r)
    return false
  if r{"text"}.getStr("").len == 0:
    fail(what & ": the tool returned no text — " & $r)
    return false
  true

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getEnv("NIF_ROOT", getAppDir().parentDir()))
  let root = tempRoot("readscope")
  defer: removeDir(root)
  let ws = root / "ws"
  createDir(ws)
  # A filename the policy must NOT need to know: the mask is an exact path, so
  # nothing here depends on ".env" being special.
  let guarded = ws / "credentials.conf"
  writeFile(guarded, "TOPSECRET-CANARY-12345\n")
  writeFile(ws / "ordinary.txt", "ordinary-visible-line\n")
  let plain = root / "plain.conf"
  writeFile(plain, "NOT-MASKED-CONTENT\n")

  let secretSource = ws / "hidden.nim"
  let visibleSource = ws / "visible.nim"
  writeFile(secretSource, "proc HiddenCanarySymbol*() = discard\n")
  writeFile(visibleSource, "proc VisibleControlSymbol*() = discard\n")
  let hiddenSkill = root / ".agents/skills/hidden/SKILL.md"
  let visibleSkill = root / ".agents/skills/visible/SKILL.md"
  createDir(hiddenSkill.parentDir)
  createDir(visibleSkill.parentDir / "references")
  writeFile(hiddenSkill, "---\nname: hidden-canary\ndescription: HiddenSkillCanary\n---\nHiddenSkillBody\n")
  writeFile(visibleSkill, "---\nname: visible-control\ndescription: visible\n---\nVisibleSkillBody\n")
  let hiddenResource = visibleSkill.parentDir / "references/private.txt"
  writeFile(hiddenResource, "HiddenResourceCanary")
  writeFile(visibleSkill.parentDir / "references/public.txt", "VisibleResourceControl")
  let readerMasks = [guarded, secretSource, hiddenSkill, hiddenResource].join("\n")

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # Subscribe to reg.publish BEFORE spawning and wait on that subscription:
  # `waitRegistered` opens its own subscription afterwards, so a component that
  # announces quickly (grep has no dependencies) can register before the test is
  # listening. Under the pooled gate that race made this test fail.
  var regSub: ptr natsSubscription
  check("reg.publish subscription", checkStatus(natsConnection_SubscribeSync(
    addr regSub, nc.conn, "reg.publish".cstring)))
  discard natsConnection_Flush(nc.conn)
  # Both readers run in ONE component set, with the same mask policy core would
  # export. Off-mode sandbox: this test is about readers, not the shell guard.
  let editProcess = startComponent(repo / "var/bin/edit", url, root = root,
    extra = @[("NIF_BASH_SANDBOX_MASKS", guarded)])
  defer:
    if editProcess.running(): editProcess.terminate()
    discard editProcess.waitForExit(2000)
    editProcess.close()
  # edit's mutation path persists undo history through the store, so a real
  # store must answer or a legitimate edit refuses (fails closed — the point of
  # the read-scope test is the policy, not a store outage).
  let store = startComponent(repo / "var/bin/store-sqlite", url, root = root)
  defer:
    if store.running(): store.terminate()
    discard store.waitForExit(2000)
    store.close()
  let grep = startComponent(repo / "var/bin/grep", url, root = root,
    extra = @[("NIF_BASH_SANDBOX_MASKS", guarded)],
    logFile = getEnv("NIF_ROOT", ".") / "var" / "readscope-grep.log")
  defer:
    if grep.running(): grep.terminate()
    discard grep.waitForExit(2000)
    grep.close()

  # A SHARED reg.publish subscription is order-dependent if each wait consumes
  # messages looking for one name: waiting for "edit" would swallow a "grep"
  # announcement that arrived first, and the next wait would never see it.
  # Collect every announced name instead, so the order components happen to
  # start in cannot decide whether this test passes.
  var announced = initTable[string, bool]()
  proc awaitComponents(names: seq[string], secs = 15): bool =
    let deadline = epochTime() + secs.float
    while epochTime() < deadline:
      var missing = false
      for name in names:
        if not announced.hasKey(name): missing = true
      if not missing: return true
      var msg: ptr natsMsg
      if natsSubscription_NextMsg(addr msg, regSub, 200) == NATS_OK:
        let data = $natsMsg_GetData(msg)
        natsMsg_Destroy(msg)
        for name in names:
          if data.contains("\"" & name & "\""): announced[name] = true
    false

  check("edit registers", awaitComponents(@["edit"], 20))
  check("grep registers", awaitComponents(@["grep"], 20))
  natsSubscription_Destroy(regSub)
  # Request/reply readiness avoids announcement ordering between independent peers.
  let mapper = startComponent(repo / "var/bin/repomap", url, root = root,
    extra = @[("NIF_BASH_SANDBOX_MASKS", readerMasks)])
  defer:
    if mapper.running(): mapper.terminate()
    discard mapper.waitForExit(2000)
    mapper.close()
  let skills = startComponent(repo / "var/bin/skills", url, root = root,
    extra = @[("NIF_BASH_SANDBOX_MASKS", readerMasks)])
  defer:
    if skills.running(): skills.terminate()
    discard skills.waitForExit(2000)
    skills.close()
  var mapped, loaded: JsonNode
  for i in 0 ..< 50:
    mapped = call(nc, "repomap", "repo_map", %*{"workspace": ws}, 2000)
    loaded = call(nc, "skills", "skill_load", %*{"name": "visible-control"}, 2000)
    if mapped{"ok"}.getBool(false) and loaded{"ok"}.getBool(false): break
    sleep(100)
  check("repomap answers with visible source", mapped{"ok"}.getBool(false) and
    ($mapped).contains("VisibleControlSymbol"), $mapped)
  check("repomap excludes masked source and tags", not ($mapped).contains("hidden.nim") and
    not ($mapped).contains("HiddenCanarySymbol"), $mapped)
  check("skills load visible instructions", loaded{"ok"}.getBool(false) and
    ($loaded).contains("VisibleSkillBody"), $loaded)
  let skillList = call(nc, "skills", "skill_list", %*{})
  check("skills discovery excludes masked instructions", skillList{"ok"}.getBool(false) and
    not ($skillList).contains("hidden-canary"), $skillList)
  let resources = call(nc, "skills", "skill_resources", %*{"name": "visible-control"})
  check("resources omit masked entries", resources{"ok"}.getBool(false) and
    ($resources).contains("public.txt") and not ($resources).contains("private.txt"), $resources)
  let privateRead = call(nc, "skills", "skill_resource", %*{"name": "visible-control", "path": "references/private.txt"})
  check("masked resource cannot load", not privateRead{"ok"}.getBool(true) and
    not ($privateRead).contains("HiddenResourceCanary"), $privateRead)
  let publicRead = call(nc, "skills", "skill_resource", %*{"name": "visible-control", "path": "references/public.txt"})
  check("unmasked resource loads", publicRead{"ok"}.getBool(false) and
    ($publicRead).contains("VisibleResourceControl"), $publicRead)

  # 1. DIRECT read of the masked path is refused, with the policy named.
  let direct = call(nc, "edit", "read", %*{"path": guarded, "__workspace": {"root": ws}})
  check("direct read of a masked path is refused",
        not ($direct).contains("TOPSECRET-CANARY"), $direct)
  check("the refusal names the mask policy",
        ($direct).contains("NIF_BASH_SANDBOX_MASKS"), $direct)

  # The same path reached through a symlink alias must also be refused: the
  # policy compares canonical paths, not spellings.
  createSymlink(guarded, ws / "alias.conf")
  let viaAlias = call(nc, "edit", "read", %*{"path": ws / "alias.conf",
    "__workspace": {"root": ws}})
  check("a symlink alias to a masked path is refused",
        not ($viaAlias).contains("TOPSECRET-CANARY"), $viaAlias)

  # An unmasked sibling must still read normally — a policy that denies
  # everything would pass the checks above while breaking the tool.
  let allowed = call(nc, "edit", "read", %*{"path": plain, "__workspace": {"root": ws}})
  check("an unmasked file still reads", ($allowed).contains("NOT-MASKED-CONTENT"), $allowed)

  # 2. TRAVERSAL: search the whole workspace for the secret's text. The masked
  #    file is reached without being named, so only result filtering can hide
  #    it.
  let swept = call(nc, "grep", "grep", %*{"pattern": "TOPSECRET-CANARY",
    "path": ws, "__workspace": {"root": ws}})
  discard okAnswer(swept, "a workspace-wide search answered")
  check("a workspace-wide search does not surface masked content",
        not ($swept).contains("TOPSECRET-CANARY"), $swept)
  let dirSwept = call(nc, "grep", "grep", %*{"pattern": ".",
    "path": ws, "__workspace": {"root": ws}})
  discard okAnswer(dirSwept, "a match-all sweep answered")
  check("a broad match-all sweep does not surface the masked path",
        not ($dirSwept).contains("credentials.conf"), $dirSwept)
  check("the sweep still shows unmasked files",
        ($dirSwept).contains("ordinary.txt"), $dirSwept)

  # `files` lists names, which is disclosure too (a masked file's existence and
  # path are part of what masking hides).
  let listed = call(nc, "grep", "files", %*{"path": ws, "__workspace": {"root": ws}})
  discard okAnswer(listed, "the file listing answered")
  check("the file listing does not name the masked path",
        not ($listed).contains("credentials.conf"), $listed)

  # 3. Masked paths are outside MUTATION authority too: an edit would otherwise
  #    echo the old content back in its diff.
  let mutated = call(nc, "edit", "edit", %*{"path": guarded,
    "edits": [{"old_string": "TOPSECRET-CANARY-12345", "new_string": "changed"}],
    "__workspace": {"root": ws}})
  check("editing a masked path is refused",
        not ($mutated).contains("TOPSECRET-CANARY"), $mutated)
  check("the masked file is unchanged on disk",
        readFile(guarded).contains("TOPSECRET-CANARY-12345"), readFile(guarded))
  # An unmasked file must remain writable through the same path.
  let wrote = call(nc, "edit", "edit", %*{"path": plain,
    "edits": [{"old_string": "NOT-MASKED", "new_string": "EDITED"}],
    "__workspace": {"root": ws}})
  check("an unmasked file is still editable",
        readFile(plain).contains("EDITED"), $wrote)

  # Autonomous readers fail closed, even for relative mask entries that the
  # direct-path seam cannot resolve. Exercise the real registered handlers.
  for name in ["lsp", "builder", "observe"]:
    let autonomous = startComponent(repo / "var/bin" / name, url, root = root,
      extra = @[("NIF_BASH_SANDBOX_MASKS", "relative-secret")])
    try:
      var answer: JsonNode
      for i in 0 ..< 50:
        answer = call(nc, name, "selftest", %*{}, 1000)
        if name == "lsp": answer = call(nc, name, "lsp", %*{"operation": "documentSymbol", "path": visibleSource}, 1000)
        if name == "builder": answer = call(nc, name, "build", %*{"lang": "nim", "name": "mask-denial", "source": "discard"}, 1000)
        if ($answer).contains("E_MASK_UNCONFINED"): break
        sleep(100)
      check(name & " refuses unconfined actions under masks",
        ($answer).contains("E_MASK_UNCONFINED"), $answer)
      # Read-only inspections stay available: the refusal targets actions that
      # would start an unconfined reader, not the whole component.
      if name == "lsp":
        let registry = call(nc, name, "lsp_servers", %*{}, 5000)
        check("LSP registry remains available under masks",
          registry{"ok"}.getBool(false) and not ($registry).contains("E_MASK_UNCONFINED"), $registry)
    finally:
      if autonomous.running(): autonomous.terminate()
      discard autonomous.waitForExit(2000)
      autonomous.close()

  report("READ SCOPE TEST")

main()
