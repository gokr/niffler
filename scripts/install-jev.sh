#!/usr/bin/env bash
# scripts/install-jev.sh — install the Von runtime behind the jev component
# defaults into var/jev-venv. Idempotent; a failure is non-fatal for the
# harness (a missing Von only means jev_suggest/jev_recommend fail and the
# shadow judge stays silent — one warning per absence episode).
#
# Deliberately NOT part of `make setup`: the runtime is ~5.4 GB including
# CUDA wheels and the model weights download on first serve, so it stays an
# opt-in like `make install-lsp` is for the language servers.
#
# uv itself is bootstrapped HOME-locally (no sudo, ~/.local/bin) when it is
# missing — fresh boxes have no pip/pipx to install it with.
#
#   NIF_JEV_VENV   venv directory (default <repo>/var/jev-venv)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENV="${NIF_JEV_VENV:-$ROOT/var/jev-venv}"

fail() { echo "FAIL $1 — $2"; }

if [ -x "$VENV/bin/von" ]; then
  if "$VENV/bin/von" --help >/dev/null 2>&1; then
    echo "ok   Von already installed in $VENV"
    echo "serve: $VENV/bin/von serve --model von-1.1 --device cpu \\"
    echo "       --host 127.0.0.1 --port 8000"
    echo "enable:  make von-up     (spawns the supervised launcher; persists"
    echo "                         across boots until 'make von-down')"
    exit 0
  fi
  fail "Von venv exists but its binary does not run" \
       "inspect $VENV or delete it and retry"
  exit 1
fi

# uv: fresh boxes have neither pip nor pipx (Ubuntu ships bare python3), so
# the old "pip install uv" hint was a dead end. Bootstrap the standalone
# installer instead — HOME-local, no sudo, ~10 MB — and only fall back to
# naming the manual commands when that fails too.
UV="$(command -v uv 2>/dev/null || true)"
if [ -z "$UV" ] && [ -x "$HOME/.local/bin/uv" ]; then UV="$HOME/.local/bin/uv"; fi
if [ -z "$UV" ]; then
  echo "uv is missing — installing it HOME-locally (no sudo; ~/.local/bin) ..."
  if curl -LsSf https://astral.sh/uv/install.sh 2>/dev/null \
       | env UV_INSTALL_DIR="$HOME/.local/bin" sh >/dev/null 2>&1 \
     && [ -x "$HOME/.local/bin/uv" ]; then
    UV="$HOME/.local/bin/uv"
    echo "ok   uv ($("$UV" --version 2>/dev/null))"
  else
    fail "uv is missing and the HOME-local installer failed" \
      "install uv by hand and retry: curl -LsSf https://astral.sh/uv/install.sh | sh   (or: sudo apt install pipx && pipx install uv)"
    exit 1
  fi
fi

# uv downloads a managed CPython 3.12 when the system lacks one.
echo "ok   creating the venv: $VENV (python 3.12)"
"$UV" venv "$VENV" --python 3.12 || {
  fail "uv venv failed" "run 'uv venv $VENV --python 3.12' by hand to see why"
  exit 1
}

echo "ok   installing von-sdk>=1.1.0 (~5.4 GB including CUDA wheels)"
"$UV" pip install --python "$VENV/bin/python" 'von-sdk>=1.1.0' || {
  fail "von-sdk install failed" \
       "retry: uv pip install --python '$VENV/bin/python' 'von-sdk>=1.1.0'"
  exit 1
}

if [ -x "$VENV/bin/von" ] && "$VENV/bin/von" --help >/dev/null 2>&1; then
  echo "ok   Von installed"
  echo "serve: $VENV/bin/von serve --model von-1.1 --device cpu \\"
  echo "       --host 127.0.0.1 --port 8000"
  echo "enable:  make von-up     (spawns the supervised launcher; persists"
  echo "                         across boots until 'make von-down')"
  echo "(the first serve downloads the model weights; jev's default"
  echo " NIF_JEV_URL matches this loopback endpoint)"
  exit 0
fi
fail "Von installed but its binary does not run" \
     "run '$VENV/bin/von --help' by hand to see why"
exit 1
