## Coding-task artifact (docs/FLEET.md §6, "Results and artifacts"): what a
## delegated task actually CHANGED. Pure module — real git against throwaway
## repos, no bus, no store, no model.
##
## The contract this pins: a receipt can name the base revision, the commit the
## task produced, the diffstat against that base, whether the tree was left
## dirty, and the verification commands that ran. It never converts any of that
## into "the change is correct" — an artifact is evidence that something
## changed, not proof that it is right.
import std/[json, os, osproc, strutils]
import helpers
import ../sdk/niffler/codingartifact

proc git(dir: string, args: string): string =
  let r = execCmdEx("git -C " & quoteShell(dir) & " " & args)
  if r.exitCode != 0:
    raise newException(IOError, "git " & args & " failed: " & r.output)
  r.output.strip()

proc initRepo(dir: string) =
  createDir(dir)
  discard git(dir, "init -q -b main")
  discard git(dir, "config user.email task@example.test")
  discard git(dir, "config user.name task")
  writeFile(dir / "note.txt", "before\n")
  discard git(dir, "add -A")
  discard git(dir, "commit -q -m 'base commit'")

proc main() =
  let tmp = tempRoot("coding-artifact")
  defer: removeDir(tmp)

  # --- not a repository at all --------------------------------------------
  block:
    let plain = tmp / "plain"
    createDir(plain)
    let seen = observeCheckout(plain)
    check("a plain directory is reported as not a repo", not seen.isRepo)
    let art = codingArtifact("", plain)
    check("an unobservable workspace is stated, never faked",
          not art{"observed"}.getBool(true) and
          art{"reason"}.getStr("").contains("not a git checkout"), $art)
    check("an unobservable artifact still carries its version",
          art{"version"}.getInt(0) == artifactVersion)
    check("its summary says so plainly",
          artifactSummary(art).contains("not observable"), artifactSummary(art))

  # --- a real repo, before any work ---------------------------------------
  let repo = tmp / "repo"
  initRepo(repo)
  let base = observeCheckout(repo)
  check("the base observation identifies the commit",
        base.isRepo and base.head.len >= 7 and base.branch == "main", $base)
  check("a clean checkout is not dirty", not base.dirty and base.untracked == 0)
  check("the base subject is the commit's own message",
        base.subject == "base commit", base.subject)

  # --- untouched work: no commit, no invention ----------------------------
  block:
    let art = codingArtifact(base.head, repo)
    check("an untouched checkout reports no commit",
          not art{"producedCommit"}.getBool(true) and
          not art{"headMoved"}.getBool(true), $art)
    check("it still names the base it started from",
          art{"base", "commit"}.getStr("") == base.head, $art)
    check("its summary reports 'no commit'",
          artifactSummary(art).contains("no commit"), artifactSummary(art))

  # --- the real case: the task committed, on top of the approved base -----
  block:
    writeFile(repo / "note.txt", "after\n")
    discard git(repo, "commit -q -am 'fix the failing test'")
    let art = codingArtifact(base.head, repo)
    check("a commit IS the artifact", art{"producedCommit"}.getBool(true), $art)
    check("HEAD moved off the base", art{"headMoved"}.getBool(true))
    check("the artifact names the produced commit",
          art{"head", "commit"}.getStr("").len >= 7 and
          art{"head", "short"}.getStr("") == observeCheckout(repo).shortHead, $art)
    check("it carries the commit subject",
          art{"head", "subject"}.getStr("") == "fix the failing test", $art)
    check("the commit is recognisably built on the approved base",
          art{"onBase"}.getBool(false), $art)
    check("the diffstat against the base is included",
          art{"diffstat"}.getStr("").contains("note.txt"), $art)
    check("a committed tree is clean", not art{"dirty"}.getBool(true), $art)
    check("the summary names the commit and its stat line",
          artifactSummary(art).contains("fix the failing test") and
          artifactSummary(art).contains("1 file changed"), artifactSummary(art))

  # --- a change left uncommitted is reported as exactly that --------------
  block:
    let headBefore = observeCheckout(repo).head
    writeFile(repo / "note.txt", "uncommitted edit\n")
    writeFile(repo / "brand-new.txt", "new file\n")
    let art = codingArtifact(headBefore, repo)
    check("an uncommitted change produces no commit",
          not art{"producedCommit"}.getBool(true), $art)
    check("the dirty tree is flagged", art{"dirty"}.getBool(false), $art)
    check("untracked files are counted, not conflated with tracked edits",
          art{"untracked"}.getInt(0) == 1, $art)
    check("the summary warns about the dirty tree",
          artifactSummary(art).contains("dirty") and
          artifactSummary(art).contains("untracked"), artifactSummary(art))
    discard git(repo, "checkout -- .")
    removeFile(repo / "brand-new.txt")

  # --- work that REPLACED the base is not presented as a continuation ----
  block:
    # A task that resets its branch and rewrites history is the case a naive
    # "HEAD moved" check reports as success. It is not the approved base.
    discard git(repo, "checkout -q -b rewritten")
    writeFile(repo / "note.txt", "rewritten\n")
    discard git(repo, "commit -q -am 'unrelated work'")
    let baseAfterRewrite = observeCheckout(repo).head
    discard git(repo, "reset -q --hard HEAD")
    discard git(repo, "checkout -q main")
    discard git(repo, "branch -q -D rewritten")
    # A base that is no longer an ancestor of HEAD must be called out.
    writeFile(repo / "note.txt", "different lineage\n")
    discard git(repo, "commit -q -am 'different lineage'")
    let art = codingArtifact(baseAfterRewrite, repo)
    check("the deleted-base case is detected, not called clean",
          art{"headMoved"}.getBool(true) and
          not art{"onBase"}.getBool(true), $art)
    check("the summary shouts about a non-base commit",
          artifactSummary(art).contains("NOT built on the approved base"),
          artifactSummary(art))

  # --- verification evidence is a record, never a verdict ----------------
  block:
    let evidence = verificationEvidence(@[
      ("nimble test", 0), ("make test-server", 1)])
    check("every verification command is recorded with its exit status",
          evidence.len == 2 and evidence[0]["command"].getStr("") == "nimble test" and
          evidence[0]["ok"].getBool(false) and
          not evidence[1]["ok"].getBool(true), $evidence)
    check("a bounded number of commands is kept",
          verificationEvidence(
            block:
              var many: seq[tuple[command: string, code: int]]
              for i in 0 ..< 40: many.add(("cmd" & $i, 0))
              many).len == artifactVerificationLimit)
    let art = codingArtifact(observeCheckout(repo).head, repo,
      @[("make test", 1)])
    check("a failing verification is surfaced in the summary",
          artifactSummary(art).contains("verification failure"), artifactSummary(art))

  # --- the requester refuses an artifact it cannot interpret -------------
  block:
    check("a well-formed artifact passes validation",
          artifactProblem(codingArtifact(base.head, repo)) == "")
    check("an unreadable artifact is refused, not rendered",
          artifactProblem(newJNull()).len > 0)
    check("a future artifact version is refused",
          artifactProblem(%*{"version": artifactVersion + 1}).contains("unsupported"))
    check("an artifact with no version is refused",
          artifactProblem(%*{"observed": true}).contains("unsupported"))

  # --- a task cannot observe its own workspace: the honest answer --------
  block:
    let art = codingArtifact("", repo, verifiable = false)
    check("unverifiable observation is stated, never invented",
          not art{"observed"}.getBool(true) and
          art{"reason"}.getStr("").contains("not observable"), $art)

  # --- the link: what a human can act on -----------------------------------
  # A diffstat pasted into a notice is noise; a URL is the thing a reviewer
  # clicks. It is emitted only when genuinely derivable from `origin`.
  block:
    let linked = tmp / "linked"
    initRepo(linked)
    proc setOrigin(url: string) =
      # `git remote remove` fails the first time (no origin yet), which is the
      # normal way to reach that state — not an error worth raising over.
      discard execCmdEx("git -C " & quoteShell(linked) & " remote remove origin")
      discard git(linked, "remote add origin " & quoteShell(url))
    setOrigin("git@github.com:gokr/niffler.git")
    check("an scp-style origin becomes a browseable web base",
          remoteWebBase(linked) == "https://github.com/gokr/niffler",
          remoteWebBase(linked))
    check("a commit link points at that commit",
          commitUrl(linked, "0123456789abcdef").endsWith("/commit/0123456789abcdef"),
          commitUrl(linked, "0123456789abcdef"))
    setOrigin("https://gitlab.example/team/proj.git")
    check("an https origin keeps its host",
          remoteWebBase(linked) == "https://gitlab.example/team/proj",
          remoteWebBase(linked))
    setOrigin("ssh://git@git.internal:2222/a/b.git")
    check("an ssh:// origin is reduced to host and path",
          remoteWebBase(linked).startsWith("https://git.internal"), remoteWebBase(linked))
    # Never invent a link: a local-only checkout has nothing to browse.
    discard git(linked, "remote remove origin")
    check("a checkout with no origin yields no web base",
          remoteWebBase(linked) == "", remoteWebBase(linked))
    check("...and therefore no commit link", commitUrl(linked, "0123456789") == "")
    setOrigin("git@github.com:gokr/niffler.git")
    let headCommit = observeCheckout(linked).head
    let withLink = codingArtifact(headCommit, linked)
    check("a commit that exists carries its link",
          withLink{"head", "url"}.getStr("").endsWith("/commit/" & headCommit),
          $withLink)
    # Links must point at a COMMIT, not at every artifact: an untouched
    # checkout has no produced commit to link to.
    let untouchedLink = codingArtifact("", linked)
    check("the artifact still renders without any link when nothing changed",
          artifactSummary(untouchedLink).contains("no commit"),
          artifactSummary(untouchedLink))
    # The prose summary carries the link, not a diff.
    let movedNow = codingArtifact(headCommit, linked,
      @[("make test", 0)])
    let rendered = artifactSummary(movedNow)
    check("the summary shows the count, never a pasted diff",
          not rendered.contains("|") and rendered.contains("commit"), rendered)

  report("CODING ARTIFACT TEST")

main()
