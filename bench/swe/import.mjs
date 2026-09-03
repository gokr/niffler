#!/usr/bin/env node
// bench/swe/import.mjs — import SWE-bench Verified task cards via the
// HuggingFace datasets-server API (no local parquet/pip deps needed).
//
//   node bench/swe/import.mjs --out bench/swe/tasks.jsonl [--repos sympy,sphinx] [--limit 50]
//
// Produces one JSON object per line with the fields the runner needs:
//   instance_id, repo, base_commit, problem_statement, hints_text, patch,
//   test_patch, FAIL_TO_PASS, PASS_TO_PASS, created_at, version, plus optional
//   environment metadata. The gold patch is kept outside generated agent repos.
import fs from "node:fs";

const argv = process.argv.slice(2);
function opt(name, dflt) {
  const i = argv.indexOf("--" + name);
  if (i === -1) return dflt;
  const v = argv[i + 1];
  return v && !v.startsWith("--") ? v : true;
}
const out = opt("out", "bench/swe/tasks.jsonl");
const repoFilter = String(opt("repos", "")).split(",").filter(Boolean);
const limit = Number(opt("limit", 0));
const DATASET = "princeton-nlp/SWE-bench_Verified";

async function fetchPage(offset) {
  const url =
    `https://datasets-server.huggingface.co/rows?dataset=${encodeURIComponent(DATASET)}` +
    `&config=default&split=test&offset=${offset}&length=100`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`datasets-server ${res.status}: ${await res.text()}`);
  return (await res.json()).rows.map((r) => r.row);
}

const all = [];
for (let offset = 0; offset < 500; offset += 100) {
  process.stdout.write(`fetching rows ${offset}..${offset + 99}…\n`);
  all.push(...(await fetchPage(offset)));
}

let rows = all;
if (repoFilter.length) rows = rows.filter((r) => repoFilter.includes(r.repo));
if (limit > 0) rows = rows.slice(0, limit);

fs.mkdirSync(out.split("/").slice(0, -1).join("/") || ".", { recursive: true });
const fd = fs.openSync(out, "w");
for (const r of rows) {
  fs.writeSync(
    fd,
    JSON.stringify({
      instance_id: r.instance_id,
      repo: r.repo,
      base_commit: r.base_commit,
      version: r.version,
      created_at: r.created_at,
      problem_statement: r.problem_statement,
      hints_text: r.hints_text,
      patch: r.patch,
      test_patch: r.test_patch,
      FAIL_TO_PASS: r.FAIL_TO_PASS,
      PASS_TO_PASS: r.PASS_TO_PASS,
      environment_setup_commit: r.environment_setup_commit,
      difficulty: r.difficulty,
    }) + "\n",
  );
}
fs.closeSync(fd);
console.log(`wrote ${rows.length} task cards to ${out}`);
