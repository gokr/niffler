## Coding-task artifact — what a delegated task actually CHANGED.
##
## A worker's prose is a claim, not a result. "I fixed the failing test" cannot
## be checked by the requester if there is no commit to look at, so the receipt
## of an unattended coding task carries the change itself: the base revision it
## started from, whether HEAD moved, the commit it produced, the diffstat
## against the base, whether the tree was left dirty, and the verification
## commands that ran (with their exit status).
##
## This module is the pure half (no store, no bus, no core import): given a
## directory it observes git, and given two observations it states what happened
## WITHOUT judging whether the code is good. "A commit exists" is evidence that
## something changed; it is never evidence that the change is correct, and the
## receipt says so.
##
## Declared in the x-harness.writes sense as a reader of the workspace: calling
## it must never look like a write to the dispatch gate.

import std/[json, os, osproc, strutils]
import jsonx

const
  artifactVersion* = 1
    ## Bumped when the artifact's shape or meaning changes. The requester
    ## refuses an unexpected version rather than misreading a field.
  artifactDiffStatLimit* = 4096
  artifactVerificationLimit* = 16

type
  CodingArtifact* = object
    ## One observation of a checkout at a moment in time.
    head*: string            ## full commit id, "" when not a git checkout
    shortHead*: string
    subject*: string         ## first line of the head commit's message
    branch*: string          ## symbolic branch, "" when detached
    dirty*: bool             ## tracked changes present (staged or not)
    untracked*: int
    isRepo*: bool

proc quoteShellCommand(argv: seq[string]): string =
  var parts: seq[string]
  for arg in argv: parts.add(quoteShell(arg))
  parts.join(" ")

proc gitOutput(dir: string, args: seq[string]): tuple[output: string, code: int] =
  ## Small, bounded, timeout-guarded git invocation. Never raises: an
  ## unreadable checkout is reported as "not observable", not as a crash in the
  ## middle of settling a receipt.
  try:
    let cmd = @["git", "-C", dir] & args
    let (output, code) = execCmdEx(quoteShellCommand(cmd), options = {})
    (output, code)
  except CatchableError:
    ("", 1)

proc observeCheckout*(dir: string): CodingArtifact =
  ## Snapshot a checkout. Every field degrades honestly: outside a repository
  ## `isRepo` is false and the rest stays empty, so a caller cannot mistake
  ## "could not look" for "nothing changed".
  result.shortHead = ""
  if dir.len == 0 or not dirExists(dir):
    return
  let (head, code) = gitOutput(dir, @["rev-parse", "HEAD"])
  if code != 0 or head.strip().len == 0:
    return
  result.isRepo = true
  result.head = head.strip()
  let (short, shortCode) = gitOutput(dir, @["rev-parse", "--short", "HEAD"])
  result.shortHead = if shortCode == 0: short.strip() else: result.head[0 ..< min(7, result.head.len)]
  let (subject, subjCode) = gitOutput(dir, @["log", "-1", "--pretty=%s"])
  result.subject = if subjCode == 0: subject.strip() else: ""
  let (branch, branchCode) = gitOutput(dir, @["rev-parse", "--abbrev-ref", "HEAD"])
  let name = if branchCode == 0: branch.strip() else: ""
  result.branch = if name == "HEAD": "" else: name
  # Porcelain is the only wording-stable way to see tracked changes; untracked
  # files are counted separately because a task that leaves new files behind has
  # not finished its job either, but "dirty" must not be true merely for them.
  let (status, statusCode) = gitOutput(dir, @["status", "--porcelain=v1"])
  if statusCode == 0:
    for line in status.splitLines():
      if line.len < 3: continue
      if line.startsWith("??"):
        inc result.untracked
      else:
        result.dirty = true

proc isAncestor*(dir, ancestor, descendant: string): bool =
  ## Whether `ancestor` is reachable from `descendant` — i.e. the work was
  ## committed ON TOP of the base rather than rewritten away. A task that
  ## rebased, force-pushed or reset its branch is reported as not-on-base
  ## instead of being presented as a clean continuation.
  if ancestor.len == 0 or descendant.len == 0: return false
  let (_, code) = gitOutput(dir, @["merge-base", "--is-ancestor", ancestor, descendant])
  code == 0

proc diffStatAgainst*(dir, base: string, limit = artifactDiffStatLimit): string =
  ## `git diff --stat base..HEAD`, bounded. Empty when it cannot be computed.
  if base.len == 0: return ""
  let (outp, code) = gitOutput(dir, @["diff", "--stat", base & "..HEAD"])
  if code != 0: return ""
  var text = outp.strip()
  if text.len > limit: text = text[0 ..< limit] & "\n[diffstat truncated]"
  text

proc verificationEvidence*(commands: seq[tuple[command: string, code: int]]): JsonNode =
  ## The verification that actually ran, as the worker observed it. Deliberately
  ## a record, not a verdict: the receipt never says "tests pass", only which
  ## command ran and what it exited with, so a requester can see the difference
  ## between "verified" and "claimed".
  result = newJArray()
  var count = 0
  for entry in commands:
    if count >= artifactVerificationLimit: break
    result.add(%*{"command": entry.command, "exitCode": entry.code,
                  "ok": entry.code == 0})
    inc count

proc codingArtifact*(base, dir: string,
                     verification: seq[tuple[command: string, code: int]] = @[],
                     verifiable = true): JsonNode =
  ## The artifact half of a coding task's receipt.
  ##
  ## `base` is the checkout's observation at admission (the revision the work
  ## started from); `dir` is the same checkout at settlement. When `verifiable`
  ## is false (no policy/permission to observe the workspace) the artifact says
  ## so instead of inventing an empty success.
  if not verifiable:
    return %*{"version": artifactVersion, "observed": false,
              "reason": "workspace was not observable at settlement"}
  let now = observeCheckout(dir)
  result = %*{"version": artifactVersion, "observed": now.isRepo,
              "base": %*{"commit": base, "short": (if base.len >= 7: base[0 ..< 7] else: base)},
              "head": %*{"commit": now.head, "short": now.shortHead,
                         "subject": now.subject, "branch": now.branch},
              "dirty": now.dirty, "untracked": now.untracked,
              "verification": verificationEvidence(verification)}
  if not now.isRepo:
    result["observed"] = %false
    result["reason"] = %"settlement directory is not a git checkout"
    return
  let moved = base.len > 0 and now.head != base
  result["headMoved"] = %moved
  if moved:
    # A commit is the artifact. Whether it is reachable from the base is the
    # difference between "built on the work you approved" and "replaced it".
    result["onBase"] = %isAncestor(dir, base, now.head)
    let stat = diffStatAgainst(dir, base)
    if stat.len > 0: result["diffstat"] = %stat
  # A task that produced no commit left its change uncommitted; that is a real
  # outcome to report, not a failure to hide.
  result["producedCommit"] = %moved

proc artifactProblem*(artifact: JsonNode): string =
  ## Validation for the requester side: an artifact it cannot interpret is
  ## refused rather than rendered as if it were evidence.
  if not artifact.isObj: return "artifact must be an object"
  let version = artifact{"version"}.getInt(0)
  if version != artifactVersion:
    return "unsupported artifact version " & $version & " (this harness reads " &
           $artifactVersion & ")"
  ""

proc failedVerifications*(artifact: JsonNode): int =
  ## How many observed verification commands exited non-zero. Surfaced in every
  ## summary because a failing command is the single most important thing a
  ## requester can be told, and it must never be hidden behind "no commit".
  if not artifact.isObj: return 0
  for entry in artifact{"verification"}.listOf:
    if not entry{"ok"}.getBool(true): inc result

proc artifactSummary*(artifact: JsonNode): string =
  ## One bounded line a requester can show without fetching anything. Names the
  ## commit when there is one, and never implies verification.
  if not artifact.isObj or not artifact{"observed"}.getBool(false):
    return "artifact: workspace not observable"
  if not artifact{"producedCommit"}.getBool(false):
    var tail = "no commit"
    if artifact{"dirty"}.getBool(false): tail.add " (tree dirty)"
    let untracked = artifact{"untracked"}.getInt(0)
    if untracked > 0: tail.add " (" & $untracked & " untracked)"
    # Verification matters even when nothing was committed: a task that ran the
    # suite and crashed it has told the requester something decisive.
    let failedNoCommit = failedVerifications(artifact)
    if failedNoCommit > 0:
      tail.add " [" & $failedNoCommit & " verification failure(s)]"
    return "artifact: " & tail
  result = "artifact: commit " & artifact{"head", "short"}.getStr("")
  let subject = artifact{"head", "subject"}.getStr("")
  if subject.len > 0: result.add " \"" & subject & "\""
  if not artifact{"onBase"}.getBool(false):
    result.add " [NOT built on the approved base]"
  else:
    let stat = artifact{"diffstat"}.getStr("")
    if stat.len > 0:
      let last = stat.splitLines()[^1]
      if last.len > 0: result.add " (" & last.strip() & ")"
  if artifact{"dirty"}.getBool(false): result.add " (tree dirty)"
  let failed = failedVerifications(artifact)
  if failed > 0: result.add " [" & $failed & " verification failure(s)]"
