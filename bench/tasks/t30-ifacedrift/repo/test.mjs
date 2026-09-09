// Verifies every svcNN module against the migration spec in README.md.
// Independent reference implementation - modules cannot fake it.
import { readFileSync, readdirSync } from "node:fs";

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
for (const f of svcFiles) {
  const nn = Number(f.match(/\d+/)[0]);
  const src = readFileSync(f, "utf8");
  const profile = (src.match(/^\/\/ profile:\s*(\S+)/m) || [])[1];
  const width = Number((src.match(/^\/\/ width:\s*(\d+)/m) || [])[1]);
  const fail = (msg) => { console.log(`${f}: FAIL ${msg}`); failed++; };
  if (profile !== "strict" && profile !== "lenient") { fail("bad/missing // profile: header"); continue; }
  if (!(width >= 4 && width <= 12)) { fail("bad/missing // width: header"); continue; }
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
