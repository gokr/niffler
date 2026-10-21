#!/usr/bin/env bash
set -euo pipefail
[[ $(uname -s) == Linux ]] || exit 0
sourceRoot=$(cd "$(dirname "$0")/.." && pwd)
root=$(mktemp -d /tmp/niffler-process-test.XXXXXX)
cleanup() { bash "$root/var/fleet-process/manager.sh" stop "$root" >/dev/null 2>&1 || true; rm -rf "$root"; }
trap cleanup EXIT
mkdir -p "$root/var/bin" "$root/var/fleet-process" "$root/shim"
touch "$root/niffler.nimble"
cp "$sourceRoot/components/fleet/process_service.sh" "$root/var/fleet-process/manager.sh"
cat > "$root/var/bin/niffler" <<'CORE'
#!/bin/bash
trap 'exit 0' TERM INT
env > "$NIF_ROOT/child.env"
echo $$ > "$NIF_ROOT/child"
while true; do sleep 0.1; done
CORE
chmod +x "$root/var/bin/niffler"
run() { bash "$root/var/fleet-process/manager.sh" "$1" "$root"; }

# BusyBox (Alpine) setpriv exists but lacks --pdeathsig: refuse up front
# instead of respawning a failing child forever.
cat > "$root/shim/setpriv" <<'SETPRIV'
#!/bin/sh
echo 'setpriv: unrecognized option: pdeathsig' >&2
exit 1
SETPRIV
chmod +x "$root/shim/setpriv"
if PATH="$root/shim:$PATH" run start 2>/dev/null; then echo 'accepted setpriv without --pdeathsig'; exit 1; fi
# The installer's preflight runs the same manager before the root exists.
if PATH="$root/shim:$PATH" bash "$root/var/fleet-process/manager.sh" preflight /nonexistent 2>/dev/null; then
  echo 'preflight accepted setpriv without --pdeathsig'; exit 1
fi
[[ ! -e "$root/var/fleet-process/pid" && ! -e "$root/child" ]]
rm "$root/shim/setpriv"
bash "$root/var/fleet-process/manager.sh" preflight /nonexistent

export NIF_LEAK=1
lifecycle() {
  rm -f "$root/child"
  run install
  run start
  for i in {1..100}; do [[ -s "$root/child" ]] && break; sleep 0.1; done
  first=$(cat "$root/child")
  # Same clean environment as the systemd unit; the login's NIF_* never leaks.
  grep -qx 'NIF_APPROVALS_DEFAULT=auto' "$root/child.env"
  grep -qx 'NIF_AUTO_APPROVE=0' "$root/child.env"
  if grep -q '^NIF_LEAK=' "$root/child.env"; then echo 'leaked login environment'; exit 1; fi
  identity=$(cat "$root/var/fleet-process/pid")
  run start
  [[ $(cat "$root/var/fleet-process/pid") == "$identity" ]]
  kill -TERM "$first"
  for i in {1..100}; do [[ $(cat "$root/child") != "$first" ]] && break; sleep 0.1; done
  [[ $(cat "$root/child") != "$first" ]]
  run status
  # A recycled PID must never be treated as our supervisor.
  printf '%s 0\n' "${identity%% *}" > "$root/var/fleet-process/pid"
  if run status; then echo 'accepted stale process identity'; exit 1; fi
  printf '%s\n' "$identity" > "$root/var/fleet-process/pid"
  run stop
  if run status; then echo 'reported stopped service as running'; exit 1; fi
  run start
  run stop
}
lifecycle

# Alpine's stock flock/setsid are BusyBox applets: prove the manager with them.
if command -v busybox >/dev/null &&
    [[ $(busybox --list | grep -cxE 'flock|setsid') == 2 ]]; then
  for applet in flock setsid; do ln -s "$(command -v busybox)" "$root/shim/$applet"; done
  PATH="$root/shim:$PATH" lifecycle
  echo 'busybox flock/setsid lifecycle ok'
fi
echo 'PROCESS SERVICE TEST PASSED'
