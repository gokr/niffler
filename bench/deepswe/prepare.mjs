#!/usr/bin/env node
// bench/deepswe/prepare.mjs — turn imported DeepSWE cards into a disposable
// task root for bench/run.mjs. Each agent checkout contains only the upstream
// repo at base_commit (tag `base`); instruction, held-out tests, gold
// solution and grading config stay outside the workspace.
//
//   node bench/deepswe/prepare.mjs --input var/bench/deepswe/tasks-deepswe.jsonl \
//        --out var/bench/deepswe/tasks [--pull-images]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import url from "node:url";
import { execFileSync } from "node:child_process";

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "../..");
const argv = process.argv.slice(2);
function opt(name, dflt) {
  const i = argv.indexOf("--" + name);
  if (i === -1) return dflt;
  const value = argv[i + 1];
  return value && !value.startsWith("--") ? value : true;
}

const input = path.resolve(ROOT, String(opt("input", "var/bench/deepswe/tasks-deepswe.jsonl")));
const out = path.resolve(ROOT, String(opt("out", "var/bench/deepswe/tasks")));
const upstream = path.resolve(ROOT, String(opt("upstream", "var/bench/deepswe/upstream")));
// Hidden cards (instruction metadata, whitelists, gold patch pointers) default
// OUTSIDE any workspace so agents cannot reach them by grepping around.
const cards = path.resolve(
  String(opt("cards", path.join(os.homedir(), ".cache", "niffler-deepswe", "cards"))),
);
const mirrors = path.resolve(ROOT, String(opt("mirrors", "var/bench/deepswe/mirrors")));
const pullImages = opt("pull-images", false) === true;

function run(cmd, args, options = {}) {
  return execFileSync(cmd, args, { encoding: "utf8", stdio: options.quiet ? "pipe" : "inherit" });
}

function safeRepo(repoUrl) {
  return repoUrl.replace(/^https?:\/\/github\.com\//, "").replaceAll("/", "__").replaceAll(/[^A-Za-z0-9_.-]/g, "-");
}

if (!fs.existsSync(input)) {
  console.error(`missing ${input}; run bench/deepswe/import.mjs first`);
  process.exit(1);
}
if (!fs.existsSync(upstream)) {
  console.error(`missing ${upstream}; run bench/deepswe/import.mjs first`);
  process.exit(1);
}
const rows = fs
  .readFileSync(input, "utf8")
  .split("\n")
  .filter(Boolean)
  .map((line) => JSON.parse(line));
if (!rows.length) throw new Error(`no cards in ${input}`);

fs.mkdirSync(out, { recursive: true });
fs.mkdirSync(cards, { recursive: true });
fs.mkdirSync(mirrors, { recursive: true });

// One shared mirror per upstream repo; checkouts are shallow at base_commit.
const byRepo = new Map();
for (const row of rows) {
  if (!byRepo.has(row.repository_url)) byRepo.set(row.repository_url, []);
  byRepo.get(row.repository_url).push(row);
}
for (const repoUrl of byRepo.keys()) {
  const mirror = path.join(mirrors, safeRepo(repoUrl) + ".git");
  if (!fs.existsSync(mirror)) {
    console.log(`cloning mirror ${repoUrl}…`);
    run("git", ["clone", "--mirror", repoUrl, mirror]);
  } else {
    console.log(`refreshing mirror ${repoUrl}…`);
    run("git", ["-C", mirror, "fetch", "--prune", "origin"]);
  }
}

for (const row of rows) {
  const id = row.task_id;
  const taskDir = path.join(out, id);
  const repoDir = path.join(taskDir, "repo");
  const mirror = path.join(mirrors, safeRepo(row.repository_url) + ".git");
  fs.rmSync(taskDir, { recursive: true, force: true });
  fs.mkdirSync(taskDir, { recursive: true });

  // Shallow checkout at exactly base_commit; no future refs exposed.
  run("git", ["init", "-q", repoDir]);
  run("git", ["-C", repoDir, "fetch", "-q", "--depth=1", `file://${mirror}`, row.base_commit]);
  run("git", ["-C", repoDir, "checkout", "-q", "--detach", "FETCH_HEAD"]);
  run("git", ["-C", repoDir, "tag", "base"]);

  fs.writeFileSync(path.join(cards, id + ".json"), JSON.stringify(row, null, 2) + "\n");
  fs.writeFileSync(
    path.join(taskDir, "meta.json"),
    JSON.stringify(
      {
        id,
        source: "DeepSWE (datacurve-ai)",
        language: row.language,
        repo: row.repository_url,
        baseCommit: row.base_commit,
        verify: "verify.sh",
        protected: row.protected || [],
        agentImage: row.agent_image,
        agentTimeoutSec: row.agent_timeout_sec,
        verifierTimeoutSec: row.verifier_timeout_sec,
      },
      null,
      2,
    ) + "\n",
  );

  // The official instruction.md verbatim, wrapped with our workspace pointer
  // and the same hard rules the SWE-bench tasks use (hidden tests, no
  // network, stay in the repo). "Commit your work" from the instruction is
  // fine — verification diffs against the `base` tag either way.
  const prompt =
    `Work in the repository at {{REPO}}.\n\n${row.instruction}\n\n` +
    `Hard rules:\n` +
    `- Never run the project's tests and never install dependencies; the ` +
    `hidden verification environment is separate and grades your diff ` +
    `afterwards. There is nothing to set up.\n` +
    `- Do not fetch anything from the network; implement from the instruction ` +
    `text and the repository code.\n` +
    `- Stay inside {{REPO}}: never read other checkouts, caches, task ` +
    `metadata, or anything else on this machine.\n` +
    `- Production code only; never modify tests.\n`;
  fs.writeFileSync(path.join(taskDir, "prompt.md"), prompt);

  const wrapper = `#!/usr/bin/env bash\nset -euo pipefail\n` +
    `root=$(cd "$(dirname "\${BASH_SOURCE[0]}")/../../../../.." && pwd)\n` +
    `exec node "$root/bench/deepswe/verify.mjs" ` +
    `--task ${JSON.stringify(id)} ` +
    `--card ${JSON.stringify(path.join(cards, id + ".json"))} ` +
    `--upstream ${JSON.stringify(upstream)} ` +
    `--repo "$PWD"\n`;
  const wrapperPath = path.join(taskDir, "verify.sh");
  fs.writeFileSync(wrapperPath, wrapper);
  fs.chmodSync(wrapperPath, 0o755);
  console.log(`prepared ${id}`);
}

if (pullImages) {
  // Sequential by design: images are ~1 GB compressed each and pulls are
  // bandwidth-bound; this happens outside measured agent/verify time.
  console.log(`pulling ${rows.length} agent images (verifier builds need them)…`);
  for (const row of rows) {
    try {
      run("docker", ["pull", row.agent_image], { quiet: true });
      console.log(`pulled ${row.task_id}`);
    } catch (e) {
      console.error(`pull failed for ${row.task_id}: ${e.message}`);
    }
  }
}

console.log(`ready: ${rows.length} tasks in ${path.relative(ROOT, out)}`);
