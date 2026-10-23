## Tiny .env loader — KEY=VALUE lines, # comments, optional "quotes".
## Existing environment variables always win (standard dotenv behavior).
##
## Hardening (CodeWhale borrow, docs/research/CODEWHALE.md): the .env file
## holds live API keys, so it is loaded defensively —
## - size cap (1 MiB): a runaway or hostile file cannot exhaust memory;
## - symlinks and multiply-linked files are rejected: .env must be a plain
##   regular file, so a repo cannot redirect the read to another target;
## - no variable expansion: `KEY=$OTHER` stays literal, so a repo cannot
##   substitute an ambient secret into a credential value.

import std/[os, strutils]
import subjects

const maxEnvBytes = 1_048_576
  ## Same cap CodeWhale applies; .env carries credentials, not bulk data.

proc dotenvFileId(path: string): string =
  ## Device+inode identity so hardlinks (same file under two names) are
  ## rejected together with symlinks.
  try:
    let fi = getFileInfo(path, followSymlink = false)
    result = $fi.id.device & ":" & $fi.id.file
    if fi.linkCount > 1:
      result = "" # multiply-linked: not a plain regular file
  except CatchableError:
    result = ""

proc trustedRoot(): string =
  ## The root a `.env` may come from, or "" when there is none.
  ##
  ## subjects.harnessRoot() is right for BUS discovery (a binary in
  ## <root>/var/bin resolves that clone), but as a TRUST anchor it is unsound
  ## on its own: for a binary outside that layout, climbing two directories
  ## lands on "/" or "/tmp", which would make every path "inside the root"
  ## (verified — a hostile .env then loaded). So an explicit NIF_ROOT is
  ## trusted, and a derived root counts only when it actually looks like a
  ## clone (niffler.nimble or a var/bin directory).
  let explicit = getEnv("NIF_ROOT", "")
  if explicit.len > 0: return absolutePath(explicit)
  let derived = harnessRoot()
  if fileExists(derived / "niffler.nimble") or dirExists(derived / "var" / "bin"):
    return absolutePath(derived)
  ""

proc withinHarnessRoot(path: string): bool =
  ## True when `path` IS the harness root's own `.env` — `<root>/.env` and
  ## nothing else. Containment alone would not be enough: a conversation
  ## workspace and a plugin checkout both live INSIDE the root (a workspace cwd
  ## is documented as "inside NIF_ROOT"), so a committed `.env` in one of those
  ## checkouts is precisely the file that must not be honoured. Comparing
  ## absolute paths (not strings) keeps a relative ".env" working when the
  ## caller's cwd happens to be the root. No trusted root means no .env is
  ## loaded at all, which is the safe answer: the environment is then the only
  ## source.
  let root = trustedRoot()
  if root.len == 0: return false
  absolutePath(path) == root / ".env"

proc loadDotEnv*(paths: varargs[string]) =
  ## Load KEY=VALUE from each path, first wins (existing env always wins too).
  ##
  ## Only the harness root's own `.env` belongs here. A `.env` sitting in an
  ## arbitrary working directory must never be honoured: the harness is
  ## routinely launched from inside repositories it is working on, and a
  ## committed `.env` there would otherwise hand that repository
  ## `NIF_AUTO_APPROVE=1` (approval bypass) or a `NIF_NATS_URL` pointing at a
  ## bus it controls. Verified before this guard existed.
  for path in paths:
    if not fileExists(path): continue
    # Only plain regular files: no symlink/hardlink/device redirection.
    var fi: FileInfo
    try:
      fi = getFileInfo(path, followSymlink = false)
    except CatchableError:
      continue
    if fi.kind != pcFile or fi.linkCount > 1:
      stderr.writeLine("dotenv: refusing non-plain .env file: " & path &
                       " (symlink or multiply-linked)")
      continue
    # Size cap: read bounded, refuse oversized files outright.
    if fi.size > maxEnvBytes:
      stderr.writeLine("dotenv: refusing oversized .env file (>1MiB): " & path)
      continue
    if not withinHarnessRoot(path):
      stderr.writeLine("dotenv: IGNORING .env — only <root>/.env is trusted: " &
                       path & " (a working directory is not a trust boundary)")
      continue
    for line in lines(path):
      let trimmed = line.strip()
      if trimmed.len == 0 or trimmed.startsWith("#"): continue
      let eq = trimmed.find('=')
      if eq <= 0: continue
      let key = trimmed[0 ..< eq].strip()
      var value = trimmed[eq + 1 .. ^1].strip()
      if value.len >= 2 and value[0] == '"' and value[^1] == '"':
        value = value[1 .. ^2]
      # No variable expansion: values stay literal bytes.
      if key.len > 0 and not existsEnv(key):
        putEnv(key, value)
