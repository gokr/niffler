#!/usr/bin/env bash
# scripts/install-embed.sh — install a LOCAL nomic embedder for semantic
# memory, with no ollama and no daemon you have to babysit.
#
# Two files, ~107 MB, unpacked under $NIF_EMBED_DIR (default
# <repo>/var/embed). `rm -rf` is the uninstall:
#
#   llama-b<NNNNN>-bin-ubuntu-x64.tar.gz   23 MB   CPU llama.cpp build
#   nomic-embed-text-v1.5.Q4_K_M.gguf      84 MB   the model
#
# Ollama is deliberately NOT used: it is ~1.8 GB for the same shape (a daemon,
# a model store and a second package manager). docs/research/LOCAL-EMBEDDINGS.md
# §2/§8 records the measurements.
#
# Deliberately NOT part of `make setup`: a stock harness pays nothing for an
# optional runtime. Enable it afterwards with
#
#   make embed-up      # supervised runtime; configure provider separately
#   make embed-down    # stops it
#
# or point a provider at any OpenAI-compatible /embeddings endpoint yourself
# (docs/MANUAL.md "Local embeddings").
#
# Why the release lookup is not `releases/latest`: llama.cpp's latest tag
# carries ONE asset, `nightly-tag.txt` — no binaries. The builds live on rolling
# `b<NNNNN>` tags marked prerelease (~38 assets each), so this script resolves
# the newest tag that actually SHIPS the tarball it needs. That detail is the
# whole reason this is a script and not a one-liner.
#
#   NIF_EMBED_DIR      install directory (default <repo>/var/embed)
#   NIF_EMBED_PORT     port llama-server listens on (default 18100)
#   NIF_EMBED_CTX      context/slot size (default 2048 — see the warning below)
#   NIF_SKIP_MODEL=1   install the runner only (weights already present)
#
# The context warning is real and measured: the model card says 8192 tokens,
# but the GGUF's own metadata says 2048 and llama-server caps the slot to it.
# Raising -c past that without YaRN truncates silently (LOCAL-EMBEDDINGS §8).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="${NIF_EMBED_DIR:-$ROOT/var/embed}"
PORT="${NIF_EMBED_PORT:-18100}"
CTX=2048
MODEL_FILE="nomic-embed-text-v1.5.Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/0188c9bf409793f810680a5a431e7b899c46104c/$MODEL_FILE"
MODEL_SHA256="d4e388894e09cf3816e8b0896d81d265b55e7a9fff9ab03fe8bf4ef5e11295ac"
MODEL_REF="local-nomic-q4"

ok()  { echo "ok   $1"; }
skip() { echo "skip $1 — $2"; }
fail() { echo "FAIL $1 — $2"; }

mkdir -p "$DIR" || { fail "install" "cannot create $DIR"; exit 1; }

# --- platform --------------------------------------------------------------
# Only the CPU builds are fetched: a GPU build would pick a backend the host may
# not have, and embeddings on CPU are fast enough (a few ms per short input).
OS=$(uname -s)
ARCH=$(uname -m)
case "$OS:$ARCH" in
  Linux:x86_64)  ASSET_RE="bin-ubuntu-x64\.tar\.gz$" ;;
  Linux:aarch64) ASSET_RE="bin-ubuntu-arm64\.tar\.gz$" ;;
  Darwin:arm64)  ASSET_RE="bin-macos-arm64\.tar\.gz$" ;;
  Darwin:x86_64) ASSET_RE="bin-macos-x64\.tar\.gz$" ;;
  *)
    fail "platform" "no prebuilt llama.cpp runner for $OS/$ARCH; install llama.cpp yourself and run scripts/embed-server.sh against it"
    exit 1 ;;
esac

need() { command -v "$1" >/dev/null 2>&1; }
for tool in curl tar; do
  need "$tool" || { fail "prerequisites" "$tool is required"; exit 1; }
done

# --- the runner ------------------------------------------------------------
# Verified present AND runnable: a half-extracted tree answers --version with an
# error, and that must be repaired rather than trusted.
SERVER="$DIR/llama-server"
runner_ok() {
  [ -x "$SERVER" ] || return 1
  LD_LIBRARY_PATH="$DIR/runner${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" DYLD_LIBRARY_PATH="$DIR/runner${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" "$SERVER" --version >/dev/null 2>&1
}

if runner_ok; then
  ok "llama-server already installed ($("$SERVER" --version 2>&1 | head -1))"
else
  if ! need python3; then
    fail "runner" "python3 is required to resolve the newest llama.cpp release (JSON parsing)"
    exit 1
  fi
  echo "resolving the newest llama.cpp release that ships a $OS/$ARCH build ..."
  # Newest-first by tag; pick the first tag whose assets include our pattern.
  # `prerelease` is expected (every rolling build is), so it is not filtered.
  release_json=$(curl -fsSL --max-time 60 \
    "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30") || {
      fail "runner" "could not reach the GitHub API (network or rate limit)"; exit 1; }

  pick=$(printf '%s' "$release_json" | ASSET_RE="$ASSET_RE" python3 -c '
import json, os, re, sys
pattern = re.compile(os.environ["ASSET_RE"])
try:
    releases = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for rel in releases:
    for asset in rel.get("assets") or []:
        if pattern.search(asset.get("name", "")):
            print(rel["tag_name"], asset["name"], asset["browser_download_url"], asset.get("digest") or "")
            sys.exit(0)
sys.exit(2)
') || { fail runner 'could not resolve release'; exit 1; }
  case "$?" in
    0) : ;;
    2) fail "runner" "no llama.cpp release in the newest 30 ships a $OS/$ARCH build"; exit 1 ;;
    *) fail "runner" "could not parse the GitHub API response (rate limited?)"; exit 1 ;;
  esac
  set -- $pick
  TAG="$1"; ASSET="$2"; URL="$3"; DIGEST="${4:-}"
  [ "${DIGEST#sha256:}" != "$DIGEST" ] || { fail runner 'release asset has no SHA256 digest'; exit 1; }
  echo "  newest build: $TAG ($ASSET)"

  tmp=$(mktemp -d "$DIR/.download.XXXXXX") || exit 1
  trap 'rm -rf "$tmp"' EXIT
  if ! curl -fL --max-time 600 -o "$tmp/runner.tar.gz" "$URL"; then
    fail "runner" "download failed: $URL"; exit 1
  fi
  python3 - "$tmp/runner.tar.gz" "${DIGEST#sha256:}" <<'PYRUNNER'
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    h = hashlib.sha256()
    for chunk in iter(lambda: f.read(1048576), b''): h.update(chunk)
if h.hexdigest() != sys.argv[2]: raise SystemExit('runner SHA256 mismatch')
PYRUNNER
  if ! tar -xzf "$tmp/runner.tar.gz" -C "$tmp"; then
    fail "runner" "extract failed (corrupt archive?)"; exit 1
  fi
  # The tarball unpacks into a versioned directory containing bin/ + lib/.
  SRC=$(find "$tmp" -type f -name llama-server -perm -u+x | head -1)
  if [ -z "$SRC" ]; then
    fail "runner" "llama-server not found in the archive"
    exit 1
  fi
  BIN_DIR=$(dirname "$SRC")
  # Copy the whole tree: the CPU kernels are shared objects selected at load
  # time, so llama-server alone is not runnable.
  rm -rf "${DIR:?}/runner"
  mkdir -p "$DIR/runner"
  cp -a "$BIN_DIR"/. "$DIR/runner"/
  rm -f "$SERVER"
  ln -sf "$DIR/runner/llama-server" "$SERVER"
  printf '%s\n' "$TAG" > "$DIR/runner-version"
  if runner_ok; then
    ok "llama-server installed ($TAG)"
  else
    fail "runner" "the fetched binary does not run on this host"
    echo "     it needs its shared libraries: try"
    echo "     LD_LIBRARY_PATH=$DIR/runner $SERVER --version"
    exit 1
  fi
fi

# --- the weights -----------------------------------------------------------
if [ "${NIF_SKIP_MODEL:-0}" = 1 ] && [ -f "$DIR/$MODEL_FILE" ]; then
  skip "model" "NIF_SKIP_MODEL=1 and the weights are present"
elif [ -f "$DIR/$MODEL_FILE" ]; then
  ok "nomic weights already present ($(( $(wc -c < "$DIR/$MODEL_FILE") / 1048576 )) MB)"
else
  echo "downloading $MODEL_FILE (~84 MB) ..."
  if ! curl -fL --max-time 1800 --progress-bar -o "$DIR/$MODEL_FILE.part" "$MODEL_URL"; then
    rm -f "$DIR/$MODEL_FILE.part"
    fail "model" "download failed: $MODEL_URL"
    exit 1
  fi
  # A truncated GGUF loads with a cryptic ggml error, so check the size before
  # adopting it. The published file is 84106624 bytes.
  size=$(wc -c < "$DIR/$MODEL_FILE.part")
  if [ "$size" -lt 80000000 ]; then
    rm -f "$DIR/$MODEL_FILE.part"
    fail "model" "download is only $size bytes — truncated, not installing it"
    exit 1
  fi
  mv "$DIR/$MODEL_FILE.part" "$DIR/$MODEL_FILE"
  ok "nomic weights installed ($((size / 1048576)) MB)"
fi

# Verify existing as well as newly downloaded weights; size is not integrity.
python3 - "$DIR/$MODEL_FILE" "$MODEL_SHA256" <<'PYHASH'
import hashlib, sys
with open(sys.argv[1], 'rb') as f:
    h = hashlib.sha256()
    for chunk in iter(lambda: f.read(1048576), b''): h.update(chunk)
    actual = h.hexdigest()
if actual != sys.argv[2]:
    raise SystemExit('model SHA256 mismatch; refusing installed weights')
PYHASH

# --- how to run it ---------------------------------------------------------
cat <<EOF

ok   local embedder ready in $DIR

Start it (foreground) with:
  bash scripts/embed-server.sh

or run it under the harness:
  make embed-up        # supervised runtime; configure provider separately
  make embed-down      # stops it

It serves an OpenAI-compatible endpoint at:
  http://127.0.0.1:$PORT/v1
  model:    $MODEL_REF
  width:    768 dimensions
  window:   $CTX tokens

Window warning: the GGUF's own metadata caps the model at 2048 tokens, and
llama-server truncates silently past the slot unless YaRN is enabled. Keep
NIF_EMBED_CTX=2048 unless you know why you are raising it.

The provider record is keyless (a loopback baseUrl may omit apiKey):
  provider_add {nickname: "localnomic", baseUrl: "http://127.0.0.1:$PORT/v1",
                embedModel: "local-nomic-q4"}
EOF
