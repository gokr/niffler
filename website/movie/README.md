# Niffler — the movie

A 2-minute animated explainer: what Niffler is, how a bus-and-processes harness
works, and why a harness the agent can extend is a different thing.

Self-contained and static. No build step, no bundler, no network:

```
website/movie/
  index.html      ten scenes; the markup is the FINAL frame (see "Editing")
  movie.css       stage, scenes, captions, HUD
  movie.js        the timeline, transport, DevTools hooks
  narration.js    the script + per-scene authored minimum durations
  vendor/         gsap.min.js 3.15 (vendored, so file:// works offline)
  tools/          render-voiceover.mjs (TTS → audio/, subtitles, pacing check)
  audio/          generated voice-over clips (empty until you render them)
```

**To watch it with sound, run one command:**

```bash
bash tools/play.sh
```

That serves the folder on an **OS-assigned port** (printed in the URL it opens,
so it cannot collide with another dev server in another checkout — pin one with
`MOVIE_PORT=8721` if you prefer), opens a browser at
`…/index.html?voice=track&autoplay=1`, and prints the URL (so it also works from
another machine on your LAN, or when no browser opener exists). Options:
`--no-voice`, `--voice=browser`, `--at=58`.

If it reports *"no narration rendered yet"*, the voice clips are missing — they
are gitignored because they are 60 MB per voice and regenerate in ~20 s:

```bash
bash tools/fetch-piper.sh                  # engine + voice → .piper/ (~63 MB, once)
node tools/render-voiceover.mjs --engine=piper
```

Or simply open `index.html` directly and press **Play** — the film is fully
interactive from `file://` too. Sound is **on by default** as soon as the clips
exist (`voice=auto` probes `audio/narration.js`, and falls back to captions when
it is absent), so there is no URL flag to remember. Nothing is fetched over the network; the only requests are the local
files.

> Browsers refuse audio before a user gesture. Pressing **Play** *is* that
> gesture. If you deep-link with `?autoplay=1` the narration waits for your next
> click and then starts from the beginning of the current line — it never plays
> silently off-sync.

## Watching it

| control | key |
|---|---|
| play / pause | `space` |
| previous / next scene | `←` `→` |
| captions on/off | `c` |
| restart | `r` |
| fullscreen | `f` |

Deep links (used by the screenshot tooling and handy for reviews):

```
index.html?autoplay=1              # from the top, no start overlay
index.html?t=47.5&autoplay=1       # an exact frame
index.html?scene=s5&into=6         # 6s into one scene
index.html?voice=browser           # speak the narration with OS voices
index.html?voice=track             # require rendered clips (warns if missing)
index.html?voice=none              # force captions only
index.html?captions=off            # no caption line
index.html?reduce=1                # near-instant transitions (also honours
                                   #  the OS prefers-reduced-motion setting)
```

`window.MOVIE` is the debugging surface: `.seek(t)`, `.play()`, `.pause()`,
`.state()`, `.scenes` (`[{id,start,dur,text,el}]`), `.tl` (the GSAP timeline).

## Voice-over

The narration is authored as **data** (`narration.js`), not as prose inside the
animation. One cue per scene, each with a `seconds` minimum. Three consumers
read it: the captions, the browser-voice preview, and the renderer.

The default engine is **Piper**, local and free — no account, no key, CPU-only,
≈8× faster than realtime. This checkout's `.env` points `NIF_OPENAI_BASE_URL` at
a provider with no `/audio/speech` endpoint, so a cloud engine cannot be the
out-of-the-box answer.

```bash
bash tools/fetch-piper.sh                    # once: engine + voice → .piper/ (gitignored)
node tools/render-voiceover.mjs --dry-run    # plan + pacing check, no network
node tools/render-voiceover.mjs --engine=piper
index.html?voice=track                      # ← now you hear it
```

Other engines, same command:

```bash
NIF_TTS_API_KEY=… node tools/render-voiceover.mjs --engine=openai   # needs a key
                                                                    # with /audio/speech
node tools/render-voiceover.mjs --engine=espeak   # robotic placeholder, offline
node tools/render-voiceover.mjs --engine=say      # macOS built-in
bash tools/fetch-piper.sh en_GB-cori-high         # a different Piper voice
```

`PIPELINE.md` compares the available TTS options and explains how to swap in a
human recording.

It writes one clip per scene (`audio/s1.mp3` …), `audio/narration.js` (the
duration manifest the player reads) and `audio/narration.srt`.

**Why per scene, not one track.** A scene lasts `max(authored, measured +
0.45s)` in `voice=track` mode. Re-record one line and only that scene changes
length; the other nine keep their frames. A single mixed track would need a
re-cut after every edit.

**Pacing is checked before you spend money.** `--dry-run` prints words, wpm,
estimated or measured duration and `ok | tight | OVERRUN` per cue, and exits 2
if any cue cannot fit. Four cues were authored too short on the first pass; the
check caught them, and the durations in `narration.js` are now honest.

Durations are measured in-process (MP3 frame walk, WAV header) — `ffprobe` is
not required.

**For a real voice-over**, the same filenames from a human take work perfectly:

- read at ~150 wpm, keep the cue boundaries (they are scene cuts);
- deliver one file per scene, MP3 or WAV, named after the cue id;
- normalise to **−16 LUFS integrated**, true peak **≤ −1 dBTP** for web
  (YouTube wants −14 LUFS); keep a consistent room tone between lines;
- update `audio/narration.js` with the real durations (or re-run the renderer
  with `--force` if it produced them);
- an optional music bed is picked up automatically as `audio/ambient.mp3` and
  ducked to 6% under narration.

Captions are the same strings and are **always** on, so the film works muted,
in autoplay, and before any audio exists.

## Editing it

Rules that keep it debuggable — each one exists because breaking it produced a
bug that was only visible on screen:

1. **The markup is the final frame.** Every animation is a `fromTo` with the
   rested state in the HTML/CSS. Reduced motion, a stalled JS engine, a
   screenshot tool and a scrubbed timeline then all show the right picture.
2. **Text never appears from a callback.** GSAP's `seek()` suppresses
   `tl.call()`, so a string appended by one is missing from every deep-linked
   frame. All copy lives in the DOM; the timeline only moves opacity, transform
   and clip paths. (First draft appended build logs this way — the card
   rendered empty at `?t=62`.)
3. **The playhead is the single source of truth.** Captions, the scene label
   and `.is-active` are derived from `tl.time()` in `renderHud()`, so a live
   play, a scrub and a deep link are identical.
4. **Use `classList`, never GSAP's `className`.** That plugin *sets* the
   attribute: `'+=is-active'` replaced the element's `.scene` class and dropped
   its layout entirely.
5. **Nothing may be random.** Layout jitter and pile placement use the seeded
   PRNG in `movie.js`, so any two frames at the same `t` are identical —
   without this, screenshot regression and re-rendering are meaningless.
6. **Avoid `backdrop-filter` on anything on screen during playback.** Measured
   in DevTools: it halved the frame rate (60 → 30 fps, median frame 16.7 →
   33.4 ms) because the backdrop changes every frame.

Add a scene: append a cue to `narration.js`, add a `<section class="scene"
id="sN">` to `index.html`, and a `Builders.sN` function in `movie.js`. The
timeline, captions, ticks and HUD all derive from the cue list.

## Verifying it

```bash
node --check movie.js                       # syntax
node tools/render-voiceover.mjs --dry-run   # script/pacing sanity
```

Frame regression (headless Chrome; the page needs no server):

```bash
CHROME=/usr/bin/google-chrome
for t in 5 20 31 45 62 76 91 104 116 127; do
  $CHROME --headless=new --disable-gpu --hide-scrollbars \
    --window-size=1600,900 --virtual-time-budget=2500 \
    --screenshot="var/frame-$t.png" "file://$PWD/index.html?t=$t&autoplay=1"
done
```

With the Chrome DevTools MCP the same checks are scripted in a browser instead
of by eye — worth re-running after any layout change, since it catches what a
screenshot cannot:

- **layout probe**: for every scene, seek to mid-scene and assert no element is
  outside the stage and nothing collides with the caption band, that exactly
  one scene has `.is-active`, that the caption text is non-empty, and that the
  HUD label matches;
- **determinism**: snapshot every visible element's geometry and opacity at the
  same `t` twice and compare — this is what proves rule 5;
- **console**: must be empty (a dangling selector only warns in GSAP);
- **network**: exactly six local requests, no 404 for the absent `audio/`;
- **frame rate**: sample `requestAnimationFrame` deltas during playback —
  median should be 16.7 ms.

## Reusing this for another movie

See **[PIPELINE.md](PIPELINE.md)**: the stack and why each piece, the order of
work, the seven invariants (each one a bug that happened), the verification
table DevTools drives, and a six-step "start a new film" checklist.

## Known limits

- 1600×900 stage, scaled to the viewport; it letterboxes on extreme aspect
  ratios rather than reflowing.
- Type falls back to system sans/mono when Inter and IBM Plex Mono are absent
  (the website has the same dependency, so the look stays consistent).
- No audio assets ship in the repo (60 MB of WAV per voice, and they are
  regenerable in ~20 s): the film is silent with captions until you run
  `tools/fetch-piper.sh` + `render-voiceover.mjs --engine=piper`.
- Browsers block audio until the first click/keypress. Pressing **Play** is
  that gesture; if you deep-link with `?autoplay=1`, the narration waits and
  starts on your next click (it never plays silently out of sync).
