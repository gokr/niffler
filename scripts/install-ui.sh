#!/usr/bin/env bash
# Install the desktop web UI through Niffler's plugin lifecycle.
# The UI is an interactive plugin: build it, publish its artifact into
# var/bin, and let the user start it. It is never spawned as a service.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/var/bin/niffler"
CLI="$ROOT/var/bin/cli"
URL_FILE="$ROOT/var/nats-url"
PID=""
SAVED_URL=""

log() { printf 'install-ui: %s\n' "$*"; }
die() { printf 'install-ui: %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [ -n "$PID" ]; then
    kill -TERM "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  if [ -n "$SAVED_URL" ]; then printf '%s\n' "$SAVED_URL" > "$URL_FILE"; fi
}
trap cleanup EXIT

[ -x "$CORE" ] && [ -x "$CLI" ] || die "harness binaries missing — run 'make build' first"
mkdir -p "$ROOT/var/logs"
[ -f "$URL_FILE" ] && SAVED_URL="$(tr -d '[:space:]' < "$URL_FILE")"

# Always use a private, auto-approved boot for installation. This avoids
# mutating a user's live conversation bus and gives plugin_install a human
# approval context even when make is running headlessly.
log "booting an isolated harness for plugin_install"
NIF_NATS_URL= NIF_NATS_SPAWN=1 NIF_AUTO_APPROVE=1 \
  "$CORE" </dev/null >>"$ROOT/var/logs/core.log" 2>&1 &
PID=$!

url=""
for _ in $(seq 1 180); do
  [ -f "$URL_FILE" ] && url="$(tr -d '[:space:]' < "$URL_FILE")"
  if [ -n "$url" ] && NIF_NATS_URL="$url" "$CLI" catalog >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
[ -n "$url" ] && NIF_NATS_URL="$url" "$CLI" catalog >/dev/null 2>&1 || \
  die "harness did not come up — see $ROOT/var/logs/core.log"

log "installing gokr/niffler-ui through the plugin manager"
NIF_NATS_URL="$url" "$CLI" install --timeout:900 gokr/niffler-ui

[ -x "$ROOT/var/bin/niffler-ui" ] || \
  die "plugin installed without var/bin/niffler-ui"
log "installed $ROOT/var/bin/niffler-ui"

# PATH integration is handled by the normal install command. Desktop launcher
# integration remains owned by the plugin checkout and is intentionally not
# required for headless installs.
log "run 'make install' to add niffler-ui to PATH, or launch var/bin/niffler-ui"
