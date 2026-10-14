## Read-scope seam: the shared policy for which paths a READER may surface.
##
## Why this lives in the SDK and not in a component: the same question ("is this
## path readable by a tool?") is asked by every reader — `read`, `grep`, and
## anything added later — and by core, which resolves paths but must not encode
## component knowledge. A copy of the rule per component is how one of them
## silently drifts and leaks. This module is pure runtime data over
## strings: no component names, no language knowledge.
##
## What this is NOT: the shell guard's mount policy. `sandbox/` hides a masked
## path from a sandboxed COMMAND by binding /dev/null over it. An in-process
## reader has no mount namespace to bend, so it can only decline to return the
## bytes. Readers enforce the same masked-path list, giving one policy a single
## spelling (`NIF_BASH_SANDBOX_MASKS`) instead of two lists that can disagree.
##
## Honest limits, stated rather than implied:
##  - This is a DENY of declared absolute paths, checked on canonical paths. It
##    cannot hide a copy, a hard link outside the list, or the same bytes reached
##    through a path that was never declared. It is a secret *mask*, not a
##    confidentiality model.
##  - It only covers readers that call it. A component that reads files without
##    asking is unaffected until it is updated.

import std/[os, osproc, strutils]

const MaxMasks = 4096

proc maskPaths*(raw = ""): seq[string] =
  ## Parse the operator-owned mask list: exact absolute paths, one per line.
  ## No filename heuristics — nothing here knows that ".env" is interesting.
  ## Blank lines and comments are ignored so a config file can be organized.
  let text = if raw.len > 0: raw else: getEnv("NIF_BASH_SANDBOX_MASKS", "")
  for line in text.splitLines():
    let p = line.strip()
    if p.len == 0 or p.startsWith("#"): continue
    if result.len >= MaxMasks: break
    # Relative entries are the shell guard's shorthand (resolved against the
    # workspace per launch). A reader has no launch to resolve against, so it
    # treats only absolute entries as masks rather than guessing a workspace.
    if p.isAbsolute(): result.add p

proc canonical*(path: string): string =
  ## Best-effort canonical spelling for comparison. `realpath` when the path
  ## exists (a mask always does), else a normalized absolute path.
  if path.len == 0: return ""
  try:
    return expandFilename(absolutePath(path))
  except CatchableError:
    discard
  try:
    return absolutePath(path)
  except CatchableError:
    return path

proc maskedPaths*(paths: openArray[string], raw = ""): seq[string] =
  ## The subset of `paths` that the mask policy hides. Both sides are canonically
  ## resolved so a differently-spelled route to a masked file (a symlinked
  ## parent, `//`, a trailing separator) still matches.
  let masks = maskPaths(raw)
  if masks.len == 0: return
  var canonMasks: seq[string]
  for m in masks: canonMasks.add canonical(m)
  for p in paths:
    let cp = canonical(p)
    if cp.len == 0: continue
    for m in canonMasks:
      if cp == m:
        result.add p
        break

proc isMasked*(path: string, raw = ""): bool =
  ## True when this single path is masked.
  maskedPaths([path], raw).len > 0

proc maskRefusal*(path: string): string =
  ## One sentence, shared by every reader, so the refusal reads the same
  ## wherever it surfaces (and the model is told *why*, not just "denied").
  "refused: " & path &
    " is an operator-masked path (NIF_BASH_SANDBOX_MASKS) — its contents are " &
    "not exposed to tools by policy; ask the operator to unmask it if needed"

proc dropMaskedLines*(output, separator = ":"): string =
  ## Filter a line-oriented command's output (path-prefixed, e.g. rg's
  ## `path:line:match`) by removing every line whose path component is masked.
  ##
  ## This is the traversal case: a search rooted at the workspace reaches masked
  ## paths that argument-level checks never see. Filtering the result is honest
  ## but weaker than exclusion — it removes what would have been RETURNED, not
  ## what was READ — so readers that can also exclude by argument should do both.
  let masks = maskPaths()
  if masks.len == 0: return output
  var canonMasks: seq[string]
  for m in masks: canonMasks.add canonical(m)
  for line in output.splitLines():
    # Start from the WHOLE line and walk leftwards, one separator at a time:
    # the path may itself contain the separator (a directory named `a:b`), so
    # the first separator is not the boundary and a left-to-right split
    # misfires.
    var path = line
    var hidden = false
    while path.len > 0:
      if canonical(path) in canonMasks:
        hidden = true
        break
      let cut = path.rfind(separator)
      if cut <= 0: break
      path = path[0 ..< cut]
    if not hidden:
      result.add line
      result.add "\n"
  if output.len > 0 and not output.endsWith("\n") and result.endsWith("\n"):
    result.setLen(result.len - 1)
