## Stable instance routing metadata, never a prompt contributor or an
## authentication claim. Only the system harness creates the file.
import std/[os, strutils, sysrand, nativesockets]

type InstanceIdentity* = object
  instanceId*: string
  name*: string

proc validInstanceId*(s: string): bool =
  if s.len != 32: return false
  for ch in s:
    if ch notin {'0'..'9', 'a'..'f'}: return false
  true

proc loadInstanceIdentity*(root: string): InstanceIdentity =
  ## Persist 128 random bits once, before spawning any components. Malformed
  ## existing files refuse: silently replacing them could adopt the wrong
  ## machine. Lifecycle assumes one system core per runtime root.
  let path = root / "var" / "instance-id"
  createDir(path.parentDir())
  if fileExists(path):
    result.instanceId = readFile(path).strip()
    if not validInstanceId(result.instanceId):
      raise newException(ValueError, "invalid instance identity at " & path)
  else:
    let bytes = urandom(16)
    for b in bytes: result.instanceId.add(toHex(int(b), 2).toLowerAscii())
    let staged = path & ".new-" & $getCurrentProcessId()
    try:
      writeFile(staged, result.instanceId & "\n")
      setFilePermissions(staged, {fpUserRead, fpUserWrite})
      moveFile(staged, path)
    finally:
      if fileExists(staged): removeFile(staged)
  result.name = getEnv("NIF_NAME", "").strip()
  if result.name.len == 0: result.name = getHostname()
