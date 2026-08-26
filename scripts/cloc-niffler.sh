#!/bin/sh
# cloc-niffler.sh — count lines in the Niffler repo, excluding generated code.
#
# Generated / vendored paths excluded:
#   var/                  — runtime state, binaries, and builder output
#   nimcache/             — Nim compiler cache
#   sdk/ts/dist/          — compiled TypeScript SDK
#   */node_modules/       — npm dependencies
#   ui/build/             — Wails build output
#   ui/frontend/dist/     — Vite build output
#   ui/frontend/wailsjs/  — generated Wails bindings
#   .git/                 — git metadata
#   .github/              — CI workflows
#
# Dependency lock/checksum files and image assets are excluded too.
#
# Usage: ./scripts/cloc-niffler.sh [cloc-args...]
#   ./scripts/cloc-niffler.sh
#   ./scripts/cloc-niffler.sh --by-file

set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd "$SCRIPT_DIR/.." && pwd)
cd "$REPO_ROOT"

cloc \
  --exclude-dir=var,nimcache,node_modules,dist,build,wailsjs,.git,.github \
  --not-match-f='\.(svg|png|jpg|jpeg|gif|webp|ico|sum|lock)$|package-lock\.json$|package\.json\.md5$' \
  "$@" \
  .
