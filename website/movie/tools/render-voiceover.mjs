#!/usr/bin/env node
/* Render the movie's narration to audio, one file per scene.
 *
 *   node tools/render-voiceover.mjs --dry-run        # plan + pacing check, no network
 *   node tools/render-voiceover.mjs --engine=openai  # neural TTS → audio/s1.mp3 …
 *   node tools/render-voiceover.mjs --engine=piper --piper-model=/path/en_US-amy.onnx
 *   node tools/render-voiceover.mjs --engine=piper --piper-length=0.9   # faster read
 *   node tools/render-voiceover.mjs --engine=xtts --speaker-wav=me.wav  # clone a voice
 *   node tools/render-voiceover.mjs --engine=kokoro   # af_nova @ 0.9 (this film)
 *   node tools/render-voiceover.mjs --engine=espeak  # offline placeholder (.wav)
 *   node tools/render-voiceover.mjs --engine=say     # macOS built-in voice
 *
 * Why per-scene files instead of one long track: the movie's timeline is keyed
 * to cue ids, and each scene lasts max(authored, measured + 0.45 s). Re-record
 * ONE line and only that scene changes length; the other nine scenes keep their
 * frames. A single mixed track would need re-cutting after every edit — that is
 * the mistake this layout exists to avoid.
 *
 * Outputs (all idempotent, plain static files, so the movie still runs from
 * file:// with no server):
 *   audio/<id>.<ext>        one clip per cue
 *   audio/narration.js      window.NARRATION_AUDIO = [{id, file, seconds}]
 *   audio/narration.srt     subtitles, timed with the same rule as the film
 *
 * Duration is measured in-process (MP3 frame walk / WAV header), so ffprobe is
 * NOT required — a stock checkout has no media tooling.
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, unlinkSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const AUDIO = join(ROOT, 'audio');

const args = new Map(
  process.argv.slice(2).map((a) => {
    const [k, ...rest] = a.replace(/^--/, '').split('=');
    return [k, rest.join('=') || 'true'];
  })
);
const flag = (k, d = '') => (args.has(k) ? args.get(k) : d);
const audition = args.has('audition');
  /* --audition: render ONE cue with every voice installed in .piper/voices and
   * write a player page, so "how do I hear the other voices?" is a click per
   * voice instead of re-rendering the whole film ten times. */
const engine = flag('engine', 'openai');
const dryRun = args.has('dry-run');
const force = args.has('force');
const GAP = 0.45;          // headroom after a line before the scene may cut
const END_PAUSE = 0.6;     // tail of the whole film
const WPM = 153;           // measured speaking rate, for the dry-run estimate

/* ------------------------------------------------------------------ *
 * the script (single source: website/movie/narration.js)
 * ------------------------------------------------------------------ */
function loadCues() {
  const src = readFileSync(join(ROOT, 'narration.js'), 'utf8');
  const win = {};
  new Function('window', src)(win);   // our own file, not user input
  if (!Array.isArray(win.NARRATION)) throw new Error('narration.js did not set window.NARRATION');
  return win.NARRATION;
}

/* ------------------------------------------------------------------ *
 * duration measurement, no external tools
 * ------------------------------------------------------------------ */
const BR_V1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
const BR_V2L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
const SR = { 3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000] };

/** Seconds in an MP3, by walking its frames (MPEG 1/2/2.5, Layer III). */
function mp3Duration(buf) {
  let i = 0;
  if (buf.length > 10 && buf.toString('latin1', 0, 3) === 'ID3') {
    const size = ((buf[6] & 0x7f) << 21) | ((buf[7] & 0x7f) << 14) |
                 ((buf[8] & 0x7f) << 7) | (buf[9] & 0x7f);
    i = 10 + size;
  }
  let seconds = 0;
  let frames = 0;
  while (i + 4 <= buf.length) {
    if (buf[i] !== 0xff || (buf[i + 1] & 0xe0) !== 0xe0) { i++; continue; }
    const ver = (buf[i + 1] >> 3) & 3;        // 3=MPEG1, 2=MPEG2, 0=MPEG2.5
    const layer = (buf[i + 1] >> 1) & 3;      // 1 = Layer III
    const brIdx = (buf[i + 2] >> 4) & 0xf;
    const srIdx = (buf[i + 2] >> 2) & 3;
    const pad = (buf[i + 2] >> 1) & 1;
    if (layer !== 1 || ver === 1 || srIdx === 3 || brIdx === 0 || brIdx === 15) { i++; continue; }
    const table = ver === 3 ? BR_V1L3 : BR_V2L3;
    const bitrate = table[brIdx] * 1000;
    const rate = SR[ver][srIdx];
    const spf = ver === 3 ? 1152 : 576;
    const len = Math.floor((spf / 8) * bitrate / rate) + pad;
    if (len <= 0) { i++; continue; }
    seconds += spf / rate;
    frames++;
    i += len;
  }
  return frames > 0 ? seconds : null;
}

function wavDuration(buf) {
  if (buf.toString('latin1', 0, 4) !== 'RIFF') return null;
  let i = 12;
  let rate = 0, channels = 0, bits = 0, dataLen = 0;
  while (i + 8 <= buf.length) {
    const id = buf.toString('latin1', i, i + 4);
    const size = buf.readUInt32LE(i + 4);
    if (id === 'fmt ') {
      channels = buf.readUInt16LE(i + 10);
      rate = buf.readUInt32LE(i + 12);
      bits = buf.readUInt16LE(i + 22);
    } else if (id === 'data') {
      dataLen = size;
      break;
    }
    i += 8 + size + (size % 2);
  }
  if (!rate || !channels || !bits) return null;
  return dataLen / (rate * channels * (bits / 8));
}

function measure(file) {
  const buf = readFileSync(file);
  const lower = file.toLowerCase();
  if (lower.endsWith('.wav')) return wavDuration(buf);
  if (lower.endsWith('.mp3')) return mp3Duration(buf);
  return null;
}

/* ------------------------------------------------------------------ *
 * engines
 * ------------------------------------------------------------------ */
const OPENAI_BASE = (process.env.NIF_TTS_BASE_URL || process.env.NIF_OPENAI_BASE_URL ||
  'https://api.openai.com/v1').replace(/\/$/, '');
const OPENAI_KEY = process.env.NIF_TTS_API_KEY || process.env.NIF_OPENAI_API_KEY || '';
const OPENAI_MODEL = process.env.NIF_TTS_MODEL || 'gpt-4o-mini-tts';
const OPENAI_VOICE = process.env.NIF_TTS_VOICE || 'sage';
const OPENAI_INSTRUCTIONS = process.env.NIF_TTS_INSTRUCTIONS ||
  'Calm, confident technical narrator. Warm but not salesy. Crisp consonants, ' +
  'measured pace, short pauses between clauses. No upward inflection at the end.';

async function synthOpenAI(text, out) {
  if (!OPENAI_KEY) throw new Error('no key: set NIF_TTS_API_KEY or NIF_OPENAI_API_KEY');
  const body = {
    model: OPENAI_MODEL,
    voice: OPENAI_VOICE,
    input: text,
    response_format: 'mp3',
    speed: Number(process.env.NIF_TTS_SPEED || 1.0),
  };
  /* gpt-4o-* takes style instructions; older tts-1* models reject the field,
   * so it is opt-in per model rather than always sent. */
  if (/gpt-4o/.test(OPENAI_MODEL)) body.instructions = OPENAI_INSTRUCTIONS;
  for (let attempt = 1; attempt <= 3; attempt++) {
    const res = await fetch(`${OPENAI_BASE}/audio/speech`, {
      method: 'POST',
      headers: { authorization: `Bearer ${OPENAI_KEY}`, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (res.ok) {
      writeFileSync(out, Buffer.from(await res.arrayBuffer()));
      return;
    }
    const detail = (await res.text()).slice(0, 300);
    if (res.status === 429 || res.status >= 500) {
      const wait = 1500 * attempt;
      console.warn(`  ${res.status} — retrying in ${wait}ms (${detail})`);
      await new Promise((r) => setTimeout(r, wait));
      continue;
    }
    throw new Error(`TTS ${res.status}: ${detail}`);
  }
  throw new Error('TTS failed after 3 attempts');
}

function run(cmd, argv, stdin, extraEnv) {
  return new Promise((resolve, reject) => {
    const env = extraEnv ? { ...process.env, ...extraEnv } : process.env;
    const p = spawn(cmd, argv, { stdio: ['pipe', 'pipe', 'pipe'], env });
    let err = '';
    p.stderr.on('data', (d) => (err += d));
    p.on('error', reject);
    p.on('close', (code) => (code === 0 ? resolve()
      : reject(new Error(`${cmd} exited ${code}: ${err.slice(0, 300)}`))));
    if (stdin != null) p.stdin.end(stdin);
  });
}

/* Piper: the default local engine. `tools/fetch-piper.sh` drops a
 * self-contained build (binary + espeak-ng data + libonnxruntime) into
 * .piper/ and a voice into .piper/voices/, so this needs no pip, no sudo and
 * no network at render time. The bundled binary needs its own directory on
 * the loader path, which is why LD_LIBRARY_PATH is set here rather than left
 * to the caller. */
function piperPaths() {
  const binDir = flag('piper-dir', process.env.NIF_PIPER_DIR ||
    join(ROOT, '.piper'));
  const bin = process.env.NIF_PIPER_BIN || join(binDir, 'piper', 'piper');
  const model = flag('piper-model', process.env.NIF_PIPER_MODEL ||
    join(binDir, 'voices', 'en_US-ryan-high.onnx'));
  return { binDir, bin, model };
}

/* Pace control. `length_scale` < 1 shortens phonemes (faster), > 1 lengthens
 * them (calmer); 1.0 is the voice's own pace. Measured on this box, cue s5:
 *   en_GB-alan-medium    125 wpm at 1.0   — slow, older timbre
 *   en_US-kusal-medium   ~185 wpm at 1.0
 *   en_US-ryan-high       196 wpm at 1.0  — the film's default (brisk, bright);
 *                         ~180 wpm at 1.15 if that reads too quick
 * Piper's own speed varies a lot by voice, so tune per voice rather than
 * assuming a shared number. Override per render:
 *   --piper-length=1.15   or   NIF_PIPER_LENGTH=1.15
 * (Piper also has --sentence_silence, which we leave at its default: the cue
 * breaks already provide the pauses, and a shorter silence makes the read
 * sound clipped between sentences.) */
async function synthPiper(text, out) {
  const { binDir, bin, model } = piperPaths();
  const lengthScale = flag('piper-length', process.env.NIF_PIPER_LENGTH || '1.0');
  if (!existsSync(bin)) {
    throw new Error(`piper binary not found at ${bin} — run tools/fetch-piper.sh`);
  }
  if (!existsSync(model)) {
    throw new Error(`piper voice not found at ${model} — run tools/fetch-piper.sh`);
  }
  await run(bin, ['-m', model, '--length_scale', lengthScale, '-f', out], text + '\n', {
    LD_LIBRARY_PATH: join(binDir, 'piper'),
  });
}

async function synthEspeak(text, out) {
  await run('espeak-ng',
    ['-v', flag('espeak-voice', 'en-GB'), '-s', flag('espeak-speed', '150'), '-w', out],
    text + '\n');
}

/* Coqui XTTS v2: zero-shot voice cloning. `--speaker-wav=<6-12s of clean
 * speech>` and every cue is read in that voice. On CPU this is minutes per cue
 * (20-60x slower than realtime), so it is a "render once, listen" engine, not
 * an iteration loop. Requires `pip install TTS` and accepting the CPML licence
 * on first run; the model is downloaded once into ~/.local/share/tts. */
async function synthXtts(text, out) {
  const speaker = flag('speaker-wav', process.env.NIF_XTTS_SPEAKER || '');
  if (!speaker) {
    throw new Error('xtts needs a reference voice: --speaker-wav=ref.wav (6-12 s, ' +
                    'clean single speaker) or NIF_XTTS_SPEAKER');
  }
  const device = flag('xtts-device', process.env.NIF_XTTS_DEVICE || 'cpu');
  const language = flag('xtts-language', process.env.NIF_XTTS_LANGUAGE || 'en');
  /* One process for all cues would be far faster (model load dominates), but
   * the renderer's contract is one synth call per cue; XTTS therefore pays a
   * model load per line. Set NIF_XTTS_BATCH=1 to render every cue in ONE
   * process instead — implemented below in main(). */
  const script = `
import sys
from TTS.api import TTS
tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(${JSON.stringify(device)})
tts.tts_to_file(text=sys.stdin.read(), speaker_wav=${JSON.stringify(speaker)},
                language=${JSON.stringify(language)}, file_path=${JSON.stringify(out)})
`;
  await run('python3', ['-c', script], text + '\n');
}

/** Batch variant for XTTS: load the model ONCE and render the whole cue list. */
async function xttsBatch(cues, ext) {
  const speaker = flag('speaker-wav', process.env.NIF_XTTS_SPEAKER || '');
  if (!speaker) throw new Error('xtts needs --speaker-wav=<ref.wav>');
  const device = flag('xtts-device', process.env.NIF_XTTS_DEVICE || 'cpu');
  const language = flag('xtts-language', process.env.NIF_XTTS_LANGUAGE || 'en');
  const jobs = cues.map((c) => ({ id: c.id, text: c.text, out: join(AUDIO, c.id + '.' + ext) }));
  const script = `
import json, sys
from TTS.api import TTS
jobs = json.loads(sys.argv[1])
tts = TTS("tts_models/multilingual/multi-dataset/xtts_v2").to(${JSON.stringify(device)})
for j in jobs:
    print("  render", j["id"], flush=True)
    tts.tts_to_file(text=j["text"], speaker_wav=${JSON.stringify(speaker)},
                    language=${JSON.stringify(language)}, file_path=j["out"])
`;
  await run('python3', ['-c', script, JSON.stringify(jobs)]);
}

/* Kokoro-82M: the best-sounding local option here (~1.3x realtime on CPU, 54
 * English voices). A private venv + model live in ~/.cache (tools/
 * fetch-kokoro.sh); jobs go to a small python bridge so the model loads ONCE
 * for the whole cue list. `speed` is Kokoro's own rate knob (>1 = faster),
 * unlike Piper's inverse `length_scale`. */
function kokoroEnv() {
  const home = process.env.NIF_KOKORO_HOME || join(process.env.HOME || '', '.cache', 'niffler-movie');
  const py = process.env.NIF_KOKORO_PYTHON || join(home, 'venv', 'bin', 'python');
  return { py, bridge: join(HERE, 'kokoro-say.py') };
}

async function runKokoroJobs(jobs) {
  const { py, bridge } = kokoroEnv();
  if (!existsSync(py)) {
    throw new Error(`kokoro venv not found at ${py} — run tools/fetch-kokoro.sh`);
  }
  const jobsFile = join(AUDIO, `.jobs-${process.pid}.json`);
  writeFileSync(jobsFile, JSON.stringify(jobs));
  try {
    await run(py, [bridge, '--jobs', jobsFile]);
  } finally {
    try { unlinkSync(jobsFile); } catch (e) { /* nothing to clean up */ }
  }
}

/* THE FILM'S VOICE (chosen by listening, measured to confirm):
 *   kokoro af_nova @ 0.9  →  ~173 wpm average, 2:05, 16% dwell
 * Nova at 1.0 was too brisk (217 wpm on the opening cue, ~183 average); 0.9
 * tightens the per-scene spread from 132-217 to 121-210 and lands the long
 * middle scenes at 168-185, which is the comfortable explainer range. These
 * defaults exist so a re-render reproduces the shipped film without flags. */
const KOKORO_VOICE_DEFAULT = 'af_nova';
const KOKORO_SPEED_DEFAULT = '0.9';

function kokoroVoice() { return flag('kokoro-voice', process.env.NIF_KOKORO_VOICE || KOKORO_VOICE_DEFAULT); }
function kokoroSpeed() { return flag('kokoro-speed', process.env.NIF_KOKORO_SPEED || KOKORO_SPEED_DEFAULT); }

async function synthKokoro(text, out) {
  await runKokoroJobs([{ id: 'cue', text, out, voice: kokoroVoice(), speed: kokoroSpeed() }]);
}

/** Batch: one model load for every cue. */
async function kokoroBatch(cues, ext) {
  await runKokoroJobs(cues.map((c) => ({
    id: c.id, text: c.text, out: join(AUDIO, c.id + '.' + ext),
    voice: kokoroVoice(), speed: kokoroSpeed(),
  })));
}

async function synthSay(text, out) {
  /* macOS: say → aiff, afconvert → wav (both ship with the OS) */
  const aiff = out.replace(/\.wav$/, '.aiff');
  await run('say', ['-v', flag('say-voice', 'Samantha'),
                    '-r', flag('say-rate', '170'), '-o', aiff], text + '\n');
  await run('afconvert', ['-f', 'WAVE', '-d', 'LEI16@22050', aiff, out]);
}

const ENGINES = {
  openai: { ext: 'mp3', synth: synthOpenAI },
  piper: { ext: 'wav', synth: synthPiper },
  espeak: { ext: 'wav', synth: synthEspeak },
  say: { ext: 'wav', synth: synthSay },
  xtts: { ext: 'wav', synth: synthXtts, batch: xttsBatch },
  kokoro: { ext: 'wav', synth: synthKokoro, batch: kokoroBatch },
};

/* ------------------------------------------------------------------ *
 * helpers
 * ------------------------------------------------------------------ */
const words = (t) => t.trim().split(/\s+/).length;
const mmss = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;

function srtTime(s) {
  const ms = Math.round((s % 1) * 1000);
  return `${String(Math.floor(s / 3600)).padStart(2, '0')}:` +
         `${String(Math.floor(s / 60) % 60).padStart(2, '0')}:` +
         `${String(Math.floor(s) % 60).padStart(2, '0')},${String(ms).padStart(3, '0')}`;
}

/* ------------------------------------------------------------------ *
 * main
 * ------------------------------------------------------------------ */
/* ------------------------------------------------------------------ *
 * audition: one line, every installed voice, one page
 * ------------------------------------------------------------------ */
async function runAudition(cues) {
  const outDir = join(AUDIO, 'audition');
  mkdirSync(outDir, { recursive: true });
  const which = flag('audition-engine', 'all');   // all | piper | kokoro
  /* Cue s5 is the best sample: it is the film's argument, long enough to hear
   * timbre rather than a single sentence. */
  const cue = cues.find((c) => c.id === flag('audition-cue', 's5')) || cues[0];
  const wordCount = words(cue.text);
  const esc = (x) => String(x).replace(/[&<>"]/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const rows = [];
  const wpmOf = (file) => {
    const sec = measure(join(outDir, file));
    return sec ? Math.round(wordCount / (sec / 60)) : 0;
  };

  /* ---- Kokoro: 54 voices, the better-sounding family ---- */
  if (which === 'all' || which === 'kokoro') {
    const { py, bridge } = kokoroEnv();
    if (!existsSync(py)) {
      console.warn('  (kokoro not installed — skipped; run tools/fetch-kokoro.sh)');
    } else {
      const picks = (flag('kokoro-voices', '') ||
        `af_nova,${KOKORO_VOICE_DEFAULT},af_heart,af_bella,af_sarah,af_sky,af_kore,` +
        'am_michael,am_fenrir,am_puck,am_adam,bm_george,bm_fable,bf_emma').split(',');
      const speeds = flag('kokoro-speeds', '1.0').split(',');
      const jobs = [], index = [];
      for (const v of picks) {
        for (const sp of speeds) {
          const file = `kokoro-${v}@${sp}.wav`;
          jobs.push({ id: `${v}@${sp}`, text: cue.text, out: join(outDir, file),
                      voice: v, speed: sp });
          index.push({ voice: `kokoro · ${v}`, pace: sp, file });
        }
      }
      const jobsFile = join(AUDIO, `.audition-${process.pid}.json`);
      writeFileSync(jobsFile, JSON.stringify(jobs));
      try { await run(py, [bridge, '--jobs', jobsFile]); }
      finally { try { unlinkSync(jobsFile); } catch (e) {} }
      for (const i of index) rows.push({ ...i, wpm: wpmOf(i.file) });
      process.stdout.write('.'.repeat(index.length));
    }
  }

  /* ---- Piper: every voice installed in .piper/voices ---- */
  if (which === 'all' || which === 'piper') {
    const { binDir, bin } = piperPaths();
    const voicesDir = join(binDir, 'voices');
    if (!existsSync(bin)) throw new Error(`piper not found at ${bin} — run tools/fetch-piper.sh`);
    const voices = readdirSync(voicesDir).filter((f) => f.endsWith('.onnx')).sort();
    if (voices.length === 0) throw new Error(`no voices in ${voicesDir} — run tools/fetch-piper.sh`);
    const lengths = flag('audition-lengths', '1,1.15').split(',').map((x) => x.trim());
    for (const voice of voices) {
      for (const ls of lengths) {
        const name = voice.replace(/\.onnx$/, '');
        const file = `${name}@${ls}.wav`;
        await run(bin, ['-m', join(voicesDir, voice), '--length_scale', ls,
                        '-f', join(outDir, file)],
                  cue.text + '\n', { LD_LIBRARY_PATH: join(binDir, 'piper') });
        rows.push({ voice: `piper · ${name}`, pace: ls, file, wpm: wpmOf(file) });
        process.stdout.write('.');
      }
    }
  }
  process.stdout.write('\n');
  rows.sort((a, b) => a.wpm - b.wpm);

  const html = `<!doctype html><meta charset="utf-8">
<title>Niffler — voice audition</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; padding: 40px 32px 80px; background: #0b1826; color: #e8f4ee;
         font: 15px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
  h1 { font-size: 26px; margin: 0 0 6px; letter-spacing: -0.01em; }
  p.lede { color: #93a9b8; margin: 0 0 12px; max-width: 74ch; }
  code { font-family: ui-monospace, Menlo, monospace; color: #42e6a4; }
  table { border-collapse: collapse; width: 100%; max-width: 1100px; margin-top: 22px; }
  th, td { text-align: left; padding: 9px 14px; border-bottom: 1px solid #1e3b52; }
  th { font-size: 12px; text-transform: uppercase; letter-spacing: .12em; color: #6f8698; font-weight: 500;
       position: sticky; top: 0; background: #0b1826; }
  td.voice { font-family: ui-monospace, Menlo, monospace; white-space: nowrap; }
  td.pace { font-family: ui-monospace, Menlo, monospace; color: #42e6a4; }
  audio { height: 32px; width: 320px; }
  tr:hover td { background: rgba(66,230,164,.05); }
  .hint { margin-top: 24px; color: #6f8698; font-size: 13px; max-width: 84ch; }
</style>
<h1>Voice audition</h1>
<p class="lede">Cue <code>${esc(cue.id)}</code> (${wordCount} words) in every available voice,
sorted by measured pace. <b>${rows.length}</b> samples.</p>
<p class="lede">Then render the film with the one you like:<br>
<code>node tools/render-voiceover.mjs --engine=kokoro --kokoro-voice=&lt;id&gt; --kokoro-speed=&lt;n&gt;</code></p>
<table>
<tr><th>voice</th><th>pace</th><th>measured</th><th>listen</th></tr>
${rows.map((r) => `<tr><td class="voice">${esc(r.voice)}</td><td>${esc(r.pace)}</td>` +
  `<td class="pace">${r.wpm} wpm</td>` +
  `<td><audio controls preload="none" src="audition/${esc(r.file)}"></audio></td></tr>`).join('\n')}
</table>
<p class="hint">Kokoro "speed" &gt;1 is faster (its own knob); Piper pace is
<code>--length_scale</code>, where lower is faster. 150–180 wpm suits an explainer.</p>
`;
  writeFileSync(join(AUDIO, 'audition.html'), html);
  console.log(`wrote audio/audition.html (${rows.length} samples)`);
  console.log(`  file://${join(AUDIO, 'audition.html')}`);
}

async function main() {
  const cues = loadCues();
  if (audition && !dryRun) return runAudition(cues);
  const eng = ENGINES[engine];
  if (!eng) throw new Error(`unknown engine ${engine} (openai|piper|kokoro|espeak|say|xtts)`);
  mkdirSync(AUDIO, { recursive: true });

  /* XTTS loading its model per cue is wasteful by minutes; batch it unless the
   * caller explicitly wants per-cue synthesis (NIF_XTTS_BATCH=0). */
  const batched = eng.batch && !dryRun && !force &&
    !cues.every((c) => existsSync(join(AUDIO, c.id + '.' + eng.ext)));
  const batchOff = engine === 'xtts' && process.env.NIF_XTTS_BATCH === '0';
  const useBatch = !!eng.batch && !dryRun && !batchOff &&
    (force || !cues.every((c) => existsSync(join(AUDIO, c.id + '.' + eng.ext))));
  if (useBatch) {
    console.log(`  batch mode: loading the model once for ${cues.length} cues`);
    await eng.batch(cues, eng.ext);
  }

  const rows = [];
  let total = 0;
  for (const cue of cues) {
    const file = `${cue.id}.${eng.ext}`;
    const path = join(AUDIO, file);
    let seconds = null;

    /* ALWAYS measure what is on disk — batched engines write their files above
     * and never enter the per-cue branch, which silently left every duration
     * null: the manifest then carried seconds: 0, the film could not re-time
     * itself, and the table printed the WPM estimate instead of the truth.
     * (Caught when a Kokoro render reported 153 wpm for every cue.) */
    if (!dryRun) {
      if (!useBatch && (!existsSync(path) || force)) {
        process.stdout.write(`  render ${cue.id} … `);
        await eng.synth(cue.text, path);
      }
      seconds = measure(path);
      if (seconds != null) {
        process.stdout.write(`  ${cue.id} ${seconds.toFixed(2)}s\n`);
      } else {
        console.warn(`  ${cue.id}: file present but duration unreadable (${path})`);
      }
    }

    /* Pacing check: a cue that cannot fit its authored scene is an editorial
     * error, not a technical one — catch it here, before spending on a render. */
    const authored = cue.seconds;
    const n = words(cue.text);
    const spoken = seconds ?? n / (WPM / 60);
    const scene = Math.max(authored, spoken + GAP);
    total += scene;
    rows.push({
      id: cue.id, words: n,
      wpm: Math.round(n / (spoken / 60)),
      spoken, authored, scene,
      fit: spoken > authored ? `OVERRUN (+${(spoken - authored).toFixed(1)}s)`
           : spoken > authored - 1.2 ? 'tight' : 'ok',
      measured: seconds != null, file,
    });
  }

  const head = 'cue    words  wpm  spoken  authored   scene  status';
  console.log('\n' + head);
  console.log('-'.repeat(64));
  for (const r of rows) {
    console.log(
      r.id.padEnd(6) + String(r.words).padStart(5) + String(r.wpm).padStart(5) +
      (r.spoken.toFixed(1) + 's').padStart(8) + (r.authored + 's').padStart(10) +
      (r.scene.toFixed(1) + 's').padStart(8) + '  ' + r.fit
    );
  }
  console.log('-'.repeat(64));
  const overruns = rows.filter((r) => r.fit.startsWith('OVERRUN')).length;
  const wordsTotal = rows.reduce((a, r) => a + r.words, 0);
  console.log(`${rows.length} cues · ${wordsTotal} words · film ${mmss(total + END_PAUSE)} · ` +
              (overruns ? `${overruns} cue(s) OVERRUN their scene` : 'all cues fit'));

  if (dryRun) {
    console.log('\n(dry run: no audio written, no network used)');
    if (overruns) {
      console.log('fix by lengthening the cue\'s `seconds` in narration.js, or cutting words.');
      process.exitCode = 2;
    }
    return;
  }

  /* the movie's loader reads this (a .js file, because file:// blocks fetch) */
  const meta = rows.map((r) => ({
    id: r.id, file: r.file,
    seconds: Number((r.measured ? r.spoken : 0).toFixed(3)),
  }));
  writeFileSync(join(AUDIO, 'narration.js'),
    '/* generated by tools/render-voiceover.mjs — do not edit */\n' +
    'window.NARRATION_AUDIO = ' + JSON.stringify(meta, null, 2) + ';\n');

  /* subtitles, timed with the same rule the film uses */
  let t = 0;
  const srt = [];
  rows.forEach((r, i) => {
    const start = t;
    t += r.scene;
    srt.push(`${i + 1}\n${srtTime(start)} --> ` +
             `${srtTime(Math.min(start + r.spoken + 0.2, start + r.scene))}\n` +
             `${cues[i].text}\n`);
  });
  writeFileSync(join(AUDIO, 'narration.srt'), srt.join('\n'));

  console.log(`\nwrote audio/narration.js, audio/narration.srt, ${rows.length} clip(s).`);
  console.log('preview with:  index.html?voice=track&autoplay=1');
}

main().catch((e) => {
  console.error('render-voiceover: ' + e.message);
  process.exit(1);
});
