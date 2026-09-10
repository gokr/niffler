#!/usr/bin/env bash
# Native guest compilation needs the Nim compiler + a C toolchain only; the
# embedded-VM compiler-source requirement is gone. checksums/sha1 is a nimble
# package resolved by config.nims (pkgs2 scan) when building fabric-exec.
set -euo pipefail

fail() {
  echo "Nim: $*" >&2
  echo 'Use a complete Nim >= 2.2.10 distribution (e.g. choosenim 2.2.10),' >&2
  echo 'and put its bin directory on PATH; see README.md prerequisites.' >&2
  exit 1
}

# Keep native/project configuration out of this toolchain-only probe.
command -v nim >/dev/null 2>&1 || fail 'not found'
nim --skipProjCfg --skipParentCfg --skipUserCfg --verbosity:0 --hints:off \
  --eval:'import std/os; doAssert (NimMajor, NimMinor, NimPatch) >= (2, 2, 10), "Nim >= 2.2.10 required"' || fail 'toolchain probe failed'
# C toolchain for the linker (the guest is compiled and linked, not VM-eval'd).
command -v cc >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 || \
  command -v clang >/dev/null 2>&1 || fail 'no C compiler (cc/gcc/clang)'
echo "Nim toolchain: OK ($(nim --version 2>/dev/null | head -1))"
