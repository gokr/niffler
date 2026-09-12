// bench/adapters/claudecode.mjs — drive Claude Code headless via `claude -p`.
//
// One round = one `claude -p <prompt> --output-format stream-json` invocation
// in the repo dir. Round 1 pins the session id (`--session-id <uuid>`),
// round 2+ resume it (`--resume <uuid>`; same cwd, so the project-scoped
// session store resolves it). The gateway is selected with env:
// ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN + ANTHROPIC_MODEL point Claude
// Code at an Anthropic-compatible endpoint (here Synthetic's /anthropic).
// Permissions are bypassed (--dangerously-skip-permissions) — headless bench,
// no human to approve gated tools. All state lives in an isolated
// CLAUDE_CONFIG_DIR (setupClaudeCodeConfig); the developer's ~/.claude and
// ~/.claude.json are never touched, and the agent writes nothing into the
// repo (verified: no .claude/ or .claude.json in the project cwd).
//
// Usage is provider-reported from the final `result` event (a sum over the
// invocation's API calls); shape (turns + tool mix) is parsed from the
// per-message assistant events of the stream. total_cost_usd from the result
// event is IGNORED — Claude Code guesses unknown models' prices — cost is
// computed here from the same price table the niffler adapter uses.
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { run, parseJsonLines, zeroUsage, addUsage } from "../lib/util.mjs";

// Isolated CLAUDE_CONFIG_DIR per (harness,model) combo: onboarding state,
// session JSONLs and any telemetry opt-outs land here, never in ~/.claude.
export function setupClaudeCodeConfig(runRoot) {
  const dir = path.join(runRoot, "claude-config");
  fs.mkdirSync(dir, { recursive: true });
  return dir;
}

// Effort → thinking budget (MAX_THINKING_TOKENS). The bench thinking profile
// names efforts ("low"…); the AnthropicMessages dialect expresses the same
// knob as a token budget. Must stay below Claude Code's assumed 32k
// max_tokens for unknown models.
const THINKING_BUDGET = { low: 2048, medium: 8192, high: 16384, max: 30000 };

// $/MTok, same table as adapters/niffler.mjs (cache write free, matching the
// pi entry's synthetic cost row). Keyed by the gateway model id.
const PRICE = {
  "syn:large:text": { input: 0.15, output: 0.5, cacheRead: 0.04, cacheWrite: 0 },
};

export async function round(opts) {
  const { repo, prompt, modelCfg, keys = {}, turnTimeoutMs, cfgDir } = opts;
  // Explicit round-level thinking (run.mjs --thinking profile) wins over the
  // per-model config default.
  const thinking = opts.thinking || modelCfg.thinking || "";
  const sessionId = opts.sessionId || randomUUID();
  const args = [
    "-p",
    prompt,
    "--output-format",
    "stream-json",
    "--verbose",
    "--dangerously-skip-permissions",
    "--model",
    modelCfg.model,
  ];
  if (opts.sessionId) args.push("--resume", opts.sessionId);
  else args.push("--session-id", sessionId);

  const env = {
    ANTHROPIC_BASE_URL: modelCfg.baseUrl,
    ANTHROPIC_AUTH_TOKEN: keys[modelCfg.apiKeyEnv] || "",
    ANTHROPIC_MODEL: modelCfg.model,
    // Background/small calls (if any slip past the nonessential-traffic
    // opt-out) must also hit the gateway, not api.anthropic.com.
    ANTHROPIC_SMALL_FAST_MODEL: modelCfg.model,
    CLAUDE_CONFIG_DIR: cfgDir,
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
    DISABLE_TELEMETRY: "1",
    DISABLE_ERROR_REPORTING: "1",
    DISABLE_AUTOUPDATER: "1",
  };
  const budget = THINKING_BUDGET[thinking];
  if (budget) env.MAX_THINKING_TOKENS = String(budget);

  const res = await run("claude", args, { cwd: repo, timeoutMs: turnTimeoutMs, env });

  const events = parseJsonLines(res.stdout);
  const roundShape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0 };
  let resultEvent = null;
  let firstPrompt = null;
  for (const e of events) {
    if (e.type === "assistant" && e.message) {
      // First assistant event's input_tokens = the first API call's full
      // prompt (system + tools + task) on this gateway — the honest
      // firstPromptTokens analog of niffler's first-call prompt_tokens.
      // (Per-call cache fields in stream events are zeroed by the gateway;
      // only the aggregated result event carries real cache numbers.)
      if (firstPrompt === null) firstPrompt = e.message.usage?.input_tokens ?? null;
      roundShape.turns += 1;
      for (const b of e.message.content || []) {
        if (b.type !== "tool_use") continue;
        const n = String(b.name || "?").toLowerCase();
        roundShape.tools[n] = (roundShape.tools[n] || 0) + 1;
        roundShape.toolCalls += 1;
        // Claude Code's read is single-file per call (path + offset/limit);
        // counted as single to keep the readSingle/readBatch columns
        // comparable with the other harnesses.
        if (n === "read") roundShape.readSingle += 1;
      }
    }
    if (e.type === "result") resultEvent = e;
  }

  const roundUsage = zeroUsage();
  if (resultEvent?.usage) {
    const u = resultEvent.usage;
    const write = u.cache_creation_input_tokens || 0;
    const read = u.cache_read_input_tokens || 0;
    // The result event aggregates the whole invocation (verified against a
    // controlled 2-call run: result.input = Σ(prompt − cached_read) across
    // calls, cache_read/creation summed). Anthropic spec semantics: write ⊆
    // input, reads are exclusive — so uncached = input − write, prompt
    // processed = input + read, and the four counters stay disjoint.
    // (Caveat: the OpenAI endpoint hides cache details entirely, so the
    // niffler/pi lanes count every prompt token as uncached — see README.)
    roundUsage.input = Math.max(0, (u.input_tokens || 0) - write);
    roundUsage.cacheWrite = write;
    roundUsage.cacheRead = read;
    roundUsage.output = u.output_tokens || 0;
    // Subset annotation (already inside output for the Anthropic dialect).
    roundUsage.reasoning = u.output_tokens_details?.thinking_tokens || 0;
    const price = PRICE[modelCfg.model];
    if (price) {
      roundUsage.cost =
        (roundUsage.input * price.input +
          roundUsage.output * price.output +
          roundUsage.cacheRead * price.cacheRead +
          roundUsage.cacheWrite * (price.cacheWrite || 0)) /
        1_000_000;
    }
  }

  let reply = resultEvent?.result;
  if (typeof reply !== "string") reply = "";
  reply = reply.trim();

  let error = null;
  if (res.timedOut) {
    error = `claude code round timed out after ${turnTimeoutMs}ms`;
  } else if (resultEvent?.is_error) {
    error = String(resultEvent.result || resultEvent.subtype || "claude code error");
  } else if (!resultEvent && res.code !== 0) {
    error = `claude code exited ${res.code}: ${(res.stderr || res.stdout || "").slice(-400)}`;
  }

  if (firstPrompt !== null) roundUsage.firstPrompt = firstPrompt;

  return { reply, error, sessionId, roundUsage, roundShape, raw: res };
}

// Usage/shape are accumulated per round by round(); totals = sums.
export function usageFromRounds(rounds) {
  const usage = zeroUsage();
  for (const r of rounds) addUsage(usage, r.roundUsage || r);
  return usage;
}

export function shapeFromRounds(rounds) {
  const shape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0 };
  for (const r of rounds) {
    const s = r.roundShape;
    if (!s) continue;
    shape.turns += s.turns;
    shape.toolCalls += s.toolCalls;
    shape.readSingle += s.readSingle;
    shape.readBatch += s.readBatch;
    for (const [k, v] of Object.entries(s.tools || {})) {
      shape.tools[k] = (shape.tools[k] || 0) + v;
    }
  }
  return shape;
}

export const name = "claudecode";
