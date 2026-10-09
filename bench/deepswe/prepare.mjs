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
// Held-out mirror (hidden tests + reference solutions): outside the repo
// tree by default (the cards rationale) so filesystem wandering cannot
// reach it — the verifier gets it via an absolute path at verify time.
const upstream = path.resolve(
  String(opt("upstream", path.join(os.homedir(), ".cache", "niffler-deepswe", "upstream"))),
);
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

// Protocol fidelity (upstream Harbor runs the agent INSIDE the agent image:
// deps installed, no network). We keep the agent on the host but extract the
// image's environment offline at prepare time:
//   - the image's /app working tree (minus .git) overlays the checkout, so
//     node_modules and friends are present exactly as the task ships;
//   - the image's toolchain homes (/root/.cargo, .bun, caches, site-packages)
//     merge into one shared image-home next to `out`, run via env prefix:
//     HOME=<image-home> PATH=... node bench/run.mjs (the adapters pass the
//     bench process env to every child). Nothing is downloaded during a task.
const imageHome = path.resolve(ROOT, String(opt("image-home", "var/bench/deepswe/image-home")));
const skipExtract = opt("skip-extract", false) === true;
fs.mkdirSync(imageHome, { recursive: true });
// "<workspace-abs>=<image>" per task: procutil's NIF_BASH_SANDBOX_MAP —
// every command runs in its task's agent image with only the workspace
// visible (the upstream agent container semantics).
const sandboxMap = [];

function extractImageEnv(image, repoDir) {
  // Overlay the image's /app over the checkout: dependencies exactly as the
  // task ships them (the sanctioned starting state). .git stays ours — the
  // `base` tag is the diff baseline. Toolchains are NOT extracted: at run
  // time every command executes inside the image (NIF_BASH_SANDBOX_MAP),
  // which is both more faithful and cheaper than mirroring its toolchain.
  //
  // Streamed (docker export | tar): an image filesystem runs to several GB
  // uncompressed and must never be buffered whole (execFileSync's maxBuffer
  // kills it at 1GiB).
  const ctr = "niffler-deepswe-x-" + Math.random().toString(36).slice(2, 10);
  const q = (x) => "'" + String(x).replaceAll("'", "'\\''") + "'";
  try {
    run("docker", ["create", "--name", ctr, image], { quiet: true });
    run("bash", ["-c",
      `docker export ${q(ctr)} | tar -x --exclude=app/.git -C ${q(repoDir)} --strip-components=1 app`]);
  } finally {
    run2("docker", ["rm", "-f", ctr], { allowFail: true, stdio: "pipe" });
  }
}

// run2 = execFileSync with an optional failure allowance (a language's image
// simply lacks some of the optional trees).
function run2(cmd, args, options = {}) {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", stdio: options.stdio || "pipe", maxBuffer: 1 << 30, input: options.input });
  } catch (e) {
    if (options.allowFail) return "";
    throw e;
  }
}

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
  if (!skipExtract) {
    // The image's /app overlays the checkout (deps as the task ships them,
    // .git excluded — `base` stays the diff baseline).
    console.log(`extracting ${id} workspace from its agent image…`);
    extractImageEnv(row.agent_image, repoDir);
  }
  sandboxMap.push(`${repoDir}=${row.agent_image}`);

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
    `- Dependencies and toolchains are preinstalled — never install or ` +
    `download anything. This machine has no usable network: implement from ` +
    `the instruction text and the repository code.\n` +
    `- Validate your work as you go: run the project's own tests, typecheck ` +
    `and build where available. The hidden verification suite is separate ` +
    `and grades your diff afterwards.\n` +
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

// One env file for the run invocation (--agent-env): the sandbox map (the
// image per task workspace — procutil wraps every command in it: no
// network, workspace-only filesystem) and nothing else. Toolchains, caches
// and python libraries all live inside the images.
const envLines = [
  `# deepswe agent environment — commands run inside the task's agent image`,
  `# (docker run --rm --network none; only the workspace is bind-mounted).`,
  `export NIF_BASH_SANDBOX_MAP=${JSON.stringify(sandboxMap.join("\n"))}`,
];
if (!skipExtract) fs.writeFileSync(path.join(imageHome, "env.sh"), envLines.join("\n") + "\n");

console.log(`ready: ${rows.length} tasks in ${path.relative(ROOT, out)} (env: ${path.relative(ROOT, imageHome)})`);
