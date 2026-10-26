#!/usr/bin/env python3
"""Kokoro TTS bridge for tools/render-voiceover.mjs.

Kokoro-82M is a small open-weight TTS model that sounds markedly better than
Piper's medium voices, at ~1.3x realtime on CPU. This wrapper keeps the
renderer's Node-only contract: JSON jobs in, WAV files out.

    python3 kokoro-say.py --jobs jobs.json    # [{id, text, out, voice, speed}]

The model loads ONCE per invocation (a load costs ~2 s, and per-cue loads would
dominate a ten-cue render). Model files are looked up in, in order:
    $NIF_KOKORO_DIR, ~/.cache/niffler-movie/models, ./models
Install with tools/fetch-kokoro.sh.
"""
import argparse, json, os, sys, wave
import numpy as np

def model_dir():
    for c in [os.environ.get("NIF_KOKORO_DIR", ""),
              os.path.expanduser("~/.cache/niffler-movie/models"),
              os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "models")]:
        if c and os.path.isfile(os.path.join(c, "kokoro-v1.0.onnx")):
            return c
    sys.exit("kokoro-say: model not found — run tools/fetch-kokoro.sh")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", required=True)
    a = ap.parse_args()
    jobs = json.load(open(a.jobs))
    from kokoro_onnx import Kokoro
    d = model_dir()
    k = Kokoro(os.path.join(d, "kokoro-v1.0.onnx"), os.path.join(d, "voices-v1.0.bin"))
    for j in jobs:
        voice = j.get("voice") or "af_heart"
        speed = float(j.get("speed") or 1.0)
        lang = j.get("lang") or "en-us"
        print("  kokoro", j["id"], voice, speed, flush=True)
        samples, sr = k.create(j["text"], voice=voice, speed=speed, lang=lang)
        a = np.asarray(samples, dtype=np.float32)
        # Kokoro's raw output is quiet (measured peak -4.6 dBFS, RMS -22 dBFS
        # against Piper's 0.0 / -16), which reads as "muffled" next to the
        # music bed and on small speakers. Normalise each cue to a -1 dBFS peak;
        # the film is the only consumer, so a per-cue peak is the right unit.
        peak = float(np.max(np.abs(a))) or 1.0
        a = a * (10 ** (-1.0 / 20.0) / peak)
        pcm = (np.clip(a, -1.0, 1.0) * 32767).astype(np.int16)
        with wave.open(j["out"], "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
            w.writeframes(pcm.tobytes())

if __name__ == "__main__":
    main()
