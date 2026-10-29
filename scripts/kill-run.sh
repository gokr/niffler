#!/usr/bin/env bash
# kill-run.sh <exact-run-id> — stop a bench run and everything it left
# behind. The global `make down` cannot be used for this: its patterns match
# bench worktrees too, so it takes unrelated runs down with it. Here the match
# is the run's own directory under var/bench/results (cwd or executable), and
# the loop repeats because a harness's supervisor revives its children once.
#
# The scan is ONE `find` per pass, not a bash loop with two `readlink` forks per
# /proc entry. That version was O(all processes) in FILE FORKS: on a host with
# ~4k processes it took 33 seconds with zero matches, which is long enough that
# a caller (the contract test spawns `sleep 60` children and asserts on them)
# can outlive its own fixtures. `find -lname` resolves the symlinks in one
# process and does the same comparison. The match is still an exact path
# component: `-lname "$target"` plus `-lname "$target/*"`.
set -u
pat="${1:?usage: kill-run.sh <exact-run-id>}"
case "$pat" in
  .|..|*/*) echo "kill-run: expected one exact run directory name" >&2; exit 2 ;;
esac
[ "$(uname -s)" = Linux ] || { echo "kill-run: Linux /proc required" >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$root/var/bench/results/$pat"
# Refuse a name that cannot exist: without this, a typo silently "succeeds"
# having matched nothing, which reads like a clean kill.
[ -d "$target" ] || [ -e "$target" ] || {
  echo "kill-run: no such run directory: $pat" >&2; exit 2; }

# One pass: every pid whose cwd OR exe is the run directory or inside it.
# -maxdepth 2 keeps this to /proc/<pid>/{cwd,exe}; the -mindepth guard skips
# /proc/cwd-style names that do not exist. Pids are de-duplicated because a
# process can match on both links.
matching_pids() {
  local links
  links="$(find /proc -maxdepth 2 \( -name cwd -o -name exe \) \
             \( -lname "**" \) 2>/dev/null)"
  [ -z "$links" ] && return 0
  printf '%s\n' "$links" | sed -e 's|^/proc/||' -e 's|/.*$||' | sort -u
}

hit=0
for _ in $(seq 1 6); do
  pids="$(matching_pids | grep -v "^$$\$" || true)"
  [ -z "$pids" ] && break
  found=0
  for pid in $pids; do
    if kill -9 "$pid" 2>/dev/null; then
      found=1
      hit=$((hit + 1))
    fi
  done
  [ "$found" = 0 ] && break
  sleep 1
done
echo "kill-run: sent SIGKILL to $hit process(es) matching $pat"
