#!/usr/bin/env bash
# Foreground runtime, normally owned by the local-embed launcher component.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="${NIF_EMBED_DIR:-$ROOT/var/embed}"
export LD_LIBRARY_PATH="$DIR/runner${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export DYLD_LIBRARY_PATH="$DIR/runner${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec "$DIR/runner/llama-server" --model "$DIR/nomic-embed-text-v1.5.Q4_K_M.gguf" \
  --embedding --host 127.0.0.1 --port "${NIF_EMBED_PORT:-18100}" \
  --ctx-size 2048 --batch-size 2048 --ubatch-size 2048 \
  --alias local-nomic-q4
