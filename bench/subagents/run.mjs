// bench/subagents/run.mjs — P4.14 subagent mechanism scenarios.
//
// The honest answer to "kinda hard to benchmark this fairly": these
// scenarios measure HARNESS mechanics, not model affinity. Each drives the
// agent tools deterministically over the cli (the model only answers the
// CHILDREN's turns) and scores bus-observable facts — children spawned,
// activations, notices delivered, replies returned — alongside the usual
// tokens/time. Do not compare cross-harness on these numbers without the
// caveat that they test the model+harness combo; they exist to catch
// Niffler regressions.
//
// Usage (from the repo root, after `make build`):
//   node bench/subagents/run.mjs --model <model> --base-url <url> \
//        --key-env <ENV_VAR_NAME> [--bench-root .] [--out <dir>]
//
// Scenarios:
//   1. delegate-and-collect  spawn 3 independent children, wait for all,
//                            assert 3 replies and 3 settlement notices
//   2. follow-up             continue a child twice — activations 2 and 3,
//                            replies returned each time
//   3. fork                  fork a parent with completed turns — the
//                            child's transcript carries the history
//   4. interrupt-and-resume  stop a running child, then continue it

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { NifflerHarness } from "../adapters/niffler.mjs";

const args = process.argv.slice(2);
function argOf(name, def = "") {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : def;
}
const benchRoot = path.resolve(argOf("--bench-root", "."));
const model = argOf("--model", "");
const baseUrl = argOf("--base-url", "");
const keyEnv = argOf("--key-env", "");
const outDir = argOf("--out", "");
if (!model || !baseUrl || !keyEnv) {
  console.error("usage: run.mjs --model <m> --base-url <url> --key-env <ENV> [--bench-root .] [--out dir]");
  process.exit(2);
}
const apiKey = process.env[keyEnv] || "";
if (!apiKey) {
  console.error(`key env ${keyEnv} is not set`);
  process.exit(2);
}

const runRoot = fs.mkdtempSync(path.join(benchRoot, "var", "bench", "subagents-"));
const harness = new NifflerHarness({
  benchRoot, runRoot, baseUrl, apiKey, model,
});
const PARENT = "bench-subagents";
const TURN_TIMEOUT = 240_000;

function cli(tool, argsJson, timeoutMs = 120_000) {
  const cli = path.join(harness.binDir, "cli");
  const res = spawnSync(
    cli,
    [`--timeout:${Math.ceil(timeoutMs / 1000)}`, "call", tool, JSON.stringify(argsJson)],
    { cwd: harness.root, env: harness.cliEnv(), encoding: "utf8",
      timeout: timeoutMs + 30_000 },
  );
  let parsed = null;
  for (const line of (res.stdout || "").trim().split("\n").reverse()) {
    try { parsed = JSON.parse(line); break; } catch {}
  }
  return { ok: parsed != null, result: parsed,
           raw: (res.stdout || "") + (res.stderr || "") };
}

// The same __session injection core's dispatch gate performs during a turn —
// the scenarios drive the agent tools as the parent conversation.
function agent(tool, args, timeoutMs = 120_000) {
  const full = { ...args, __session: { session: PARENT } };
  const r = cli(tool, full, timeoutMs);
  if (!r.ok || !r.result) {
    return { ok: false, error: `cli ${tool} failed: ${r.raw.slice(-300)}` };
  }
  return r.result;
}

async function waitTerminal(jobId, timeoutMs = 300_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const r = agent("agent_status", { jobId }, 30_000);
    const status = r?.status ?? "unknown";
    if (status !== "running" && status !== "stopping") return r;
    await new Promise((res) => setTimeout(res, 1000));
  }
  return { status: "wait-timeout", jobId };
}

function scenario(name) {
  const t0 = Date.now();
  return {
    name,
    checks: [],
    metrics: {},
    check(ok, what, detail = "") {
      this.checks.push({ ok, what, detail: String(detail).slice(-300) });
      console.log(`  ${ok ? "ok" : "FAIL"}: ${what}${ok ? "" : " — " + detail}`);
      return ok;
    },
    done() { this.metrics.elapsedMs = Date.now() - t0; return this; },
  };
}

async function scenarioDelegateAndCollect() {
  const s = scenario("delegate-and-collect");
  const tasks = [
    "Reply with exactly one line: the word alpha.",
    "Reply with exactly one line: the word beta.",
    "Reply with exactly one line: the word gamma.",
  ];
  const jobs = [];
  for (const task of tasks) {
    const r = agent("agent_spawn", { task });
    if (!s.check(r.jobId?.startsWith("job-"), "spawn returned a jobId", JSON.stringify(r))) {
      return s.done();
    }
    jobs.push(r);
  }
  s.metrics.children = jobs.length;
  const results = [];
  for (const j of jobs) results.push(await waitTerminal(j.jobId));
  const replies = results.filter((r) => r.status === "done" && (r.reply ?? "").length > 0);
  s.metrics.replies = replies.length;
  s.check(replies.length === 3, "all three children replied",
          JSON.stringify(results.map((r) => r.status)));
  const notices = agent("agent_notices", { session: PARENT, peek: true }, 30_000);
  const settled = (notices.notices ?? []).filter((n) => n.direction !== "parent-mail");
  s.metrics.notices = settled.length;
  s.check(settled.length === 3, "three settlement notices reached the parent",
          JSON.stringify(notices).slice(-300));
  return s.done();
}

async function scenarioFollowUp() {
  const s = scenario("follow-up");
  const first = agent("agent_run",
    { task: "Reply with exactly one line: your favorite color is blue." },
    TURN_TIMEOUT + 60_000);
  if (!s.check(first.sessionId?.startsWith("agent-"), "fresh run returned a child",
               JSON.stringify(first).slice(-300))) return s.done();
  const child = first.sessionId;
  const info1 = cli("session_info", { sessionId: child }, 30_000);
  s.metrics.activations = 1;
  for (let i = 2; i <= 3; i++) {
    const r = agent("agent_run",
      { session: child, task: `Follow-up ${i}: reply with exactly one line: the number ${i}.` },
      TURN_TIMEOUT + 60_000);
    s.check((r.reply ?? "").length > 0 && r.continued === true,
            `continuation ${i - 1} returned a reply`, JSON.stringify(r).slice(-300));
    s.metrics.activations = i;
  }
  const info = cli("session_info", { sessionId: child }, 30_000);
  s.check(info.activations === 3, "activation ledger counts 3 turns",
          JSON.stringify(info));
  s.check(info.children === 0 || info.children === undefined,
          "a child has no children", JSON.stringify(info));
  return s.done();
}

async function scenarioFork() {
  const s = scenario("fork");
  // Give the parent two completed turns (the model just chats — the CONTENT
  // does not matter; what matters is that completed turns exist to fork).
  for (const content of [
    "Remember the codeword HARBOR. Reply with exactly one line acknowledging it.",
    "Reply with exactly one line: the word anchor.",
  ]) {
    const r = cli("session", { sessionId: PARENT, content }, TURN_TIMEOUT + 60_000);
    if (!r.ok) {
      s.check(false, "parent turn completed", r.raw.slice(-300));
      return s.done();
    }
  }
  const forked = agent("agent_run",
    { task: "What codeword did this conversation remember? Reply with only the codeword.",
      fork: true },
    TURN_TIMEOUT + 60_000);
  if (!s.check(forked.sessionId?.startsWith("agent-"),
               "fork returned a child", JSON.stringify(forked).slice(-300))) {
    return s.done();
  }
  s.metrics.forkCopied = forked.fork?.copied ?? 0;
  s.check((forked.fork?.copied ?? 0) > 0, "fork carries provenance",
          JSON.stringify(forked.fork));
  const reply = (forked.reply ?? "").toUpperCase();
  s.check(reply.includes("HARBOR"),
          "the forked child ANSWERED from inherited history (no restating)",
          forked.reply);
  const transcript = cli("session_info", { sessionId: forked.sessionId }, 30_000);
  s.check((transcript.messageCount ?? 0) > 2,
          "the child's transcript carries the inherited history",
          JSON.stringify(transcript));
  return s.done();
}

async function scenarioInterruptAndResume() {
  const s = scenario("interrupt-and-resume");
  const spawned = agent("agent_spawn",
    { task: "Write a 600-word essay about lighthouses. Take your time." });
  if (!s.check(spawned.jobId?.startsWith("job-"), "spawn returned a jobId",
               JSON.stringify(spawned))) return s.done();
  const child = spawned.sessionId;
  // wait until the turn is actually running, then stop it
  let stopped = null;
  const deadline = Date.now() + 120_000;
  while (Date.now() < deadline) {
    const st = agent("agent_status", { jobId: spawned.jobId }, 30_000);
    if (st.status === "running") {
      stopped = agent("agent_stop", { jobId: spawned.jobId }, 30_000);
      break;
    }
    if (st.status !== "running" && st.status !== "stopping" && st.status !== "unknown") {
      // settled too fast to interrupt: still resume-able, note it
      stopped = { status: st.status, tooFast: true };
      break;
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  s.check(stopped !== null, "the running child was stopped (or settled fast)",
          JSON.stringify(stopped));
  const resumed = agent("agent_run",
    { session: child, task: "The interrupted task is void. Reply with exactly one line: resumed." },
    TURN_TIMEOUT + 60_000);
  s.check((resumed.reply ?? "").length > 0 && resumed.activation >= 2,
          "interrupt-then-continue composed (activation >= 2, reply returned)",
          JSON.stringify(resumed).slice(-300));
  return s.done();
}

async function main() {
  await harness.start();
  try {
    const results = [];
    for (const fn of [scenarioDelegateAndCollect, scenarioFollowUp,
                      scenarioFork, scenarioInterruptAndResume]) {
      console.log(`\n== ${fn.name.replace(/^scenario/, "")}`);
      try {
        results.push(await fn());
      } catch (e) {
        const s = scenario(fn.name.replace(/^scenario/, ""));
        s.check(false, "scenario threw", e.stack || e.message);
        results.push(s.done());
      }
    }
    console.log("\n== summary");
    let failed = 0;
    for (const r of results) {
      const bad = r.checks.filter((c) => !c.ok);
      failed += bad.length;
      console.log(`${bad.length === 0 ? "PASS" : "FAIL"}  ${r.name}  ` +
                  `${r.checks.length - bad.length}/${r.checks.length} checks · ` +
                  `${r.metrics.elapsedMs ?? 0}ms · ` +
                  Object.entries(r.metrics)
                    .filter(([k]) => k !== "elapsedMs")
                    .map(([k, v]) => `${k}=${v}`).join(" "));
    }
    console.log(`\nsubagent-bench ${failed === 0 ? "PASSED" : `FAILED (${failed} check(s))`}`);
    if (outDir) {
      fs.mkdirSync(outDir, { recursive: true });
      fs.writeFileSync(path.join(outDir, "subagents-report.json"),
                       JSON.stringify({ model, baseUrl, results }, null, 2));
      console.log(`report written to ${path.join(outDir, "subagents-report.json")}`);
    }
    process.exitCode = failed === 0 ? 0 : 1;
  } finally {
    await harness.stop();
  }
}

await main();
