#!/usr/bin/env node
// bench/launch.mjs — interactive launcher for bench runs (run.mjs front-end).
//
// Asks: target (localhost / wowbagger), harnesses, provider/model, thinking
// level, benchmark + tasks, rounds/jobs — then launches the run detached and
// prints monitor/report commands. Every question takes a default on Enter;
// all answers can also be passed as flags, which makes this scriptable:
//
//   node bench/launch.mjs --dry-run \
//     --harness niffler,pi --model glm-5.3-flash --thinking max \
//     --task-root var/bench/deepswe/tasks-pilot --tasks all --rounds 1
//
// Keys are resolved exactly like run.mjs does (bench/lib/keys.mjs: env >
// repo .env > opencode auth.json); this script only pre-checks and warns.
import fs from "node:fs";
import path from "node:path";
import url from "node:url";
import readline from "node:readline";
import { spawn, spawnSync } from "node:child_process";
import { resolveKeys } from "./lib/keys.mjs";

const ROOT = path.resolve(path.dirname(url.fileURLToPath(import.meta.url)), "..");
const cfg = JSON.parse(fs.readFileSync(path.join(ROOT, "bench", "config.json"), "utf8"));
const MODELS = Object.keys(cfg.models || {});
const HARNESS_CHOICES = ["niffler", "pi", "opencode", "codewhale"];
const WOW = { host: "gokr@wowbagger.krampe.se", dir: "~/niffler" };

// ---------- tiny flag parser (--key value) ----------
const argv = process.argv.slice(2);
const flag = (name, def) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : def;
};
const has = (name) => argv.includes(`--${name}`);

// ---------- prompt engine ----------
// TTY: readline with Enter=default. Piped input (tests/CI): consumed upfront
// line-by-line — deterministic, immune to the readline-EOF race; an empty
// line or EOF takes the default.
const isTTY = Boolean(process.stdin.isTTY);
const rl = isTTY ? readline.createInterface({ input: process.stdin, output: process.stdout }) : null;
let piped = null;
let pipedIdx = 0;
let pending = null;
const settle = (v) => { const p = pending; pending = null; p && p(v); };
if (rl) rl.on("close", () => settle(null));
else piped = fs.readFileSync(0, "utf8").split("\n").map((s) => s.trim());
const ask = (q, def) =>
  new Promise((res) => {
    if (!isTTY) {
      const line = piped[pipedIdx++];
      const v = line === undefined || line === "" ? null : line;
      process.stdout.write(`${q}${def ? ` [${def}]` : ""}: ${v ?? ""}\n`);
      return res(v);
    }
    pending = res;
    rl.question(`${q}${def ? ` [${def}]` : ""}: `, (a) => settle(a.trim() || null));
  });
const close = () => rl && rl.close();

const parseList = (s, allowed) => {
  if (s === "all") return allowed.slice(); // only an explicit 'all'
  if (!s) return [];
  return s.split(",").map((x) => x.trim().toLowerCase()).filter((x) => allowed.includes(x));
};
const sanitize = (s) => String(s).replace(/[^a-zA-Z0-9._-]/g, "");

// ---------- inventory ----------
const listTasks = (root) => {
  const abs = path.isAbsolute(root) ? root : path.join(ROOT, root);
  try {
    return fs
      .readdirSync(abs)
      .filter((d) => fs.existsSync(path.join(abs, d, "meta.json")))
      .sort();
  } catch {
    return null; // root missing
  }
};

const BENCHMARKS = [
  { key: "deepswe-pilot", label: "DeepSWE pilot-10 (ready, images pulled)", root: "var/bench/deepswe/tasks-pilot" },
  { key: "deepswe-full", label: "DeepSWE full 113 (needs prepare + image pulls)", root: "var/bench/deepswe/tasks" },
  { key: "full17", label: "full17 custom tasks (bench/tasks)", root: "bench/tasks" },
  { key: "swe-verified", label: "SWE-bench Verified (needs bench/swe/import.mjs)", root: "var/bench/swe/tasks" },
];
for (const b of BENCHMARKS) {
  const t = listTasks(b.root);
  b.count = t ? t.length : 0;
  b.ready = t !== null;
  b.tasks = t || [];
}

const timeoutDefaults = (root) =>
  /deepswe/.test(root)
    ? { turn: 185, task: 200, test: 2000 } // DeepSWE: 3h agent window, 30min verifier
    : { turn: cfg.defaults.turnTimeoutMin, task: cfg.defaults.taskTimeoutMin, test: cfg.defaults.testTimeoutSec };

// ---------- pre-flight ----------
const sshOk = (() => {
  const r = spawnSync("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=6", WOW.host, "echo ok"], {
    encoding: "utf8", timeout: 10_000,
  });
  return r.status === 0 && /ok/.test(r.stdout);
})();

const keyWarning = (model) => {
  const { keys, missing } = resolveKeys(ROOT, new Set([model]));
  if (missing.length) return `missing keys for ${model}: ${missing.join(", ")}`;
  const envs = cfg.models[model]
    ? [...new Set(Object.values(cfg.models[model]).map((h) => h.apiKeyEnv).filter(Boolean))]
    : [];
  const unres = envs.filter((e) => !keys[e]);
  return unres.length ? `unresolved key envs for ${model}: ${unres.join(", ")}` : null;
};

// ---------- prompts (flag > prompt > default) ----------
console.log(`\nbench launcher — ${MODELS.length} models configured, ssh to wowbagger: ${sshOk ? "OK" : "UNAVAILABLE"}\n`);

let target = has("target") ? flag("target") : null;
if (!target) {
  const t = await ask(`Target  1) localhost  2) wowbagger (ssh, ${sshOk ? "reachable" : "NO CREDENTIALS"}) [1]`, "1");
  target = t === "2" ? "wowbagger" : "localhost";
}
target = target.toLowerCase();

let harnesses = parseList(flag("harness"), HARNESS_CHOICES);
if (!harnesses.length) {
  const h = await ask(`Harnesses (comma list or all) [niffler,pi]`, "niffler,pi");
  harnesses = parseList(h, HARNESS_CHOICES);
  if (!harnesses.length) harnesses = ["niffler", "pi"];
}

let model = flag("model") || null;
if (!model) {
  const list = MODELS.map((m, i) => `${i + 1}) ${m} (${cfg.models[m].label})`).join("  ");
  const m = await ask(`Model  ${list} [1]`, "1");
  model = /^\d+$/.test(m) ? MODELS[Number(m) - 1] : m;
}
if (!MODELS.includes(model)) {
  console.error(`unknown model '${model}' — known: ${MODELS.join(", ")}`);
  close();
  process.exit(1);
}
const kw = keyWarning(model);
if (kw) console.warn(`warning: ${kw}`);

const profiles = Object.keys(cfg.thinking?.profiles || {});
let thinking = flag("thinking") || null;
if (!thinking) {
  const opts = [...profiles, "model-default"].map((p, i) => `${i + 1}) ${p}`).join("  ");
  const t = await ask(`Thinking  ${opts} [model-default]`, String(profiles.length + 1));
  thinking = /^\d+$/.test(t) ? [...profiles, "model-default"][Number(t) - 1] : t;
}
if (thinking === "model-default") thinking = null;
if (thinking && !profiles.includes(thinking)) {
  console.error(`unknown thinking profile '${thinking}' — known: ${profiles.join(", ")}`);
  close();
  process.exit(1);
}

let bench = BENCHMARKS.find((b) => b.key === flag("bench")) || null;
if (!bench) {
  const list = BENCHMARKS.map((b, i) => `${i + 1}) ${b.label} — ${b.ready ? `${b.count} task(s)` : "not imported"}`).join("\n           ");
  const b = await ask(`Benchmark  ${list}\n           [1]`, "1");
  bench = /^\d+$/.test(b) ? BENCHMARKS[Number(b) - 1] : BENCHMARKS.find((x) => x.key === b) || BENCHMARKS[0];
}
if (!bench.ready) {
  console.error(`'${bench.label}' is not prepared yet — see bench/${bench.key.startsWith("deepswe") ? "deepswe" : "swe"}/README.md`);
  close();
  process.exit(1);
}

let taskSel = flag("tasks") || null;
if (!taskSel) {
  const preview = bench.tasks.slice(0, 20).map((t, i) => `${i + 1}:${t}`).join("\n   ");
  const more = bench.tasks.length > 20 ? `\n   … +${bench.tasks.length - 20} more` : "";
  taskSel = await ask(
    `Tasks of ${bench.count} — all | s<N> (sample) | comma indexes or task names\n   ${preview}${more}\n   [all]`,
    "all",
  );
}
let tasksArg = "all";
const picked = [];
if (taskSel !== "all") {
  const sm = taskSel.match(/^s(\d+)$/i);
  if (sm) {
    const n = Math.min(Number(sm[1]), bench.tasks.length);
    for (let i = 0; i < n; i++) picked.push(bench.tasks[i]); // first N: deterministic, image-friendly
  } else {
    for (const part of taskSel.split(",")) {
      const t = part.trim();
      const i = /^\d+$/.test(t) ? Number(t) : 0;
      if (i >= 1 && i <= bench.tasks.length) picked.push(bench.tasks[i - 1]);
      else if (bench.tasks.includes(t)) picked.push(t);
    }
  }
  tasksArg = [...new Set(picked)].join(",");
  if (!tasksArg) {
    console.error("no tasks selected");
    close();
    process.exit(1);
  }
}

let rounds = flag("rounds") || null;
if (!rounds) rounds = (await ask(`Rounds (1 = canonical one-shot) [1]`, "1")) || "1";
let jobs = flag("jobs") || null;
if (!jobs) jobs = (await ask(`Parallel jobs [${cfg.defaults.jobs}]`, String(cfg.defaults.jobs))) || String(cfg.defaults.jobs);

const td = timeoutDefaults(bench.root);
td.turn = Number(flag("turn-timeout-min", td.turn));
td.task = Number(flag("task-timeout-min", td.task));
td.test = Number(flag("test-timeout-sec", td.test));
let runId = flag("run-id") || null;
if (!runId) {
  const dflt = `${bench.key}-${sanitize(model)}${thinking ? "-" + thinking : ""}-${new Date().toISOString().slice(5, 16).replace(/[-:T]/g, "")}`;
  runId = (await ask(`Run id [${dflt}]`, dflt)) || dflt;
}

let ref = flag("ref") || null;
if (target === "wowbagger" && !ref) ref = (await ask(`Niffler ref to build on wowbagger [main]`, "main")) || "main";

// ---------- command ----------
const common = [
  "--task-root", bench.root,
  "--task", tasksArg,
  "--harness", harnesses.join(","),
  "--model", model,
  ...(thinking ? ["--thinking", thinking] : []),
  "--rounds", String(rounds),
  "--jobs", String(jobs),
  "--turn-timeout-min", String(td.turn),
  "--task-timeout-min", String(td.task),
  "--test-timeout-sec", String(td.test),
  "--run-id", runId,
];
// passthrough flags run.mjs understands
for (const f of ["resume", "keep-repos"]) if (has(f)) common.push("--" + f);

const localCmd = `node bench/run.mjs ${common.map((a) => (/[\s,]/.test(a) ? JSON.stringify(a) : a)).join(" ")}`;
const remoteCmd =
  `ssh ${WOW.host} 'cd ${WOW.dir} && nohup env NIFFLER_REF=${ref || "main"} ` +
  `docker compose -f bench/container/compose.yaml run --rm bench ${localCmd.replace("node ", "node ")} ` +
  `> var/bench/logs/${sanitize(runId)}.log 2>&1 &'`;
const runCmd = target === "wowbagger" ? remoteCmd : localCmd;

console.log(`\n──────── command (${target}) ────────\n${runCmd}\n`);
if (target === "wowbagger") {
  console.log(
    `notes: remote needs ${WOW.dir}/.env (keys) and the task root prepared there\n` +
      `       (bench/deepswe/prepare.mjs + --pull-images) — see bench/container/README.md.\n` +
      `report: ssh ${WOW.host} 'cd ${WOW.dir} && node bench/report.mjs --run ${sanitize(runId)}'\n`,
  );
}

const launch = has("yes") ? true : has("dry-run") ? false : null;
let go = launch;
if (go === null) {
  const a = await ask(`Launch detached now? [Y/n]`, "Y");
  // typed answer (incl. plain Enter) decides; piped EOF (null) never launches
  go = a === null ? false : !/^n/i.test(a || "Y");
}
close();
if (!go) {
  console.log("dry run — nothing launched.");
  process.exit(0);
}

if (target === "wowbagger") {
  const child = spawn("ssh", [WOW.host, remoteCmd.replace(`ssh ${WOW.host} `, "").replace(/^'(.*)'$/, "$1")], {
    stdio: "inherit",
  });
  child.on("exit", (c) => process.exit(c || 0));
} else {
  const logDir = path.join(ROOT, "var", "bench", "logs");
  fs.mkdirSync(logDir, { recursive: true });
  const logPath = path.join(logDir, `${sanitize(runId)}.log`);
  const out = fs.openSync(logPath, "a");
  const child = spawn("node", ["bench/run.mjs", ...common], {
    cwd: ROOT,
    detached: true,
    stdio: ["ignore", out, out],
    env: process.env,
  });
  child.unref();
  console.log(`launched pid ${child.pid} — log: ${logPath}`);
  console.log(`monitor:  tail -f ${path.relative(ROOT, logPath)}`);
  console.log(`report:   node bench/report.mjs --run ${runId}`);
}
