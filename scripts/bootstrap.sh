#!/usr/bin/env bash
# bootstrap.sh — the one-line Niffler installer.
#
#   curl -fsSL https://raw.githubusercontent.com/gokr/niffler/main/scripts/bootstrap.sh | bash
#
# Finds or creates the clone, installs platform prerequisites, builds core +
# components, seeds .env, and installs the PATH entries including the
# niffler-tui client wrapper — then offers the optional extras (`make
# install-lsp`, `make install-tools`, `make install-jev`) one by one, each
# defaulting to no. Idempotent: safe to re-run at any point.
#
# Nothing happens without an explanation, and nothing in $HOME is created
# before consent: it asks — accept the default location (~/niffler), type
# another one, or abort. Non-interactive runs pass the location explicitly:
#
#   curl -fsSL .../bootstrap.sh | bash -s -- /where/you/want/niffler
#
# This script only orchestrates the Makefile front door (`make setup`,
# `make build`, `make install-tui`, and on request the optional `make
# install-lsp` / `install-tools` / `install-jev`) — it invents no build or
# install logic of its own (the PATH-entry logic lives in scripts/install.sh
# behind `make install`).
#
# Arguments / environment:
#   --dry-run          print the plan and what would run, change nothing
#   <dir>              clone target (first non-flag argument; overrides all)
#   NIF_INSTALL_DIR    clone target when not already in one (default ~/niffler)
#   NIF_REF=stable|main|vX.Y.Z
#                      version to install without asking (stable = latest
#                      release tag, resolved from GitHub at run time)
#   NIF_BIN_DIR        where the PATH entries go (default ~/bin, see `make install`)
#   NIF_SKIP_SETUP=1   skip `make setup` (prerequisites already present)
#   NIF_WITH_NODE=1    install optional Node.js without asking (automation)
#   NIF_ASSUME_YES=1   skip the proceed prompt (automation; a no-tty run
#                      announces itself and proceeds regardless)
set -euo pipefail

say() { printf 'niffler-bootstrap: %s\n' "$*"; }
info() { printf 'niffler-bootstrap:   %s\n' "$*"; }
die() { printf 'niffler-bootstrap: %s\n' "$*" >&2; exit 1; }

# /dev/tty can exist with no controlling terminal (containers); probe by
# opening it, never by -r alone.
hasTty() { { : < /dev/tty; } 2>/dev/null; }

usage() {
  cat <<'EOF'
usage: bootstrap.sh [--dry-run] [<dir>]

  curl -fsSL .../scripts/bootstrap.sh | bash
  curl -fsSL .../scripts/bootstrap.sh | bash -s -- /where/you/want/niffler

 Adopts the checkout you run it in, or clones Niffler (asking: the latest
 stable release or latest main — NIF_REF pins either — and before creating
 ~/niffler: <dir> or NIF_INSTALL_DIR pick the location), installs every
 missing prerequisite (git, make, Go — and asks about optional Node.js, for
 npx skills / npm MCP servers / TypeScript components), then runs make
 setup, make build and make install-tui, and finally offers the optional
 extras (make install-lsp, install-tools, install-jev) one by one — each an
 explicit [y/N], Enter skips. Idempotent.
EOF
}

DRY_RUN=0
TARGET="${NIF_INSTALL_DIR:-}"
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help|-h) usage; exit 0 ;;
    *) TARGET="$arg" ;;
  esac
done

run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf 'niffler-bootstrap:   would run: %s\n' "$*"
  else
    # Children never touch our stdin: under `curl | bash` it IS the script
    # stream (a debconf prompt inside apt would eat the remaining lines).
    "$@" < /dev/null
  fi
}

# Root, or sudo for the privileged installs below. Defined once, at the top:
# every step uses $SUDO and `set -u` dies on an unset one (a re-run that
# skips the prerequisite block used to hit exactly that).
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

# Always say up front exactly what is about to happen.
say "Niffler installer — the plan, five steps:"
info "1. find or create the clone   (asks: stable release or main, and where to"
info "                              put ~/niffler; installs git, make, Go — and"
info "                              asks about optional Node.js)"
info "2. make setup                 the Nim toolchain + nimble packages"
info "3. make release               core + every component into var/bin"
info "4. seed .env                  provider/API-key settings — only if missing"
info "5. make install-tui           PATH entries (NIF_BIN_DIR, else auto-detected): niffler,"
info "                              niffler-cli, niffler-console + the niffler-tui wrapper"
info "                              (niffler-prefixed names only — component binaries never shadow Unix tools)"
info "then optional extras, each asked one by one ([y/N] — Enter skips):"
info "                  make install-lsp    language servers for the lsp component"
info "                  make install-tools  the agent CLI toolkit (jq, yq, ripgrep, fd, bat, ...)"
info "                  make install-jev    the Von runtime behind the jev advisor (~5.4 GB)"
[ "$DRY_RUN" = 1 ] && say "(dry run — nothing will be changed)"
echo

# One confirmation before anything happens. Under `curl | bash` stdin is the
# script stream itself, so read the answer from /dev/tty. Without a tty
# (automation), announce and proceed; NIF_ASSUME_YES=1 skips the pause.
if [ "$DRY_RUN" = 0 ] && [ -z "${NIF_ASSUME_YES:-}" ]; then
  if hasTty; then
    printf 'niffler-bootstrap: proceed with this plan? [Y/n] '
    answer=""
    read -r answer </dev/tty 2>/dev/null || answer=""
    case "$answer" in
      ""|[Yy]*) ;;
      *) die "aborted before touching anything" ;;
    esac
  else
    say "no tty to ask — proceeding with the plan above (NIF_ASSUME_YES=1 skips this note)"
  fi
fi

REPO_URL="https://github.com/gokr/niffler.git"

# Step 1 — consent to the location first (zero side effects before it), then
# make sure git + make exist on a pristine machine, then find or make the clone.
if [ -f niffler.nimble ] && [ -d .git ]; then
  ROOT="$(pwd)"
  say "step 1/5 — adopting this checkout as the instance home: $ROOT (no clone needed)"
else
  ROOT="${TARGET:-$HOME/niffler}"
  if [ ! -d "$ROOT/.git" ] && [ -z "$TARGET" ]; then
    # Read the answer from /dev/tty, never stdin: under `curl | bash` stdin
    # is the script stream itself.
    if [ "$DRY_RUN" = 0 ] && hasTty; then
      printf 'niffler-bootstrap: step 1/5 — clone into %s? [Y/n, or type another path] ' "$ROOT"
      answer=""
      read -r answer </dev/tty 2>/dev/null || answer=""
      case "$answer" in
        ""|[Yy]*) ;;
        [Nn]*) die "aborted before creating the clone — re-run with a location: curl ... | bash -s -- /where/you/want/it" ;;
        *) ROOT="${answer/#\~/$HOME}" ;;
      esac
    else
      say "step 1/5 — no tty to ask; target is $ROOT (pass a path or NIF_INSTALL_DIR to choose)"
    fi
  else
    say "step 1/5 — clone location: $ROOT"
  fi

  missing=""
  for tool in git make curl; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
  done
  if [ -n "$missing" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      say "step 1/5 — pristine machine, installing:$missing (apt)"
      run $SUDO apt-get update
      run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $missing ca-certificates
    else
      die "missing:$missing — install them first. macOS: xcode-select --install (plus Homebrew from brew.sh); Linux: your package manager. Then re-run."
    fi
  fi

  if ! command -v go >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
      say "step 1/5 — would install Go from go.dev (current stable)"
    elif command -v brew >/dev/null 2>&1; then
      say "step 1/5 — installing Go (brew)"
      run brew install go
    elif command -v apt-get >/dev/null 2>&1; then
      say "step 1/5 — installing Go from go.dev (current stable)"
      GOV="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -1)"
      [ -n "$GOV" ] || die "cannot resolve the current Go version from go.dev — install Go manually: https://go.dev/dl"
      ARCH="$(dpkg --print-architecture)"
      run curl -fsSL "https://go.dev/dl/${GOV}.linux-${ARCH}.tar.gz" -o /tmp/niffler-go.tgz
      run $SUDO rm -rf /usr/local/go
      run $SUDO tar -C /usr/local -xzf /tmp/niffler-go.tgz
      run $SUDO ln -sf /usr/local/go/bin/go /usr/local/bin/go
      run $SUDO ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
    else
      die "Go is missing — brew install go (macOS), or install from https://go.dev/dl, then re-run"
    fi
  fi

  # Node is OPTIONAL: Niffler itself is Nim + Go — core, every component and
  # the TUI build without it. It earns its place for npx skills, npm-based
  # MCP servers and TypeScript components — so ask, and default to no.
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    wantNode=""
    if [ -n "${NIF_WITH_NODE:-}" ]; then
      wantNode=1
      say "step 1/5 — installing Node.js (NIF_WITH_NODE=1)"
    elif [ "$DRY_RUN" = 1 ]; then
      say "step 1/5 — would ask about optional Node.js ([y/N] — npx skills, npm MCP servers, TypeScript components)"
    elif hasTty; then
      printf 'niffler-bootstrap: Node.js is not needed for Niffler itself but is useful for\n  installing skills with npx, installing some MCP servers, and making Niffler\n  components in TypeScript. Install it anyway? [y/N] '
      answer=""
      read -r answer </dev/tty 2>/dev/null || answer=""
      case "$answer" in
        [Yy]*) wantNode=1 ;;
        *) say "step 1/5 — skipping optional Node.js (NIF_WITH_NODE=1 whenever you want it)" ;;
      esac
    else
      say "step 1/5 — no tty to ask — skipping optional Node.js (NIF_WITH_NODE=1 to include)"
    fi
    if [ -n "$wantNode" ]; then
      if command -v brew >/dev/null 2>&1; then
        say "step 1/5 — installing Node.js (brew)"
        run brew install node
      elif command -v apt-get >/dev/null 2>&1; then
        say "step 1/5 — installing Node.js (apt; switching to NodeSource 22 only if apt's node is older than 20)"
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
        nodeMajor="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
        if [ "$nodeMajor" -lt 20 ] 2>/dev/null; then
          say "step 1/5 — apt shipped Node $nodeMajor — adding the NodeSource 22 repository"
          run $SUDO bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'
          run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
        fi
      else
        die "Node.js could not be installed here — install it from https://nodejs.org (or brew) and re-run"
      fi
    fi
  fi

  # Version: the latest stable release tag (resolved from GitHub), or latest
  # main. NIF_REF skips the question; an existing checkout keeps whatever it
  # has — a tag checkout is a pin (a release tag never moves; delete the
  # clone or pass NIF_REF=main to change versions).
  REF="${NIF_REF:-}"
  if [ -d "$ROOT/.git" ]; then
    :
  elif [ -n "$REF" ]; then
    say "step 1/5 — installing '$REF' (NIF_REF)"
  elif [ "$DRY_RUN" = 1 ]; then
    say "step 1/5 — would ask: the latest stable release [S] (recommended), or the latest development from main [m]?"
  elif hasTty; then
    printf 'niffler-bootstrap: Install the latest stable release (recommended),\n  or the latest development from main? [S/m] '
    answer=""
    read -r answer </dev/tty 2>/dev/null || answer=""
    case "$answer" in
      [Mm]*) REF=main ;;
      *) REF=stable ;;
    esac
  else
    REF=stable
    say "step 1/5 — no tty to ask — installing the stable release (NIF_REF=main for development)"
  fi
  if [ "$REF" = "stable" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      REF="latest-release-tag"
    else
      REF="$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null | awk '{print $2;}' | sed 's#refs/tags/##' | grep -E '^v[0-9]' | sort -V | tail -1)"
      [ -n "$REF" ] || die "cannot resolve the latest release tag from GitHub — pass NIF_REF=main or NIF_REF=vX.Y.Z"
    fi
    say "step 1/5 — stable release: $REF"
  fi

  if [ -d "$ROOT/.git" ]; then
    PINNED=""
    if [ -z "$(git -C "$ROOT" symbolic-ref -q HEAD 2>/dev/null)" ]; then
      PINNED="$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || true)"
    fi
    if [ -n "$PINNED" ]; then
      say "step 1/5 — reusing the existing clone at $ROOT — pinned at $PINNED"
      info "a release tag never moves; delete $ROOT or pass NIF_REF=main to change versions"
    else
      info "reusing the existing clone at $ROOT — updating it (git pull --ff-only)"
      run git -C "$ROOT" pull --ff-only || info "git pull skipped (local changes or offline) — continuing with the clone as-is"
    fi
  else
    if [ "$REF" = "main" ]; then
      info "cloning $REPO_URL (latest development)"
      run git clone "$REPO_URL" "$ROOT"
    else
      info "cloning $REPO_URL at $REF (stable)"
      run git clone --branch "$REF" --depth 1 "$REPO_URL" "$ROOT"
    fi
  fi
  if [ "$DRY_RUN" = 1 ]; then
    say "(dry run — would continue inside $ROOT)"
  else
    cd "$ROOT" || die "cannot enter $ROOT"
  fi
fi

if [ "$DRY_RUN" = 0 ] && ! command -v make >/dev/null 2>&1; then
  die "make is required (step 1 should have installed it)"
fi

# Step 2 — platform prerequisites.
if [ "${NIF_SKIP_SETUP:-0}" = "1" ]; then
  say "step 2/5 — skipped (NIF_SKIP_SETUP=1): make setup would install prerequisites"
else
  say "step 2/5 — make setup: Nim toolchain + nimble packages"
  if [ "$DRY_RUN" = 1 ]; then
    run make setup
  elif make setup < /dev/null; then
    :
  else
    die "make setup failed — see the output above; make doctor in the clone reports what is missing. Fix and re-run (this script is idempotent)."
  fi
fi

# Step 3 — the build. Release, not debug: this is the binary the user will
# run. `make build` compiles debug (checks on, timing lanes available) and is
# what developers want in the clone; the install path ships optimized.
say "step 3/5 — make release: building core + every component into var/bin (a few minutes)"
run make release

# Step 4 — seed .env so the harness has a model to talk to.
if [ ! -f .env ]; then
  say "step 4/5 — seeding .env from .env.example"
  run cp .env.example .env
  info "open .env and add NIF_OPENAI_API_KEY (or your provider's settings) before chatting"
else
  say "step 4/5 — .env already present, leaving it alone"
fi

# Step 5 — PATH entries + the terminal client wrapper.
say "step 5/5 — make install-tui: installing PATH entries + the niffler-tui wrapper"
run make install-tui

# Optional extras — genuinely optional add-ons, offered one by one and
# defaulting to no (bare Enter skips every one): the harness runs fine
# without them, and the skip path always names the make target so nothing is
# lost by pressing Enter. A no-tty run (automation) skips each with that
# note; --dry-run prints what would be asked. A failed optional install is
# never fatal here — this is the end of an otherwise successful install.
offerExtra() {
  # offerExtra <make target> <one-line what it is> [tty]
  # "tty" runs make with /dev/tty as stdin — install-lsp asks its
  # per-language questions on stdin and would otherwise see none.
  local target="$1" what="$2" answer=""
  if [ "$DRY_RUN" = 1 ]; then
    say "would ask about optional 'make $target' ([y/N] — $what)"
    return 0
  fi
  if ! hasTty; then
    say "no tty to ask — skipping optional 'make $target' ($what); run it whenever you want"
    return 0
  fi
  printf 'niffler-bootstrap: optional — %s\n  make %s? [y/N] ' "$what" "$target"
  read -r answer </dev/tty 2>/dev/null || answer=""
  case "$answer" in
    [Yy]*)
      say "running make $target"
      if [ "${3:-}" = "tty" ]; then
        make "$target" < /dev/tty || info "make $target reported problems — it is optional; re-run it any time"
      else
        make "$target" < /dev/null || info "make $target reported problems — it is optional; re-run it any time"
      fi
      ;;
    *) say "skipped — run 'make $target' whenever you want it" ;;
  esac
}

echo
say "optional extras — every one of these is optional; Enter (the default) skips:"
offerExtra install-lsp "language servers for the lsp component (Go/Nim/TS + per-language y/n)" tty
offerExtra install-tools "the agent CLI toolkit for bash: jq, yq, ripgrep, fd, fzf, bat, tree, htop, wget, zip, unzip, sqlite3"
if [ -x var/jev-venv/bin/von ]; then
  say "optional 'make install-jev' — Von is already installed ('make von-up' enables the launcher)"
else
  offerExtra install-jev "the Von runtime behind the jev advisor (~5.4 GB; 'make von-up' enables it)"
fi

echo
say "all done. what now:"
info "1. put a model API key in .env (step 4) if you have not already"
info "2. run: niffler-tui — the terminal chat client; it boots the harness on demand"
info "'niffler' by itself is the admin shell (status, catalog, sessions — no chat)"
info "full manual: docs/MANUAL.md · problems: make doctor"
