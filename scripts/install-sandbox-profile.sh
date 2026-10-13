#!/usr/bin/env bash
# scripts/install-sandbox-profile.sh — grant the sandbox launcher permission to
# create user namespaces on Linux.
#
# WHY THIS IS NEEDED (docs/research/SANDBOX-ROUTE.md): Ubuntu 23.10+ ships
# kernel.apparmor_restrict_unprivileged_userns=1, which refuses CLONE_NEWUSER to
# any *unconfined* program. That silently disables bubblewrap:
#
#     $ bwrap --unshare-user --ro-bind / / /bin/true
#     bwrap: setting up uid map: Permission denied
#
# AppArmor grants `userns` to a program that HAS a profile, which is why Ubuntu
# ships three-line "unconfined but named" stubs for ch-run, buildah and crun.
# This script installs the same shape for Niffler's launcher.
#
# The profile must name the binary that CREATES the namespace. AppArmor attaches
# per exec, so profiling a wrapper does not extend to the bwrap it spawns.
# See SANDBOX-ROUTE.md §4 — if the launcher creates the namespace itself, this
# path should point at the launcher; if bwrap is profiled directly, point it
# there, accepting that the grant then covers every bwrap on the machine.
#
# Idempotent; failures are non-fatal (the harness runs unguarded-but-reported
# without it — sandboxing is opt-in). Needs root: pass --sudo to use sudo.
#
#   ./scripts/install-sandbox-profile.sh [--sudo] [--target PATH]
#
# Uninstall: ./scripts/install-sandbox-profile.sh --uninstall [--sudo]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCHER="$ROOT/var/bin/niffler-sandbox"
TARGET="$LAUNCHER"
USE_SUDO=0
UNINSTALL=0
PROFILE_DIR="/etc/apparmor.d"
PROFILE_NAME="niffler-sandbox"

while [ $# -gt 0 ]; do
  case "$1" in
    --sudo) USE_SUDO=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --target) shift; TARGET="${1:-}" ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(uname -s)" != "Linux" ]; then
  echo "sandbox profile: not Linux — on macOS use Seatbelt (needs no profile)."
  exit 0
fi

run() { if [ "$USE_SUDO" = 1 ]; then sudo "$@"; else "$@"; fi; }

PROFILE_PATH="$PROFILE_DIR/$PROFILE_NAME"

if [ "$UNINSTALL" = 1 ]; then
  if run test -f "$PROFILE_PATH"; then
    run apparmor_parser -R "$PROFILE_PATH" 2>/dev/null || true
    run rm -f "$PROFILE_PATH"
    echo "sandbox profile: removed $PROFILE_PATH"
  else
    echo "sandbox profile: nothing to remove"
  fi
  exit 0
fi

if [ ! -x "$TARGET" ]; then
  echo "sandbox profile: no launcher at $TARGET — run 'make build' first" >&2
  exit 1
fi

# Resolve symlinks: AppArmor matches the file it executes, and a profile naming
# a symlinked spelling will not attach.
TARGET="$(readlink -f "$TARGET")"

if ! command -v apparmor_parser >/dev/null; then
  echo "sandbox profile: apparmor_parser not found — install apparmor-utils" >&2
  exit 1
fi

restricted="$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)"
if [ "$restricted" != "1" ]; then
  echo "sandbox profile: userns is not restricted on this kernel ($restricted) —"
  echo "  bubblewrap should work without a profile. Installing anyway (harmless)."
fi

tmp="$(mktemp)"
cat > "$tmp" <<EOF
# Installed by Niffler's scripts/install-sandbox-profile.sh.
#
# AppArmor refuses user namespaces to unconfined programs on Ubuntu 23.10+, which
# disables bubblewrap. This grants 'userns' to the Niffler sandbox launcher only.
# Shape copied from Ubuntu's own stubs for ch-run, buildah and crun.
#
# See docs/research/SANDBOX-ROUTE.md. Remove with:
#   ./scripts/install-sandbox-profile.sh --uninstall
abi <abi/4.0>,
include <tunables/global>

profile $PROFILE_NAME $TARGET flags=(unconfined) {
  userns,

  # site-specific additions and overrides
  include if exists <local/$PROFILE_NAME>
}
EOF

if ! run install -m 0644 "$tmp" "$PROFILE_PATH"; then
  rm -f "$tmp"
  echo "sandbox profile: could not write $PROFILE_PATH (needs root — try --sudo)" >&2
  exit 1
fi
rm -f "$tmp"

if ! run apparmor_parser -r "$PROFILE_PATH"; then
  echo "sandbox profile: wrote $PROFILE_PATH but apparmor_parser refused it." >&2
  echo "  The guard stays unavailable; the launcher will report that honestly." >&2
  exit 1
fi

echo "sandbox profile: installed for $TARGET"
echo "verify with: $ROOT/var/bin/niffler-sandbox probe"
