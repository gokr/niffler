#!/usr/bin/env bash
# Compile the test to a disposable path: `nim c -r` defaults to writing the
# binary next to the source (tests/test_iniparse), which used to overwrite a
# file tracked in the base commit and trip the protected-file guard.
set -e
cd "$(dirname "$0")"
mkdir -p nimcache
nim c --hints:off --warnings:off --path:src -o:nimcache/test_iniparse tests/test_iniparse.nim 2>&1
./nimcache/test_iniparse
