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
  for (const e of events) {
    if (e.sessionID) sid = e.sessionID;
    if (e.type === "error") {
      error =
        e.error?.data?.message || e.error?.message || JSON.stringify(e.error) || "opencode error event";
    }
    if (e.type === "step_finish" || e.type === "step-finish") {
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
  return { reply, error, sessionId: sid, roundUsage: stepUsage, raw: res };
}

// Usage is accumulated per round by round(); total = sum of the given
// per-round usage objects (or round records carrying .roundUsage).
export function usageFromRounds(rounds) {
  const usage = zeroUsage();
  for (const r of rounds) addUsage(usage, r.roundUsage || r);
  return usage;
}

export const name = "opencode";
