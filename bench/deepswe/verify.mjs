#!/usr/bin/env node
// bench/deepswe/verify.mjs — grade one candidate patch with Datacurve's own
// DeepSWE verifier, unchanged: the task's tests/Dockerfile (agent image + the
// hidden tests) is built locally, then test.sh runs inside a no-network
// container against a pristine /app with the agent patch + hidden test patch
// applied by their shared grader.py. Resolution = reward.json reward == 1.
//
// The agent never sees the verifier container, the held-out tests, or the
// gold solution; only its `git diff --binary base` crosses the boundary.
import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import { execFileSync } from "node:child_process";

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "../..");
const argv = process.argv.slice(2);
function required(name) {
  const i = argv.indexOf("--" + name);
  if (i < 0 || !argv[i + 1]) throw new Error(`missing --${name}`);
  return argv[i + 1];
}
function tail(value, limit = 6000) {
  value = String(value || "");
  return value.length <= limit ? value : "…\n" + value.slice(-limit);
}

const task = required("task");
const cardPath = path.resolve(required("card"));
const upstream = path.resolve(required("upstream"));
const repo = path.resolve(required("repo"));

const card = JSON.parse(fs.readFileSync(cardPath, "utf8"));
const testsDir = path.join(upstream, "tasks", task, "tests");
if (!fs.existsSync(path.join(testsDir, "Dockerfile"))) {
  console.error(`verifier tests missing under ${testsDir}`);
  process.exit(2);
}
if (!card.agent_image) {
  console.error(`card has no agent_image (pull it: prepare.mjs --pull-images)`);
  process.exit(2);
}

const runtimeBase = path.join(ROOT, "var", "bench", "deepswe", "evaluations");
const nonce = `${Date.now()}-${process.pid}-${Math.random().toString(16).slice(2, 8)}`;
const runtime = path.join(runtimeBase, `${task}-${nonce}`);
const patchFile = path.join(runtime, "model.patch");
const verifierDir = path.join(runtime, "verifier");
fs.mkdirSync(verifierDir, { recursive: true });

let patch = "";
try {
  // Intent-to-add makes untracked production files appear in git diff without
  // staging their contents as a real commit.
  execFileSync("git", ["-C", repo, "add", "-N", "--", "."], { stdio: "ignore" });
  patch = execFileSync("git", ["-C", repo, "diff", "--binary", "base", "--"], {
    encoding: "utf8",
    maxBuffer: 50 * 1024 * 1024,
  });
} catch (error) {
  console.error(`could not capture candidate patch: ${error.message}`);
  process.exit(2);
}
if (!patch.trim()) {
  console.error("candidate patch is empty");
  process.exit(1);
}
fs.writeFileSync(patchFile, patch);

// Build the verifier image once per task (FROM the agent image, hidden tests
// baked in). Cached by tag so parallel lanes and retries skip the build.
const image = `niffler-deepswe-verifier:${task.replace(/[^A-Za-z0-9_.-]/g, "-")}`;
try {
  execFileSync("docker", ["image", "inspect", image], { stdio: "ignore" });
} catch {
  execFileSync("docker", ["build", "-t", image, testsDir], { stdio: "inherit" });
}

// Copy the patch into the runtime so the ro mount is stable, then run the
// verifier exactly like Harbor/Pier would: entrypoint tests/test.sh, no
// network, resource limits from the task card.
const cpus = String(card.verifier_cpus || 2);
const memoryMb = String(card.verifier_memory_mb || 8192);
const timeoutMs = Number(
  process.env.NIF_DEEPSWE_HARNESS_TIMEOUT_MS ||
    (Number(card.verifier_timeout_sec || 1800) + 120) * 1000,
);
let harnessOutput = "";
try {
  harnessOutput = execFileSync(
    "docker",
    [
      "run", "--rm",
      "--network", "none",
      "--cpus", cpus,
      "--memory", `${memoryMb}m`,
      "-v", `${patchFile}:/logs/artifacts/model.patch:ro`,
      "-v", `${verifierDir}:/logs/verifier`,
      image,
      "/bin/bash", "/tests/test.sh",
    ],
    {
      encoding: "utf8",
      maxBuffer: 50 * 1024 * 1024,
      timeout: timeoutMs,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
} catch (error) {
  harnessOutput = `${error.stdout || ""}\n${error.stderr || ""}`;
  console.error(tail(harnessOutput));
  console.error(`verifier container failed: ${error.message}`);
  process.exit(2);
}

const rewardPath = path.join(verifierDir, "reward.json");
const runLogPath = path.join(verifierDir, "run.log");
const sentinelPath = path.join(verifierDir, "reward.txt");
if (!fs.existsSync(rewardPath)) {
  const sentinel = fs.existsSync(sentinelPath) ? fs.readFileSync(sentinelPath, "utf8").trim() : "";
  if (sentinel === "-1") console.error("verifier crash sentinel (reward.txt = -1)");
  console.error(tail(fs.existsSync(runLogPath) ? fs.readFileSync(runLogPath, "utf8") : harnessOutput));
  console.error(`verifier produced no reward.json: ${rewardPath}`);
  process.exit(2);
}

const reward = JSON.parse(fs.readFileSync(rewardPath, "utf8"));
console.log(
  `f2p ${reward.f2p_passed ?? 0}/${reward.f2p_total ?? 0}, ` +
    `p2p ${reward.p2p_passed ?? 0}/${reward.p2p_total ?? 0}, ` +
    `partial ${reward.partial ?? 0}` +
    (reward.apply_failed ? ", apply_failed" : ""),
);
if (Number(reward.reward) === 1) {
  console.log(`DeepSWE resolved: ${task}`);
  process.exit(0);
}
if (reward.apply_failed) {
  console.error("candidate patch did not apply to the pristine base");
} else {
  console.error(tail(fs.readFileSync(runLogPath, "utf8")));
}
console.error(`DeepSWE unresolved: ${task}`);
process.exit(1);
