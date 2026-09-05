# Niffler compiler config
# All dependencies come from nimble (niffler.nimble); the pkgs2 scan below
# keeps plain `nim c` invocations (builder, smoke test) resolving them even
# when nimble.paths is stale.

import std/[os, strutils]
let pkgsDir = getHomeDir() / ".nimble" / "pkgs2"
if dirExists(pkgsDir):
  for kind, path in walkDir(pkgsDir):
    let base = path.extractFilename()
    for prefix in ["lz4wrapper-", "crunchy-", "supersnappy-", "sunny-", "yaml-",
                   "natswrapper-", "bitbarrel-", "futhark-", "htmlparser-",
                   "checksums-"]:
      if base.startsWith(prefix):
        switch("path", path)

# HTTPS for std/httpclient in every build (shipped components, builder-built
# tools, plugins, smoke, probes). Needs libssl-dev (Ubuntu) / Xcode CLT
# (macOS) — `make setup` installs it.
switch("define", "ssl")

# Link PCRE explicitly instead of loading it by a bare filename at runtime
# (Homebrew libraries are outside macOS's default dlopen search path).
switch("define", "usePcreHeader")
switch("passL", "-lpcre")
when defined(macosx):
  let brewPrefix = staticExec("brew --prefix").strip()
  switch("passC", "-I" & quoteShell(brewPrefix / "include"))
  switch("passL", "-L" & quoteShell(brewPrefix / "lib"))

# Per-entrypoint nim cache. Nim's default is ~/.cache/nim/<project>_d, so every
# component named main.nim collides across worktrees. One cache per checkout is
# still unsafe because `make -j` compiles several entrypoints concurrently.
# Use the project path relative to this config as a stable, filesystem-safe key:
# parallel component/test builds cannot overwrite each other's objects, while
# repeat builds of the same entrypoint remain incremental. Test sandboxes that
# provide an explicit cache path keep overriding this setting.
let cacheKey = projectPath().relativePath(thisDir()).changeFileExt("").replace(DirSep, '_')
switch("nimcache", thisDir() / "var" / "nimcache" / cacheKey)

# futhark (via natswrapper) emits a bogus FILE-size warning for the C header
switch("warning", "User:off")

when defined(release):
  switch("opt", "speed")
else:
  switch("debuginfo")
  switch("stacktrace", "on")
  switch("linetrace", "on")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
