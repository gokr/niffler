#!/usr/bin/env bash
# test-bootstrap.sh — validate scripts/bootstrap.sh against a clean Ubuntu.
#
#   scripts/test-bootstrap.sh                    # all scenarios (A is slow)
#   BOOTSTRAP_TEST_IMAGE=ubuntu:22.04 scripts/test-bootstrap.sh
#   CONTAINER_RUNTIME=podman scripts/test-bootstrap.sh
#
# Scenario matrix:
#   A full     — the real flow, non-interactively (`bash -s -- /opt/niffler`):
#                apt git/make -> clone -> make setup -> make build ->
#                make install-tui, then asserts the core binary, the seeded
#                .env, and the niffler-tui wrapper.
#   B dry-run  — --dry-run on a pristine image must change nothing.
#   C help     — --help exits 0 with usage.
#   D consent  — the tty prompt; answering n must abort before creating
#                anything (no clone dir, no apt run).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BS="$ROOT/scripts/bootstrap.sh"
IMAGE="${BOOTSTRAP_TEST_IMAGE:-ubuntu:24.04}"
RUNTIME="${CONTAINER_RUNTIME:-}"
if [ -z "$RUNTIME" ]; then
  for t in docker podman; do
    command -v "$t" >/dev/null 2>&1 && RUNTIME="$t" && break
  done
fi
[ -n "$RUNTIME" ] || { echo "test-bootstrap: need docker or podman (or set CONTAINER_RUNTIME)" >&2; exit 1; }

say() { printf 'test-bootstrap: %s\n' "$*"; }
say "runtime: $RUNTIME · image: $IMAGE · script: $BS"
fail=0

say "scenario B: --dry-run on a pristine image (must change nothing, exit 0)"
if b_out="$($RUNTIME run --rm -i "$IMAGE" bash -s -- --dry-run /opt/x < "$BS" 2>&1)"; then
  echo "$b_out" | tail -3
  echo "ok: dry-run exits 0"
else
  echo "B fail: --dry-run must exit 0"; echo "$b_out" | tail -6; fail=1
fi

say "scenario C: --help (must exit 0)"
if $RUNTIME run --rm -i "$IMAGE" bash -s -- --help < "$BS" >/dev/null 2>&1; then
  echo "ok: --help exits 0"
else
  echo "C fail: --help must exit 0"; fail=1
fi

say "scenario D: the consent prompt (answering n must abort before creating)"
$RUNTIME run --rm -i -v "$BS":/bs.sh:ro "$IMAGE" bash -c '
  set +e
  printf "y\nn\n" | script -qec "bash /bs.sh" /dev/null >/tmp/d.log 2>&1
  rc=$?
  tail -4 /tmp/d.log
  [ "$rc" -ne 0 ] || { echo "d1 fail: expected a non-zero abort exit"; exit 1; }
  grep -q "proceed with this plan" /tmp/d.log || { echo "d2 fail: the plan confirmation never appeared"; exit 1; }
  [ ! -e /root/niffler ] || { echo "d3 fail: /root/niffler created despite abort"; exit 1; }
  echo "ok: plan confirmed, location declined, nothing created"
' || fail=1

say "scenario E: re-run path (prerequisites present must not trip set -u)"
if e_out="$($RUNTIME run --rm -i "$IMAGE" bash -c '
  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq git make curl ca-certificates >/dev/null 2>&1
  bash -s -- --dry-run /opt/x
' < "$BS" 2>&1)" && echo "$e_out" | grep -q "would ask about optional Node.js"; then
  echo "ok: second-run path clean (reached the optional-Node step without dying)"
else
  echo "E fail: bootstrap broke with prerequisites already present"; echo "$e_out" | tail -6; fail=1
fi

say "scenario A: one line on a pristine image (slow — prereqs, toolchains, full build)"
$RUNTIME run --rm -i "$IMAGE" bash -c '
  bash -s -- /opt/niffler || { echo "A fail: bootstrap exited non-zero"; echo "== core.log tail:"; tail -30 /opt/niffler/var/logs/core.log 2>/dev/null; exit 1; }
  test -x /opt/niffler/var/bin/niffler || { echo "A fail: core binary missing"; exit 1; }
  echo "ok: core binary built"
  test -f /opt/niffler/.env || { echo "A fail: .env not seeded"; exit 1; }
  echo "ok: .env seeded"
  ls ~/bin 2>/dev/null | sed "s/^/  bin: /"
  command -v niffler-tui >/dev/null 2>&1 || { echo "A fail: niffler-tui wrapper missing from PATH"; exit 1; }
  echo "ok: niffler-tui wrapper installed ($(command -v niffler-tui))"
' < "$BS" || fail=1

if [ "$fail" = 0 ]; then
  say "BOOTSTRAP TEST PASSED (A full · B dry-run · C help · D consent · E re-run)"
else
  say "BOOTSTRAP TEST FAILED"
fi
exit "$fail"
