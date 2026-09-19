#!/usr/bin/env bash
# Parallel bus-contract test runner.
#
#   bash scripts/run-tests.sh [-j N] [--] <test-binary>...
#
# Each test binary boots its own NATS server and its own temporary NIF_ROOT
# (see tests/helpers.nim), so tests are isolated and can run in a bounded
# pool. The caller usually holds the shared build lock for the whole run
# (scripts/with-build-lock.sh -s) — that is what keeps test runs from
# overlapping repository build writes; the pool only overlaps the tests
# with each other, which the suite was designed for (docs/MANUAL.md
# "Testing").
#
# Behavior:
#   - N tests run at a time (default: NIF_TEST_JOBS, else half the CPUs)
#   - per-test output is captured to var/test-logs/<name>.log; a failing
#     test's tail is printed immediately and the run continues (the exit
#     status at the end reflects every failure)
#   - every test reports its wall time; the summary lists the slowest —
#     that is the input for tuning the pool and for finding test-side waits
#   - NIF_TEST_VERBOSE=1 also prints each test's full captured output
#   - set NIF_TEST_JOBS=1 for the old sequential behavior
#
# Exit: 0 when every test passed, 1 otherwise.

set -uo pipefail

jobs="${NIF_TEST_JOBS:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -j) jobs="$2"; shift 2 ;;
    -j*) jobs="${1#-j}"; shift ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [[ $# -lt 1 ]]; then
  echo "usage: run-tests.sh [-j N] -- <test-binary>..." >&2
  exit 2
fi

if [[ -z "$jobs" ]]; then
  cpus=$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2) | head -1 )
  jobs=$(( cpus / 2 ))
  [[ "$jobs" -ge 1 ]] || jobs=1
fi
[[ "$jobs" -ge 1 ]] 2>/dev/null || jobs=1

logdir="${NIF_TEST_LOGDIR:-var/test-logs}"
mkdir -p "$logdir"

declare -a args=("$@")
declare -a slot_pid slot_name slot_start slot_log
next=0
running=0
failed=0
declare -a results

cleanup() {
  local s pid
  for s in $(seq 0 $((jobs - 1))); do
    pid="${slot_pid[$s]:-}"
    if [[ -n "$pid" ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT INT TERM

now_ms() {
  # milliseconds since epoch; EPOCHREALTIME (bash >= 5) is microsecond
  # precise, the fallback keeps BSD/macOS date working at whole seconds.
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local raw=${EPOCHREALTIME/./}
    echo $((10#${raw:0:${#raw}-3}))
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

fmt_ms() {
  # 1234 -> "1.234s", 42 -> "0.042s"
  printf '%d.%03ds' $(( $1 / 1000 )) $(( $1 % 1000 ))
}

free_slot() {
  local s
  for s in $(seq 0 $((jobs - 1))); do
    if [[ -z "${slot_pid[$s]:-}" ]]; then
      echo "$s"
      return
    fi
  done
  echo -1
}

total_start=$(now_ms)
echo "run-tests: ${#args[@]} tests, $jobs at a time (logs in $logdir)"

while :; do
  # fill free slots
  while [[ $next -lt ${#args[@]} ]]; do
    s=$(free_slot)
    [[ "$s" -lt 0 ]] && break
    t="${args[$next]}"
    next=$((next + 1))
    name=$(basename "$t")
    log="$logdir/$name.log"
    "$t" >"$log" 2>&1 &
    slot_pid[$s]=$!
    slot_name[$s]="$name"
    slot_start[$s]=$(now_ms)
    slot_log[$s]="$log"
    running=$((running + 1))
    printf 'run  %s\n' "$name"
  done

  [[ "$running" -eq 0 ]] && break

  # reap finished slots
  for s in $(seq 0 $((jobs - 1))); do
    pid="${slot_pid[$s]:-}"
    [[ -z "$pid" ]] && continue
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"
      code=$?
      dur_ms=$(( $(now_ms) - slot_start[$s] ))
      secs=$(fmt_ms "$dur_ms")
      running=$((running - 1))
      results+=("$dur_ms ${slot_name[$s]}")
      if [[ $code -eq 0 ]]; then
        marker=$(grep -E '(TEST )?PASSED$' "${slot_log[$s]}" 2>/dev/null | tail -1)
        if [[ -n "$marker" ]]; then
          printf 'ok   %8s %s — %s\n' "$secs" "${slot_name[$s]}" "$marker"
        else
          printf 'ok   %8s %s\n' "$secs" "${slot_name[$s]}"
        fi
        if [[ "${NIF_TEST_VERBOSE:-0}" != "0" ]]; then
          sed 's/^/     | /' "${slot_log[$s]}"
        fi
      else
        printf 'FAIL %8s %s (exit %d) — %s\n' "$secs" "${slot_name[$s]}" "$code" "${slot_log[$s]}"
        tail -n 40 "${slot_log[$s]}" | sed 's/^/     | /'
        failed=$((failed + 1))
      fi
      slot_pid[$s]=""
    fi
  done
  sleep 0.2
done

wall=$(fmt_ms $(( $(now_ms) - total_start )))
echo
if [[ "$failed" -eq 0 ]]; then
  echo "run-tests: ${#results[@]} passed in ${wall} (jobs=$jobs)"
else
  echo "run-tests: $failed failed, $(( ${#results[@]} - failed )) passed in ${wall} (jobs=$jobs)"
fi
if [[ "${NIF_TEST_TIMINGS:-1}" != "0" && "${#results[@]}" -gt 0 ]]; then
  printf '%s\n' "${results[@]}" | sort -rn | head -8 |
    awk '{printf "  slowest: %8.3fs %s\n", $1/1000, $2}'
fi

[[ "$failed" -eq 0 ]] || exit 1
exit 0
