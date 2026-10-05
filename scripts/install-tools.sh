#!/usr/bin/env bash
# scripts/install-tools.sh — the agent CLI toolkit behind `make install-tools`:
# the small, constantly-reached-for command-line tools an LLM uses through the
# bash component (jq and friends). Idempotent per tool; failures are
# non-fatal — a missing tool only means the agent falls back to coreutils.
#
# The set, and why each is here:
#   jq        JSON on the command line (slice tool output, envelopes, API
#             results — the single most reached-for tool)
#   yq        YAML/XML with jq-style syntax (manifest.yaml, config files)
#   ripgrep   fast recursive search (rg)
#   fd        fast, friendly file finding (Debian ships it as fdfind)
#   fzf       fuzzy select over lists (pick files, sessions, history)
#   bat       syntax-highlighted cat (Debian ships it as batcat)
#   tree      directory overviews at a glance
#   htop      process monitoring beyond top
#   wget      one-file downloads
#   zip       pack archives
#   unzip     unpack archives
#   sqlite3   read the store database directly (var/store.db debugging)
#
# Installs from the platform package manager (apt on Debian/Ubuntu, brew on
# macOS); sudo is used only for the system package install. Debian's fd/bat
# renames get plain-name symlinks in ~/.local/bin so the names an agent
# expects to type work everywhere.
set -uo pipefail

BIN="$HOME/.local/bin"
installed=0
failed=0
updated=0

ok()   { echo "ok   $1"; }
new()  { echo "ok   $1"; installed=$((installed+1)); }
fail() { echo "FAIL $1 — $2"; }

have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(uname)" = "Darwin" ]; then PKGMGR=brew; else PKGMGR=apt; fi
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then SUDO=sudo; fi

installPkg() {
  # installPkg <package> — one best-effort package install (0 = success).
  if [ "$PKGMGR" = "brew" ]; then
    brew install "$1"
    return
  fi
  if [ "$updated" = 0 ]; then
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get update
    updated=1
  fi
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"
}

linkAs() {
  # linkAs <src> <alias> — Debian ships fd/bat as fdfind/batcat; give the
  # agent the upstream name it will actually type. Never shadows anything.
  have "$1" || return 0
  have "$2" && return 0
  mkdir -p "$BIN"
  ln -sf "$(command -v "$1")" "$BIN/$2"
  echo "note: $2 -> $(command -v "$1") (in $BIN)"
}

# command|apt package|brew formula|alternate binary (Debian renames; empty =
# same as command)
specs='
jq|jq|jq|
yq|yq|yq|
rg|ripgrep|ripgrep|
fd|fd-find|fd|fdfind
fzf|fzf|fzf|
bat|bat|bat|batcat
tree|tree|tree|
htop|htop|htop|
wget|wget|wget|
zip|zip|zip|
unzip|unzip|unzip|
sqlite3|sqlite3|sqlite3|
'

while IFS='|' read -r cmd aptpkg brewpkg alt; do
  [ -n "$cmd" ] || continue
  [ -n "$alt" ] || alt="$cmd"
  pkg="$aptpkg"
  [ "$PKGMGR" = "brew" ] && pkg="$brewpkg"
  if have "$cmd" || have "$alt"; then
    ok "$cmd"
    continue
  fi
  if installPkg "$pkg" && { have "$cmd" || have "$alt"; }; then
    new "$cmd"
  else
    failed=$((failed+1))
    fail "$cmd" "'$PKGMGR install $pkg' did not provide it (install manually when you want it)"
  fi
done <<< "$specs"

linkAs fdfind fd
linkAs batcat bat

echo
if [ "$installed" -gt 0 ]; then
  echo "install-tools: $installed newly installed — none of these are required;"
  echo "               the agent simply falls back to coreutils without them"
elif [ "$failed" -gt 0 ]; then
  echo "install-tools: $failed still missing after failed installs — see the FAIL lines above;"
  echo "               none of them are required, install manually when you want them"
else
  echo "install-tools: nothing to do — the whole toolkit was already present"
fi
