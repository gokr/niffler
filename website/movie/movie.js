/* Niffler — the movie. Scene-driven GSAP timeline.
 *
 * Design rules that keep this debuggable rather than a pile of tweens:
 *   - every scene owns a slice of ONE master timeline, placed at an absolute
 *     label; nothing uses wall-clock timers, so `MOVIE.seek(t)` is exact and a
 *     screenshot at t=47.5 shows the same frame every run;
 *   - every scene animation is a fromTo with explicit endpoints, so the
 *     static layout in the HTML/CSS is the FINAL frame (reduced motion, print,
 *     a stalled JS engine and DevTools' "capture full size screenshot" all
 *     still show the right picture);
 *   - the scene list is derived from window.NARRATION, so re-timing the voice
 *     track re-times the film. Nothing hard-codes seconds downstream.
 *
 * DevTools hooks (window.MOVIE): seek(t), play(), pause(), sceneAt(t),
 * state(), scenes[], tl. Query flags: ?t=<sec>, ?scene=s5, ?autoplay=1,
 * ?voice=none|browser|track, ?captions=off, ?reduce=1.
 */
'use strict';

const STAGE_W = 1600;
const STAGE_H = 900;
const params = new URLSearchParams(location.search);
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));

const reduced = params.get('reduce') === '1' ||
  window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/** Deterministic PRNG: the background pile must look identical on every run,
 *  or a screenshot comparison (and a re-render of the video) is meaningless. */
function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) % 4294967296;
    return s / 4294967296;
  };
}

const el = (tag, cls, text) => {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = text;
  return n;
};

/* ------------------------------------------------------------------ *
 * stage sizing
 * ------------------------------------------------------------------ */

function fitStage() {
  const stage = $('#stage');
  const pad = 24;
  const scale = Math.min(
    (window.innerWidth - pad) / STAGE_W,
    (window.innerHeight - pad) / STAGE_H
  );
  stage.style.transform = `scale(${Math.max(scale, 0.2)})`;
}

/* ------------------------------------------------------------------ *
 * voice track
 * ------------------------------------------------------------------ */

const Voice = {
  mode: params.get('voice') || 'auto', // auto | none | browser | track
  meta: {},                            // id -> {file, seconds}
  audios: {},                          // id -> HTMLAudioElement
  bed: null,
  current: null,
  enabled: false,
  hasPlayed: false,   /* any narration actually heard? decides rewind vs resume */

  /** `auto` (the default) probes for a rendered voice-over and uses it.
   *  Only `track`/`auto` load anything from audio/, and only a MISSING
   *  manifest in explicit `track` mode warns: with clips present, opening
   *  index.html plainly plays WITH sound, which is what a viewer expects —
   *  requiring a URL flag to hear the narration is how "I still don't hear
   *  sound" happens. A silent clone (no clips) is not an error. */
  async load() {
    if (this.mode !== 'track' && this.mode !== 'auto') return;
    const explicit = this.mode === 'track';
    await new Promise((resolve) => {
      const s = document.createElement('script');
      s.src = 'audio/narration.js';
      s.onload = resolve;
      s.onerror = () => {
        if (explicit) {
          console.warn('[movie] audio/narration.js missing — captions only. ' +
                       'Run: bash tools/fetch-piper.sh && ' +
                       'node tools/render-voiceover.mjs --engine=piper');
        }
        resolve();
      };
      document.head.appendChild(s);
    });
    if (!Array.isArray(window.NARRATION_AUDIO) || window.NARRATION_AUDIO.length === 0) {
      if (this.mode === 'auto') this.mode = 'none';   // silent clone: captions carry it
      return;
    }
    this.mode = 'track';
    const list = window.NARRATION_AUDIO || [];
    for (const cue of list) {
      if (!cue.file) continue;
      const a = new Audio('audio/' + cue.file);
      a.preload = 'auto';
      this.audios[cue.id] = a;
      this.meta[cue.id] = { file: cue.file, seconds: Number(cue.seconds) || 0 };
    }
  },

  /** How long a scene holds.
   *
   * `Math.max(authored, spoken)` is right for a SLOW voice (the scene must
   * stretch) but wrong for a fast one: with Kokoro's af_nova at ~180 wpm the
   * film kept every authored length and sat in silence for ~38 s of its 142 s
   * (measured: 100 s of speech, 142 s of scenes). So the scene follows the
   * voice with a bounded dwell — at most `HOLD_MAX` seconds of room after the
   * line — and never exceeds the authored length, which stays the animation's
   * budget. `?hold=full` restores the old behaviour (scene >= authored). */
  sceneSeconds(id, authored) {
    if (this.mode !== 'track') return authored;
    const m = this.meta[id];
    if (!m || !(m.seconds > 0)) return authored;
    if (Master.holdFull) return Math.max(authored, m.seconds + 0.45);
    const HOLD_MAX = Number(params.get('holdMax') || 2.0);
    return Math.min(authored, Math.max(m.seconds + 0.9, m.seconds + HOLD_MAX));
  },

  start(id, text) {
    if (!this.enabled) return;
    this.stop();
    if (this.mode === 'track') {
      const a = this.audios[id];
      if (a) {
        a.currentTime = 0;
        this.current = a;
        this.pendingId = id;
        this.tryPlay(a);
        if (this.bed) this.bed.volume = 0.06;
      }
      return;
    }
    if (this.mode === 'browser' && 'speechSynthesis' in window) {
      const u = new SpeechSynthesisUtterance(text);
      u.rate = 1.0;
      u.pitch = 1.0;
      u.volume = 1.0;
      const pick = speechSynthesis.getVoices().find((v) =>
        /en[-_](GB|US)/i.test(v.lang) && /natural|premium|enhanced|google/i.test(v.name));
      if (pick) u.voice = pick;
      this.current = u;
      speechSynthesis.speak(u);
    }
  },

  /** Play, and if the browser blocks it (autoplay policy: no user gesture
   *  yet), remember that so the next click/keypress resumes the SAME line
   *  instead of leaving the film silently mute. */
  tryPlay(media) {
    const p = media.play();
    if (p && typeof p.then === 'function') {
      p.then(() => { this.hasPlayed = true; this.blocked = null; }).catch((err) => {
        this.blocked = (err && err.name) || 'blocked';
        if (!this.warned) {
          this.warned = true;
          console.warn('[movie] narration is blocked until a click or keypress ' +
                       '(' + this.blocked + '). It will start on the next gesture.');
        }
        this.armGesture();
      });
    }
  },

  armGesture() {
    if (this.gestureArmed) return;
    this.gestureArmed = true;
    const resume = () => {
      this.gestureArmed = false;
      window.removeEventListener('pointerdown', resume, true);
      window.removeEventListener('keydown', resume, true);
      if (!this.enabled || !this.pendingId) return;

      /* A block can happen at two very different moments, and resuming the
       * LINE is only right for one of them:
       *  - at startup (?autoplay=1, no gesture yet): nothing has been heard, so
       *    the film has been running SILENTLY and is now in some later scene.
       *    Resuming that line is how "I only hear it from the second segment"
       *    happened — the opening was already gone. Rewind to the top and let
       *    picture and voice start together.
       *  - mid-film (rare): restart the current line, staying in sync. */
      if (!this.hasPlayed) {
        if (Master.seek) { Master.seek(0); Master.tl.play(); Master.playing = true; }
        this.pendingId = (Master.scenes && Master.scenes[0] && Master.scenes[0].id) || this.pendingId;
      }
      const a = this.audios[this.pendingId];
      if (!a || !a.paused) return;
      a.currentTime = 0;
      this.tryPlay(a);
    };
    window.addEventListener('pointerdown', resume, true);
    window.addEventListener('keydown', resume, true);
  },

  stop() {
    if (this.mode === 'browser' && 'speechSynthesis' in window) speechSynthesis.cancel();
    if (this.current && this.current.pause) {
      this.current.pause();
      this.current.currentTime = 0;
    }
    if (this.bed) this.bed.volume = 0.12;
    this.current = null;
  },

  pause() {
    if (this.mode === 'browser' && 'speechSynthesis' in window) speechSynthesis.pause();
    if (this.current && this.current.pause) this.current.pause();
  },

  resume() {
    if (this.mode === 'browser' && 'speechSynthesis' in window) speechSynthesis.resume();
    if (this.current && this.current.play) this.current.play().catch(() => {});
  },
};

/* ------------------------------------------------------------------ *
 * scene content built at runtime (kept out of the HTML so the markup
 * stays readable: these are decorative and generated deterministically)
 * ------------------------------------------------------------------ */

const PILE = ['bash', 'edit', 'grep', 'git', 'lsp', 'fetch', 'store', 'llm',
  'models', 'mcp', 'builder', 'skills', 'plugins', 'processes', 'observe',
  'recall', 'repomap', 'fleet', 'hooks', 'config', 'locks', 'compaction'];

function buildPile() {
  const pile = $('#toolPile');
  if (!pile) return [];
  const rand = rng(20261025);
  const cols = 5, rows = 5;
  const cw = 100 / cols, ch = 100 / rows;
  const chips = [];
  PILE.forEach((name, i) => {
    const c = el('div', 'pile-chip', name);
    const col = i % cols, row = Math.floor(i / cols) % rows;
    const jx = (rand() - 0.5) * 10, jy = (rand() - 0.5) * 12;
    c.style.left = (col * cw + jx + 2) + '%';
    c.style.top = (row * ch + jy + 2) + '%';
    c.style.transform = `rotate(${(rand() - 0.5) * 7}deg)`;
    pile.appendChild(c);
    chips.push(c);
  });
  return chips;
}

/** Peers on an ellipse around the core, with connector lines drawn in SVG.
 *  Positions are computed from the container box, so the layout survives a
 *  stage resize instead of depending on hand-tuned pixel values. */
function buildPeers() {
  const wrap = $('#peerWrap');
  const svg = $('#peerSvg');
  const chips = $$('#peers .chip');
  if (!wrap || !svg || chips.length === 0) return { chips, lines: [], dots: [], center: { x: 0, y: 0 } };
  const w = wrap.clientWidth, h = wrap.clientHeight;
  const cx = w / 2, cy = h / 2;
  const rx = w * 0.40, ry = h * 0.40;
  const lines = [], dots = [];
  svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
  chips.forEach((chip, i) => {
    const a = (-90 + (360 / chips.length) * i) * Math.PI / 180;
    const x = cx + Math.cos(a) * rx * (1 + 0.06 * Math.sin(i * 1.7));
    const y = cy + Math.sin(a) * ry;
    chip.style.left = (x / w * 100) + '%';
    chip.style.top = (y / h * 100) + '%';
    const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
    line.setAttribute('x1', cx); line.setAttribute('y1', cy);
    line.setAttribute('x2', x); line.setAttribute('y2', y);
    line.setAttribute('class', 'bus-line');
    line.setAttribute('stroke-dasharray', '5 7');
    svg.appendChild(line);
    lines.push(line);
    const dot = document.createElementNS('http://www.w3.org/2000/svg', 'circle');
    dot.setAttribute('cx', x); dot.setAttribute('cy', y); dot.setAttribute('r', 3);
    dot.setAttribute('fill', '#42e6a4');
    svg.appendChild(dot);
    dots.push(dot);
  });
  return { chips, lines, dots, center: { x: cx, y: cy, w, h } };
}

function buildBus() {
  const wrap = $('#busWrap');
  const svg = $('#busSvg');
  const node = $('#coreNode3');
  if (!wrap || !svg || !node) return { envelopes: [], line: null };
  const w = wrap.clientWidth, h = wrap.clientHeight;
  const y = h * 0.5;
  svg.setAttribute('viewBox', `0 0 ${w} ${h}`);
  const line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
  line.setAttribute('x1', 40); line.setAttribute('y1', y);
  line.setAttribute('x2', w - 40); line.setAttribute('y2', y);
  line.setAttribute('class', 'bus-line');
  svg.appendChild(line);
  node.style.left = (w / 2) + 'px';
  node.style.top = y + 'px';
  const label = $('#busLabel');
  if (label) { label.style.left = (w * 0.76) + 'px'; label.style.top = (y - 46) + 'px'; }
  const envelopes = [];
  for (let i = 0; i < 7; i++) {
    const e = el('div', 'envelope');
    e.style.left = '50%';
    e.style.top = y + 'px';
    wrap.appendChild(e);
    envelopes.push(e);
  }
  return { envelopes, line, w, h, y };
}

function buildTokenbar() {
  const bar = $('#tokenbar');
  if (!bar) return { prefix: [], history: [] };
  const prefix = [], history = [];
  for (let i = 0; i < 6; i++) {
    const c = el('i');
    c.style.background = 'rgba(108, 198, 255, 0.45)';
    bar.appendChild(c); prefix.push(c);
  }
  for (let i = 0; i < 9; i++) {
    const c = el('i');
    c.style.background = 'rgba(66, 230, 164, 0.55)';
    c.style.transform = 'scaleX(0)';
    bar.appendChild(c); history.push(c);
  }
  return { prefix, history };
}

function buildBubbles() {
  const laneA = $('#laneA'), laneB = $('#laneB');
  const mk = (parent, text, cls) => {
    const b = el('div', 'bubble', text);
    if (cls) b.style.cssText += cls;
    parent.querySelector('.track').appendChild(b);
    return b;
  };
  return {
    a: laneA ? mk(laneA, 'turn already running → busy', 'right:8px;top:2px') : null,
    b: laneB ? mk(laneB, 'answered while A works', 'right:8px;top:2px') : null,
  };
}

/* ------------------------------------------------------------------ *
 * scene timelines
 * ------------------------------------------------------------------ */

const Builders = {};

/* s1 — cold open: the mark draws itself, the wordmark lands. */
Builders.s1 = (tl, el, t0, dur, d) => {
  /* Draws the REAL lockup (icon + "Niffler" on one baseline) and ends on it:
   * speed lines → terminal box → prompt → the word sliding in. The previous
   * version stacked the icon above a separate wordmark with an invented dot,
   * so the film never finished on the brand logo. */
  const strokes = $$('.logo-strokes .draw', el);
  tl.fromTo(strokes,
    { strokeDasharray: 1, strokeDashoffset: 1 },
    { strokeDashoffset: 0, duration: d(0.85), stagger: d(0.18), ease: 'power2.inOut' }, t0 + 0.2);
  /* Fade only. A `scale` tween on an SVG <rect> left a residual
   * translate(-16.2,-8.64) baked into the element (measured: the fill box sat
   * 29px left and 15px above its own stroke rect, so the mark read as two
   * offset squares), because GSAP compensates a pixel transformOrigin unless
   * transform-box is set. The mark is symmetric — a fade-in is enough. */
  tl.fromTo($('.logo-box', el), { autoAlpha: 0 },
    { autoAlpha: 1, duration: d(0.55), ease: 'power2.out' }, t0 + 0.5);
  tl.fromTo($('.logo-box-stroke', el), { autoAlpha: 0 }, { autoAlpha: 1, duration: d(0.7) }, t0 + 0.85);
  tl.fromTo($$('.logo-prompt .draw', el),
    { strokeDasharray: 1, strokeDashoffset: 1 },
    { strokeDashoffset: 0, duration: d(0.55), stagger: d(0.18), ease: 'power2.out' }, t0 + 1.15);
  /* the wordmark completes the logo */
  tl.fromTo($('.logo-word', el), { x: -26, autoAlpha: 0 },
    { x: 0, autoAlpha: 1, duration: d(1.1), ease: 'expo.out' }, t0 + 1.6);
  tl.fromTo($('.kicker', el), { y: 16, autoAlpha: 0 },
    { y: 0, autoAlpha: 1, duration: d(0.8), ease: 'power2.out' }, t0 + 2.7);
  tl.fromTo($('.s1-stack', el), { scale: 0.985 }, { scale: 1.015, duration: dur, ease: 'none' }, t0);
};

/* s2 — the monolith: a pile of schemas, a prompt that overflows. */
Builders.s2 = (tl, el, t0, dur, d) => {
  const chips = buildPile();
  tl.fromTo($('.eyebrow', el), { autoAlpha: 0, x: -14 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 0.1);
  tl.fromTo($('.monolith', el), { autoAlpha: 0, y: 22 }, { autoAlpha: 1, y: 0, duration: d(0.7), ease: 'power2.out' }, t0 + 0.3);
  tl.fromTo(chips, { scale: 0.4, autoAlpha: 0, rotation: 0 },
    { scale: 1, autoAlpha: 1, duration: d(0.32), stagger: d(0.045), ease: 'back.out(2)' }, t0 + 0.9);
  tl.fromTo($('.h-md', el), { autoAlpha: 0, y: 18 }, { autoAlpha: 1, y: 0, duration: d(0.7) }, t0 + 1.1);
  tl.fromTo($$('.stat', el), { autoAlpha: 0, y: 12 }, { autoAlpha: 1, y: 0, duration: d(0.5), stagger: d(0.12) }, t0 + 1.8);
  tl.fromTo($('.lede', el), { autoAlpha: 0 }, { autoAlpha: 1, duration: d(0.7) }, t0 + 2.6);
  tl.fromTo($('#millMeter', el), { width: '0%' }, { width: '100%', duration: d(4.2), ease: 'power1.in' }, t0 + 3.0);
  tl.to($('#millMeter', el), { opacity: 0.55, duration: d(0.22), repeat: 5, yoyo: true }, t0 + 7.4);
  /* Deterministic jitter: a run-to-run random frame makes a screenshot diff
   * (and a video re-render) meaningless. Seeded, like the pile layout. */
  const shake = rng(778899);
  const offsets = chips.map(() => (shake() - 0.5) * 7);
  chips.forEach((c, i) => {
    tl.to(c, { x: offsets[i], duration: d(0.18), repeat: 7, yoyo: true, ease: 'none' },
      t0 + 7.6 + i * 0.04);
  });
};

/* s3 — the bus: one line, envelopes, a small core. */
Builders.s3 = (tl, el, t0, dur, d) => {
  const bus = buildBus();
  tl.fromTo($('.eyebrow', el), { autoAlpha: 0, x: -14 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 0.1);
  tl.fromTo($('.h-md', el), { autoAlpha: 0, y: 18 }, { autoAlpha: 1, y: 0, duration: d(0.7) }, t0 + 0.3);
  if (bus.line) {
    tl.fromTo(bus.line, { scaleX: 0, transformOrigin: 'left center' },
      { scaleX: 1, duration: d(1.1), ease: 'power2.inOut' }, t0 + 1.0);
  }
  tl.fromTo($('#coreNode3', el), { scale: 0.7, autoAlpha: 0 },
    { scale: 1, autoAlpha: 1, duration: d(0.7), ease: 'back.out(2)' }, t0 + 1.9);
  /* A steady stream, not one burst: a 13 s scene with 2 s of motion looked
   * dead in the middle (caught on a still frame at t=31). */
  bus.envelopes.forEach((e, i) => {
    const dir = i % 2 === 0 ? 1 : -1;
    const at = 2.4 + i * 0.45;
    tl.fromTo(e, { autoAlpha: 0, x: -dir * 200 }, { autoAlpha: 1, duration: d(0.3) }, t0 + at);
    tl.fromTo(e, { x: -dir * 200 }, {
      x: dir * 260, duration: d(2.2), ease: 'power1.inOut', repeat: 2, repeatDelay: 0.35,
    }, t0 + at);
    tl.to(e, { autoAlpha: 0, duration: d(0.3) }, t0 + at + 2.2 * 3 + 0.7);
  });
  tl.fromTo($('#busLabel', el), { autoAlpha: 0, y: 10 }, { autoAlpha: 1, y: 0, duration: d(0.6) }, t0 + 3.2);
  /* No .lede in s3 any more: the envelope card is the second text object, and
   * a tween on a deleted selector is a silent GSAP warning, not an error
   * (found in the DevTools console, not in the code). */
  tl.fromTo($('#s3 .envelope-card', el), { autoAlpha: 0, y: 16 },
    { autoAlpha: 1, y: 0, duration: d(0.8) }, t0 + 2.2);
  /* the subject names: the concrete answer to "one protocol" */
  tl.fromTo($$('#subjects li', el), { autoAlpha: 0, y: 8 },
    { autoAlpha: 1, y: 0, duration: d(0.45), stagger: d(0.16) }, t0 + 3.4);
};

/* s4 — peers: separate processes, joining and leaving while the bus runs. */
Builders.s4 = (tl, el, t0, dur, d) => {
  const peers = buildPeers();
  tl.fromTo($('.eyebrow', el), { autoAlpha: 0, x: -14 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 0.1);
  tl.fromTo($('.h-sm', el), { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: d(0.6) }, t0 + 0.25);
  tl.fromTo($('#coreNode4', el), { scale: 0.7, autoAlpha: 0 },
    { scale: 1, autoAlpha: 1, duration: d(0.6), ease: 'back.out(2)' }, t0 + 0.7);
  if (peers.lines.length) {
    peers.lines.forEach((line, i) => {
      const len = Math.hypot(
        Number(line.getAttribute('x2')) - Number(line.getAttribute('x1')),
        Number(line.getAttribute('y2')) - Number(line.getAttribute('y1'))
      );
      tl.fromTo(line, { strokeDashoffset: len, opacity: 0 },
        { strokeDashoffset: 0, opacity: 0.85, duration: d(0.55), ease: 'power1.out' }, t0 + 1.0 + i * 0.075);
    });
    tl.fromTo(peers.dots, { scale: 0, transformOrigin: 'center center', autoAlpha: 0 },
      { scale: 1, autoAlpha: 1, duration: d(0.3), stagger: d(0.075), ease: 'back.out(3)' }, t0 + 1.05);
    tl.fromTo(peers.chips, { scale: 0.55, autoAlpha: 0, y: 8 },
      { scale: 1, autoAlpha: 1, y: 0, duration: d(0.45), stagger: d(0.075), ease: 'back.out(2.2)' }, t0 + 1.15);
    /* the point of "peers": they come and go. Two depart, one joins. */
    tl.to(peers.chips[5], { autoAlpha: 0.22, scale: 0.92, duration: d(0.4) }, t0 + 7.4);
    tl.to(peers.chips[9], { autoAlpha: 0.22, scale: 0.92, duration: d(0.4) }, t0 + 7.9);
    tl.fromTo(peers.chips[12], { scale: 1 }, { scale: 1.12, duration: d(0.3), yoyo: true, repeat: 1 }, t0 + 8.4);
  }
};

/* s5 — self-extension: write, build, spawn, and call the new tool.
 *
 * Every string here is already in the DOM and only its opacity moves. That is
 * not a style preference: GSAP's seek() suppresses callbacks, so a log line
 * appended by tl.call() is MISSING from every deep-linked frame (?t=…), from
 * a DevTools scrub, and from a re-render of the video. Verified in the first
 * draft — the build card rendered empty at t=62. Text lives in the markup;
 * the timeline only decides what is visible. */
Builders.s5 = (tl, el, t0, dur, d) => {
  const steps = $$('.step', el);
  const buildLines = $$('#stepBuild .line', el);
  const spawnLines = $$('#stepSpawn .line', el);
  tl.fromTo($('.eyebrow', el), { autoAlpha: 0, x: -14 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 0.1);
  tl.fromTo($('.h-sm', el), { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: d(0.6) }, t0 + 0.25);
  tl.fromTo(steps, { autoAlpha: 0, y: 26 }, { autoAlpha: 1, y: 0, duration: d(0.6), stagger: d(0.16), ease: 'power2.out' }, t0 + 0.6);

  /* 1. the source appears (clip reveal: cheaper and more legible than typing) */
  tl.fromTo($('.code', el), { clipPath: 'inset(0 100% 0 0)', autoAlpha: 0.4 },
    { clipPath: 'inset(0 0% 0 0)', autoAlpha: 1, duration: d(2.0), ease: 'none' }, t0 + 1.3);

  /* 2. build: log lines, then the bar, then the completion mark */
  buildLines.forEach((ln, i) => {
    tl.fromTo(ln, { autoAlpha: 0, x: -6 }, { autoAlpha: 1, x: 0, duration: d(0.34) },
      t0 + 3.5 + i * 0.62);
  });
  tl.fromTo($('#buildBar', el), { width: '0%' },
    { width: '100%', duration: d(2.3), ease: 'power1.inOut' }, t0 + 3.7);
  tl.fromTo($('#stepBuild .check', el), { autoAlpha: 0.2, scale: 0.7 },
    { autoAlpha: 1, scale: 1, duration: d(0.4), ease: 'back.out(3)' }, t0 + 6.3);

  /* 3. spawn: the capability appears on the bus, then answers a call */
  spawnLines.forEach((ln, i) => {
    tl.fromTo(ln, { autoAlpha: 0, x: -6 }, { autoAlpha: 1, x: 0, duration: d(0.34) },
      t0 + 7.1 + i * 0.55);
  });
  tl.fromTo($('#newChip', el), { scale: 0.2, autoAlpha: 0 },
    { scale: 1, autoAlpha: 1, duration: d(0.6), ease: 'back.out(3)' }, t0 + 8.3);
  tl.fromTo('#newChip', { boxShadow: '0 0 0 0 rgba(66,230,164,0.55)' },
    { boxShadow: '0 0 0 26px rgba(66,230,164,0)', duration: d(1.1), ease: 'power2.out' }, t0 + 8.5);
  tl.fromTo($('#stepSpawn .check', el), { autoAlpha: 0.2, scale: 0.7 },
    { autoAlpha: 1, scale: 1, duration: d(0.4), ease: 'back.out(3)' }, t0 + 9.3);
  tl.fromTo($('#stepWrite .check', el), { autoAlpha: 0.2, scale: 0.7 },
    { autoAlpha: 1, scale: 1, duration: d(0.4), ease: 'back.out(3)' }, t0 + 9.6);
  tl.fromTo($('.lede', el), { autoAlpha: 0, y: 12 }, { autoAlpha: 1, y: 0, duration: d(0.7) }, t0 + 10.1);
};

/* s6 — one conversation, one process: no nesting, no blocking.
 * Two runners side by side. A works for the whole scene; B answers and its
 * verdict flips while A is still busy — the visual claim is "these are
 * independent processes", so the lanes are framed as processes. */
Builders.s6 = (tl, el, t0, dur, d) => {
  const bubbles = buildBubbles();
  const swap = (target, at) => {
    tl.fromTo($(`${target} .v-idle`, el), { autoAlpha: 1 }, { autoAlpha: 0, duration: d(0.3) }, at);
    tl.fromTo($(`${target} .v-done`, el), { autoAlpha: 0 }, { autoAlpha: 1, duration: d(0.3) }, at + 0.08);
  };
  tl.fromTo($('.eyebrow', el), { autoAlpha: 0, x: -14 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 0.1);
  tl.fromTo($('.h-sm', el), { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: d(0.6) }, t0 + 0.25);
  tl.fromTo($$('.lane', el), { autoAlpha: 0, x: -18 },
    { autoAlpha: 1, x: 0, duration: d(0.6), stagger: d(0.18) }, t0 + 0.7);
  tl.fromTo($('#workA', el), { width: '0%' }, { width: '68%', duration: d(8), ease: 'power1.out' }, t0 + 1.2);
  tl.fromTo($('#workB', el), { width: '0%' }, { width: '100%', duration: d(1.2), ease: 'power2.out' }, t0 + 1.4);
  swap('#laneB .verdict', t0 + 2.7);
  tl.fromTo(bubbles.a, { autoAlpha: 0, y: -6 }, { autoAlpha: 1, y: 0, duration: d(0.45) }, t0 + 4.0);
  tl.fromTo(bubbles.b, { autoAlpha: 0, y: -6 }, { autoAlpha: 1, y: 0, duration: d(0.45) }, t0 + 5.0);
  swap('#laneA .verdict', t0 + 6.4);
  tl.fromTo($('.note-row', el), { autoAlpha: 0, y: 8 },
    { autoAlpha: 1, y: 0, duration: d(0.6), stagger: d(0.1) }, t0 + 7.2);
};

/* s7 — the request, three times: the prefix never moves, the tail grows.
 * The cache number is a static claim in the DOM, not a counter driven by
 * onUpdate (which a seek skips) — the frame is the same live or scrubbed. */
Builders.s7 = (tl, el, t0, dur, d) => {
  const reqs = $$('.req', el);
  tl.fromTo($('.eyebrow', el), { autoAlpha: 0, x: -14 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 0.1);
  tl.fromTo($('.h-sm', el), { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: d(0.6) }, t0 + 0.25);
  /* the three requests arrive in order; each prefix block is identical */
  tl.fromTo(reqs, { autoAlpha: 0, y: 12 },
    { autoAlpha: 1, y: 0, duration: d(0.55), stagger: d(0.7), ease: 'power2.out' }, t0 + 0.8);
  tl.fromTo($$('.req-blocks .pre', el), { scaleY: 0.4, transformOrigin: 'center bottom' },
    { scaleY: 1, duration: d(0.5), stagger: d(0.7) }, t0 + 0.9);
  /* the newly appended cell: history grows, the prefix does not */
  tl.fromTo($('#req3 .hist.new', el), { scaleX: 0, transformOrigin: 'left center', autoAlpha: 0 },
    { scaleX: 1, autoAlpha: 1, duration: d(0.5), ease: 'back.out(2)' }, t0 + 3.2);
  tl.fromTo($('#req3 .hist.new', el), { boxShadow: '0 0 0 0 rgba(66,230,164,0.6)' },
    { boxShadow: '0 0 0 16px rgba(66,230,164,0)', duration: d(0.9) }, t0 + 3.3);
  tl.fromTo($('.req-legend', el), { autoAlpha: 0 }, { autoAlpha: 1, duration: d(0.6) }, t0 + 4.0);
  /* the number is the argument */
  tl.fromTo($('.cache-stat', el), { autoAlpha: 0, x: 14 }, { autoAlpha: 1, x: 0, duration: d(0.7) }, t0 + 4.2);
  tl.fromTo($('#cacheHit', el), { scale: 0.7, autoAlpha: 0 },
    { scale: 1, autoAlpha: 1, duration: d(0.8), ease: 'back.out(2.5)' }, t0 + 4.4);
  /* discovery: one schema at a time, appended — never spliced into the head */
  tl.fromTo($('.discovery', el), { autoAlpha: 0, y: 10 }, { autoAlpha: 1, y: 0, duration: d(0.5) }, t0 + 6.0);
  tl.to('#pillDiscover', { borderColor: '#42e6a4', color: '#dcf8ec', duration: d(0.35) }, t0 + 6.8);
  tl.to('#pillInvoke', { borderColor: '#42e6a4', color: '#dcf8ec', duration: d(0.35) }, t0 + 7.5);
  tl.fromTo('#pillTool', { scale: 0.9, boxShadow: '0 0 0 0 rgba(66,230,164,0.5)' },
    { scale: 1.04, boxShadow: '0 0 0 14px rgba(66,230,164,0)', duration: d(0.8), ease: 'power2.out' }, t0 + 8.1);
};

/* s8 — reliability: arbitration and repair, each with its second half. */
Builders.s8 = (tl, el, t0, dur, d) => {
  const swap = (target, at) => {
    tl.fromTo($(`${target} .v-idle`, el), { autoAlpha: 1 }, { autoAlpha: 0, duration: d(0.3) }, at);
    tl.fromTo($(`${target} .v-done`, el), { autoAlpha: 0 }, { autoAlpha: 1, duration: d(0.3) }, at + 0.08);
  };
  tl.fromTo($('.eyebrow', el), { autoAlpha: 0, x: -14 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 0.1);
  tl.fromTo($('.h-sm', el), { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: d(0.6) }, t0 + 0.25);
  tl.fromTo($$('.card', el), { autoAlpha: 0, y: 22 },
    { autoAlpha: 1, y: 0, duration: d(0.6), stagger: d(0.2) }, t0 + 0.7);

  /* left: a lease is taken, a second writer is refused BY NAME */
  swap('.lease-row .swap', t0 + 1.6);
  tl.fromTo('#denyRow', { autoAlpha: 0, x: -10 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 3.2);
  tl.fromTo('#denyRow', { x: -3 }, { x: 0, duration: d(0.08), repeat: 5, yoyo: true, ease: 'none' }, t0 + 3.7);
  tl.fromTo('.card .split', { autoAlpha: 0, y: 6 }, { autoAlpha: 1, y: 0, duration: d(0.5), stagger: d(0.15) }, t0 + 4.4);

  /* right: the lost tool result is stitched, not fatal */
  tl.fromTo($$('.stitch .row', el), { autoAlpha: 0, x: 8 },
    { autoAlpha: 1, x: 0, duration: d(0.4), stagger: d(0.55) }, t0 + 2.0);
  tl.fromTo('#healRow', { scale: 0.96, boxShadow: '0 0 0 0 rgba(66,230,164,0.45)' },
    { scale: 1, boxShadow: '0 0 0 18px rgba(66,230,164,0)', duration: d(0.9), ease: 'power2.out' }, t0 + 4.8);
};

/* s9 — three SDKs over one wire. */
Builders.s9 = (tl, el, t0, dur, d) => {
  tl.fromTo($('.eyebrow', el), { autoAlpha: 0, x: -14 }, { autoAlpha: 1, x: 0, duration: d(0.5) }, t0 + 0.1);
  tl.fromTo($('.h-sm', el), { autoAlpha: 0, y: 16 }, { autoAlpha: 1, y: 0, duration: d(0.6) }, t0 + 0.25);
  tl.fromTo($$('.sdk', el), { autoAlpha: 0, y: 24, scale: 0.94 },
    { autoAlpha: 1, y: 0, scale: 1, duration: d(0.55), stagger: d(0.14), ease: 'back.out(1.7)' }, t0 + 0.8);
  tl.fromTo($('.wire', el), { scaleX: 0, transformOrigin: 'center center' },
    { scaleX: 1, duration: d(1.1), ease: 'power2.inOut' }, t0 + 2.0);
  tl.fromTo($('.wire-label', el), { autoAlpha: 0, y: 8 }, { autoAlpha: 1, y: 0, duration: d(0.6) }, t0 + 2.6);
  tl.fromTo($('.note-row', el), { autoAlpha: 0 }, { autoAlpha: 1, duration: d(0.7) }, t0 + 3.6);
};

/* s10 — close. */
Builders.s10 = (tl, el, t0, dur, d) => {
  tl.fromTo($('.s10-stack svg', el), { autoAlpha: 0, y: 18 }, { autoAlpha: 1, y: 0, duration: d(0.8) }, t0 + 0.3);
  tl.fromTo($('.h-md', el), { autoAlpha: 0, y: 18 }, { autoAlpha: 1, y: 0, duration: d(0.8) }, t0 + 0.9);
  tl.fromTo($('.terminal', el), { clipPath: 'inset(0 100% 0 0)', autoAlpha: 0 },
    { clipPath: 'inset(0 0% 0 0)', autoAlpha: 1, duration: d(1.2), ease: 'steps(8)' }, t0 + 2.0);
  tl.fromTo($('.url', el), { autoAlpha: 0 }, { autoAlpha: 1, duration: d(0.8) }, t0 + 3.6);
  tl.fromTo('.s10-stack', { scale: 1 }, { scale: 1.02, duration: dur, ease: 'none' }, t0);
};

/* ------------------------------------------------------------------ *
 * timeline assembly
 * ------------------------------------------------------------------ */

const Cues = (window.NARRATION || []).slice();
const Scenes = [];   // {id, start, dur, text, el}
const Master = { tl: null, captions: true, playing: false,
                 holdFull: params.get('hold') === 'full' };

function setCaption(text) {
  const cap = $('#captions');
  if (!cap) return;
  $('span', cap).textContent = text || '';
}

function buildTimeline() {
  const tl = gsap.timeline({
    paused: true,
    defaults: { ease: 'power2.out' },
    onUpdate: renderHud,
    onComplete: () => {
      Master.playing = false;
      Master.ended = true;
      Voice.stop();
      showGate('Replay');
    },
  });
  /* Register the global object BEFORE building, so DevTools can introspect a
   * timeline that is still being constructed. */
  window.MOVIE = Master;
  Master.tl = tl;
  Master.scenes = Scenes;

  const d = (sec) => (reduced ? 0.01 : sec);
  const sceneEls = $$('.scene');

  Scenes.length = 0;
  for (const s of sceneEls) s.setAttribute('aria-hidden', 'true');
  let cursor = 0;
  for (const cue of Cues) {
    const sceneEl = sceneEls.find((s) => s.id === cue.id || s.dataset.scene === cue.id);
    if (!sceneEl) {
      console.warn('[movie] no DOM for cue', cue.id);
      continue;
    }
    const dur = Voice.sceneSeconds(cue.id, cue.seconds);
    const start = cursor;
    Scenes.push({ id: cue.id, start, dur, text: cue.text, el: sceneEl });
    cursor += dur;

    tl.addLabel(cue.id, start);
    /* Opacity is a tween (a seek applies it); the .is-active class is applied
     * by renderHud from the playhead, NOT here — a callback is skipped by
     * seek(), and classList is used instead of GSAP's `className` plugin,
     * which SETS the attribute and once deleted .scene itself (the element
     * became position:static and lost its layout). */
    tl.set(sceneEl, { autoAlpha: 1 }, start);
    tl.call(() => Voice.start(cue.id, cue.text), null, start + 0.001);
    const builder = Builders[cue.id];
    if (builder) builder(tl, sceneEl, start, dur, d);
    /* crossfade out over the last 0.55 s so scenes breathe instead of cutting */
    tl.to(sceneEl, { autoAlpha: 0, duration: reduced ? 0.01 : 0.55, ease: 'power1.in' },
      start + dur - 0.55);

  }
  Master.duration = cursor;
  buildTicks();
  renderHud();
  return tl;
}

function buildTicks() {
  const bar = $('#progress');
  if (!bar) return;
  $$('.tick', bar).forEach((t) => t.remove());
  const total = Master.duration || 1;
  for (const s of Scenes) {
    const tick = el('div', 'tick');
    tick.style.left = (s.start / total * 100) + '%';
    bar.appendChild(tick);
  }
}

function sceneAt(t) {
  for (let i = Scenes.length - 1; i >= 0; i--) {
    if (t >= Scenes[i].start) return Scenes[i];
  }
  return Scenes[0];
}

function fmt(sec) {
  const s = Math.max(0, Math.floor(sec));
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
}

let lastSceneId = '';

function renderHud() {
  const tl = Master.tl;
  if (!tl) return;
  const t = tl.time();
  /* The caption follows the playhead, not a callback: seeking backwards,
   * deep-linking to ?t= and scrubbing in DevTools all show the right line. */
  const scene = sceneAt(t);
  if (scene && scene.id !== lastSceneId) {
    lastSceneId = scene.id;
    const label = $('#sceneLabel');
    if (label) label.textContent = scene.id;
    setCaption(scene.text);
    /* exactly one scene is marked active, whatever the playhead did to get
     * here: a live play, a seek, a scrub, a deep link. */
    for (const other of (Master.scenes || [])) {
      const on = other === scene;
      other.el.classList.toggle('is-active', on);
      other.el.setAttribute('aria-hidden', on ? 'false' : 'true');
    }
  }
  const pct = Master.duration ? (t / Master.duration) * 100 : 0;
  const fill = $('#progress > i');
  if (fill) fill.style.width = pct.toFixed(2) + '%';
  const clock = $('#clock');
  if (clock) clock.textContent = fmt(t) + ' / ' + fmt(Master.duration);
}

/* ------------------------------------------------------------------ *
 * transport
 * ------------------------------------------------------------------ */

function showGate(label) {
  const gate = $('#gate');
  if (!gate) return;
  $('#startBtn').textContent = label || 'Play';
  gate.classList.remove('hidden');
}

function startPlayback() {
  $('#gate').classList.add('hidden');
  /* Hand focus back to the document so Space/arrows reach the transport. */
  if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
  Voice.enabled = true;
  Voice.stop();
  const at = Master.tl.time();
  if (Master.ended || (Master.duration && at >= Master.duration - 0.05)) {
    /* replay: a finished timeline would otherwise just sit at the end, so the
     * "Replay" button appeared to do nothing. */
    Master.tl.pause(0);
    Master.ended = false;
  }
  Master.playing = true;
  Master.tl.play();
  if (Voice.mode === 'track' && !Voice.bed) {
    /* optional music bed: silent no-op when the file is absent */
    const bed = new Audio('audio/ambient.mp3');
    bed.loop = true;
    bed.volume = 0.12;
    bed.addEventListener('canplay', () => { Voice.bed = bed; bed.play().catch(() => {}); });
    bed.load();
  }
}

function togglePlay() {
  if (!Master.tl) return;
  if (Master.tl.paused()) {
    if ($('#gate').classList.contains('hidden') === false) return startPlayback();
    Master.playing = true;
    Master.tl.play();
    Voice.resume();
  } else {
    Master.playing = false;
    Master.tl.pause();
    Voice.pause();
  }
}

function jumpScene(dir) {
  if (!Master.tl) return;
  const now = Master.tl.time();
  const cur = Scenes.findIndex((s) => s === sceneAt(now));
  const idx = Math.min(Math.max(cur + dir, 0), Scenes.length - 1);
  const scene = Scenes[idx];
  const target = scene.start + 0.05;
  Master.tl.pause();
  Master.tl.seek(target);
  Voice.stop();
  if (Master.playing) {
    /* Skipping used to kill the narration for good: the timeline resumed but
     * nothing restarted the audio, so every scene after the first skip was
     * silent (reported as "cursor left/right and the voice is gone"). */
    Voice.start(scene.id, scene.text);
    Master.tl.play();
  }
}

/** DevTools / deep-link seek: exact, idempotent, audio-safe. */
function seek(t) {
  if (!Master.tl) return null;
  Master.ended = false;
  Master.tl.pause();
  Master.tl.seek(Math.min(Math.max(Number(t) || 0, 0), Master.duration));
  Voice.stop();
  renderHud();
  return { t: Master.tl.time(), scene: sceneAt(Master.tl.time()).id };
}

/* ------------------------------------------------------------------ *
 * boot
 * ------------------------------------------------------------------ */

function wireControls() {
  $('#startBtn').addEventListener('click', startPlayback);
  /* Clicking Play used to leave focus on the (now hidden) button in some
   * browsers, and the guard below then let the BUTTON handle Space — which
   * re-ran startPlayback on an already-playing film, so pause appeared broken.
   * Playback now moves focus off the button, and the guard only defers for
   * real text fields. */
  window.addEventListener('keydown', (e) => {
    const t = e.target;
    if (t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement ||
        t instanceof HTMLSelectElement) return;
    switch (e.key) {
      case ' ': e.preventDefault(); togglePlay(); break;
      case 'ArrowRight': e.preventDefault(); jumpScene(1); break;
      case 'ArrowLeft': e.preventDefault(); jumpScene(-1); break;
      case 'c': {
        Master.captions = !Master.captions;
        $('#captions').classList.toggle('hidden', !Master.captions);
        break;
      }
      case 'r': e.preventDefault(); seek(0); startPlayback(); break;
      case 'f': {
        if (!document.fullscreenElement) document.documentElement.requestFullscreen?.();
        else document.exitFullscreen?.();
        break;
      }
    }
  });
  /* Click the picture to pause/resume — the convention for every video player,
   * and the discoverable alternative to the keyboard. The gate and the HUD are
   * excluded so its button and progress bar stay usable. */
  $('#stage').addEventListener('click', (e) => {
    if (e.target.closest('#gate') || e.target.closest('#hud')) return;
    if (!Master.tl || $('#gate').classList.contains('hidden') === false) return;
    togglePlay();
  });
  window.addEventListener('resize', fitStage);
  /* hide the HUD when the pointer rests, like a video player */
  let hudTimer = null;
  window.addEventListener('mousemove', () => {
    $('#hud')?.classList.remove('dim');
    clearTimeout(hudTimer);
    hudTimer = setTimeout(() => $('#hud')?.classList.add('dim'), 2600);
  });
}

async function boot() {
  fitStage();
  wireControls();
  await Voice.load();
  buildTimeline();

  if (params.get('captions') === 'off') {
    Master.captions = false;
    $('#captions').classList.add('hidden');
  }

  /* Deep links used by tooling (and by the screenshot script):
   *   index.html?t=47.5&autoplay=1   – a frame at an exact time
   *   index.html?scene=s5&autoplay=1 – the start of a scene
   *   index.html?autoplay=1          – from the top, no gate
   */
  if (params.has('scene')) {
    const found = Scenes.find((s) => s.id === params.get('scene'));
    if (found) seek(found.start + (Number(params.get('into')) || 1.2));
    if (params.get('autoplay') === '1') { $('#gate').classList.add('hidden'); }
  } else if (params.has('t')) {
    seek(Number(params.get('t')));
    if (params.get('autoplay') === '1') { $('#gate').classList.add('hidden'); }
  } else if (params.get('autoplay') === '1') {
    startPlayback();
  }

  Master.seek = seek;
  Master.play = () => { $('#gate').classList.add('hidden'); Master.playing = true; Master.tl.play(); };
  Master.pause = () => { Master.playing = false; Master.tl.pause(); };
  /* Audio is otherwise invisible to an automated check: an Audio() element is
   * not in the DOM, so "did the voice actually play?" would be answered by ear.
   * This exposes the facts (which clip, currentTime, paused, muted, error). */
  Master.voice = Voice;
  Master.audioState = () => {
    const out = { mode: Voice.mode, enabled: Voice.enabled, clips: {} };
    for (const [id, a] of Object.entries(Voice.audios)) {
      out.clips[id] = {
        t: +a.currentTime.toFixed(2),
        dur: +a.duration.toFixed(2),
        paused: a.paused, muted: a.muted, volume: a.volume,
        error: a.error ? a.error.code : null,
        readyState: a.readyState,
      };
    }
    if (Voice.mode === 'browser') out.speaking = window.speechSynthesis?.speaking;
    out.blocked = Voice.blocked || null;
    return out;
  };
  Master.state = () => ({
    t: Master.tl.time(), duration: Master.duration,
    scene: sceneAt(Master.tl.time()).id,
    playing: !Master.tl.paused(), voice: Voice.mode, reduced,
  });
  document.documentElement.dataset.movieReady = '1';
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', boot);
} else {
  boot();
}
