## Pure root/bin resolution for the lsp component.
##
## Filesystem-only and side-effect-free so tests/t_lsp.nim can import it
## directly (hermetic coverage, no bus):
##
## - rootMarkersForExt/deriveRoot: which directory should a language server
##   treat as its root? Defaulting to the conversation workspace (the harness
##   clone) makes a server load every nested module in the repo — gopls on
##   this clone spends its first minute indexing components/*, ui/ and
##   var/plugins/*. Walk up from the queried file to the nearest marker for
##   its language instead.
## - fallbackBinDirs/resolveBinIn: a configured command that is not on PATH
##   may still live in the usual per-user install dirs (~/go/bin for gopls,
##   ~/.nimble/bin for nimlangserver) — find it there instead of failing with
##   "not found on PATH — install it".

import std/[os, strutils]

# ---------------------------------------------------------------------------
# language-server roots

proc rootMarkersForExt*(ext: string): seq[string] =
  ## Root markers for a file extension, nearest-first semantics (the walk
  ## returns the first directory carrying any of them). Unknown extensions
  ## fall back to repo markers, so the clone root remains the root — the
  ## behavior every language had before derivation existed.
  result =
    case ext
    of ".go": @["go.mod", "go.work"]
    of ".rs": @["Cargo.toml"]
    of ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs":
      @["tsconfig.json", "package.json"]
    of ".py", ".pyi": @["pyproject.toml", "setup.py", "setup.cfg"]
    of ".nim", ".nims": @["*.nimble", "config.nims"]
    of ".c", ".h", ".cpp", ".cc", ".cxx", ".hpp", ".hh":
      @["compile_commands.json", "CMakeLists.txt"]
    else: @[]
  result.add(".git")

proc hasMarker*(dir: string, markers: seq[string]): bool =
  ## Does `dir` carry one of `markers`? A marker starting with "*." (or "*")
  ## matches by suffix, so `*.nimble` finds niffler.nimble.
  for m in markers:
    if m.len == 0: continue
    if m[0] == '*':
      let suffix = m[1 .. ^1]
      try:
        for kind, path in walkDir(dir, relative = true):
          if kind == pcFile and path.endsWith(suffix): return true
      except CatchableError:
        discard
    elif fileExists(dir / m) or dirExists(dir / m):
      return true

proc deriveRoot*(file, workspace: string, markers: seq[string]): string =
  ## Nearest ancestor of `file` — starting at the file's own directory —
  ## that carries one of `markers`; `workspace` when none is found or the
  ## file is not inside `workspace`. Never walks above `workspace`, so the
  ## derived root always stays inside the caller's scope (the scope check
  ## in hLsp keeps comparing like with like).
  var ws = workspace
  while ws.len > 1 and ws[^1] == '/': ws = ws[0 .. ^2]
  if ws.len == 0 or file.len == 0 or not file.isAbsolute(): return ws
  var dir = file.parentDir()
  while dir.len > 0 and (dir == ws or dir.startsWith(ws & "/")):
    if hasMarker(dir, markers): return dir
    let up = dir.parentDir()
    if up == dir or up.len < ws.len: break
    dir = up
  ws

# ---------------------------------------------------------------------------
# per-user install directories (PATH fallback)

proc fallbackBinDirs*(home: string, extra = ""): seq[string] =
  ## Directories searched when a configured server command is not on PATH:
  ## NIF_LSP_BIN_DIRS first (colon-separated — tests and custom toolchains),
  ## then the usual per-user install locations under `home`.
  if extra.len > 0:
    for part in extra.split(PathSep):
      if part.len > 0: result.add(part)
  if home.len > 0:
    for rel in ["go/bin", ".nimble/bin", ".local/bin", "bin"]:
      result.add(home / rel)

proc isExecutableFile(path: string): bool =
  ## findExe() accepts any existing absolute path, executable or not —
  ## check the mode ourselves so a stray data file in ~/go/bin cannot be
  ## chosen as a language server.
  if not fileExists(path) or dirExists(path): return false
  when defined(windows):
    return true
  else:
    try:
      let perms = getFilePermissions(path)
      return fpUserExec in perms or fpGroupExec in perms or fpOthersExec in perms
    except CatchableError:
      return false

proc resolveBinIn*(name: string, dirs: seq[string]): string =
  ## Absolute path to `name` in the first of `dirs` that has it executable;
  ## "" when none does. Names containing a separator are paths already and
  ## are left to the caller.
  if name.len == 0 or name.contains('/') or name.contains('\\'):
    return ""
  for d in dirs:
    let candidate = d / name
    if isExecutableFile(candidate): return candidate
