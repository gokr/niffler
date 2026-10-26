#!/usr/bin/env bash
# Install Kokoro-82M (TTS) into a private venv — the better-sounding option.
#
#   bash tools/fetch-kokoro.sh              # venv + model (~360 MB total)
#   bash tools/fetch-kokoro.sh --voices     # also list the 54 voice ids
#
# Why a venv in ~/.cache instead of the repo: the model is 340 MB and the deps
# (onnxruntime, numpy) are ~100 MB; both are machine-local caches, not source.
# Nothing here is needed for Piper, and `make`/the repo build never touch it.
set -euo pipefail

CACHE="${NIF_KOKORO_HOME:-$HOME/.cache/niffler-movie}"
VENV="$CACHE/venv"; MODELS="$CACHE/models"
mkdir -p "$MODELS"

if [ ! -x "$VENV/bin/python" ]; then
  echo "→ creating venv in $VENV"
  python3 -m venv "$VENV"
fi
echo "→ installing kokoro-onnx (onnxruntime + numpy)"
"$VENV/bin/pip" install -q --upgrade pip
"$VENV/bin/pip" install -q kokoro-onnx

for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  if [ ! -s "$MODELS/$f" ]; then
    echo "→ fetching $f"
    curl -fsSL -o "$MODELS/$f" \
      "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/$f"
  fi
done
echo "✓ kokoro ready: $MODELS"

if [ "${1:-}" = "--voices" ]; then
  "$VENV/bin/python" - <<'PY'
from kokoro_onnx import Kokoro
import os
d = os.path.expanduser("~/.cache/niffler-movie/models")
k = Kokoro(f"{d}/kokoro-v1.0.onnx", f"{d}/voices-v1.0.bin")
print(" ".join(sorted(k.get_voices())))
PY
fi

echo
echo "Render the film with it:"
echo "  node tools/render-voiceover.mjs --engine=kokoro --kokoro-voice=af_heart"
echo "Audition the voices first:"
echo "  node tools/render-voiceover.mjs --audition --engine=kokoro"
