#!/usr/bin/env node
// bench/deepswe/import.mjs — import Datacurve DeepSWE task cards from a clone
// of https://github.com/datacurve-ai/deep-swe (Harbor task format).
//
//   node bench/deepswe/import.mjs --out var/bench/deepswe/tasks-deepswe.jsonl \
//        [--lang go,python] [--tasks id1,id2] [--limit N] [--upstream DIR]
//
// Produces one JSON object per line (a "card") with everything verification
// needs later: instruction text, base commit, agent image, f2p/p2p whitelists
// and the protected (hidden-test) paths. Cards are kept OUT of agent
// workspaces — prepare.mjs writes them to a cache dir next to the upstream
// clone (which also holds the held-out tests/ and solution/).
import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import { execFileSync } from "node:child_process";

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "../..");
const argv = process.argv.slice(2);
function opt(name, dflt) {
  const i = argv.indexOf("--" + name);
  if (i === -1) return dflt;
  const v = argv[i + 1];
  return v && !v.startsWith("--") ? v : true;
}
const out = path.resolve(ROOT, String(opt("out", "var/bench/deepswe/tasks-deepswe.jsonl")));
const upstream = path.resolve(ROOT, String(opt("upstream", "var/bench/deepswe/upstream")));
const langFilter = String(opt("lang", "")).split(",").filter(Boolean);
const taskFilter = String(opt("tasks", "")).split(",").filter(Boolean);
const limit = Number(opt("limit", 0));
const REPO = "https://github.com/datacurve-ai/deep-swe";

// Clone or refresh the upstream benchmark repo (task definitions + held-out
// tests + solutions; agents never see this directory).
if (!fs.existsSync(path.join(upstream, ".git"))) {
  fs.mkdirSync(path.dirname(upstream), { recursive: true });
  console.log(`cloning ${REPO}…`);
  execFileSync("git", ["clone", "--depth", "1", REPO, upstream], { stdio: "inherit" });
} else {
  console.log(`refreshing ${upstream}…`);
  execFileSync("git", ["-C", upstream, "fetch", "--depth", "1", "origin", "main"]);
  execFileSync("git", ["-C", upstream, "reset", "--hard", "FETCH_HEAD"]);
}

// task.toml parsing via python3's stdlib tomllib (3.11+); one process for all
// tasks keeps this dependency-free and fast.
const tasksRoot = path.join(upstream, "tasks");
if (!fs.existsSync(tasksRoot)) throw new Error(`no tasks/ under ${upstream}`);
const py = `
import json, sys, tomllib
from pathlib import Path
root = Path(sys.argv[1])
out = {}
for toml in sorted(root.glob("*/task.toml")):
    with open(toml, "rb") as f:
        out[toml.parent.name] = tomllib.load(f)
print(json.dumps(out))
`;
const tomls = JSON.parse(
  execFileSync("python3", ["-c", py, tasksRoot], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }),
);

// Same id extraction as the official grader (tests/grader.py patch_paths).
function patchPaths(text) {
  const seen = new Set();
  const paths = [];
  for (const line of String(text || "").split("\n")) {
    let p = null;
    const m = line.match(/^diff --git (?:"?a\/(.*?)"?) (?:"?b\/(.*?)"?)$/);
    if (m) p = m[2];
    else if (line.startsWith("+++ b/")) p = line.slice(6);
    if (p && p !== "/dev/null" && !seen.has(p)) {
      seen.add(p);
      paths.push(p);
    }
  }
  return paths;
}

let rows = [];
for (const [id, t] of Object.entries(tomls)) {
  const meta = t.metadata || {};
  const agentEnv = t.environment || {};
  const verifier = t.verifier || {};
  const card = {
    task_id: meta.task_id || id,
    language: meta.language || "",
    repository_url: meta.repository_url || "",
    base_commit: meta.base_commit_hash || "",
    display_title: meta.display_title || "",
    display_description: meta.display_description || "",
    instruction: fs
      .readFileSync(path.join(tasksRoot, id, "instruction.md"), "utf8")
      .trim(),
    agent_image: agentEnv.docker_image || "",
    agent_timeout_sec: (t.agent && t.agent.timeout_sec) || 10800,
    verifier_timeout_sec: verifier.timeout_sec || 1800,
    verifier_cpus: (verifier.environment && verifier.environment.cpus) || 2,
    verifier_memory_mb: (verifier.environment && verifier.environment.memory_mb) || 8192,
    upstream: path.relative(ROOT, path.join(tasksRoot, id)),
  };
  const cfgPath = path.join(tasksRoot, id, "tests", "config.json");
  if (fs.existsSync(cfgPath)) {
    const cfg = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
    card.f2p_node_ids = cfg.f2p_node_ids || [];
    card.p2p_node_ids = cfg.p2p_node_ids || [];
  }
  const testPatchPath = path.join(tasksRoot, id, "tests", "test.patch");
  card.protected = fs.existsSync(testPatchPath)
    ? patchPaths(fs.readFileSync(testPatchPath, "utf8"))
    : [];
  rows.push(card);
}

if (langFilter.length) rows = rows.filter((r) => langFilter.includes(r.language));
if (taskFilter.length) rows = rows.filter((r) => taskFilter.includes(r.task_id));
if (limit > 0) rows = rows.slice(0, limit);

fs.mkdirSync(path.dirname(out), { recursive: true });
const fd = fs.openSync(out, "w");
for (const r of rows) fs.writeSync(fd, JSON.stringify(r) + "\n");
fs.closeSync(fd);
const langs = {};
for (const r of rows) langs[r.language] = (langs[r.language] || 0) + 1;
console.log(`wrote ${rows.length} task cards to ${path.relative(ROOT, out)} (${JSON.stringify(langs)})`);
