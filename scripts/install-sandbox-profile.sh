#!/usr/bin/env bash
# Optional AppArmor userns grant for the system bubblewrap binary.
# This permits ALL uses of that binary to create user namespaces; it does not
# grant host root, confine commands, or turn on Niffler's bash sandbox.
# Exec profile inheritance is policy-dependent; we profile bwrap directly
# rather than relying on an untested wrapper inheritance configuration.
# Usage: make install-sandbox-profile SUDO=1
# Preview: bash scripts/install-sandbox-profile.sh --dry-run
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET=/usr/bin/bwrap
PROFILE_PATH=/etc/apparmor.d/niffler-bwrap
USE_SUDO=0
UNINSTALL=0
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sudo) USE_SUDO=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      printf '%s\n' 'Usage: install-sandbox-profile.sh [--sudo] [--dry-run] [--uninstall]'
      exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
if [ "$(uname -s)" != Linux ]; then
  echo 'AppArmor installation is Linux-only; no changes made.'
  exit 0
fi
run() { if [ "$USE_SUDO" = 1 ]; then sudo "$@"; else "$@"; fi; }
if [ "$UNINSTALL" = 1 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    printf 'Would unload and remove %s\n' "$PROFILE_PATH"
    exit 0
  fi
  if [ -f "$PROFILE_PATH" ]; then
    # Do not report successful removal if the running policy remains loaded.
    run apparmor_parser -R "$PROFILE_PATH"
    run rm -- "$PROFILE_PATH"
    echo "Removed $PROFILE_PATH"
  else
    echo 'No Niffler bubblewrap profile to remove.'
  fi
  exit 0
fi

# Fixed system path: never grant userns to a PATH-selected, agent-writable
# binary, and never interpolate arbitrary paths into privileged policy syntax.
if [ ! -x "$TARGET" ] || [ -L "$TARGET" ]; then
  echo 'Expected a system binary at /usr/bin/bwrap; install bubblewrap first.' >&2
  exit 1
fi
read -r owner mode < <(stat -c '%u %a' "$TARGET")
if [ "$owner" != 0 ] || (( (8#$mode & 8#022) != 0 )); then
  echo '/usr/bin/bwrap must be root-owned and not group/world writable.' >&2
  exit 1
fi
printf '%s\n' 'Scope: this userns permission applies to every use of /usr/bin/bwrap.'

# Private workspace scratch, removed even on failure. No privileged change until
# the exact generated profile has passed apparmor_parser's syntax check.
mkdir -p "$ROOT/var"
tmpDir="$(mktemp -d "$ROOT/var/sandbox-profile.XXXXXX")"
trap 'rm -rf -- "$tmpDir"' EXIT
profile="$tmpDir/niffler-bwrap"
cat > "$profile" <<'EOF'
# Managed by Niffler install-sandbox-profile.sh. Applies to ALL system bwrap uses.
# Allows user namespace creation, not host privilege elevation or confinement.
abi <abi/4.0>,
include <tunables/global>

profile niffler-bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/niffler-bwrap>
}
EOF
if [ "$DRY_RUN" = 1 ]; then
  printf 'Would install and load %s:\n' "$PROFILE_PATH"
  cat "$profile"
  exit 0
fi
if ! command -v apparmor_parser >/dev/null; then
  echo 'apparmor_parser not found; install the AppArmor tooling first.' >&2
  exit 1
fi
apparmor_parser -Q -T "$profile"
if [ -e "$PROFILE_PATH" ]; then
  # Preserve a different operator-managed profile; do not overwrite it blindly.
  if ! cmp -s "$profile" "$PROFILE_PATH"; then
    echo "$PROFILE_PATH differs; review/remove it manually before installation." >&2
    exit 1
  fi
else
  run install -m 0644 "$profile" "$PROFILE_PATH"
fi
if ! run apparmor_parser -r "$PROFILE_PATH"; then
  echo "Profile load failed; $PROFILE_PATH remains for diagnosis. No sandbox success claimed." >&2
  exit 1
fi
printf 'Profile loaded. This is NOT proof of confinement. Verify with:\n  %s/var/bin/niffler-sandbox probe\n  make test-sandbox\n' "$ROOT"
