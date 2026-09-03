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

proc loadDotEnv*(paths: varargs[string]) =
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
