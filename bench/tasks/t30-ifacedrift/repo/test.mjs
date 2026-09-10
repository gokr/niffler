// Verifies every svcNN module against the migration spec in README.md.
// Independent reference implementation - modules cannot fake it.
//
// The expected module set and each module's profile/width are PINNED to the
// base revision: an agent cannot make the task easier by deleting modules or
// rewriting a header, and an empty/missing directory fails instead of
// vacuously "passing".
import { readFileSync, readdirSync } from "node:fs";

const EXPECTED = {
  "svc01.mjs": ["lenient", 10], "svc02.mjs": ["strict", 8],
  "svc03.mjs": ["lenient", 6], "svc04.mjs": ["strict", 10],
  "svc05.mjs": ["lenient", 8], "svc06.mjs": ["strict", 6],
  "svc07.mjs": ["strict", 10], "svc08.mjs": ["lenient", 8],
  "svc09.mjs": ["strict", 6], "svc10.mjs": ["lenient", 10],
  "svc11.mjs": ["strict", 8], "svc12.mjs": ["lenient", 6],
  "svc13.mjs": ["strict", 10], "svc14.mjs": ["strict", 8],
  "svc15.mjs": ["lenient", 6], "svc16.mjs": ["strict", 10],
  "svc17.mjs": ["lenient", 8], "svc18.mjs": ["strict", 6],
  "svc19.mjs": ["lenient", 10], "svc20.mjs": ["strict", 8],
  "svc21.mjs": ["strict", 6], "svc22.mjs": ["lenient", 10],
  "svc23.mjs": ["strict", 8], "svc24.mjs": ["lenient", 6],
};

function refParse(input, mode) {
  const out = {};
  for (const seg of input.split(";")) {
    if (mode === "lenient" && seg.trim() === "") continue;
    const eq = seg.indexOf("=");
    if (eq < 0) throw new Error("no '='");
    let k = seg.slice(0, eq), v = seg.slice(eq + 1);
    if (mode === "lenient") { k = k.trim(); v = v.trim(); }
    else if (k !== k.trim() || v !== v.trim()) throw new Error("strict ws");
    if (k in out) throw new Error("dup");
    out[k] = v;
  }
  return out;
}
const refFormat = (obj, width) =>
  Object.keys(obj).sort().map((k) => k.padEnd(width, ".") + obj[k]).join("\n");

const svcFiles = readdirSync(".").filter((f) => /^svc\d+\.mjs$/.test(f)).sort();
let failed = 0;
const missing = Object.keys(EXPECTED).filter((f) => !svcFiles.includes(f));
const extra = svcFiles.filter((f) => !(f in EXPECTED));
for (const f of missing) { console.log(`${f}: FAIL expected module is missing`); failed++; }
for (const f of extra) { console.log(`${f}: FAIL unexpected module`); failed++; }
for (const f of Object.keys(EXPECTED)) {
  if (!svcFiles.includes(f)) continue;
  const [wantProfile, wantWidth] = EXPECTED[f];
  const nn = Number(f.match(/\d+/)[0]);
  const src = readFileSync(f, "utf8");
  const profile = (src.match(/^\/\/ profile:\s*(\S+)/m) || [])[1];
  const width = Number((src.match(/^\/\/ width:\s*(\d+)/m) || [])[1]);
  const fail = (msg) => { console.log(`${f}: FAIL ${msg}`); failed++; };
  // headers are part of the contract: they must still declare the base values
  if (profile !== wantProfile) { fail(`// profile: changed (${profile} != ${wantProfile})`); continue; }
  if (width !== wantWidth) { fail(`// width: changed (${width} != ${wantWidth})`); continue; }
  let mod;
  try { mod = await import(`./${f}`); } catch (e) { fail(`import error: ${e.message}`); continue; }
  const clean = `k1=${nn};k22=${nn * 2};k333=${nn * 3}`;
  const padded = ` k1 = ${nn} ; k22 = ${nn * 2} `;
  const dup = `k1=${nn};k1=${nn + 1}`;
  const wantClean = refFormat(refParse(clean, profile), width);
  try {
    const got = mod.transform(clean);
    if (got !== wantClean) { fail(`clean: got ${JSON.stringify(got)}, want ${JSON.stringify(wantClean)}`); continue; }
  } catch (e) { fail(`clean: threw ${e.message}`); continue; }
  const paddedThrows = profile === "strict";
  let wantPadded = null;
  if (!paddedThrows) wantPadded = refFormat(refParse(padded, profile), width);
  try {
    const got = mod.transform(padded);
    if (paddedThrows) fail("padded: expected a strict-mode throw, got output");
    else if (got !== wantPadded) fail(`padded: got ${JSON.stringify(got)}, want ${JSON.stringify(wantPadded)}`);
  } catch (e) {
    if (!paddedThrows) fail(`padded: lenient mode should trim, not throw (${e.message})`);
  }
  try {
    mod.transform(dup);
    fail("dup: expected a duplicate-key throw");
  } catch { /* required */ }
}
if (failed) { console.log(`${failed} check(s) failed`); process.exit(1); }
console.log(`all ${svcFiles.length} modules pass`);
