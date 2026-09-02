#!/usr/bin/env node
// bench/run.mjs — run the harness benchmark matrix.
//
//   node bench/run.mjs --harness pi --model deepseek-v4-flash --task t01
//   node bench/run.mjs --all                      # full matrix
//
// For every (harness, model, task) combo it: copies the pristine task repo
// into a private workdir, loops [agent turn → ./test.sh] until green or the
// round/time budget is exhausted, and writes one result JSON per combo run
// with wall-time, token usage and diff stats.
import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import { execFileSync } from "node:child_process";
import { run, readJson, writeJson, tail, nowIso, zeroUsage } from "./lib/util.mjs";
import { resolveKeys } from "./lib/keys.mjs";
import * as pi from "./adapters/pi.mjs";
import * as oc from "./adapters/opencode.mjs";
import * as niffler from "./adapters/niffler.mjs";

const BENCH_ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "..");
const BENCH_DIR = path.join(BENCH_ROOT, "bench");
const cfg = readJson(path.join(BENCH_DIR, "config.json"));

// ---------- CLI ----------
const argv = process.argv.slice(2);
function opt(name, dflt) {
  const i = argv.indexOf("--" + name);
  if (i === -1) return dflt;
  const v = argv[i + 1];
  return v && !v.startsWith("--") ? v : true;
}
const harnessArg = opt("harness", "all");
const modelArg = opt("model", "all");
const taskArg = opt("task", "all");
const RUN_ID = opt("run-id", new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19));
const RESULTS = path.join(BENCH_ROOT, "var", "bench", "results", RUN_ID);
const roundsMax = Number(opt("rounds", cfg.defaults.rounds));
const taskTimeoutMs = Number(opt("task-timeout-min", cfg.defaults.taskTimeoutMin)) * 60_000;
const turnTimeoutMs = Number(opt("turn-timeout-min", cfg.defaults.turnTimeoutMin)) * 60_000;
const testTimeoutMs = Number(opt("test-timeout-sec", cfg.defaults.testTimeoutSec)) * 1000;
const JOBS = Number(opt("jobs", cfg.defaults.jobs));
const KEEP_REPOS = opt("keep-repos", false) === true;

const harnesses =
  harnessArg === "all" ? ["niffler", "pi", "opencode"] : harnessArg.split(",");
const models = modelArg === "all" ? Object.keys(cfg.models) : modelArg.split(",");
const taskDirs = fs
  .readdirSync(path.join(BENCH_DIR, "tasks"), { withFileTypes: true })
  .filter((d) => d.isDirectory() && d.name.startsWith("t"))
  .map((d) => d.name)
  .sort();
const tasks = taskArg === "all" ? taskDirs : taskArg.split(",");

const { keys, missing } = resolveKeys(BENCH_ROOT);
if (missing.length) {
  console.error(`bench: missing API keys: ${missing.join(", ")} — see bench/README.md`);
  process.exit(1);
}
if (
  harnessArg.split(",").includes("niffler-expert") &&
  cfg.expertJudge &&
  !keys[cfg.expertJudge.apiKeyEnv || "SYNTHETIC_API_KEY"]
) {
  console.error(
    `bench: missing ${cfg.expertJudge.apiKeyEnv || "SYNTHETIC_API_KEY"} for the expert judge (config.expertJudge)`,
  );
  process.exit(1);
}

// ---------- helpers ----------
function git(repo, args) {
  return execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
}

function prepareRepo(taskId, dest) {
  const src = path.join(BENCH_DIR, "tasks", taskId, "repo");
  fs.cpSync(src, dest, { recursive: true });
  // Task repos ship as plain files; create the pristine base commit here so
  // every run gets an identical history to diff against.
  if (!fs.existsSync(path.join(dest, ".git"))) {
    git(dest, ["init", "-q"]);
    git(dest, ["add", "-A"]);
    git(dest, ["-c", "user.email=bench@local", "-c", "user.name=bench", "commit", "-qm", "base"]);
    git(dest, ["tag", "base"]);
  }
  try {
    git(dest, ["rev-parse", "base"]); // sanity: pristine history must be present
  } catch {
    console.warn(`bench: task ${taskId} repo has no 'base' tag — diff stats will be skipped`);
  }
}

function runTests(repo, meta, taskDir) {
  // Hidden-test mode: meta.verify names a script next to prompt.md (e.g. a
  // SWE-bench verify.sh that applies the test patch only now). Otherwise the
  // repo's own test.sh runs.
  if (meta.verify) {
    return run("bash", [path.join(BENCH_DIR, "tasks", taskDir, meta.verify)], {
      cwd: repo,
      timeoutMs: testTimeoutMs,
    });
  }
  return run("bash", ["test.sh"], { cwd: repo, timeoutMs: testTimeoutMs });
}

function diffStat(repo) {
  let files = [];
  let short = "";
  try {
    files = git(repo, ["diff", "--name-only", "base"])
      .split("\n")
      .filter(Boolean);
    short = git(repo, ["diff", "--shortstat", "base"]);
  } catch {
    return { files: [], insertions: 0, deletions: 0 };
  }
  let insertions = 0;
  let deletions = 0;
  const m = short.match(/(\d+) insertion|(\d+) deletion/g) || [];
  for (const part of m) {
    const n = Number(part.match(/\d+/)[0]);
    if (part.includes("insertion")) insertions += n;
    else deletions += n;
  }
  return { files, insertions, deletions };
}

function protectedTouched(repo, meta) {
  const changed = new Set(diffStat(repo).files);
  for (const pat of meta.protected || []) {
    for (const f of changed) {
      if (pat.endsWith("/**") ? f.startsWith(pat.slice(0, -2)) : f === pat) return f;
    }
  }
  return null;
}

function feedbackPrompt(meta, testOut) {
  return [
    "Your changes still fail verification. `./test.sh` exits non-zero with this output (tail):",
    "",
    tail(testOut, 6000),
    "",
    `Keep working in the repository until ./test.sh passes. Do not modify: ${(meta.protected || []).join(", ")}.`,
    "When everything passes, reply with a one-line summary.",
  ].join("\n");
}

// Fill the {{REPO}} placeholder per harness. Pi/OpenCode run the agent with
// cwd = the repo; Niffler sessions get the repo as their workspace (cwd), so
// the prompt points at the working directory instead of an absolute path —
// relative paths keep every tool inside the workspace by construction.
function fillPrompt(template, combo, repo) {
  if (isNifflerHarness(combo.harness)) {
    return template.replaceAll("{{REPO}}", "your current working directory");
  }
  return template.replaceAll("{{REPO}}", repo);
}

// ---------- adapters registry ----------
const ADAPTERS = {
  pi: {
    mod: pi,
    needsKeys: ["DEEPSEEK_API_KEY", "LLMGATEWAY_API_KEY"],
  },
  opencode: { mod: oc, needsKeys: [] },
  niffler: {
    mod: niffler,
    needsKeys: [],
    isService: true, // harness lifecycle per combo
  },
  "niffler-expert": {
    mod: niffler,
    needsKeys: [],
    isService: true,
  },
};

const isNifflerHarness = (name) => name === "niffler" || name === "niffler-expert";

// ---------- one task run ----------
async function runTask(combo, taskId, taskMeta, taskPrompt, shared) {
  const workdir = path.join(RESULTS, `${combo.harness}__${combo.model}__${taskId}`);
  fs.rmSync(workdir, { recursive: true, force: true });
  fs.mkdirSync(workdir, { recursive: true });
  const repo = path.join(workdir, "repo");
  prepareRepo(taskId, repo);
  const sessionId = `bench-${RUN_ID}-${combo.harness}-${taskId}`.replace(
    /[^a-zA-Z0-9._-]/g,
    "-",
  );
  let setupError = null;
  if (combo.harness === "niffler-expert") {
    try {
      // Setup is outside time-to-green: expert_follow arms observation but
      // does not perform a judgment until the measured turn starts.
      await shared.niffler.beginTask(sessionId);
    } catch (e) {
      setupError = e;
    }
  }

  const startedAt = nowIso();
  const t0 = Date.now();
  const rounds = [];
  const roundUsages = [];
  let verdict = "fail";
  let agentTimeS = 0;
  let testTimeS = 0;
  let adapterState = {};
  let roundReply = "";

  try {
    if (setupError) throw setupError;
    for (let r = 1; r <= roundsMax; r++) {
      if (Date.now() - t0 > taskTimeoutMs) {
        verdict = "timeout";
        break;
      }
      const prompt =
        r === 1
          ? fillPrompt(taskPrompt, combo, repo)
          : feedbackPrompt(taskMeta, rounds.at(-1)?.testOutputTail || "");
      const r0 = Date.now();
      let res;
      if (combo.harness === "pi") {
        res = await pi.round({
          repo,
          prompt,
          modelCfg: combo.modelCfg.pi,
          keys,
          sessionsDir: path.join(workdir, "pi-sessions"),
          sessionFile: adapterState.sessionFile || null,
          cfgDir: shared.piCfgDir,
          turnTimeoutMs,
        });
        adapterState.sessionFile = res.sessionFile;
      } else if (combo.harness === "opencode") {
        res = await oc.round({
          repo,
          prompt,
          modelCfg: combo.modelCfg.opencode,
          turnTimeoutMs,
          sessionId: adapterState.sessionId || null,
        });
        adapterState.sessionId = res.sessionId;
      } else if (isNifflerHarness(combo.harness)) {
        res = await shared.niffler.round({
          sessionId,
          prompt,
          turnTimeoutMs,
          cwd: shared.niffler.workspaceFor(repo),
        });
      }
      const agentS = (Date.now() - r0) / 1000;
      agentTimeS += agentS;
      if (res.roundUsage) roundUsages.push(res.roundUsage);
      if (res.raw) {
        fs.writeFileSync(
          path.join(workdir, `round-${r}.log`),
          `## stdout\n${res.raw.stdout}\n## stderr\n${res.raw.stderr}\n`,
        );
      }

      const test0 = Date.now();
      const test = res.error
        ? { code: -1, stdout: "", stderr: res.error }
        : await runTests(repo, taskMeta, taskId);
      const testS = (Date.now() - test0) / 1000;
      testTimeS += testS;
      const pass = !res.error && test.code === 0;

      rounds.push({
        r,
        agentS: Number(agentS.toFixed(1)),
        testS: Number(testS.toFixed(1)),
        pass,
        error: res.error || null,
        replyTail: tail(res.reply, 800),
        testOutputTail: tail(test.stdout + test.stderr, 4000),
      });
      roundReply = res.reply || "";
      console.log(
        `  [${combo.harness}/${combo.model}/${taskId}] round ${r}: ` +
          `${pass ? "PASS" : "fail"} (agent ${agentS.toFixed(0)}s)` +
          (res.error ? ` error=${String(res.error).slice(0, 120)}` : ""),
      );
      if (pass) {
        verdict = "pass";
        break;
      }
      if (Date.now() - t0 > taskTimeoutMs) {
        verdict = "timeout";
        break;
      }
    }
  } catch (err) {
    verdict = "error";
    rounds.push({ r: rounds.length + 1, error: String(err?.stack || err) });
  }

  const totalTimeS = (Date.now() - t0) / 1000;

  // Token usage per harness source of truth. Preserve Niffler's complete
  // persisted transcript while its private store is still online so the run
  // can be audited after shutdown.
  let usage = zeroUsage();
  let expert = null;
  let transcript = null;
  try {
    if (combo.harness === "pi") usage = pi.usageFromSession(adapterState.sessionFile);
    else if (combo.harness === "opencode") usage = oc.usageFromRounds(roundUsages);
    else if (isNifflerHarness(combo.harness)) {
      transcript = await shared.niffler.transcript(sessionId);
      writeJson(path.join(workdir, "transcript.json"), { sessionId, items: transcript });
      usage = await shared.niffler.usageFromTranscript(sessionId, transcript);
    }
  } catch (e) {
    usage.error = String(e);
  }
  // Prompt-size telemetry: the first assistant answer's prompt_tokens is
  // the cheapest cross-run proxy for system prompt + toolset bloat (see
  // bench/README.md — keep an eye on the first-call footprint).
  let firstPromptTokens = null;
  if (transcript) {
    const first = transcript.find(
      (it) => it.value?.role === "assistant" && it.value?.usage,
    );
    firstPromptTokens = first?.value?.usage?.prompt_tokens ?? null;
  }
  if (combo.harness === "niffler-expert") {
    try {
      expert = await shared.niffler.expertMetricsSince(sessionId);
      // Expert prompt is OpenAI-style (cached is a subset of prompt), while
      // benchmark usage counters are disjoint.
      const expertCached = Math.min(expert.tokens.prompt, expert.tokens.cached);
      usage.input += expert.tokens.prompt - expertCached;
      usage.output += expert.tokens.completion;
      usage.cacheRead += expertCached;
    } catch (e) {
      expert = { active: false, error: String(e) };
    }
  }

  // Diff stats + protected-file guard.
  let diff = { files: [], insertions: 0, deletions: 0 };
  let invalid = null;
  try {
    diff = diffStat(repo);
    try {
      fs.writeFileSync(path.join(workdir, "patch.diff"), git(repo, ["diff", "base"]));
    } catch {}
    const hit = protectedTouched(repo, taskMeta);
    if (hit) {
      invalid = `protected file modified: ${hit}`;
      if (verdict === "pass") verdict = "invalid";
    }
  } catch {}

  const result = {
    runId: RUN_ID,
    startedAt,
    sessionId,
    workspace: isNifflerHarness(combo.harness)
      ? shared.niffler.workspaceFor(repo)
      : null,
    harness: combo.harness,
    model: combo.model,
    modelLabel: combo.modelCfg.label || combo.model,
    task: taskId,
    verdict,
    invalid,
    rounds: rounds.length,
    agentTimeS: Number(agentTimeS.toFixed(1)),
    testTimeS: Number(testTimeS.toFixed(1)),
    totalTimeS: Number(totalTimeS.toFixed(1)),
    tokens: usage,
    firstPromptTokens,
    expert,
    diff,
    roundsDetail: rounds,
    finalReply: tail(roundReply, 2000),
    workdir,
  };
  writeJson(path.join(workdir, "result.json"), result);
  // The agent needs a real git repo while working, but once patch.diff and
  // diff stats are captured the nested .git is pure scratch. Strip it by
  // default so VSCode and other editor scanners do not list every completed
  // benchmark task as a repository; --keep-repos preserves it for debugging.
  if (!KEEP_REPOS) {
    fs.rmSync(path.join(repo, ".git"), { recursive: true, force: true });
  }
  console.log(
    `[${combo.harness}/${combo.model}/${taskId}] ${verdict.toUpperCase()} ` +
      `${result.totalTimeS.toFixed(0)}s, ${result.rounds} rounds, ` +
      `tok in/out ${usage.input}/${usage.output}` +
      (invalid ? ` (${invalid})` : ""),
  );
  return result;
}

// ---------- combo runner ----------
async function runCombo(combo, taskIds) {
  const comboRoot = path.join(RESULTS, `_combo-${combo.harness}__${combo.model}`);
  fs.mkdirSync(comboRoot, { recursive: true });
  const shared = { piCfgDir: pi.setupPiConfig(comboRoot, cfg) };

  if (isNifflerHarness(combo.harness)) {
    shared.niffler = new niffler.NifflerHarness({
      benchRoot: BENCH_ROOT,
      runRoot: comboRoot,
      baseUrl: combo.modelCfg.niffler.baseUrl,
      apiKey: keys[combo.modelCfg.niffler.apiKeyEnv],
      model: combo.modelCfg.niffler.model,
      expertEnabled: combo.harness === "niffler-expert",
      expertJudge:
        combo.harness === "niffler-expert" && cfg.expertJudge
          ? {
              ...cfg.expertJudge,
              apiKey: keys[cfg.expertJudge.apiKeyEnv || "SYNTHETIC_API_KEY"] || "",
            }
          : null,
    });
    console.log(`booting niffler harness (${combo.model}) on a private bus…`);
    try {
      await shared.niffler.start();
    } catch (e) {
      console.error(`bench: niffler harness failed to start: ${e.message}`);
      for (const taskId of taskIds) {
        writeJson(path.join(RESULTS, `${combo.harness}__${combo.model}__${taskId}`, "result.json"), {
          runId: RUN_ID,
          harness: combo.harness,
          model: combo.model,
          task: taskId,
          verdict: "error",
          error: `harness start failed: ${e.message}`,
        });
      }
      return;
    }
  }

  try {
    for (const taskId of taskIds) {
      const meta = readJson(path.join(BENCH_DIR, "tasks", taskId, "meta.json"));
      const template = fs.readFileSync(path.join(BENCH_DIR, "tasks", taskId, "prompt.md"), "utf8");
      await runTask(combo, taskId, meta, template, shared);
    }
  } finally {
    if (shared.niffler) {
      console.log(`stopping niffler harness (${combo.model})…`);
      await shared.niffler.stop();
    }
  }
}

// ---------- main ----------
async function main() {
  fs.mkdirSync(RESULTS, { recursive: true });
  const combos = [];
  for (const model of models) {
    if (!cfg.models[model]) {
      console.error(`bench: unknown model '${model}' (have: ${Object.keys(cfg.models).join(", ")})`);
      process.exit(1);
    }
    for (const harness of harnesses) {
      if (!ADAPTERS[harness]) {
        console.error(`bench: unknown harness '${harness}'`);
        process.exit(1);
      }
      combos.push({ harness, model, modelCfg: cfg.models[model] });
    }
  }
  console.log(
    `bench run ${RUN_ID}: ${combos.length} combos × ${tasks.length} tasks ` +
      `(rounds≤${roundsMax}, task≤${taskTimeoutMs / 60000}min, jobs=${JOBS})`,
  );
  writeJson(path.join(RESULTS, "run.json"), {
    runId: RUN_ID,
    startedAt: nowIso(),
    combos,
    tasks,
    roundsMax,
    taskTimeoutMs,
    turnTimeoutMs,
    keepRepos: KEEP_REPOS,
  });

  // Simple worker pool over combos; Niffler boots one harness per combo.
  let idx = 0;
  async function worker() {
    while (idx < combos.length) {
      const combo = combos[idx++];
      await runCombo(combo, tasks);
    }
  }
  await Promise.all(Array.from({ length: Math.min(JOBS, combos.length) }, worker));
  console.log(`bench: done — results in ${RESULTS}`);
  console.log(`bench: report with  node bench/report.mjs --run ${RUN_ID}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
