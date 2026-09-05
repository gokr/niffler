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
import * as cw from "./adapters/codewhale.mjs";
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
const TASK_ROOT = path.resolve(BENCH_ROOT, String(opt("task-root", "bench/tasks")));
const RUN_ID = opt("run-id", new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19));
const RESULTS = path.join(BENCH_ROOT, "var", "bench", "results", RUN_ID);
// --resume: skip cells of THIS run id whose result.json already holds a
// verdict (pass/fail/timeout/invalid) — only error cells re-run. Lets a
// killed/suspended run continue where it stopped; delete a cell's
// result.json to force its re-run.
const RESUME = argv.includes("--resume");
const roundsMax = Number(opt("rounds", cfg.defaults.rounds));
const taskTimeoutMs = Number(opt("task-timeout-min", cfg.defaults.taskTimeoutMin)) * 60_000;
const turnTimeoutMs = Number(opt("turn-timeout-min", cfg.defaults.turnTimeoutMin)) * 60_000;
const testTimeoutMs = Number(opt("test-timeout-sec", cfg.defaults.testTimeoutSec)) * 1000;
const JOBS = Number(opt("jobs", cfg.defaults.jobs));
// Niffler-only: LLM round budget per turn (NIF_MAX_TURN_ROUNDS). Default 100:
// the 60 default clipped long agentic SWE turns (sympy-13031 exhausted it and
// submitted an empty patch).
const maxTurnRounds = Number(opt("max-turn-rounds", 100));
const KEEP_REPOS = opt("keep-repos", false) === true;

// ---------- thinking profile ----------
// Uniform reasoning-effort control across harnesses (--thinking low|max per
// config.json thinking.profiles). Each profile maps a harness to the
// strongest effort its own CLI can express: pi sends --thinking (real "max"
// via thinkingLevelMap in adapters/pi.mjs), niffler forwards the value as the
// session's reasoning_effort, opencode passes --variant, codewhale writes
// reasoning_effort into its isolated config.toml. Without --thinking the
// per-model defaults (models.<m>.<harness>.thinking) apply — today that means
// niffler/pi run "low" and opencode/codewhale the provider default.
const THINKING = String(opt("thinking", "") || "");
const thinkingProfiles = cfg.thinking?.profiles || {};
let thinkingByHarness = null;
if (THINKING) {
  thinkingByHarness = thinkingProfiles[THINKING];
  if (!thinkingByHarness) {
    console.error(
      `bench: unknown thinking profile '${THINKING}' (have: ${Object.keys(thinkingProfiles).join(", ")})`,
    );
    process.exit(1);
  }
  console.log(
    `bench: thinking profile '${THINKING}': ` +
      Object.entries(thinkingByHarness)
        .map(([h, v]) => `${h}=${v}`)
        .join(", "),
  );
}
const thinkingFor = (harness) => (thinkingByHarness ? thinkingByHarness[harness] || "" : "");

const harnesses =
  harnessArg === "all"
    ? ["niffler", "pi", "opencode", "codewhale"]
    : harnessArg.split(",");
const models = modelArg === "all" ? Object.keys(cfg.models) : modelArg.split(",");
const taskDirs = fs
  .readdirSync(TASK_ROOT, { withFileTypes: true })
  .filter(
    (d) =>
      d.isDirectory() &&
      fs.existsSync(path.join(TASK_ROOT, d.name, "meta.json")) &&
      fs.existsSync(path.join(TASK_ROOT, d.name, "prompt.md")) &&
      fs.existsSync(path.join(TASK_ROOT, d.name, "repo")),
  )
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

// ---------- provider preflight ----------
// A dead provider (out of balance, revoked key) used to surface as N failed
// cells × 6 feedback rounds before anyone noticed. Probe every selected
// endpoint once up front; a 401/402/403 aborts the whole run before any
// cell burns tokens. --skip-preflight bypasses (mocked/offline providers).
const SKIP_PREFLIGHT = argv.includes("--skip-preflight");
async function preflight() {
  const endpoints = new Map(); // "baseUrl|apiKeyEnv" -> {baseUrl, apiKeyEnv}
  const add = (baseUrl, apiKeyEnv) => {
    if (baseUrl && apiKeyEnv) endpoints.set(`${baseUrl}|${apiKeyEnv}`, { baseUrl, apiKeyEnv });
  };
  for (const model of models) {
    const mc = cfg.models[model];
    if (mc?.niffler) add(mc.niffler.baseUrl, mc.niffler.apiKeyEnv);
  }
  if (harnessArg.split(",").includes("niffler-expert") && cfg.expertJudge) {
    add(cfg.expertJudge.baseUrl, cfg.expertJudge.apiKeyEnv || "SYNTHETIC_API_KEY");
  }
  const dead = [];
  for (const { baseUrl, apiKeyEnv } of endpoints.values()) {
    const key = keys[apiKeyEnv];
    if (!key) continue; // missing keys already failed resolution above
    const url = baseUrl.replace(/\/+$/, "") + "/models";
    try {
      const res = await fetch(url, {
        headers: { Authorization: `Bearer ${key}` },
        signal: AbortSignal.timeout(15_000),
      });
      if ([401, 402, 403].includes(res.status)) {
        dead.push(`${baseUrl} → HTTP ${res.status} (${apiKeyEnv})`);
      }
    } catch (e) {
      // Transport trouble here is a warning only: the run itself retries
      // transient outages, but a hard auth/balance refusal is fatal.
      console.warn(`bench: preflight could not reach ${url}: ${e.message}`);
    }
  }
  if (dead.length) {
    console.error("bench: provider preflight failed — aborting before any run:");
    for (const d of dead) console.error(`  ${d}`);
    process.exit(1);
  }
}
if (!SKIP_PREFLIGHT) await preflight();

// ---------- helpers ----------
function git(repo, args) {
  return execFileSync("git", ["-C", repo, ...args], { encoding: "utf8" }).trim();
}

// Agents on this box may run docker bind-mounts that leave root-owned scratch
// in a workdir (seen: cpython-39 .pyc from an agent-run container). A plain
// rm then fails, which would crash the lane; fall back to renaming the
// poisoned dir aside so the rerun starts clean.
function resetWorkdir(workdir) {
  try {
    fs.rmSync(workdir, { recursive: true, force: true });
  } catch {
    try {
      fs.renameSync(workdir, workdir + ".poisoned-" + Date.now());
    } catch {}
    fs.rmSync(workdir, { recursive: true, force: true });
  }
  fs.mkdirSync(workdir, { recursive: true });
}

function prepareRepo(taskId, dest) {
  const src = path.join(TASK_ROOT, taskId, "repo");
  fs.cpSync(src, dest, { recursive: true });
  // Test runs litter the repo with derived artifacts (Python __pycache__,
  // compiled test binaries). Ignore them so a model's normal `git add -A`
  // doesn't stage test-run byproducts into the diff.
  const gi = path.join(dest, ".gitignore");
  if (!fs.existsSync(gi)) {
    fs.writeFileSync(gi, "__pycache__/\n*.pyc\n");
  }
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

function runTests(repo, meta, taskId) {
  // Hidden-test mode: meta.verify names a script next to prompt.md (e.g. a
  // SWE-bench verify.sh that applies the test patch only now). Otherwise the
  // repo's own test.sh runs.
  if (meta.verify) {
    return run("bash", [path.join(TASK_ROOT, taskId, meta.verify)], {
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

const SOURCE_EXT =
  /\.(py|nim|nimble|js|ts|mjs|cjs|sh|bash|cfg|ini|toml|yaml|yml|json|c|h|cpp|hpp|rs|go)$/;

function protectedTouched(repo, meta) {
  let tracked = null;
  try {
    tracked = new Set(
      git(repo, ["ls-tree", "-r", "--name-only", "base"])
        .split("\n")
        .filter(Boolean),
    );
  } catch {}
  const changed = new Set(
    diffStat(repo).files.filter(
      (f) => !f.includes("__pycache__/") && !f.endsWith(".pyc"),
    ),
  );
  for (const pat of meta.protected || []) {
    for (const f of changed) {
      if (!(pat.endsWith("/**") ? f.startsWith(pat.slice(0, -2)) : f === pat))
        continue;
      // Files new to base only violate when they look like source: compiled
      // test binaries and other build artifacts under tests/ are byproducts
      // of RUNNING the tests, not tampering (a planted conftest.py would be).
      if (tracked && !tracked.has(f) && !SOURCE_EXT.test(f)) continue;
      return f;
    }
  }
  return null;
}

function feedbackPrompt(meta, testOut) {
  const verifier = meta.verify ? "The official hidden verifier" : "`./test.sh`";
  return [
    `Your changes still fail verification. ${verifier} exits non-zero with this output (tail):`,
    "",
    tail(testOut, 6000),
    "",
    `Keep working until verification passes. Do not modify: ${(meta.protected || []).join(", ") || "tests"}.`,
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
  codewhale: {
    mod: cw,
    needsKeys: ["DEEPSEEK_API_KEY", "LLMGATEWAY_API_KEY"],
  },
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
  resetWorkdir(workdir);
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
  let fatalProviderError = null;

  // Gateway outages must not fail one-shot tasks: transport-level errors
  // (connection/TLS/timeout, or a Niffler turn whose LLM calls never went
  // through) are retried in place. Auth/balance failures are not retried.
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  let prevUsageTotal = 0;
  const isTransportError = (msg) => {
    const m = String(msg || "");
    if (/balance|401|403|unauthorized|invalid.{0,20}key/i.test(m)) return false;
    return /connection|timed out|tls|fetch failed|socket|network|econn|eai_again|reset by peer/i.test(m);
  };
  // Auth/balance/permission refusals cannot heal within a run: every further
  // round would burn the same failure. Fatal errors stop the cell after one
  // verification of the partial patch (which may already pass — seen: a
  // DeepSeek 402 killed t17 mid-turn while its patch was complete).
  const isFatalProviderError = (msg) =>
    /\b(401|402|403)\b|insufficient.{0,20}balance|balance.{0,20}insufficient|unauthorized|invalid.{0,20}key|quota.{0,20}exceeded|permission.{0,20}denied/i.test(
      String(msg || ""),
    );

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
      let transportRetries = 0;
      let res = null;
      for (;;) {
        const r0 = Date.now();
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
            thinking: thinkingFor("pi"),
          });
          adapterState.sessionFile = res.sessionFile;
        } else if (combo.harness === "opencode") {
          res = await oc.round({
            repo,
            prompt,
            modelCfg: combo.modelCfg.opencode,
            turnTimeoutMs,
            sessionId: adapterState.sessionId || null,
            thinking: thinkingFor("opencode"),
          });
          adapterState.sessionId = res.sessionId;
        } else if (combo.harness === "codewhale") {
          res = await cw.round({
            repo,
            prompt,
            modelCfg: combo.modelCfg.codewhale,
            keys,
            turnTimeoutMs,
            thinking: thinkingFor("codewhale"),
          });
        } else if (isNifflerHarness(combo.harness)) {
          res = await shared.niffler.round({
            sessionId,
            prompt,
            turnTimeoutMs,
            cwd: shared.niffler.workspaceFor(repo),
          });
        }
        const agentS = (Date.now() - r0) / 1000;
        let transportFail = res.error && isTransportError(res.error);
        if (!res.error && isNifflerHarness(combo.harness) && transportRetries < 2) {
          // A "successful" turn whose every LLM call hit an outage ends with
          // zero provider usage; retry rather than record a bogus fail.
          try {
            const u = await shared.niffler.usageFromTranscript(sessionId);
            const total = u.input + u.output + u.cacheRead;
            if (total === prevUsageTotal && String(res.reply || "").trim().length < 200) {
              transportFail = true;
            } else {
              prevUsageTotal = total;
            }
          } catch {}
        }
        if (transportFail && transportRetries < 2) {
          transportRetries += 1;
          console.log(
            `  [${combo.harness}/${combo.model}/${taskId}] transport error, retry ${transportRetries}/2 in 5s` +
              (res.error ? `: ${String(res.error).slice(0, 80)}` : " (zero-usage turn)"),
          );
          await sleep(5_000);
          continue;
        }
        res.agentS = agentS;
        if (transportRetries && !res.error) {
          // keep the retry count visible on the round that eventually ran
          res.transportRetries = transportRetries;
        }
        agentTimeS += agentS;
        break;

      }
      if (res.roundUsage) roundUsages.push(res.roundUsage);
      if (res.raw) {
        fs.writeFileSync(
          path.join(workdir, `round-${r}.log`),
          `## stdout\n${res.raw.stdout}\n## stderr\n${res.raw.stderr}\n`,
        );
      }

      const test0 = Date.now();
      const fatal = !!res.error && isFatalProviderError(res.error);
      // A turn-round-budget exhaustion marker is informational: if the
      // captured diff still passes, the cell passes (the model was cut off
      // mid-turn, not mid-edit). Fatal provider errors also verify once —
      // the partial patch may already be complete.
      const budgetOnly = !!res.error && /round budget exhausted/.test(String(res.error));
      const test =
        !res.error || fatal || budgetOnly
          ? await runTests(repo, taskMeta, taskId)
          : { code: -1, stdout: "", stderr: res.error };
      const testS = (Date.now() - test0) / 1000;
      testTimeS += testS;
      const pass = (!res.error || budgetOnly) && test.code === 0;

      rounds.push({
        r,
        agentS: Number((res.agentS || 0).toFixed(1)),
        testS: Number(testS.toFixed(1)),
        pass,
        error: res.error || null,
        fatal: fatal ? res.error : null,
        transportRetries: res.transportRetries || 0,
        replyTail: tail(res.reply, 800),
        testOutputTail: tail(test.stdout + test.stderr, 4000),
      });
      roundReply = res.reply || "";
      console.log(
        `  [${combo.harness}/${combo.model}/${taskId}] round ${r}: ` +
          `${pass ? "PASS" : "fail"} (agent ${(res.agentS || 0).toFixed(0)}s)` +
          (res.error ? ` error=${String(res.error).slice(0, 120)}` : ""),
      );
      if (pass) {
        verdict = "pass";
        break;
      }
      if (fatal) {
        verdict = "error";
        fatalProviderError = res.error;
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
    else if (combo.harness === "codewhale") usage = cw.usageFromRounds(roundUsages);
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
  // Footprint guard: the direct toolset + baseprompt must stay small (see
  // bench/README.md). Exceeding the budget is a warning, not a failure —
  // but it should trigger a prompt-diet before the next full run.
  let footprintOver = false;
  const budget = cfg.defaults?.firstPromptBudget ?? null;
  if (firstPromptTokens && budget && firstPromptTokens > budget) {
    footprintOver = true;
    console.warn(
      `[footprint] ${combo.harness}/${combo.model}/${taskId}: first prompt ` +
        `${firstPromptTokens} tokens exceeds budget ${budget} — trim the ` +
        "direct toolset / baseprompt",
    );
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
    // Include untracked files in stats and the submitted patch without truly
    // staging their contents.
    try {
      execFileSync("git", ["-C", repo, "add", "-N", "--", "."], { stdio: "ignore" });
    } catch {}
    diff = diffStat(repo);
    try {
      fs.writeFileSync(path.join(workdir, "patch.diff"), git(repo, ["diff", "--binary", "base"]));
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
    thinking: thinkingFor(combo.harness) || null,
    task: taskId,
    verdict,
    invalid,
    fatal: fatalProviderError,
    rounds: rounds.length,
    agentTimeS: Number(agentTimeS.toFixed(1)),
    testTimeS: Number(testTimeS.toFixed(1)),
    totalTimeS: Number(totalTimeS.toFixed(1)),
    tokens: usage,
    firstPromptTokens,
    footprintOver,
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
      (invalid ? ` (${invalid})` : "") +
      (fatalProviderError ? ` [fatal: ${String(fatalProviderError).slice(0, 80)}]` : ""),
  );
  return result;
}

// ---------- combo state (lazy boot, task-major sharing) ----------
// Niffler harnesses boot lazily on their first cell and stay up until the
// whole run ends; pi/opencode combos need only per-combo scratch dirs.
const comboStates = new Map(); // "harness|model" -> {combo, shared, error, booting}
async function ensureCombo(combo) {
  const key = `${combo.harness}|${combo.model}`;
  let st = comboStates.get(key);
  if (!st) {
    st = { combo, shared: null, error: null, booting: null };
    comboStates.set(key, st);
  }
  if (!st.booting) {
    st.booting = (async () => {
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
          thinking: thinkingByHarness ? thinkingFor("niffler") : combo.modelCfg.niffler.thinking || "",
          maxTurnRounds,
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
          st.error = `harness start failed: ${e.message}`;
        }
      }
      st.shared = shared;
    })();
  }
  await st.booting;
  return st;
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
      if (harness === "codewhale" && !cfg.models[model].codewhale) {
        console.error(
          `bench: model '${model}' has no codewhale section in config.json`,
        );
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
    taskRoot: path.relative(BENCH_ROOT, TASK_ROOT) || ".",
    roundsMax,
    taskTimeoutMs,
    turnTimeoutMs,
    keepRepos: KEEP_REPOS,
    thinking: {
      profile: THINKING || null,
      harnesses: thinkingByHarness,
    },
  });

  // Task-major scheduling: one cell = (combo, task). Cells are emitted task
  // by task with the harness order rotated per task index, so no harness
  // lane systematically runs first (temporal bias seen in full17: one
  // provider died mid-run and only the early lanes survived it).
  const cells = [];
  for (let t = 0; t < tasks.length; t++) {
    for (let i = 0; i < combos.length; i++) {
      cells.push({ combo: combos[(i + t) % combos.length], taskId: tasks[t] });
    }
  }
  const taskMetaOf = new Map(
    tasks.map((taskId) => [taskId, readJson(path.join(TASK_ROOT, taskId, "meta.json"))]),
  );
  const taskPromptOf = new Map(
    tasks.map((taskId) => [taskId, fs.readFileSync(path.join(TASK_ROOT, taskId, "prompt.md"), "utf8")]),
  );
  let cellIdx = 0;
  async function worker() {
    while (cellIdx < cells.length) {
      const { combo, taskId } = cells[cellIdx++];
      if (RESUME) {
        try {
          const prev = JSON.parse(fs.readFileSync(
            path.join(RESULTS, `${combo.harness}__${combo.model}__${taskId}`, "result.json"), "utf8"));
          if (prev.runId === RUN_ID && prev.verdict && prev.verdict !== "error") {
            console.log(`[${combo.harness}/${combo.model}/${taskId}] resume: kept ${prev.verdict}`);
            continue;
          }
        } catch {}
      }
      try {
        const st = await ensureCombo(combo);
        if (st.error) {
          // Harness boot failed once: record the error for every remaining
          // cell of this combo instead of retrying the boot per cell.
          writeJson(
            path.join(RESULTS, `${combo.harness}__${combo.model}__${taskId}`, "result.json"),
            {
              runId: RUN_ID,
              harness: combo.harness,
              model: combo.model,
              task: taskId,
              verdict: "error",
              error: st.error,
            },
          );
          console.log(`[${combo.harness}/${combo.model}/${taskId}] ERROR ${st.error}`);
          continue;
        }
        await runTask(combo, taskId, taskMetaOf.get(taskId), taskPromptOf.get(taskId), st.shared);
      } catch (err) {
        console.error(`[${combo.harness}/${combo.model}/${taskId}] crashed: ${err?.stack || err}`);
        writeJson(
          path.join(RESULTS, `${combo.harness}__${combo.model}__${taskId}`, "result.json"),
          { runId: RUN_ID, harness: combo.harness, model: combo.model, task: taskId, verdict: "error", error: String(err?.stack || err) },
        );
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(JOBS, cells.length) }, worker));
  for (const st of comboStates.values()) {
    if (st.shared?.niffler) {
      console.log(`stopping niffler harness (${st.combo.model})…`);
      await st.shared.niffler.stop();
    }
  }
  console.log(`bench: done — results in ${RESULTS}`);
  console.log(`bench: report with  node bench/report.mjs --run ${RUN_ID}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
