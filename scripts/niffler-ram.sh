#!/usr/bin/env bash
# scripts/niffler-ram.sh — RAM of running Niffler stacks: harness + NATS +
# every spawned component + session runners + clients (tui/cli/console/ui).
#
#   scripts/niffler-ram.sh             # snapshot
#   watch -n5 scripts/niffler-ram.sh   # live view
#
# Membership rule: a process belongs to Niffler when its executable lives in
# a checkout's var/bin/ (niffler, tui, cli, console, session, every
# component, nats-server, mcp-bridge) or is the desktop UI
# (ui/build/bin/niffler-ui). This beats a PPID tree walk, which misses both
# shapes a running system actually takes: the tui is the PARENT of an
# autostarted harness (ensureHarness), and the bench driver (node run.mjs)
# owns the private bus of a bench harness beside it.
#
# Stacks are reported separately: bench-spawned private harnesses (cwd under
# <checkout>/var/bench/results/<run>/) get their own group, so a bench run
# never blurs into your dev clone's numbers.
#
# RSS double-counts file-backed pages when two stacks share one var/bin
# build; PSS (proportional set size, from smaps_rollup) is the honest
# physical total. Workload children of the bash tool (make, compilers,
# test binaries, ...) are deliberately excluded: they are what Niffler is
# running, not Niffler itself.
set -euo pipefail

PAGE=$(getconf PAGESIZE)
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for d in /proc/[0-9]*; do
  pid=${d#/proc/}
  exe=$(readlink "$d/exe" 2>/dev/null) || continue
  if [[ $exe == */var/bin/* ]]; then
    bin=${exe##*/var/bin/}; prefix=${exe%/var/bin/*}
  elif [[ $exe == */ui/build/bin/niffler-ui ]]; then
    bin=niffler-ui; prefix=${exe%/ui/build/bin/niffler-ui}
  else
    continue
  fi
  cw=$(readlink "$d/cwd" 2>/dev/null) || cw=""
  group=${prefix##*/}
  if [[ $cw == "$prefix"/var/bench/results/* ]]; then
    group="bench:${cw#"$prefix"/var/bench/results/}"
    group=${group%%/*}
  fi
  rss=$(awk '{print $2}' "$d/statm" 2>/dev/null) || continue
  rss=$(( rss * PAGE / 1024 )) # kB
  pss=$( (awk '/^Pss:/{print $2}' "$d/smaps_rollup" 2>/dev/null) || true )
  pss=${pss:-0}
  printf '%s\t%s\t%s\t%s\n' "$group" "$bin" "$rss" "$pss"
done | sort -t$'\t' -k1,1 -k2,2 > "$tmp"

if [[ ! -s "$tmp" ]]; then
  echo "no niffler processes found"
  exit 0
fi

awk -F'\t' '
function human(k) {
  if (k >= 1048576) return sprintf("%.2fG", k / 1048576);
  if (k >= 1024)    return sprintf("%.1fM", k / 1024);
  return sprintf("%.0fk", k);
}
function row() {
  printf "%-34s %-14s %5d %10s %10s\n", pg, pb, rc, human(rr), human(rp);
}
function subtotal() {
  printf "%-34s %-14s %5d %10s %10s\n", pg, "= stack total", gc, human(gr), human(gp);
  printf "\n";
}
BEGIN {
  printf "%-34s %-14s %5s %10s %10s\n", "stack", "binary", "procs", "RSS", "PSS";
}
{
  if ($1 != pg) {
    if (pg != "") { row(); subtotal(); pb = "" }
    pg = $1; gr = 0; gp = 0; gc = 0
  }
  if ($2 != pb) {
    if (pb != "") row();
    pb = $2; rr = 0; rp = 0; rc = 0
  }
  rr += $3; rp += $4; rc++;
  gr += $3; gp += $4; gc++;
  tr += $3; tp += $4; tc++
}
END {
  if (tc == 0) { print "no niffler processes found"; exit 0 }
  if (pb != "") row();
  if (pg != "") subtotal();
  printf "%-34s %-14s %5d %10s %10s\n", "TOTAL", "", tc, human(tr), human(tp);
}
' "$tmp"
