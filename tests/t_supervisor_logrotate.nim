## Size-based log rotation (core/supervisor.nim: rotateLogs).
##
## Two properties carry this change, and both fail loudly if the
## implementation is "fixed" the obvious ways:
##
##  1. The live file keeps its INODE. var/logs/core.log is core's stdout, an
##     inherited fd opened by whichever UI autostarted it
##     (scripts/niffler-tui.in, install.sh: `>>core.log`). Neither can follow a
##     rename, so rotating via moveFile would leave core writing to an unlinked
##     inode: the log appears frozen while the disk fills. This test holds an fd
##     open across rotation, writes through it AFTER, and requires the bytes to
##     land at the file path.
##  2. The retained generation is bounded. Rotating core.log.1 into
##     core.log.1.1 would build a chain and double the disk the cap exists to
##     bound.

import std/[os, posix, strutils]
import ../core/supervisor
import helpers

proc writeBytes(path: string, count: int, filler = "x") =
  ## Append `count` bytes without keeping the fd open.
  var f = open(path, fmAppend)
  defer: f.close()
  f.write(filler.repeat(count))

proc main() =
  let root = tempRoot("logrotate")
  defer: removeDir(root)
  createDir(root / "var" / "logs")
  let dir = root / "var" / "logs"
  let sup = Supervisor(root: root)

  # --- 1. under the cap nothing is touched ---------------------------------
  let small = dir / "small.log"
  writeBytes(small, 100)
  sup.rotateLogs(1000)
  check("a file under the cap is left alone",
        getFileSize(small) == 100 and not fileExists(small & ".1"),
        $getFileSize(small))

  # --- 2. over the cap: one generation, live file truncated ----------------
  let big = dir / "big.log"
  writeBytes(big, 3000, "a")
  sup.rotateLogs(1000)
  check("the live file is truncated to zero", getFileSize(big) == 0,
        $getFileSize(big))
  check("the previous generation keeps the content",
        fileExists(big & ".1") and getFileSize(big & ".1") == 3000,
        $getFileSize(big & ".1"))

  # --- 3. rotation is not a chain -----------------------------------------
  writeBytes(big, 3000, "b")
  sup.rotateLogs(1000)
  check("a second rotation replaces the generation instead of chaining",
        not fileExists(big & ".1.1"), "found " & big & ".1.1")
  check("the retained generation holds the newest content",
        fileExists(big & ".1") and readFile(big & ".1") == "b".repeat(3000),
        "retained generation is stale")

  # --- 4. THE KEY PROPERTY: an open fd survives rotation -------------------
  let live = dir / "core.log"
  writeBytes(live, 10)
  let fd = posix.open(live.cstring, O_WRONLY or O_APPEND)
  check("writer fd opened on the live log", fd >= 0)
  writeBytes(live, 2000, "c")
  sup.rotateLogs(1000)
  check("rotation truncated the live file", getFileSize(live) == 0,
        $getFileSize(live))
  let payload = "AFTER-ROTATION"
  let wrote = posix.write(fd, payload[0].unsafeAddr, payload.len)
  discard posix.close(fd)
  check("a write through the pre-rotation fd is visible in the live path",
        wrote == payload.len and readFile(live) == payload,
        "live file after fd write: " & readFile(live))

  # --- 5. a missing dir and a disabled cap are not fatal ------------------
  let noDir = Supervisor(root: root / "absent")
  noDir.rotateLogs(1000)
  check("a root without var/logs is a no-op", true)
  writeBytes(big, 3000, "d")
  sup.rotateLogs(0)
  check("a non-positive cap disables rotation",
        getFileSize(big) == 3000 and not fileExists(big & ".1.1"),
        $getFileSize(big))

  report("SUPERVISOR LOG ROTATION")

main()
