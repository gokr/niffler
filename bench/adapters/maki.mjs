// bench/adapters/maki.mjs — drive Maki (tontinton/maki, Rust) over its
// Claude-Code-compatible `--print --output-format stream-json` mode.
//
// One CLI invocation per round in the task repo. Rounds after the first
// continue the same session (`--resume <session_id>`), so feedback rounds are
// genuine continuations rather than fresh conversations. Usage and tool
// calls come from the stream itself: `system/init` (tool inventory),
// `assistant` messages (usage per call) and the terminal `result` (num_turns,
// total_cost_usd, stop_reason). The stream is Claude-Code-shaped, so the
// parsing mirrors bench/adapters/claudecode.mjs.
import fs from "node:fs";
import path from "node:path";
import { run, zeroUsage, addUsage } from "../lib/util.mjs";

function makiExecutable(explicit) {
  const value = explicit || process.env.MAKI_BIN;
  if (value) return value;
  const built = path.resolve(process.cwd(), "../harnesses/maki/target/release/maki");
  return fs.existsSync(built) ? built : "maki";
}

function toolNameOf(block) {
  return block?.name || block?.tool_name || "?";
}

function usageOf(message) {
  const u = message?.usage;
  if (!u) return zeroUsage();
  return {
    input: u.input_tokens || 0,
    output: u.output_tokens || 0,
    reasoning: u.reasoning_tokens || 0,
    cacheRead: u.cache_read_input_tokens || 0,
    cacheWrite: u.cache_creation_input_tokens || 0,
    cost: 0,
  };
}

// firstPromptOf is the first API call's TOTAL prompt (system + tools + task):
// DeepSeek splits the prompt across the three usage fields (uncached input +
// implicit-cache read + cache creation), so all three sum to the honest
// firstPromptTokens — input_tokens alone under-reports by the cached prefix
// (a warm 512-token prefix was observed even on a first request).
function firstPromptOf(usage) {
  if (!usage) return null;
  const input = usage.input_tokens || 0;
  const read = usage.cache_read_input_tokens || 0;
  const write = usage.cache_creation_input_tokens || 0;
  const total = input + read + write;
  return total > 0 ? total : null;
}

// summarizeEvents folds one round's stream-json events into the reply,
// error, session id, aggregated usage (with firstPrompt from the first
// assistant frame) and the tool-call shape. Exported for tests — the same
// shape the dsh adapter's summarizeEvents has.
export function summarizeEvents(events, opts = {}) {
  const usage = zeroUsage();
  const shape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0, leakUrls: [] };
  let reply = "";
  let error = opts.preError || null;
  let firstPrompt = null;
  let nextSessionId = opts.sessionId || null;
  const seen = new Set();
  for (const e of events) {
    if (e.type === "system" && e.subtype === "init") nextSessionId = e.session_id || nextSessionId;
    if (e.type === "assistant") {
      shape.turns += 1;
      if (firstPrompt === null) firstPrompt = firstPromptOf(e.message?.usage);
      addUsage(usage, usageOf(e.message));
      for (const b of e.message?.content || []) {
        if (b?.type === "text" && b.text) reply = b.text;
        if (b?.type === "tool_use" || b?.type === "tool-call") {
          const name = toolNameOf(b);
          const id = b.id || `${name}:${shape.toolCalls}`;
          if (!seen.has(id)) {
            seen.add(id);
            shape.tools[name] = (shape.tools[name] || 0) + 1;
            shape.toolCalls += 1;
          }
        }
      }
    }
    if (e.type === "result") {
      if (e.is_error && !error) error = String(e.result || "maki result error");
      if (!reply && e.result) reply = String(e.result);
    }
  }
  if (firstPrompt !== null) usage.firstPrompt = firstPrompt;
  shape.leaked = shape.leakUrls.length > 0;
  return { reply: String(reply).trim(), error, sessionId: nextSessionId, roundUsage: usage, roundShape: shape };
}

function parseStream(text) {
  const events = [];
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || !trimmed.startsWith("{")) continue;
    try { events.push(JSON.parse(trimmed)); } catch { /* non-JSON noise */ }
  }
  return events;
}

export class MakiHarness {
  constructor(opts) {
    this.bin = opts.bin || makiExecutable();
    this.model = opts.model;
    this.thinking = opts.thinking || "";
    this.modelSpec = opts.modelSpec || `deepseek/${this.model}`;
  }

  async round({ repo, prompt, keys, model, modelSpec, sessionId, turnTimeoutMs }) {
    // The bench model key is the provider model id (deepseek/<id>); pass the
    // full `provider/model-id` spec to override it.
    const spec = modelSpec || `deepseek/${model}`;
    const resume = sessionId ? ["--resume", sessionId] : [];
    // `low` has no Maki spelling; the provider default applies. --trust loads
    // project config without prompting (CI/state-dir semantics), --yolo keeps
    // permission prompts out of the timed region.
    const res = await run(this.bin, [
      "--print", "--output-format", "stream-json", "--yolo", "--trust",
      "--model", spec, ...resume, prompt,
    ], { cwd: repo, env: { ...process.env, DEEPSEEK_API_KEY: keys?.DEEPSEEK_API_KEY || process.env.DEEPSEEK_API_KEY || "" }, timeoutMs: turnTimeoutMs });
    const events = parseStream(res.stdout || "");
    const folded = summarizeEvents(events, {
      preError: res.timedOut ? `maki round timed out after ${turnTimeoutMs}ms` : null,
      sessionId,
    });
    return {
      ...folded,
      raw: { stdout: res.stdout, stderr: res.stderr },
    };
  }
}

// run.mjs dispatches one-shot adapters through module-level `round`
// (the pi/cw/cc convention); Maki is stateless apart from the session id the
// caller threads through, so one shared harness is enough.
const sharedHarness = new MakiHarness({});
export async function round(opts) {
  return sharedHarness.round(opts);
}

export function usageFromRounds(rounds) {
  const usage = zeroUsage();
  for (const round of rounds) addUsage(usage, round.roundUsage || round);
  return usage;
}

export function shapeFromRounds(rounds) {
  const shape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0, leakUrls: [] };
  for (const round of rounds) {
    const value = round.roundShape;
    if (!value) continue;
    shape.turns += value.turns || 0;
    shape.toolCalls += value.toolCalls || 0;
    shape.readSingle += value.readSingle || 0;
    shape.readBatch += value.readBatch || 0;
    for (const url of value.leakUrls || []) if (!shape.leakUrls.includes(url)) shape.leakUrls.push(url);
    for (const [name, count] of Object.entries(value.tools || {})) {
      shape.tools[name] = (shape.tools[name] || 0) + count;
    }
  }
  shape.leaked = shape.leakUrls.length > 0;
  return shape;
}

export const name = "maki";
