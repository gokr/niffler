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

# Per-repo nim cache. Nim's default is ~/.cache/nim/<project>_d — every
# repo's main.nim maps to the SAME main_d, so two concurrent builds anywhere
# (this repo's worktrees, agent-built components, other projects) overwrite
# each other's objects and links fail with "hidden symbol ... isn't defined".
# Pinning the cache under var/ (gitignored) scopes it to this checkout:
# worktrees and bench harness roots (which copy this config.nims) each get
# their own cache; test sandboxes keep overriding it per-sandbox.
switch("nimcache", thisDir() / "var" / "nimcache")

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
