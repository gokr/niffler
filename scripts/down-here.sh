#!/usr/bin/env bash
# down-here ROOT — stop THIS checkout's harness, components and spawned bus,
# and nothing else.
#
# The global `make down` pkills by broad patterns (every var/bin/niffler on
# the machine, every nats-server regardless of port) — the right hammer for
# stray detached cores, but it takes down bench worktrees, other clones'
# live harnesses and every bus on the machine with it. This variant pins
# every kill to the checkout root. Pinning is subtle because the obvious
# signals all lie on a real machine (measured):
#
#   - /proc/<pid>/exe RESOLVES SYMLINKS: a bench sandbox's binaries are a
#     symlink farm over the checkout's var/bin, so "exe under our var/bin"
#     catches bench leftovers too. cmdline (argv[0]) shows the farm path.
#   - cwd is inherited, not set: a core launched from a shell sitting in
#     another clone drags its whole tree's cwd there (seen: nifflerprod's
#     bus running with cwd=~/git/niffler).
#   - env alone is incomplete: operator-launched cores have no NIF_ROOT at
#     all; bench buses have no NIF_* env (the runner spawns them itself).
#
# So ownership is decided per process kind from three signals:
#
#   core      exe under ROOT/var/bin AND (NIF_ROOT=ROOT OR no NIF_ROOT)
#             (bench cores always carry NIF_ROOT=<sandbox>, excluding them)
#   component NIF_ROOT=ROOT (the supervisor stamps it onto every child) —
#             or, for pre-stamping leftovers, exe under ROOT/var/bin with
#             no NIF_ROOT and not a nats-server
#   bus       nats-server whose PARENT is one of ours, or the pid named by
#             var/nats-pid (the core's pidfile — an alive pid there is an
#             orphaned bus from a crashed core, the case `down` exists for;
#             pid-reuse guarded by checking the exe really is nats-server).
#             A bench bus is the runner's child, never ours — attach-only
#             harnesses (NIF_NATS_URL env) do not own their bus by contract.
#   ui        niffler-ui whose cwd is ROOT (UIs own their core's lifecycle)
#
# --dry-run lists what would stop. In-flight tests under this root die with
# everything else — TEST_LOCK does not guard against this script.
set -u
dry_run=0
root=""
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) dry_run=1 ;;
    *) root="${arg%/}" ;;
  esac
done
if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "down-here: need the checkout root as the first argument" >&2
  exit 1
fi

declare -a cand_pids=() cand_base=() cand_env=() cand_ppid=()
declare -A cand_seen=() is_ours=()
declare -A label_of

# pass 1: candidates — exe under this root's var/bin, or shared-name
# binaries (nats-server/niffler-ui) living in this root (cwd pin)
for d in /proc/[0-9]*; do
  pid="${d#/proc/}"
  [ "$pid" = "$$" ] && continue
  exe="$(readlink "$d/exe" 2>/dev/null)" || continue
  base="$(basename "$exe")"
  take=0
  case "$exe" in
    "$root/var/bin/"*) take=1 ;;
    */nats-server|*/niffler-ui)
      cwd="$(readlink "$d/cwd" 2>/dev/null)" || continue
      [ "$cwd" = "$root" ] && take=1 ;;
  esac
  [ "$take" -eq 1 ] || continue
  [ -z "${cand_seen[$pid]:-}" ] || continue
  cand_seen[$pid]=1
  env_root="$(tr '\0' '\n' < "$d/environ" 2>/dev/null | grep '^NIF_ROOT=' | head -1 | cut -d= -f2-)"
  ppid="$(awk '{print $4}' "$d/stat" 2>/dev/null)"
  cand_pids+=("$pid")
  cand_base+=("$base")
  cand_env+=("${env_root:-}")
  cand_ppid+=("${ppid:-0}")
  cmd="$(tr '\0' ' ' < "$d/cmdline" 2>/dev/null)"
  cmd="${cmd% }"
  label_of[$pid]="${base}: ${cmd:-?}"
done

# pass 2: classify — cores and components first, then buses by parentage
n=${#cand_pids[@]}
for i in $(seq 0 $((n - 1))); do
  pid="${cand_pids[$i]}"; base="${cand_base[$i]}"; env="${cand_env[$i]}"
  case "$base" in
    niffler|niffler-ui)
      [ "$env" = "$root" ] || [ -z "$env" ] && is_ours[$pid]=1 ;;
    nats-server)
      : ;; # buses decided in pass 3 (parentage/pidfile)
    *)
      [ "$env" = "$root" ] && is_ours[$pid]=1
      if [ -z "$env" ] && [ -z "${is_ours[$pid]:-}" ]; then
        exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
        case "$exe" in "$root/var/bin/"*) is_ours[$pid]=1 ;; esac
      fi ;;
  esac
done
for i in $(seq 0 $((n - 1))); do
  pid="${cand_pids[$i]}"
  [ "${cand_base[$i]}" = "nats-server" ] || continue
  ppid="${cand_ppid[$i]}"
  if [ -n "${is_ours[$ppid]:-}" ]; then is_ours[$pid]=1; continue; fi
  pidfile="$root/var/nats-pid"
  if [ -r "$pidfile" ] && [ "$pid" = "$(cat "$pidfile" 2>/dev/null)" ]; then
    is_ours[$pid]=1
  fi
done

declare -a pids=() labels=()
for pid in "${cand_pids[@]}"; do
  [ -n "${is_ours[$pid]:-}" ] || continue
  pids+=("$pid")
  labels+=("${label_of[$pid]}")
done

if [ "${#pids[@]}" -eq 0 ]; then
  echo "down-here: nothing running for $root"
  exit 0
fi

if [ "$dry_run" -eq 1 ]; then
  echo "down-here (dry run): would stop ${#pids[@]} process(es) for $root:"
  for label in "${labels[@]}"; do
    printf '  %s\n' "$label"
  done
  exit 0
fi

kill "${pids[@]}" 2>/dev/null
# grace period: the core drains its components (onDrain) on SIGTERM
for _ in $(seq 1 30); do
  alive=0
  for pid in "${pids[@]}"; do
    [ -d "/proc/$pid" ] && alive=$((alive + 1))
  done
  [ "$alive" -eq 0 ] && break
  sleep 0.1
done
# escalate on whatever is left
for i in "${!pids[@]}"; do
  pid="${pids[$i]}"
  if [ -d "/proc/$pid" ]; then
    kill -9 "$pid" 2>/dev/null
    labels[$i]="${labels[$i]} [SIGKILL]"
  fi
done
rm -f "$root/var/nats-pid"

echo "down-here: stopped ${#pids[@]} process(es) for $root:"
for label in "${labels[@]}"; do
  printf '  %s\n' "$label"
done
