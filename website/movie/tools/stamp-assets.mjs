#!/usr/bin/env node
/* Stamp index.html's asset URLs with a content hash.
 *
 * GitHub Pages answers every file with `cache-control: max-age=600`, so a
 * browser that loaded the film keeps the OLD movie.js for ten minutes after a
 * deploy — and a stale JS paired with a fresh CSS is a broken mix, not a stale
 * look. (That is exactly what "it does not load on my phone" turned out to be,
 * once the phone layout itself was fixed: the phones were still running the
 * previous script.)
 *
 * A content-hash query makes each deploy a distinct URL while staying stable
 * for unchanged files, so repeat visits still hit the cache.
 *
 * Run: node tools/stamp-assets.mjs          (rewrites index.html in place)
 *      node tools/stamp-assets.mjs --check  (exit 1 if a stamp is stale)
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const INPUTS = ['movie.css', 'narration.js', 'movie.js'];
const checkOnly = process.argv.includes('--check');

const stamp = (f) =>
  createHash('sha256').update(readFileSync(join(ROOT, f))).digest('hex').slice(0, 10);

const hashes = Object.fromEntries(INPUTS.map((f) => [f, stamp(f)]));
const indexPath = join(ROOT, 'index.html');
const before = readFileSync(indexPath, 'utf8');
let stale = 0;

const after = before.replace(
  /(href|src)="(movie\.css|movie\.js|narration\.js)(\?v=[0-9a-f]+)?"/g,
  (_, attr, file, existing) => {
    const want = `?v=${hashes[file]}`;
    if (existing !== want) stale++;
    return `${attr}="${file}${want}"`;
  }
);

if (checkOnly) {
  if (stale > 0) {
    console.error(`stamp-assets: ${stale} stale asset URL(s) in index.html — run: node tools/stamp-assets.mjs`);
    process.exit(1);
  }
  console.log('stamp-assets: index.html asset stamps are current');
} else if (after !== before) {
  writeFileSync(indexPath, after);
  console.log('stamp-assets: updated', JSON.stringify(hashes));
} else {
  console.log('stamp-assets: already current', JSON.stringify(hashes));
}
