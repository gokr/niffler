#!/usr/bin/env node
// Turn imported SWE-bench cards into a disposable custom task root for
// bench/run.mjs. Repositories are checked out at exactly base_commit with no
// future refs, while hidden test/gold patches stay outside the agent repo.
import fs from "node:fs";
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

const input = path.resolve(ROOT, String(opt("input", "var/bench/swe/tasks-sympy.jsonl")));
const out = path.resolve(ROOT, String(opt("out", "var/bench/swe/tasks")));
const cards = path.resolve(ROOT, String(opt("cards", "var/bench/swe/cards")));
const mirrors = path.resolve(ROOT, String(opt("mirrors", "var/bench/swe/mirrors")));
const pullImages = opt("pull-images", false) === true;
const workers = String(opt("workers", "2"));

function run(cmd, args, options = {}) {
  return execFileSync(cmd, args, { encoding: "utf8", stdio: options.quiet ? "pipe" : "inherit" });
}

function safeRepo(repo) {
  return repo.replaceAll("/", "__").replaceAll(/[^A-Za-z0-9_.-]/g, "-");
}

function testFiles(patch) {
  const files = new Set();
  for (const match of String(patch || "").matchAll(/^\+\+\+ b\/(.+)$/gm)) {
    if (match[1] !== "/dev/null") files.add(match[1]);
  }
  return [...files].sort();
}

if (!fs.existsSync(input)) {
  console.error(`missing ${input}; run bench/swe/import.mjs first`);
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

const byRepo = new Map();
for (const row of rows) {
  if (!byRepo.has(row.repo)) byRepo.set(row.repo, []);
  byRepo.get(row.repo).push(row);
}
for (const repo of byRepo.keys()) {
  const mirror = path.join(mirrors, safeRepo(repo) + ".git");
  if (!fs.existsSync(mirror)) {
    console.log(`cloning mirror ${repo}…`);
    run("git", ["clone", "--mirror", `https://github.com/${repo}.git`, mirror]);
  } else {
    console.log(`refreshing mirror ${repo}…`);
    run("git", ["-C", mirror, "fetch", "--prune", "origin"]);
  }
}

for (const row of rows) {
  const id = row.instance_id;
  const taskDir = path.join(out, id);
  const repoDir = path.join(taskDir, "repo");
  const mirror = path.join(mirrors, safeRepo(row.repo) + ".git");
  fs.rmSync(taskDir, { recursive: true, force: true });
  fs.mkdirSync(taskDir, { recursive: true });

  // Fetch only the base commit into the agent checkout. The mirror has future
  // history for efficient setup, but no future refs are exposed to the agent.
  run("git", ["init", "-q", repoDir]);
  run("git", ["-C", repoDir, "fetch", "-q", "--depth=1", `file://${mirror}`, row.base_commit]);
  run("git", ["-C", repoDir, "checkout", "-q", "--detach", "FETCH_HEAD"]);
  run("git", ["-C", repoDir, "tag", "base"]);

  const cardPath = path.join(cards, id + ".jsonl");
  fs.writeFileSync(cardPath, JSON.stringify(row) + "\n");
  fs.writeFileSync(
    path.join(taskDir, "meta.json"),
    JSON.stringify(
      {
        id,
        source: "SWE-bench Verified",
        repo: row.repo,
        baseCommit: row.base_commit,
        verify: "verify.sh",
        protected: testFiles(row.test_patch),
      },
      null,
      2,
    ) + "\n",
  );
  fs.writeFileSync(
    path.join(taskDir, "prompt.md"),
    `Work in the repository at {{REPO}}.\n\n` +
      `Resolve this GitHub issue from SWE-bench Verified:\n\n${row.problem_statement.trim()}\n\n` +
      `Modify production code only; do not modify tests. The official hidden ` +
      `verification suite will be run after your turn. When finished, reply ` +
      `with a concise summary of the fix.\n`,
  );
  const wrapper = `#!/usr/bin/env bash\nset -euo pipefail\n` +
    `root=$(cd "$(dirname "\${BASH_SOURCE[0]}")/../../../../.." && pwd)\n` +
    `exec node "$root/bench/swe/verify.mjs" ` +
    `--instance ${JSON.stringify(id)} ` +
    `--dataset "${path.join(cards, id + ".jsonl")}" ` +
    `--repo "$PWD"\n`;
  const wrapperPath = path.join(taskDir, "verify.sh");
  fs.writeFileSync(wrapperPath, wrapper);
  fs.chmodSync(wrapperPath, 0o755);
  console.log(`prepared ${id}`);
}

if (pullImages) {
  const python = path.join(ROOT, "var/bench/swe/.venv/bin/python");
  if (!fs.existsSync(python)) throw new Error("run bench/swe/setup.sh before --pull-images");
  console.log(`preparing ${rows.length} official instance images…`);
  const imageRoot = path.join(ROOT, "var/bench/swe/images");
  fs.mkdirSync(imageRoot, { recursive: true });
  run(python, [
    "-m", "swebench.harness.prepare_images",
    "--dataset_name", input,
    "--split", "test",
    "--instance_ids", ...rows.map((row) => row.instance_id),
    "--max_workers", workers,
    "--namespace", "swebench",
    // swebench 4.1.0's CLI passes None tags into make_test_spec, which asserts
    // non-None; run_evaluation defaults these to "latest" internally.
    "--tag", "latest",
    "--env_image_tag", "latest",
    "--force_rebuild", "false",
  ], { cwd: imageRoot });
}

console.log(`ready: ${rows.length} tasks in ${path.relative(ROOT, out)}`);
