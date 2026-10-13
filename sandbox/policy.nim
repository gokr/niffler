## The sandbox launcher's launch policy — one immutable request per command.
##
## Deliberately tiny (SANDBOX-PLAN §2): a canonical workspace, a canonical cwd
## inside it, optional extra writable roots, optional masked paths, an explicit
## environment and an exact argv. There is no policy lattice, no glob language
## and no per-privilege ordering — those were rejected before implementation,
## not after.
##
## This module is pure path/argv logic so it can be tested without spawning
## anything (tests/t_sandbox.nim exercises it directly).

import std/[os, strutils]

type
  Backend* = enum
    ## What actually confined a launch. `bkNone` is a refusal, never a fallback.
    bkNone = "none"
    bkWrap = "bwrap"       ## full promise: reads and writes confined
    bkLandlock = "landlock" ## writes confined, reads unconfined

  LaunchRequest* = object
    ## One resolved launch. Every path is canonical and absolute.
    workspace*: string     ## the conversation workspace (writable)
    cwd*: string           ## working directory inside the workspace
    extraRoots*: seq[string] ## additional writable directories (operator config)
    masks*: seq[string]    ## paths made unreadable/unwritable (secrets)
    argv*: seq[string]     ## exact command, never a shell string
    envKeep*: seq[string]  ## environment allowlist (empty = launcher default)

  SandboxError* = object of CatchableError

proc canonicalExisting*(path: string): string =
  ## Absolute, symlink-resolved path. The backend decides on the real path:
  ## a workspace reached through a symlinked `var` and one reached directly are
  ## the same directory, and comparing spellings made every launch miss
  ## (see procutil.realPathOf for the sibling bug that motivated this).
  result = expandFilename(path)

proc insideRoot(ws, path: string): bool =
  ## True when `path` is `ws` itself or below it. Prefix comparison is done on
  ## whole path components so `/ws-other` is not treated as inside `/ws`.
  if ws.len == 0 or path.len == 0: return false
  path == ws or path.startsWith(ws & "/")

proc validate*(req: LaunchRequest): string =
  ## Returns "" when the request is launchable, else a human-readable reason.
  ## Validation is fail-closed: anything unclear refuses the command rather
  ## than running it with a weaker policy than asked for.
  if req.workspace.len == 0:
    return "no workspace: a guarded launch needs an authoritative workspace root"
  if not dirExists(req.workspace):
    return "workspace does not exist: " & req.workspace
  if req.cwd.len > 0:
    if not dirExists(req.cwd):
      return "cwd does not exist: " & req.cwd
    if not insideRoot(req.workspace, req.cwd):
      var ok = false
      for r in req.extraRoots:
        if insideRoot(r, req.cwd): ok = true
      if not ok:
        return "cwd is outside the workspace and its granted roots: " & req.cwd
  for r in req.extraRoots:
    if r.len == 0 or not dirExists(r):
      return "granted root does not exist: " & (if r.len == 0: "(empty)" else: r)
  if req.argv.len == 0:
    return "no command to run"
  for m in req.masks:
    if m.len == 0: return "empty mask path"
  ""

proc effectiveDir*(req: LaunchRequest): string =
  ## The directory the command runs in — cwd when given, else the workspace.
  if req.cwd.len > 0: req.cwd else: req.workspace
