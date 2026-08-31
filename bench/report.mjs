#!/usr/bin/env node
// bench/report.mjs — aggregate bench results into a markdown + CSV report.
//
//   node bench/report.mjs --run <runId>     # bench/results/<runId>
//   node bench/report.mjs --latest
import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const BENCH_DIR = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)));
const argv = process.argv.slice(2);
function opt(name) {
  const i = argv.indexOf("--" + name);
  return i === -1 ? null : argv[i + 1];
}

let runDir;
if (opt("run")) runDir = path.join(BENCH_DIR, "results", opt("run"));
else if (opt("latest")) {
  const dirs = fs
    .readdirSync(path.join(BENCH_DIR, "results"), { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();
  if (!dirs.length) {
    console.error("no runs found");
    process.exit(1);
  }
  runDir = path.join(BENCH_DIR, "results", dirs.at(-1));
} else {
  console.error("usage: report.mjs --run <id> | --latest");
  process.exit(1);
}

const results = [];
for (const f of fs.readdirSync(runDir)) {
  if (!f.endsWith(".json") || f === "run.json") continue;
  const r = JSON.parse(fs.readFileSync(path.join(runDir, f), "utf8"));
  if (r.verdict) results.push(r);
}
if (!results.length) {
  console.error(`no results in ${runDir}`);
  process.exit(1);
}

results.sort(
  (a, b) =>
    a.model.localeCompare(b.model) ||
    a.harness.localeCompare(b.harness) ||
    a.task.localeCompare(b.task),
);

const fmtTok = (n) => (n >= 1000 ? (n / 1000).toFixed(1) + "k" : String(n));
const md = [];
md.push(`# bench report — ${path.basename(runDir)}`);
md.push("");
md.push(
  "| model | harness | task | verdict | time (s) | rounds | tok in | tok out | cache r/w | cost $ | diff (+/-) |",
);
md.push("|---|---|---|---|---:|---:|---:|---:|---|---:|---|");
for (const r of results) {
  md.push(
    `| ${r.model} | ${r.harness} | ${r.task} | ${r.verdict}${r.invalid ? "*" : ""} | ` +
      `${r.totalTimeS} | ${r.rounds} | ${fmtTok(r.tokens?.input || 0)} | ` +
      `${fmtTok(r.tokens?.output || 0)} | ` +
      `${fmtTok(r.tokens?.cacheRead || 0)}/${fmtTok(r.tokens?.cacheWrite || 0)} | ` +
      `${(r.tokens?.cost || 0).toFixed(4)} | ` +
      `${r.diff?.insertions || 0}/${r.diff?.deletions || 0} |`,
  );
}
md.push("");
md.push("## Per-combo summary");
md.push("");
md.push("| model | harness | pass rate | avg time (s) | avg tok in | avg tok out | avg diff (+/-) |");
md.push("|---|---|---|---:|---:|---:|---|");
const groups = new Map();
for (const r of results) {
  const k = `${r.model}|${r.harness}`;
  if (!groups.has(k)) groups.set(k, []);
  groups.get(k).push(r);
}
for (const [k, rs] of groups) {
  const [model, harness] = k.split("|");
  const n = rs.length;
  const pass = rs.filter((r) => r.verdict === "pass").length;
  const avg = (f) => rs.reduce((s, r) => s + (f(r) || 0), 0) / n;
  md.push(
    `| ${model} | ${harness} | ${pass}/${n} | ${avg((r) => r.totalTimeS).toFixed(0)} | ` +
      `${fmtTok(avg((r) => r.tokens?.input))} | ${fmtTok(avg((r) => r.tokens?.output))} | ` +
      `${avg((r) => r.diff?.insertions).toFixed(0)}/${avg((r) => r.diff?.deletions).toFixed(0)} |`,
  );
}
md.push("");
md.push("*`invalid*` = tests pass but protected files (tests) were modified.*");

const outMd = path.join(runDir, "report.md");
fs.writeFileSync(outMd, md.join("\n") + "\n");

// CSV
const csv = ["model,harness,task,verdict,totalTimeS,agentTimeS,rounds,tokIn,tokOut,cacheRead,cacheWrite,costUSD,insertions,deletions"];
for (const r of results) {
  csv.push(
    [
      r.model,
      r.harness,
      r.task,
      r.verdict,
      r.totalTimeS,
      r.agentTimeS,
      r.rounds,
      r.tokens?.input || 0,
      r.tokens?.output || 0,
      r.tokens?.cacheRead || 0,
      r.tokens?.cacheWrite || 0,
      (r.tokens?.cost || 0).toFixed(6),
      r.diff?.insertions || 0,
      r.diff?.deletions || 0,
    ].join(","),
  );
}
fs.writeFileSync(path.join(runDir, "report.csv"), csv.join("\n") + "\n");

console.log(md.join("\n"));
console.log(`\nwrote ${outMd} and report.csv`);
