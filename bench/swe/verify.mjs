#!/usr/bin/env node
// Grade one candidate patch with the official SWE-bench 4.x Docker harness.
// The hidden test patch lives only in the one-row dataset passed here and is
// applied inside the disposable evaluator container, never to the agent repo.
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
function tail(value, limit = 8000) {
  value = String(value || "");
  return value.length <= limit ? value : "…\n" + value.slice(-limit);
}

const instance = required("instance");
const dataset = path.resolve(required("dataset"));
const repo = path.resolve(required("repo"));
const python = process.env.NIF_SWEBENCH_PYTHON || path.join(ROOT, "var/bench/swe/.venv/bin/python");
const runtimeBase = path.join(ROOT, "var/bench/swe/evaluations");
const nonce = `${Date.now()}-${process.pid}-${Math.random().toString(16).slice(2, 8)}`;
const runId = `niffler-${instance}-${nonce}`.replaceAll(/[^A-Za-z0-9_.-]/g, "-");
const runtime = path.join(runtimeBase, runId);
const prediction = path.join(runtime, "prediction.jsonl");
const model = "niffler-swe-pilot";

if (!fs.existsSync(python)) {
  console.error("SWE-bench environment missing; run bench/swe/setup.sh");
  process.exit(2);
}
if (!fs.existsSync(dataset)) {
  console.error(`SWE-bench card missing: ${dataset}`);
  process.exit(2);
}
fs.mkdirSync(runtime, { recursive: true });

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
fs.writeFileSync(
  prediction,
  JSON.stringify({ instance_id: instance, model_name_or_path: model, model_patch: patch }) + "\n",
);

let harnessOutput = "";
try {
  harnessOutput = execFileSync(
    python,
    [
      "-m", "swebench.harness.run_evaluation",
      "--dataset_name", dataset,
      "--split", "test",
      "--instance_ids", instance,
      "--predictions_path", prediction,
      "--max_workers", "1",
      "--cache_level", "instance",
      "--clean", "false",
      "--timeout", process.env.NIF_SWEBENCH_TEST_TIMEOUT || "900",
      "--run_id", runId,
    ],
    {
      cwd: runtime,
      encoding: "utf8",
      maxBuffer: 50 * 1024 * 1024,
      timeout: Number(process.env.NIF_SWEBENCH_HARNESS_TIMEOUT_MS || 1_200_000),
      env: { ...process.env, HF_HUB_DISABLE_TELEMETRY: "1" },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
} catch (error) {
  harnessOutput = `${error.stdout || ""}\n${error.stderr || ""}`;
  console.error(tail(harnessOutput));
  console.error(`official evaluator failed: ${error.message}`);
  process.exit(2);
}

const reportPath = path.join(
  runtime,
  "logs", "run_evaluation", runId, model, instance, "report.json",
);
const testOutputPath = path.join(
  runtime,
  "logs", "run_evaluation", runId, model, instance, "test_output.txt",
);
if (!fs.existsSync(reportPath)) {
  console.error(tail(harnessOutput));
  console.error(`official evaluator produced no report: ${reportPath}`);
  process.exit(2);
}
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const result = report[instance] || {};
const testOutput = fs.existsSync(testOutputPath) ? fs.readFileSync(testOutputPath, "utf8") : "";
const statuses = result.tests_status || {};
for (const group of ["FAIL_TO_PASS", "PASS_TO_PASS"]) {
  const status = statuses[group] || {};
  console.log(`${group}: ${status.success?.length || 0} passed, ${status.failure?.length || 0} failed`);
}
if (result.resolved === true) {
  console.log(`SWE-bench resolved: ${instance}`);
  process.exit(0);
}
console.log(tail(testOutput));
console.error(`SWE-bench unresolved: ${instance}`);
process.exit(1);
