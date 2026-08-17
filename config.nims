# mini Niffler compiler config
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
