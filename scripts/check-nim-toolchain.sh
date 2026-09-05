#!/usr/bin/env bash
# fabric-exec imports the compiler and its bundled checksums by relative path.
set -euo pipefail

fail() {
  echo "Nim: $*" >&2
  echo 'Use a complete Nim >= 2.2.10 distribution (e.g. choosenim 2.2.10),' >&2
  echo 'and put its bin directory on PATH; see README.md prerequisites.' >&2
  exit 1
}

# Keep native/project configuration out of this toolchain-only probe.
command -v nim >/dev/null 2>&1 || fail 'not found'
compiler_dir=$(nim --skipProjCfg --skipParentCfg --skipUserCfg --verbosity:0 --hints:off --eval:'import std/os; doAssert (NimMajor, NimMinor, NimPatch) >= (2, 2, 10), "Nim >= 2.2.10 required"; echo getCurrentCompilerExe().parentDir.parentDir / "compiler"') || fail 'toolchain probe failed'
for source in nimeval.nim vm.nim ../dist/checksums/src/checksums/md5.nim ../dist/checksums/src/checksums/sha1.nim; do
  [[ -f "$compiler_dir/$source" ]] || fail "incomplete compiler sources: $compiler_dir/$source is missing"
done
echo "Nim compiler sources: OK ($compiler_dir)"
