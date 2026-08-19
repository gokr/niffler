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
                   "natswrapper-", "bitbarrel-", "futhark-"]:
      if base.startsWith(prefix):
        switch("path", path)

# HTTPS for std/httpclient in every build (shipped components, builder-built
# tools, plugins, smoke, probes). Needs libssl-dev (Ubuntu) / Xcode CLT
# (macOS) — `make setup` installs it.
switch("define", "ssl")

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
