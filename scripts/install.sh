#!/usr/bin/env bash
# install.sh — put Niffler on the user's PATH after a fresh clone +
# `make build`: symlinks for the admin shell and bus tools, the desktop UI
# when built, and (on request) the niffler-tui plugin as the terminal client.
#
# Only niffler-prefixed names are ever installed — never component binaries
# (grep, git, edit, bash, ...), so adding this to PATH cannot shadow Unix
# tools. Component binaries stay in <root>/var/bin.
#
# Usage:
#   make install                     # interactive: asks about niffler-tui
#   make install WITH_TUI=1          # non-interactive: also install the tui
#   make install FORCE=1             # reinstall the plugin even if present
#   make install NIF_BIN_DIR=~/bin   # explicit bin dir (auto-detected else)
#   make uninstall                   # remove the PATH entries again
# When the plugin is already installed, the dance first tries plugin_install
# (a record whose checkout vanished self-heals there) and falls back to
# plugin_update, which repairs a live checkout with a missing binary.
# Env: NIF_BOOT_TIMEOUT_S (default 300) — how long the plugin install waits
#      for the isolated harness boot before giving up.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"

log()  { printf 'install: %s\n' "$*"; }
warn() { printf 'install: WARNING: %s\n' "$*" >&2; }
die()  { printf 'install: %s\n' "$*" >&2; exit 1; }

# Plugin-install dance state (globals so the EXIT trap sees them even if
# die() fires mid-dance); DANCE_PID empty means there is nothing to clean.
DANCE_PID="" DANCE_URL_FILE="" DANCE_SAVED=""
cleanup_dance() {
  if [ -n "$DANCE_PID" ]; then
    kill -TERM "$DANCE_PID" 2>/dev/null || true
    wait "$DANCE_PID" 2>/dev/null || true
    DANCE_PID=""
  fi
  if [ -n "$DANCE_URL_FILE" ]; then
    if [ -n "$DANCE_SAVED" ]; then printf '%s\n' "$DANCE_SAVED" > "$DANCE_URL_FILE"
    else rm -f "$DANCE_URL_FILE"; fi
  fi
}

# --------------------------------------------------------------------------
# bin dir: explicit override wins, then the first existing + writable user
# dir already on PATH, else ~/.local/bin is created (with a PATH warning).
BIN_DIR="${NIF_BIN_DIR:-}"
if [ -z "$BIN_DIR" ]; then
  for d in "$HOME/.local/bin" "$HOME/bin" /opt/homebrew/bin /usr/local/bin; do
    case ":$PATH:" in *":$d:"*) ;; *) continue ;; esac
    if [ -d "$d" ] && [ -w "$d" ]; then BIN_DIR="$d"; break; fi
  done
fi
if [ -z "$BIN_DIR" ]; then
  mkdir -p "$HOME/.local/bin"
  BIN_DIR="$HOME/.local/bin"
fi
mkdir -p "$BIN_DIR"
case ":$PATH:" in *":$BIN_DIR:"*) ;; *)
  warn "$BIN_DIR is not on PATH in this shell — but on Ubuntu that fixes itself:"
  warn "  the default ~/.profile adds ~/.local/bin to PATH at login once the dir"
  warn "  exists (log back in, or: source ~/.profile). Right now: export PATH=\"$BIN_DIR:\$PATH\""
  warn "  (system-wide instead: sudo make install NIF_BIN_DIR=/usr/local/bin)" ;;
esac

# --------------------------------------------------------------------------
# The clone is the home of the instance and its .env is the master config.
# Generate a starter on fresh installs: the harness owns the well-known home
# port (4222) unless another clone already runs there — in which case core
# boots isolated and says so loudly. Existing env in the shell always wins.
if [ ! -f "$ROOT/.env" ] && [ "$MODE" = "" ]; then
  cat > "$ROOT/.env" <<'EOF'
# Niffler master config for this clone (scripts/install.sh starter).
# Every value here can be overridden by the process environment.

# Home bus: this clone claims nats://127.0.0.1:4222 when free, attaches to
# its own core there, and yields loudly (isolated random port) if another
# harness owns the port. Delete or set NIF_NATS_SPAWN=1 for a dev clone
# that should never touch the shared port.
NIF_NATS_URL=nats://127.0.0.1:4222

# LLM access (components load these via sdk/dotenv; never commit them):
# NIF_OPENAI_API_KEY=sk-...
# NIF_OPENAI_BASE_URL=https://api.openai.com/v1
# NIF_OPENAI_MODEL=gpt-4o-mini
EOF
  log "generated starter $ROOT/.env — add your API key for LLM access"
fi

if [ "$MODE" = "--uninstall" ]; then
  for n in niffler niffler-cli niffler-console niffler-tui; do
    [ -e "$BIN_DIR/$n" ] || [ -L "$BIN_DIR/$n" ] || continue
    rm -f "$BIN_DIR/$n"
    log "removed $BIN_DIR/$n"
  done
  # niffler-ui only when it is a symlink made HERE: an older version of this
  # script linked the (now experimental, external) desktop UI. A real binary or
  # a launcher someone else installed is left alone.
  if [ -L "$BIN_DIR/niffler-ui" ]; then
    rm -f "$BIN_DIR/niffler-ui"
    log "removed $BIN_DIR/niffler-ui"
  fi
  log "uninstall complete (bin dir: $BIN_DIR)"
  exit 0
fi
[ "$MODE" = "" ] || die "unknown option: $MODE (expected --uninstall or nothing)"

[ -x "$ROOT/var/bin/niffler" ] || die "var/bin/niffler missing — run 'make build' first."
[ -x "$ROOT/var/bin/cli" ] || die "var/bin/cli missing — run 'make build' first."

# --------------------------------------------------------------------------
# plain symlinks — niffler-prefixed names only.
link() {
  ln -sfn "$ROOT/var/bin/$2" "$BIN_DIR/$1"
  log "$BIN_DIR/$1 -> var/bin/$2"
}
link niffler niffler
link niffler-cli cli
link niffler-console console
# No niffler-ui here: the Wails desktop UI is an experimental, unmaintained side
# project in its own repository (gokr/niffler-ui) and this harness neither builds
# nor installs it. niffler-tui is the client that ships.

# ---------------------------------------------------------------------------
# niffler-tui plugin (separate repo, gokr/niffler-tui — an example of how
# anyone can build a UI for Niffler). Opt-in: the wrapper is installed only
# once the plugin binary exists; installing it needs a short harness dance.
have_tui() { [ -x "$ROOT/var/bin/tui" ]; }

ask() {
  # Prompt only on a real terminal; anything else (CI, pipes) defaults to No.
  [ -t 0 ] || return 1
  local reply=""
  printf 'install: %s ' "$1"
  read -r -t 120 reply </dev/tty 2>/dev/null || read -r -t 120 reply || true
  case "$reply" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

gen_wrapper() {
  sed "s|@ROOT@|$ROOT|g" "$ROOT/scripts/niffler-tui.in" > "$BIN_DIR/niffler-tui"
  chmod +x "$BIN_DIR/niffler-tui"
  log "$BIN_DIR/niffler-tui (wrapper — boots $ROOT on demand)"
}

install_tui_plugin() {
  [ -f "$ROOT/.env" ] || \
    warn "no .env in $ROOT — the harness will boot without an LLM API key"

  DANCE_URL_FILE="$ROOT/var/nats-url"
  DANCE_SAVED=""
  [ -f "$DANCE_URL_FILE" ] && DANCE_SAVED="$(cat "$DANCE_URL_FILE")"

  # Isolated, auto-approved boot: NIF_NATS_URL= beats any .env, NIF_NATS_SPAWN=1
  # guarantees a private random-port bus (never touches a running harness),
  # NIF_AUTO_APPROVE=1 bypasses the plugin_install terminal approval prompt,
  # which has no human attached in this headless boot. The core is stopped
  # right after the install; approval enforcement is untouched at runtime.
  log "installing the niffler-tui plugin via an isolated harness boot ..."
  mkdir -p "$ROOT/var/logs"
  NIF_NATS_URL='' NIF_NATS_SPAWN=1 NIF_AUTO_APPROVE=1 \
    "$ROOT/var/bin/niffler" </dev/null >>"$ROOT/var/logs/core.log" 2>&1 &
  DANCE_PID=$!
  trap cleanup_dance EXIT

  # The boot spawns nats-server, core and every component — a few seconds on a
  # fast machine, minutes only on a machine that is really swapping.
  # NIF_BOOT_TIMEOUT_S tunes it; one probe a second (a 5/s spawn-storm of the
  # CLI only slows the boot we are waiting for), and the heartbeat names the
  # phase so a slow wait is diagnosable.
  local boot_s="${NIF_BOOT_TIMEOUT_S:-300}"
  local ok="" start=$SECONDS nextNote=30 tries=$boot_s
  for _ in $(seq 1 "$tries"); do
    if [ -f "$DANCE_URL_FILE" ] && \
       NIF_NATS_URL="$(cat "$DANCE_URL_FILE")" "$ROOT/var/bin/cli" catalog >/dev/null 2>&1; then
      ok=1; break
    fi
    if [ $(( SECONDS - start )) -ge "$nextNote" ]; then
      log "still waiting ($(( SECONDS - start ))s of ${boot_s}s) — bus file $([ -f "$DANCE_URL_FILE" ] && echo present || echo 'not written yet'), ~28 processes starting"
      nextNote=$(( nextNote + 30 ))
    fi
    sleep 1
  done
  if [ -z "$ok" ]; then
    warn "harness did not come up in ${boot_s}s — last lines of $ROOT/var/logs/core.log:"
    tail -25 "$ROOT/var/logs/core.log" 2>/dev/null | sed 's/^/  | /' >&2 || true
    warn "if the log ends abruptly, suspect the OOM killer on a small VM:"
    warn "  free -h; dmesg -T | grep -i -E 'oom|killed process' | tail"
    warn "if it mentions a store lock or a live bus, a previous harness is still around:"
    warn "  make down   (or make down-here), then re-run"
    die "harness did not come up — see $ROOT/var/logs/core.log"
  fi

  # First try a plain install. A record whose checkout is still there makes
  # plugin_install refuse ("already installed"), and the repair for that is
  # plugin_update: a branch pin pulls/rebuilds in place, and the repair-build
  # path replaces a missing interactive binary without a reinstall.
  local tui_url
  tui_url="$(cat "$DANCE_URL_FILE")"
  if NIF_NATS_URL="$tui_url" "$ROOT/var/bin/cli" install \
       --timeout:600 gokr/niffler-tui; then
    log "niffler-tui plugin installed"
  elif NIF_NATS_URL="$tui_url" "$ROOT/var/bin/cli" call plugin_update \
         '{"package":"niffler-tui"}'; then
    log "niffler-tui plugin updated (existing install refreshed)"
  else
    die "plugin install/update failed — see $ROOT/var/logs/core.log"
  fi

  cleanup_dance
  trap - EXIT
}

if have_tui && [ "${FORCE:-}" != "1" ]; then
  gen_wrapper
elif [ "${WITH_TUI:-}" = "1" ] || ask "Install the niffler-tui plugin (gokr/niffler-tui) as the terminal client? [y/N]"; then
  install_tui_plugin
  gen_wrapper
else
  log "skipping niffler-tui (add later: make install WITH_TUI=1)"
fi

log "done — bin dir: $BIN_DIR"
log "run 'niffler-tui' (terminal chat) or 'niffler' (admin shell)"
