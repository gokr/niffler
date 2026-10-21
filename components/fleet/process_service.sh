#!/usr/bin/env bash
# Explicit Linux process service. Survives SSH logout, not host reboot.
set -euo pipefail
umask 077
fail() { echo "fleet-process: $*" >&2; exit 1; }
[[ $# == 2 && $(uname -s) == Linux ]] || fail 'usage: manager action root (Linux required)'
action=$1
for command in flock setsid; do command -v "$command" >/dev/null || fail "$command required"; done
# BusyBox (Alpine) ships a setpriv without --pdeathsig; probe the capability,
# never mere presence, or the supervisor would respawn a failing child forever.
setpriv --pdeathsig TERM true >/dev/null 2>&1 || fail 'setpriv with --pdeathsig required (util-linux; Alpine: apk add setpriv)'
# The installer runs this before the root exists, so it fails before any write.
[[ $action != preflight ]] || exit 0
root=$(cd -- "$2" && pwd -P)
[[ -f "$root/niffler.nimble" && -x "$root/var/bin/niffler" ]] || fail 'not a built Niffler root'
state="$root/var/fleet-process"
[[ ! -L "$root/var" && ! -L "$state" ]] || fail 'symlinked service state'
mkdir -p "$state"
chmod 700 "$state"
stamp() { awk '{print $22}' "/proc/$1/stat" 2>/dev/null; }
alive() {
  [[ -f "$state/pid" && ! -L "$state/pid" ]] || return 1
  read -r pid born < "$state/pid"
  [[ $pid =~ ^[0-9]+$ && $born =~ ^[0-9]+$ ]] || fail 'invalid supervisor identity'
  [[ $(stamp "$pid") == "$born" ]] && kill -0 "$pid" 2>/dev/null
}
if [[ $action == supervise ]]; then
  exec 8>"$state/running.lock"
  flock -n 8 || exit 0
  child=''
  cleanup() {
    trap - TERM INT EXIT
    if [[ -n $child ]]; then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
    rm -f "$state/pid"
  }
  trap cleanup EXIT
  trap 'exit 0' TERM INT
  printf '%s %s\n' "$$" "$(stamp $$)" > "$state/pid.tmp"
  chmod 600 "$state/pid.tmp"
  mv "$state/pid.tmp" "$state/pid"
  # The same clean environment scripts/server.sh render() gives the systemd
  # unit (t_fleet asserts every NIF_* there appears here); never inherit the
  # SSH login's NIF_* settings.
  serviceEnv=(HOME="$HOME" USER="$(id -un)" LOGNAME="$(id -un)" NIF_ROOT="$root"
    NIF_NATS_URL= NIF_NATS_SPAWN=1 NIF_AUTOSTART=0 NIF_AUTO_APPROVE=0
    NIF_APPROVALS_DEFAULT=auto PATH="$HOME/.nimble/bin:/usr/local/bin:/usr/bin:/bin")
  cd "$root"
  while true; do
    env -i "${serviceEnv[@]}" setpriv --pdeathsig TERM "$root/var/bin/niffler" 8>&- &
    child=$!
    wait "$child" || true
    child=''
    sleep 3
  done
fi
exec 9>"$state/control.lock"
flock -x 9
case "$action" in
  install) echo 'fleet-process: installed; reboot persistence is NOT provided' ;;
  start)
    if alive; then echo "fleet-process: already running pid=$pid"; exit 0; fi
    nohup setsid bash "$state/manager.sh" supervise "$root" 9>&- </dev/null >>"$state/service.log" 2>&1 &
    for attempt in {1..50}; do
      if alive; then echo "fleet-process: running pid=$pid; reboot persistence=none"; exit 0; fi
      sleep 0.1
    done
    fail 'supervisor did not start; inspect service.log'
    ;;
  stop)
    if ! alive; then echo 'fleet-process: stopped'; exit 0; fi
    kill -TERM "$pid"
    for attempt in {1..300}; do
      if ! alive; then echo 'fleet-process: stopped'; exit 0; fi
      sleep 0.1
    done
    fail 'supervisor has not stopped; no unverified kill attempted'
    ;;
  status) alive || fail 'stopped'; echo "fleet-process: running pid=$pid; reboot persistence=none" ;;
  logs) tail -100 "$state/service.log" ;;
  *) fail "unsupported action: $action" ;;
esac
