// bench/adapters/opencode.mjs — drive opencode headless via `opencode run`.
//
// One round = one `opencode run <prompt> --format json --pure --auto`.
// Round 2+ continue the same session via `--session <id>`. Tokens are the
// sum of all `step_finish` events' token counters (provider-reported).
import { run, parseJsonLines, zeroUsage, addUsage } from "../lib/util.mjs";

export async function round(opts) {
  const { repo, prompt, modelCfg, turnTimeoutMs, sessionId } = opts;
  const args = [
    "run",
    prompt,
    "--format",
    "json",
    "--pure",
    "--auto",
    "-m",
    modelCfg.model,
    "--dir",
    repo,
  ];
  if (sessionId) args.push("--session", sessionId);
  // Reasoning effort: opencode's --variant passes the effort straight to the
  // provider (e.g. reasoning_effort for openai-compatible endpoints). No
  // per-model default in config.json today — only the run-level profile.
  const thinking = opts.thinking || modelCfg.thinking || "";
  if (thinking) args.push("--variant", thinking);
  const res = await run("opencode", args, { cwd: repo, timeoutMs: turnTimeoutMs });

  const events = parseJsonLines(res.stdout);
  let reply = "";
  let error = null;
  let sid = sessionId || null;
  const stepUsage = zeroUsage();
  // Turn shape alongside usage: one step_finish per LLM step (the turns
  // column's analog) and one tool_use event per tool invocation.
  const roundShape = { turns: 0, toolCalls: 0, tools: {} };
  for (const e of events) {
    if (e.sessionID) sid = e.sessionID;
    if (e.type === "error") {
      error =
        e.error?.data?.message || e.error?.message || JSON.stringify(e.error) || "opencode error event";
    }
    if (e.type === "tool_use" && e.part?.type === "tool") {
      const n = String(e.part.tool || "?");
      roundShape.tools[n] = (roundShape.tools[n] || 0) + 1;
      roundShape.toolCalls += 1;
    }
    if (e.type === "step_finish" || e.type === "step-finish") {
      roundShape.turns += 1;
      const t = e.part?.tokens || {};
      addUsage(stepUsage, {
        input: t.input || 0,
        output: t.output || 0,
        reasoning: t.reasoning || 0,
        cacheRead: t.cache?.read || 0,
        cacheWrite: t.cache?.write || 0,
        cost: e.part?.cost || 0,
      });
    }
    // Last assistant text part wins.
    const part = e.part;
    if (part?.type === "text" && part.text) reply = part.text.trim();
  }
  if (res.timedOut) error = error || `opencode round timed out after ${turnTimeoutMs}ms`;
  if (res.code !== 0 && !error) {
    error = `opencode exited ${res.code}: ${(res.stderr || res.stdout || "").slice(-400)}`;
  }
  return { reply, error, sessionId: sid, roundUsage: stepUsage, roundShape, raw: res };
}

// Usage is accumulated per round by round(); total = sum of the given
// per-round usage objects (or round records carrying .roundUsage).
export function usageFromRounds(rounds) {
  const usage = zeroUsage();
  for (const r of rounds) addUsage(usage, r.roundUsage || r);
  return usage;
}

// Turn shape over the run's rounds (steps = turns; tool_use events = calls).
export function shapeFromRounds(rounds) {
  const shape = { turns: 0, toolCalls: 0, tools: {} };
  for (const r of rounds) {
    const s = r.roundShape || {};
    shape.turns += s.turns || 0;
    shape.toolCalls += s.toolCalls || 0;
    for (const [n, c] of Object.entries(s.tools || {})) {
      shape.tools[n] = (shape.tools[n] || 0) + c;
    }
  }
  return shape;
}

export const name = "opencode";
