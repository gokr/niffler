#!/usr/bin/env bash
# provider-triage ROOT — capture WHY a harness lost its providers, BEFORE
# restarting it.
#
# The symptom this exists for: several niffler-tui instances at once report
# "cannot resolve this conversation's pinned provider", and /provider shows NO
# providers at all. Everything comes back after `make down-here` (or clean +
# build), which restarts core, the store AND every component — so the
# observation alone cannot say WHICH of them lost the data, and a restart
# destroys the evidence.
#
# This script splits the candidates without changing anything:
#
#   1. the STORE lost the rows       -> `list kind=provider` is empty but
#                                       sqlite3 on the DB also returns 0 rows
#   2. the STORE is not answering    -> the store calls time out or error,
#                                       while sqlite3 DOES return rows
#   3. the PROVIDER component is bad -> `list` works but `provider_list` fails
#                                       or comes back empty
#   4. only the CLIENT is wrong      -> store and provider both answer fine
#                                       from here; the TUI's view was stale
#
# It only READS. No restart, no repair. (selftest writes and deletes one
# throwaway document — that is the store's own health check.)
#
# Usage:
#   scripts/provider-triage.sh [ROOT]        # ROOT defaults to this checkout
#   NIF_NATS_URL=nats://host:4222 scripts/provider-triage.sh /path/to/clone
#
# Exit 0 = captured (whatever it found); 1 = could not run (no cli).
set -uo pipefail

ROOT="${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}"
CLI="$ROOT/var/bin/cli"
OUT_DIR="$ROOT/var/triage"
OUT="$OUT_DIR/provider-triage-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$OUT_DIR" || { echo "cannot create $OUT_DIR" >&2; exit 1; }
if [[ ! -x "$CLI" ]]; then
  echo "provider-triage: $CLI is missing or not executable." >&2
  echo "  A broken build is one of the causes — note it, then build and retry." >&2
  exit 1
fi

# Tee: the terminal shows it, the log keeps it for a bug report.
exec > >(tee "$OUT") 2>&1

say() { printf '\n=== %s\n' "$*"; }
run() {
  local label="$1"; shift
  printf -- '--- %s\n$ cli %s\n' "$label" "$*"
  local start end rc
  start=$(date +%s%N)
  timeout "${TRIAGE_TIMEOUT:-20}" "$CLI" --timeout:15 "$@" 2>&1
  rc=$?
  end=$(date +%s%N)
  printf '  [exit %s, %dms]\n' "$rc" $(( (end - start) / 1000000 ))
}

printf 'provider triage — %s\nroot: %s\nbus : %s\n' "$(date)" "$ROOT" \
  "${NIF_NATS_URL:-<from $ROOT/var/nats-url>}"

say "1. what is running (before anything is touched)"
for pair in "core:$ROOT/var/bin/niffler" "store:$ROOT/var/bin/store" \
            "provider:$ROOT/var/bin/provider" "llm:$ROOT/var/bin/llm"; do
  name="${pair%%:*}"; path="${pair#*:}"
  printf -- '--- %s\n' "$name"
  pgrep -af "$path" | grep -v provider-triage || echo '  (not running)'
done
printf -- '--- nats-server\n'
pgrep -af 'nats-server' | head -5 || echo '  (none)'
printf -- '--- store residency (a leak shows here)\n'
for pid in $(pgrep -f "$ROOT/var/bin/store"); do
  ps -o pid,rss,etime --no-headers -p "$pid" 2>/dev/null |
    awk '{printf "  pid=%s rss=%.1fMB uptime=%s\n", $1, $2/1024, $3}'
done

say "2. store identity and binding (the silent-loss probe)"
printf -- '--- var/instance-id\n'
if [[ -f "$ROOT/var/instance-id" ]]; then cat "$ROOT/var/instance-id"; else echo '  (MISSING)'; fi
printf -- '--- how the store booted (does its identity ever change?)\n'
grep -E 'serving documents for instance|no instance identity|this database is bound' \
  "$ROOT/var/logs/store.log" 2>/dev/null | tail -5 || echo '  (no boot line found)'
printf -- '--- store_binding vs rows actually in the file\n'
if [[ -f "$ROOT/var/store.db" ]] && command -v sqlite3 >/dev/null 2>&1; then
  sqlite3 "$ROOT/var/store.db" \
    "select 'binding', instance_id, adopted from store_binding;" 2>&1
  sqlite3 "$ROOT/var/store.db" \
    "select 'rows', instance_id, count(*) from docs group by instance_id;" 2>&1
  echo '  >> a binding/rows mismatch, or an empty binding beside owned rows,'
  echo '     IS the bug this script exists for (refused at boot since 9bee9a1).'
else
  echo '  (needs sqlite3 — without it this probe cannot run)'
fi

say "3. the store's own view"
run "store list kind=provider" call list '{"kind":"provider","limit":20}'
run "store selftest" call selftest '{}'

say "4. the DB file, read directly (bypasses every component)"
DB="$ROOT/var/store.db"
if [[ -f "$DB" ]]; then
  ls -la "$DB"* 2>/dev/null
  if command -v sqlite3 >/dev/null 2>&1; then
    printf -- '--- row counts by kind (top 15)\n'
    sqlite3 "$DB" "select kind, count(*) from docs group by kind order by 2 desc limit 15;" 2>&1
    printf -- '--- provider rows\n'
    sqlite3 "$DB" "select id, rev from docs where kind='provider';" 2>&1
    printf -- '--- integrity\n'
    sqlite3 "$DB" "pragma quick_check;" 2>&1
  else
    echo '  (sqlite3 not installed — it is the most decisive probe here)'
  fi
else
  echo "  no $DB — tidb backend? check NIF_STORE_TIDB_DSN"
fi

say "5. the provider component's own view"
run "provider_list" call provider_list '{}'
run "provider_status" call provider_status '{}'
run "provider_get synthetic (a miss now carries code not-found)" call provider_get '{"nickname":"synthetic"}'

say "6. what core advertises (is the component registered at all?)"
run "catalog components" call catalog '{"op":"components"}'

say "7. recent component errors"
for name in store provider llm; do
  log="$ROOT/var/logs/$name.log"
  [[ -f "$log" ]] || continue
  printf -- '--- %s\n' "$log"
  grep -iE 'error|warn|refus|timeout|unreach|not found' "$log" 2>/dev/null |
    tail -40 || echo '  (nothing matching)'
done

say "verdict"
cat <<'EOF'
  section 2 empty AND section 3 empty  -> the DB really has no provider rows
                                          (candidate 1: data was lost)
  section 3 HAS rows, section 2 fails  -> the store is not answering
                                          (candidate 2: store wedged/leaked)
  section 2 has rows, section 4 fails  -> the provider component is broken
                                          (candidate 3)
  sections 2 and 4 both fine           -> only the client was wrong
                                          (candidate 4: stale TUI view)

Keep this log before restarting: a restart destroys every one of these answers.
EOF

printf '\nlog written: %s\n' "$OUT"
