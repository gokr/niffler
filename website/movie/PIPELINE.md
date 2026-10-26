# The movie pipeline — how this was built, and how to make another one

Everything below is what actually produced `website/movie/`. It is written so a
second film (a release trailer, a component demo, a talk intro) can reuse the
machinery instead of rediscovering it.

```
film idea ──▶ narration.js ──▶ index.html scenes ──▶ movie.js timeline
                    │                                     │
                    │                          ┌──────────┴──────────┐
                    ▼                          ▼                     ▼
            render-voiceover.mjs        DevTools checks        screenshots
                    │                                                │
                    ▼                                                ▼
            audio/*.wav + manifest                        ffmpeg (optional video)
                    │
                    ▼
              index.html?voice=track
```

## 1. The stack (and why each piece)

| piece | choice | why |
|---|---|---|
| animation | **GSAP 3** (`vendor/gsap.min.js`, 72 KB) | one deterministic timeline with `seek()`; no framework, no build step |
| layout | hand-written CSS on a fixed **1600×900 stage**, `transform: scale()` to fit | the picture is identical at every viewport/tool; a screenshot is a frame |
| type | system sans/mono, website palette | matches the site; no webfont request |
| fonts/colour | `--paper/--ink/--mint` from `../styles.css` | the movie looks like the product |
| narration | **data** in `narration.js` | pictures and voice can't drift apart |
| TTS | **Piper** (local, CPU) by default | no account, no key, 8× realtime on CPU, 60 MB voice |
| video (optional) | `ffmpeg` over the screenshot stills | only for a shareable mp4 |
| verification | **Chrome DevTools MCP** + headless screenshots | catches what reading the code cannot |

No bundler, no npm install, no server. The whole film is 9 static files and
opens with `file://`.

## 2. Order of work (this order matters)

1. **Script first, in cues.** One cue per scene, `{id, seconds, text}` in
   `narration.js`. ~30 words per cue ≈ 12 s at 150 wpm. `seconds` is a
   *minimum*, not a fixed length, so a measured voice can stretch a scene.
2. **Static layout second.** Write each scene as the FINAL frame: real text in
   the DOM, positioned. Never "build" content in JS.
3. **Timeline third.** One `Builders.sN(tl, el, t0, dur, d)` per scene, placed
   at an absolute label. Only opacity/transform/clip-path move.
4. **Voice fourth**, then re-render: the film re-times itself.
5. **Verify last**, with the DevTools checks in §5.

## 3. Invariants (each one is a bug that happened)

1. **The markup is the final frame.** Every tween is `fromTo` with the rested
   state in HTML/CSS. Reduced motion, a stalled engine, a screenshot tool and a
   scrubbed timeline all show the right picture.
2. **Text never appears from a callback.** GSAP's `seek()` suppresses
   `tl.call()`. A string appended by a callback is missing from every deep
   link. First draft appended build logs this way: the card rendered empty at
   `?t=62`.
3. **The playhead is the single source of truth** for caption, scene label and
   `.is-active` — derived in `renderHud()` from `tl.time()`.
4. **`classList`, never GSAP's `className`.** That plugin *sets* the attribute:
   `'+=is-active'` deleted `.scene` and the whole layout with it.
5. **Nothing random.** Seeded PRNG for jitter (`rng(seed)` in `movie.js`), or
   two frames at the same `t` differ and regression is meaningless.
6. **No `backdrop-filter` on screen during playback.** Measured: it halved the
   frame rate (60 → 30 fps, median frame 16.7 → 33.4 ms) because the backdrop
   changes every frame.
7. **Audio must survive the autoplay policy.** A blocked `play()` is
   `NotAllowedError`, not an exception — swallowing it leaves the film mute
   forever (measured: clip at `readyState 4`, 0.00 s after 2.7 s of play). The
   player remembers the line and retries on the next gesture.

## 4. Making the voice

```bash
bash tools/fetch-piper.sh                # once: engine + voice into .piper/
node tools/render-voiceover.mjs --dry-run            # pacing, free, no network
node tools/render-voiceover.mjs --engine=piper       # writes audio/
```

Per **scene**, not one track: a scene lasts `max(authored, measured + 0.45 s)`,
so re-recording one line re-times only that scene. Outputs: `audio/sN.wav`,
`audio/narration.js` (duration manifest), `audio/narration.srt`.

The renderer measures durations **in-process** (MP3 frame walk, WAV header) —
no ffprobe. `--dry-run` prints words / wpm / measured / `ok|tight|OVERRUN` and
exits 2 on an overrun: an editorial error, caught before spending on a render.

### TTS options

| engine | quality | cost | notes |
|---|---|---|---|
| **Piper** (local) | good, natural | free | `tools/fetch-piper.sh`; CPU, ~8× realtime, 60 MB/voice; **default** |
| **Kokoro-82M** (local) | very good — best here | free | `tools/fetch-kokoro.sh`; 54 English voices, ~1.3× realtime CPU, 340 MB model. **Recommended over Piper** |
| **Coqui XTTS v2** (local) | very good; **clones a voice from ~6 s of audio** | free | `pip install TTS` (~2 GB with deps), needs a licence click, minutes-per-cue on CPU, seconds on a GPU. `--engine=xtts` is a stub to fill (see below) |
| Kokoro (local) | very good | free | newer, needs Python/onnx; heavier setup than Piper |
| Chatterbox / StyleTTS2 (local) | very good | free | similar class to XTTS |
| espeak-ng | robotic | free | already inside the Piper bundle; placeholder only |
| macOS `say` | decent | free | Mac only (`--engine=say`) |
| OpenAI `gpt-4o-mini-tts` | excellent, style-promptable | $/1k chars | needs a key **with `/audio/speech`**; `--engine=openai` |
| ElevenLabs | excellent, emotive | $ | best quality, real cost |
| Azure / Google Cloud | very good | $ | per-character, enterprise-friendly |
| **human VO** | best | time | one file per cue id, same filenames |

Why Piper is the default here: this checkout's `.env` points
`NIF_OPENAI_BASE_URL` at a provider with no `/audio/speech` endpoint (it 401s),
so a cloud path cannot be the out-of-the-box answer. `--engine=openai` still
works with `NIF_TTS_API_KEY` + `NIF_TTS_BASE_URL`.

### Cloning a voice with Coqui XTTS (worth trying)

XTTS v2 does zero-shot cloning: give it ~6 seconds of reference audio and it
reads new text in that voice. On a laptop CPU it is roughly 20–60× slower than
realtime, so expect minutes per cue; on a GPU it is a few seconds. Setup:

```bash
python3 -m pip install --user TTS          # ~2 GB with torch
# it downloads the model on first use and asks you to accept the CPML licence
```

A reference sample is best as 6–12 s of clean, close-mic, single-speaker speech
at 22–44 kHz — no music, no room echo. Then:

```bash
node tools/render-voiceover.mjs --engine=xtts --speaker-wav=my-voice.wav
# GPU:      --xtts-device=cuda
# per-cue:  NIF_XTTS_BATCH=0   (default batches: one model load for all 10 cues)
```

The engine loads the model once and writes `audio/s1.wav … s10.wav`; everything
downstream (duration measurement, manifest, SRT, scene re-timing) is identical
to Piper, so the film re-times itself and the picture stays in sync.

Everything downstream is unchanged: durations are measured from the files, so
the film re-times itself and the SRT regenerates. Two cautions: the licence is
non-commercial (Coqui Public Model License), and a cloned voice should be your
own or one you have permission to use — the model makes that easy to get wrong.

For a human or cloud take: read at ~150 wpm, keep the cue boundaries (they are
scene cuts), one file per id, normalise to **−16 LUFS / −1 dBTP** (web) or
**−14 LUFS** (YouTube), and a music bed is picked up as `audio/ambient.mp3`
ducked to 6%.

## 5. Verification loop (the part that found the bugs)

Run in Chrome via the DevTools MCP, or reproduce with headless screenshots.
Re-run after *every* layout change.

| check | assertion | what it caught here |
|---|---|---|
| **layout probe** | for each scene × 3 playhead positions: no element outside the stage, nothing under the caption band, exactly one `.is-active`, caption non-empty, HUD label matches | 9/10 scenes losing `.is-active` on seek; s3 too sparse |
| **determinism** | snapshot 369 element boxes at the same `t` twice, compare | `Math.random()` jitter |
| **console** | empty | a dangling GSAP target (`#s3 .lede`) — warns, never errors |
| **network** | exactly 6 local files, no 404 for absent `audio/` | — |
| **frame rate** | sample rAF deltas ≥2.5 s: median 16.7 ms | `backdrop-filter` halving fps |
| **audio** | `MOVIE.audioState().clips.s1.t` must advance | the autoplay-swallow bug |
| **transport** | finish → gate says Replay → click rewinds to 0 and plays | replay that did nothing |

Headless stills (what produced the frames reviewed here):

```bash
CHROME=/usr/bin/google-chrome
for t in 5 20 31 45 62 76 91 104 116 127; do
  $CHROME --headless=new --disable-gpu --hide-scrollbars \
    --window-size=1600,900 --virtual-time-budget=2500 \
    --screenshot="var/f-$t.png" "file://$PWD/index.html?t=$t&autoplay=1"
done
```

Optional video: render the stills, then
`ffmpeg -framerate 30 -pattern_type glob -i 'var/f-*.png' -c:v libx264 -pix_fmt yuv420p out.mp4`
(no ffmpeg on this box — the film is HTML by design, which is the better
artifact anyway).

## 6. Starting a new film

1. Copy the skeleton, keeping `movie.css`'s stage/scene/HUD scaffolding:
   ```bash
   cp -r website/movie website/my-film
   cd website/my-film && rm -rf .piper audio/*.wav audio/narration.js audio/narration.srt
   ```
2. Replace `narration.js` (script + authored seconds) — this defines the film.
3. Replace the `<section class="scene" id="sN">` blocks; keep `scene` /
   `scene tight` so captions never collide.
4. Write `Builders.sN` for the scenes that animate; drop the rest (a scene with
   no builder is a static card, which is fine).
5. `node tools/render-voiceover.mjs --dry-run` until `all cues fit`.
6. `bash tools/fetch-piper.sh && node tools/render-voiceover.mjs --engine=piper`.
7. Run the §5 checks; fix; commit.

`window.MOVIE` is the debugging surface throughout: `.seek(t)`, `.state()`,
`.scenes`, `.audioState()`, `.tl`.
