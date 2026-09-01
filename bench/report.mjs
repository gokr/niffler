#!/usr/bin/env node
// bench/report.mjs — aggregate bench results into a markdown + CSV report.
//
//   node bench/report.mjs --run <runId>     # var/bench/results/<runId>
//   node bench/report.mjs --latest
import fs from "node:fs";
import path from "node:path";
import url from "node:url";

const BENCH_DIR = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)));
// Raw run output lives under var/ (disposable runtime state, wiped by
// `make clean`); the committed record is the aggregated bench/reports/.
const RESULTS_ROOT = path.join(BENCH_DIR, "..", "var", "bench", "results");
const argv = process.argv.slice(2);
function opt(name) {
  const i = argv.indexOf("--" + name);
  if (i === -1) return null;
  return argv[i + 1] ?? true; // flag form (--latest) must be truthy too
}

let runDir;
if (opt("run")) runDir = path.join(RESULTS_ROOT, opt("run"));
else if (opt("latest")) {
  const dirs = fs
    .readdirSync(RESULTS_ROOT, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => d.name)
    .sort();
  if (!dirs.length) {
    console.error("no runs found");
    process.exit(1);
  }
  runDir = path.join(RESULTS_ROOT, dirs.at(-1));
} else {
  console.error("usage: report.mjs --run <id> | --latest");
  process.exit(1);
}

const results = [];
function scan(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (!e.name.startsWith("_")) scan(p); // _combo-* holds harness state only
    } else if (e.name.endsWith(".json") && e.name !== "run.json") {
      try {
        const r = JSON.parse(fs.readFileSync(p, "utf8"));
        if (r.verdict) results.push(r);
      } catch {}
    }
  }
}
scan(runDir);
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
const hasExpert = results.some((r) => r.expert);
const md = [];
md.push(`# bench report — ${path.basename(runDir)}`);
md.push("");
md.push(
  "| model | harness | task | verdict | time (s) | rounds | tok in | tok out | cache r/w | cost $ | diff (+/-) |" +
    (hasExpert ? " expert judge/steer/accepted |" : ""),
);
md.push(
  "|---|---|---|---|---:|---:|---:|---:|---|---:|---|" +
    (hasExpert ? "---|" : ""),
);
for (const r of results) {
  md.push(
    `| ${r.model} | ${r.harness} | ${r.task} | ${r.verdict}${r.invalid ? "*" : ""} | ` +
      `${r.totalTimeS} | ${r.rounds} | ${fmtTok(r.tokens?.input || 0)} | ` +
      `${fmtTok(r.tokens?.output || 0)} | ` +
      `${fmtTok(r.tokens?.cacheRead || 0)}/${fmtTok(r.tokens?.cacheWrite || 0)} | ` +
      `${(r.tokens?.cost || 0).toFixed(4)} | ` +
      `${r.diff?.insertions || 0}/${r.diff?.deletions || 0} |` +
      (hasExpert
        ? ` ${r.expert ? `${r.expert.judgments || 0}/${r.expert.steers || 0}/${r.expert.accepted || 0}` : "-"} |`
        : ""),
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
const csv = ["model,harness,task,verdict,totalTimeS,agentTimeS,rounds,tokIn,tokOut,cacheRead,cacheWrite,costUSD,insertions,deletions,expertActive,expertJudgments,expertSilences,expertSteers,expertAccepted,expertRejected,expertStaleDrops,expertErrors,expertPromptTokens,expertCachedTokens,expertCompletionTokens"];
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
      r.expert?.active || false,
      r.expert?.judgments || 0,
      r.expert?.silences || 0,
      r.expert?.steers || 0,
      r.expert?.accepted || 0,
      r.expert?.rejected || 0,
      r.expert?.staleDrops || 0,
      r.expert?.errors || 0,
      r.expert?.tokens?.prompt || 0,
      r.expert?.tokens?.cached || 0,
      r.expert?.tokens?.completion || 0,
    ].join(","),
  );
}
fs.writeFileSync(path.join(runDir, "report.csv"), csv.join("\n") + "\n");

console.log(md.join("\n"));
console.log(`\nwrote ${outMd} and report.csv`);
