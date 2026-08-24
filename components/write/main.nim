## write component — atomic whole-file write: create, overwrite, truncate.
##
## The counterpart to hashline-edit (anchored read/replace): write owns
## whole files — new components, configs, scripts, generated artifacts —
## while hashline-edit owns surgical edits of files the model has read.
## Every write lands via temp file + rename in the target directory, so a
## crash never leaves a half-written file, and existing permissions
## survive. Approval-gated like hashline-edit's replace.

import std/[json, os, posix, strutils]
import niffler/sdk

let comp = newComponent("write", "0.1.0")

proc posixStat(pathname: cstring, buf: var Stat): cint {.importc: "stat",
  header: "<sys/stat.h>".}
proc posixFchmod(fd: cint, mode: Mode): cint {.importc: "fchmod",
  header: "<sys/stat.h>".}
proc posixRename(oldpath, newpath: cstring): cint {.importc: "rename",
  header: "<stdio.h>".}

proc maxBytes(): int =
  ## Content cap. Default sits just under NATS's 1MB payload limit so an
  ## oversized write gets a clear error from us instead of a bus-level
  ## rejection. NIF_WRITE_MAX_BYTES overrides (tests use a small value).
  result = parseInt(getEnv("NIF_WRITE_MAX_BYTES", "900000"))
  if result <= 0: result = 900000

proc writeAtomic(path: string, content: string):
                 tuple[target: string, bytes: int, overwrote: bool] =
  ## Temp file + rename in the target dir (hashline-edit's pattern).
  ## Follows a symlink target, creates parent dirs, preserves permissions.
  result.target = path
  try:
    if result.target.len > 0 and
        (fileExists(result.target) or symlinkExists(result.target)):
      result.target = expandSymlink(result.target)
  except CatchableError:
    discard
  if result.target.len == 0:
    raise newException(ValueError, "empty path")
  if dirExists(result.target):
    raise newException(ValueError,
      result.target & " is a directory — write needs a file path")
  let dir = result.target.parentDir()
  if dir.len > 0:
    createDir(dir)
  var st: Stat
  result.overwrote = posixStat(result.target.cstring, st) == 0
  let tmp = dir / (".tmp-" & newId())
  var f = open(tmp, fmWrite)
  try:
    f.write(content)
    if result.overwrote:
      discard posixFchmod(cint(f.getFileHandle()), st.st_mode and Mode(0o7777))
  finally:
    f.close()
  if posixRename(tmp.cstring, result.target.cstring) != 0:
    let err = $osLastError()
    if fileExists(tmp): removeFile(tmp)
    raise newException(IOError, "rename onto " & result.target & " failed: " & err)
  result.bytes = content.len

comp.tool:
  proc write(path: string, content: string): JsonNode =
    ## Create or overwrite a whole file atomically — temp file + rename,
    ## so a crash never leaves a partial file; existing permissions are
    ## preserved and parent directories are created automatically. Use
    ## this for NEW files (new components, configs, scripts, generated
    ## artifacts) and wholesale rewrites of small files. For surgical
    ## edits of files you have read with hashline-edit, prefer its replace
    ## tool: anchored on the lines you actually saw, and undoable. Empty
    ## content truncates the file. Content is capped (default 900KB — the
    ## bus itself cannot carry more); for larger files use bash (heredoc
    ## or base64). Approval is required for every write.
    ## - path: File to write, relative to the harness root or absolute
    ## - content: The full new file content ("" truncates the file)
    if content.len > maxBytes():
      raise newException(ValueError,
        "content is " & $content.len & " bytes, over the write cap of " &
        $maxBytes() & " — use bash for large files")
    let done = writeAtomic(path, content)
    return %*{"path": done.target, "bytes_written": done.bytes,
              "overwrote": done.overwrote}

comp.tools[^1].schema["x-harness"] = %*{"approval": "always", "timeoutMs": 60000}

comp.run()
