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
import std/[json, os, osproc, strutils, times]
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

  check("edit registers", waitRegisteredOn(regSub, "edit"))
  check("grep registers", waitRegisteredOn(regSub, "grep"))
  natsSubscription_Destroy(regSub)
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

  report("READ SCOPE TEST")

main()
