#!/usr/bin/env bash
# mini Niffler runner — start/stop the harness without knowing its internals.
#
#   up      ensure a bus + core are running, then launch the desktop UI
#   down    stop the UI, core, and the bus core spawned
#   status  show what's running
#
# The core handles bus autostart itself: it reuses a bus on the default port
# (127.0.0.1:4222) if one is already live, otherwise it spawns nats-server on
# a random loopback port and writes var/nats-url. The UI bridge discovers the
# bus through that file.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$ROOT/var/.niffler.up"
NATS_URL_FILE="$ROOT/var/nats-url"
CORE_BIN="$ROOT/var/bin/niffler"
UI_BIN="$ROOT/ui/build/bin/niffler-ui"

core_running() {
  pgrep -f "$CORE_BIN" >/dev/null 2>&1
}

port_live() {
  (exec 3<>/dev/tcp/127.0.0.1/4222) 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1
}

nats_port_from() {
  local url="${1:-}"
  case "$url" in
    nats://*:*) echo "${url##*:}" ;;
    *) echo "" ;;
  esac
}

start_core() {
  local pre_nats=0
  if port_live; then pre_nats=1; fi
  echo "core: starting (bus: $([ "$pre_nats" = 1 ] && echo "reusing nats://127.0.0.1:4222" || echo "spawning nats-server"))"
  nohup "$CORE_BIN" </dev/null >"$ROOT/var/core.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 100); do
    [ -s "$NATS_URL_FILE" ] && break
    sleep 0.1
  done
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "core: FAILED to start — see var/core.log" >&2
    rm -f "$STATE"
    exit 1
  fi
  printf 'core_pid=%s\npre_nats=%s\n' "$pid" "$pre_nats" >"$STATE"
  echo "core: up on $(cat "$NATS_URL_FILE")"
}

cmd_up() {
  if [ ! -x "$CORE_BIN" ]; then
    echo "core binary missing — run 'make all' first" >&2
    exit 1
  fi
  if [ ! -x "$UI_BIN" ]; then
    echo "UI binary missing — run 'make all' first" >&2
    exit 1
  fi
  mkdir -p "$ROOT/var"
  if core_running; then
    echo "core: already running"
  else
    start_core
  fi
  sleep 1 # let the required components register before the UI opens
  echo "ui: launching $UI_BIN"
  exec "$UI_BIN"
}

cmd_down() {
  local core_pid="" pre_nats=1
  if [ -f "$STATE" ]; then
    . "$STATE"
    if [ -n "$core_pid" ] && kill -0 "$core_pid" 2>/dev/null; then
      echo "core: stopping (pid $core_pid)"
      kill "$core_pid"
    fi
    rm -f "$STATE"
  else
    pkill -f "$CORE_BIN" 2>/dev/null && echo "core: stopping" || true
  fi
  pkill -f "niffler-ui" 2>/dev/null && echo "ui: stopping" || true
  if [ "${pre_nats:-1}" = 0 ]; then
    local port
    port="$(nats_port_from "$(cat "$NATS_URL_FILE" 2>/dev/null || true)")"
    if [ -n "$port" ]; then
      pkill -f "nats-server.*-p $port" 2>/dev/null && echo "bus: stopping (port $port)" || true
    fi
  fi
  echo "down"
}

cmd_status() {
  if core_running; then
    echo "core: running ($([ -f "$NATS_URL_FILE" ] && cat "$NATS_URL_FILE" || echo "bus unknown"))"
  else
    echo "core: not running"
  fi
  if pgrep -f "niffler-ui" >/dev/null 2>&1; then
    echo "ui: running"
  else
    echo "ui: not running"
  fi
  if port_live; then
    echo "bus: nats-server on 127.0.0.1:4222"
  else
    echo "bus: nothing on 127.0.0.1:4222"
  fi
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *) echo "usage: $0 up|down|status" >&2; exit 1 ;;
esac
