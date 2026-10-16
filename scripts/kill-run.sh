#!/usr/bin/env bash
# kill-run.sh <exact-run-id> — stop a bench run and everything it left
# behind. The global `make down` cannot be used for this: its patterns match
# bench worktrees too, so it takes unrelated runs down with it. Here the match
# is the run's own directory under var/bench/results (cwd or executable), and
# the loop repeats because a harness's supervisor revives its children once.
set -u
pat="${1:?usage: kill-run.sh <exact-run-id>}"
case "$pat" in
  .|..|*/*) echo "kill-run: expected one exact run directory name" >&2; exit 2 ;;
esac
[ "$(uname -s)" = Linux ] || { echo "kill-run: Linux /proc required" >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
hit=0
for _ in $(seq 1 6); do
  found=0
  for d in /proc/[0-9]*; do
    pid="${d#/proc/}"
    [ "$pid" = "$$" ] && continue
    cwd="$(readlink "$d/cwd" 2>/dev/null || true)"
    exe="$(readlink "$d/exe" 2>/dev/null || true)"
    # Exact path component, not a substring: matching "runA" against a live
    # "runAB" would kill an unrelated (often just-started) run.
    target="$root/var/bench/results/$pat"
    case "$cwd" in
      "$target"|"$target"/*) ;;
      *) case "$exe" in
        "$target"|"$target"/*) ;;
        *) continue ;;
      esac ;;
    esac
    if kill -9 "$pid" 2>/dev/null; then
      found=1
      hit=$((hit + 1))
    fi
  done
  [ "$found" = 0 ] && break
  sleep 1
done
echo "kill-run: sent SIGKILL to $hit process(es) matching $pat"
