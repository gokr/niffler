#!/usr/bin/env bash
# Install a local, self-contained TTS engine for the movie's narration.
#
#   bash tools/fetch-piper.sh                 # piper + en_GB-alan-medium
#   bash tools/fetch-piper.sh en_US-ryan-high # a different voice
#   VOICE=en_US-lessac-medium bash tools/fetch-piper.sh
#
# Voice notes (all measured on this box, 30-word cue):
#   en_GB-alan-medium    125 wpm at default pace — warm, but slow and older
#   en_US-ryan-high      154 wpm, brighter/firmer; at --length_scale 0.85 ≈173
#                        wpm — the current default for this film
#   en_US-kusal-medium   ≈157 wpm at 0.85, light and quick (medium = fast to render)
#   en_US-kristin-medium / en_GB-cori-high   female alternatives
# The US voices are the younger-sounding ones; alan/cori are the older,
# more "documentary" timbre.
#
# Why Piper: it runs on CPU (≈8× faster than realtime here), needs no GPU, no
# account and no API key, and the model is 60 MB. The harness's own .env points
# NIF_OPENAI_BASE_URL at a provider without an /audio/speech endpoint, so a
# cloud TTS path cannot be the default — see the README's "Voice-over" section
# for the full comparison.
#
# Everything lands in .piper/ (gitignored): the release tarball already bundles
# espeak-ng, its data and libonnxruntime, so there is no pip, no sudo and
# nothing to compile.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOVIE="$(dirname "$HERE")"
DEST="$MOVIE/.piper"
# Ryan-high is the film's default: brighter and noticeably brisker than alan,
# which read as slow/older on first listen.
VOICE="${1:-${VOICE:-en_US-ryan-high}}"
REL="${PIPER_RELEASE:-2023.11.14-2}"

mkdir -p "$DEST/voices"

if [ ! -x "$DEST/piper/piper" ]; then
  echo "→ fetching piper $REL"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/piper.tgz" \
    "https://github.com/rhasspy/piper/releases/download/$REL/piper_linux_x86_64.tar.gz"
  tar xzf "$tmp/piper.tgz" -C "$DEST"
  echo "  ✓ $DEST/piper"
else
  echo "✓ piper already present"
fi

# A voice id is <lang>_<REGION>-<family>-<quality>, e.g. en_GB-alan-medium.
# The repository lays it out as
#   <lang>/<lang>_<REGION>/<family>/<quality>/<voice>.onnx
# (an explicit VOICE_PATH overrides the derivation for unusual ids).
lang="${VOICE%%_*}"                                     # en
rest="${VOICE#*_}"                                      # GB-alan-medium
region="${rest%%-*}"                                    # GB
name="${rest#*-}"                                       # alan-medium
family="${name%%-*}"                                    # alan
quality="${name##*-}"                                   # medium
# NB the directory is <lang>_<REGION> with an UNDERSCORE (en_GB), while the
# voice id itself uses en_GB too — deriving "en-GB" from the id 404s.
base="${VOICE_PATH:-https://huggingface.co/rhasspy/piper-voices/resolve/main/$lang/${lang}_${region}/$family/$quality/$VOICE}"
if [ ! -f "$DEST/voices/$VOICE.onnx" ]; then
  echo "→ fetching voice $VOICE (≈60–115 MB)"
  curl -fsSL -o "$DEST/voices/$VOICE.onnx"        "$base.onnx"
  curl -fsSL -o "$DEST/voices/$VOICE.onnx.json"   "$base.onnx.json"
  echo "  ✓ $DEST/voices/$VOICE.onnx"
else
  echo "✓ voice $VOICE already present"
fi

echo
echo "Smoke test:"
echo "  echo 'Niffler. Simple and fast.' | LD_LIBRARY_PATH=$DEST/piper $DEST/piper/piper -m $DEST/voices/$VOICE.onnx -f /tmp/piper-smoke.wav && echo '  ✓ /tmp/piper-smoke.wav'"
echo
echo "Render the narration:"
echo "  node tools/render-voiceover.mjs --engine=piper --piper-model=$DEST/voices/$VOICE.onnx"
