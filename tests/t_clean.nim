## Exercise the real clean recipe in an isolated checkout, never the live var/.
import std/[os, osproc, tempfiles]

proc main() =
  let repo = getEnv("NIF_REPO_ROOT", getCurrentDir())
  let root = createTempDir("clean-contract-", "", repo / "var")
  defer: removeDir(root)
  createDir(root / "scripts")
  copyFile(repo / "Makefile", root / "Makefile")
  copyFile(repo / "scripts/with-build-lock.sh", root / "scripts/with-build-lock.sh")

  let preserved = ["var/store.db", "var/store.db-wal", "var/store.db-shm",
    "var/store.db.lock", "var/barrel-db/data", "var/bench/results/run.json",
    "var/logs/core.log", "var/plugins/example/source.nim",
    "var/build/custom.nim", "var/build/custom/main.go",
    "var/nats-url", "var/instance-id", "var/fleet/worker.json",
    "var/processes/registry.json", "var/processes/notices/p1.json",
    "var/unknown/future-state",
    ".env"]
  let artifacts = ["var/bin/niffler", "var/bin/.mode",
    "var/nimcache/core/object.o", "nimcache/object.o"]
  for path in preserved:
    createDir(parentDir(root / path))
    writeFile(root / path, "preserve " & path)
  for path in artifacts:
    createDir(parentDir(root / path))
    writeFile(root / path, "build output")

  # Avoid inheriting the outer test suite's shared lock into this fixture.
  for attempt in 0..1:
    let command = "env -u MAKEFLAGS -u MFLAGS make --no-print-directory -C " &
      quoteShell(root) & " clean NIF_BUILD_LOCK=" &
      quoteShell(root / ".niffler-build.lock")
    let result = execCmdEx(command)
    doAssert result.exitCode == 0, result.output
    for path in preserved:
      doAssert fileExists(root / path), "clean deleted " & path
      doAssert readFile(root / path) == "preserve " & path
    for path in ["var/bin", "var/nimcache", "nimcache"]:
      doAssert not dirExists(root / path), "clean left " & path
  echo "CLEAN TEST PASSED"

main()
