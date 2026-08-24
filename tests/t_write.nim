## write component tests — bus contract: registration + write behaviour.
##
## Spawns write against a throwaway NATS and drives it with envelopes:
## create with parent dirs, overwrite, truncate, permission preservation,
## symlink follow-through, directory refusal, content cap, drain.

import std/[json, os, osproc, strutils]
import natswrapper
import helpers

proc main() =

  let root = getEnv("NIF_ROOT", getAppDir().parentDir())
  let bin = root / "var" / "bin" / "write"
  if not fileExists(bin):
    fail(bin & " missing — run `make build` first")
    quit(1)
  let tmp = tempRoot("write")
  defer: removeDir(tmp)

  let (server, url) = startNats()
  defer: stopServer(server)
  var nc = waitConnect(url)
  defer: nc.close()

  # small write cap so the cap test stays well under NATS's 1MB payload limit
  let wProc = startComponent(bin, url, root = tmp,
                             extra = [("NIF_WRITE_MAX_BYTES", "100000")])
  defer:
    if wProc.running():
      wProc.terminate()
      sleep(200)
    wProc.close()

  check("write registers", waitRegistered(nc, "write"))

  # new file, parent directories created
  let r1 = call(nc, "write", "write",
                %*{"path": "dir/sub/new.txt", "content": "hello\nworld\n"})
  check("write creates new file", r1{"bytes_written"}.getInt(-1) == 12 and
        r1{"overwrote"}.getBool(true) == false, $r1)
  check("write created parent dirs",
        readFile(tmp / "dir" / "sub" / "new.txt") == "hello\nworld\n")

  # overwrite: content replaced, flag set
  let r2 = call(nc, "write", "write",
                %*{"path": "dir/sub/new.txt", "content": "replaced"})
  check("write overwrites", r2{"overwrote"}.getBool(false) == true and
        readFile(tmp / "dir" / "sub" / "new.txt") == "replaced", $r2)

  # empty content truncates
  let r3 = call(nc, "write", "write",
                %*{"path": "dir/sub/new.txt", "content": ""})
  check("write truncates on empty content",
        r3{"bytes_written"}.getInt(-1) == 0 and
        readFile(tmp / "dir" / "sub" / "new.txt") == "", $r3)

  # permissions preserved across overwrite
  let modePath = tmp / "mode.txt"
  writeFile(modePath, "first")
  setFilePermissions(modePath, {fpUserRead, fpUserWrite})
  discard call(nc, "write", "write",
               %*{"path": "mode.txt", "content": "second"})
  check("write preserves permissions",
        getFilePermissions(modePath) == {fpUserRead, fpUserWrite})

  # symlink: write lands on the target, link stays a link
  let linkPath = tmp / "link.txt"
  writeFile(tmp / "target.txt", "old")
  createSymlink("target.txt", linkPath)
  let r5 = call(nc, "write", "write",
                %*{"path": "link.txt", "content": "new"})
  check("write follows symlink", r5{"path"}.getStr("").contains("target.txt") and
        readFile(tmp / "target.txt") == "new" and symlinkExists(linkPath), $r5)

  # directory path refused with a clear error
  let r6 = call(nc, "write", "write",
                %*{"path": "dir", "content": "x"})
  check("write refuses directories", r6.hasKey("error") and
        r6{"error"}.getStr("").contains("directory"), $r6)

  # content cap (test env: 100000 bytes)
  let big = newString(120_000).replace("\0", "x")
  let r7 = call(nc, "write", "write",
                %*{"path": "big.txt", "content": big})
  check("write enforces content cap", r7.hasKey("error") and
        r7{"error"}.getStr("").contains("write cap"), $r7)
  check("write cap wrote nothing", not fileExists(tmp / "big.txt"))

  # drain: component exits
  drain(nc)
  sleep(700)
  check("write drains and exits", not wProc.running())

  report("WRITE TEST")

main()
