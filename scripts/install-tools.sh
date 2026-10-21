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
#   gh        the GitHub CLI: open pull requests, inspect runs, read issues.
#             Deliberately its OWN entry rather than folded into the bulk set,
#             because the binary alone does nothing: every API call needs a
#             token, and it cannot reuse an SSH key (SSH authenticates git
#             transport only, the REST API wants a bearer token). See
#             docs/MANUAL.md "GitHub CLI and a token" for the setup, and note
#             that install-tools never creates or stores a credential.
#   trafilatura
#             better HTML-to-text for the fetch component (strips nav/
#             boilerplate); without it fetch falls back to its built-in
#             extractor. Not available as a distro package — installed as an
#             isolated Python CLI via uv (preferred), pipx, or pip --user.
#             Optional, and the only tool here that asks before installing
#             (default yes on a terminal).
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

# Optional filters: `install-tools.sh rg` installs only that entry from the
# table below. `make setup` uses it to guarantee ripgrep, which the
# bus-contract suite's grep/files tests shell out to (the component degrades
# gracefully without it, the tests do not), without dragging the whole
# toolkit into a prerequisite install. With no arguments every entry is
# considered, exactly as before.
only=("$@")
wanted() {
  [ "${#only[@]}" -eq 0 ] && return 0
  local name
  for name in "${only[@]}"; do
    [ "$name" = "$1" ] && return 0
  done
  return 1
}

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
gh|gh|gh|
'

while IFS='|' read -r cmd aptpkg brewpkg alt; do
  [ -n "$cmd" ] || continue
  wanted "$cmd" || continue
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

# ---------------------------------------------------------------------------
# trafilatura — optional, and the one tool that prompts (default yes). It is a
# Python CLI, so it comes from uv/pipx/pip rather than the package manager, and
# the fetch component prefers it for HTML extraction but works without it.
haveTrafilatura() {
  have trafilatura && return 0
  [ -x "$BIN/trafilatura" ] && return 0
  return 1
}

trafilaturaWanted() {
  case "${WITH_TRAFILATURA:-}" in
    1 | yes | YES | true | y | Y) return 0 ;;
    0 | no | NO | false | n | N) return 1 ;;
  esac
  # Ask only on a real terminal, and default to yes: an empty reply installs.
  # Anything non-interactive (CI, pipes, make install-tools in a script)
  # skips unless WITH_TRAFILATURA=1 asked for it — never block a build on a
  # prompt nobody can answer.
  [ -t 0 ] || return 1
  local reply=""
  printf 'install: install trafilatura (better HTML-to-text for fetch)? [Y/n] '
  read -r -t 120 reply </dev/tty 2>/dev/null || read -r -t 120 reply || true
  case "$reply" in
    n | N | no | No | NO) return 1 ;;
    *) return 0 ;;
  esac
}

installTrafilatura() {
  # One best-effort isolated install; the first mechanism that provides the
  # binary wins (0 = success).
  if have uv && uv tool install trafilatura >/dev/null 2>&1; then return 0; fi
  if have pipx && pipx install trafilatura >/dev/null 2>&1; then return 0; fi
  for c in pip3 pip python3; do
    if have "$c" && "$c" -m pip install --user trafilatura >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

if ! wanted trafilatura; then
  : # a filtered run that did not ask for it
elif haveTrafilatura; then
  ok trafilatura
elif trafilaturaWanted; then
  if installTrafilatura && haveTrafilatura; then
    new trafilatura
  else
    failed=$((failed+1))
    fail trafilatura "'uv tool install trafilatura' did not provide it (optional — fetch uses its built-in extractor)"
  fi
else
  echo "skip trafilatura — optional; later: make install-tools WITH_TRAFILATURA=1"
fi

echo
if [ "$failed" -gt 0 ] && [ "${#only[@]}" -gt 0 ] && [ "${only[0]}" = "rg" ]; then
  # The filtered run `make setup` depends on: ripgrep is a TEST prerequisite,
  # not an optional nicety, so a failure here must be loud and fatal.
  echo "install-tools: ripgrep is required for 'make test' (the grep/files tests"
  echo "               shell out to rg) — install it before running the gate"
  exit 1
elif [ "$installed" -gt 0 ]; then
  echo "install-tools: $installed newly installed — none of these are required;"
  echo "               the agent simply falls back to coreutils without them"
elif [ "$failed" -gt 0 ]; then
  echo "install-tools: $failed still missing after failed installs — see the FAIL lines above;"
  echo "               none of them are required, install manually when you want them"
elif [ "${#only[@]}" -gt 0 ]; then
  echo "install-tools: nothing to do — ${only[*]} already present"
else
  echo "install-tools: nothing to do — the whole toolkit was already present"
fi
