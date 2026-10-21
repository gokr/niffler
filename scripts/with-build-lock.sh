#!/usr/bin/env bash
# Serialize writes to shared build artifacts and protect test runs.
#
#   bash scripts/with-build-lock.sh [-s] -- <command...>
#
# -s: shared mode — test runs may overlap each other, but any writer waits
#     for all of them. Without -s the lock is exclusive (builds, clean).
# The lock file lives at the repository root (NIF_BUILD_LOCK), outside
# every cleaned tree, so `make clean` cannot unlink it while held.
# Test children must not inherit the lock: flock --close and the mkdir
# fallback never hold the lock in a child process.
set -euo pipefail

mode="exclusive"
if [[ "${1:-}" == "-s" ]]; then
  mode="shared"
  shift
fi
[[ "${1:-}" == "--" ]] && shift
[[ $# -ge 1 ]] || { echo "with-build-lock: missing command" >&2; exit 2; }

lock_file="${NIF_BUILD_LOCK:-.niffler-build.lock}"
mkdir -p "$(dirname "$lock_file")"

# util-linux flock only: BusyBox (Alpine) flock has no -o, so a child would
# inherit the lock. Probe a private temp file, never the contended lock
# itself, so every process on one host picks the same mechanism.
flock_closes_lock() {
  command -v flock >/dev/null 2>&1 || return 1
  local probe ok=1
  probe=$(mktemp 2>/dev/null) || return 1
  if flock -o "$probe" true >/dev/null 2>&1; then ok=0; fi
  rm -f "$probe"
  return "$ok"
}

if flock_closes_lock; then
  if [[ "$mode" == "shared" ]]; then
    exec flock -s -o "$lock_file" "$@"
  fi
  exec flock -o "$lock_file" "$@"
fi

# macOS has no flock by default and BusyBox flock lacks -o. mkdir is atomic
# and keeps concurrent access safe; shared and exclusive modes both serialize
# here. Stale owners are reclaimed when their PID is gone, or after a grace
# period when the owner record itself is missing.
lock_dir="${lock_file}.d"
while ! mkdir "$lock_dir" 2>/dev/null; do
  owner=""
  if [[ -f "$lock_dir/pid" ]]; then
    read -r owner <"$lock_dir/pid" || true
  fi
  stale=0
  if [[ -n "$owner" ]]; then
    kill -0 "$owner" 2>/dev/null || stale=1
  else
    if [[ -n "$(find "$lock_dir" -maxdepth 0 -mmin +2 2>/dev/null)" ]]; then
      stale=1
    fi
  fi
  if ((stale)); then
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
    continue
  fi
  sleep 0.1
done

cleanup() {
  rm -f "$lock_dir/pid"
  rmdir "$lock_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
printf '%s\n' "$$" >"$lock_dir/pid"
"$@"
