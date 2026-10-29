// bench/adapters/droid.mjs — drive Factory's Droid CLI headless (`droid exec`).
//
// Verified against Droid 0.251.0 with Synthetic DeepSeek V4.1 Flash
// (BYOK, no Factory account needed as long as the model arrives through
// `--settings` — a model merged from ~/.factory/settings.json is not picked
// up before the folder is trusted and silently falls back to gpt-6-sol,
// which *does* demand a Factory login). Stream frames: `system/init`
// (session_id, tools, model), `message` (role, text), `reasoning`,
// `tool_call` (toolName, parameters), `tool_result`, and one final
// `completion` (finalText, numTurns, usage) — usage counters are
// Anthropic-shaped (input_tokens, output_tokens, cache_read_input_tokens,
// cache_creation_input_tokens, thinking_tokens) with input EXCLUSIVE of the
// cache reads (verified: a 2-call round reports input 10524 + cache_read
// 10240 against a ~10.2k system+tools prompt).
//
// One round = one `droid exec -o stream-json` invocation in the repo dir.
// Round 1 lets Droid mint a session id (reported in the `system/init` frame);
// round 2+ continue it with `-s <id>`. Permissions are skipped
// (`--skip-permissions-unsafe`, the Droid spelling of Claude Code's
// --dangerously-skip-permissions) — a bench cell has no human to approve.
//
// Model wiring: Droid's BYOK custom models live in settings.json
// (`customModels: [{model, provider, baseUrl, apiKey, maxContextLimit,
// maxOutputTokens}]`) and can be merged for one process only with
// `--settings <path>`. The bench therefore writes a per-combo settings file
// and never touches the developer's ~/.factory/settings.json — except that
// auth credentials do live in ~/.factory (login is per user, not per run).
// apiKey is `$SYNTHETIC_API_KEY`, interpolated by Droid from the env the
// adapter passes, so no key is written to disk.
//
// Usage is provider-reported when Droid emits it; if a run finds no usage
// frames the round records zero counters and warns once (see `usageSeen`).
import fs from "node:fs";
import path from "node:path";
import { run, parseJsonLines, zeroUsage, addUsage } from "../lib/util.mjs";

// $/MTok for Synthetic's DeepSeek V4.1 Flash (same table as the
// claudecode/niffler adapters): prompt 0.8, completion 1.2, cache read 0.16,
// cache write billed at the prompt rate (see claudecode.mjs for why).
const PRICE = {
  "hf:deepseek-ai/DeepSeek-V4.1-Flash":
    { input: 0.8, output: 1.2, cacheRead: 0.16, cacheWrite: 0.8 },
};

// Per-combo runtime settings file: custom model definition only. Kept
// separate from ~/.factory/settings.json on purpose.
export function setupDroidConfig(runRoot, modelCfg) {
  const dir = path.join(runRoot, "droid-config");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "settings.json");
  const settings = {};
  if (modelCfg.provider) {
    settings.customModels = [
      {
        model: modelCfg.model,
        provider: modelCfg.provider,
        baseUrl: modelCfg.baseUrl,
        // Droid interpolates ${VAR} from its environment at load time; the
        // key therefore never lands on disk.
        apiKey: `\${${modelCfg.apiKeyEnv || "SYNTHETIC_API_KEY"}}`,
        ...(modelCfg.maxContextLimit ? { maxContextLimit: modelCfg.maxContextLimit } : {}),
        ...(modelCfg.maxOutputTokens ? { maxOutputTokens: modelCfg.maxOutputTokens } : {}),
      },
    ];
  }
  fs.writeFileSync(file, JSON.stringify(settings, null, 2));
  return file;
}

// Walk one stream frame for usage counters. Droid has shipped both
// Anthropic-style (input_tokens/output_tokens/cache_*) and OpenAI-style
// (prompt_tokens/completion_tokens/prompt_tokens_details.cached_tokens)
// numbers depending on provider; accept either and keep the counters
// disjoint the way the report expects (uncached / cacheRead / cacheWrite).
function usageOf(u) {
  if (!u || typeof u !== "object") return null;
  const num = (v) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
  const openai = u.prompt_tokens !== undefined && u.input_tokens === undefined;
  const prompt = openai ? num(u.prompt_tokens) : num(u.input_tokens);
  const output = openai ? num(u.completion_tokens) : num(u.output_tokens);
  const cacheRead = openai
    ? num(u.prompt_tokens_details?.cached_tokens)
    : num(u.cache_read_input_tokens);
  const cacheWrite = openai
    ? num(u.prompt_tokens_details?.cache_creation_tokens)
    : num(u.cache_creation_input_tokens);
  if (!prompt && !output && !cacheRead) return null;
  // Anthropic dialect (Droid's own counters): input excludes cache reads, so
  // uncached = input - cache writes. OpenAI dialect: both are subsets of
  // prompt. Disjoint counters either way, matching the report's columns.
  const uncached = openai
    ? Math.max(0, prompt - cacheRead - cacheWrite)
    : Math.max(0, prompt - cacheWrite);
  return {
    input: uncached,
    output,
    cacheRead,
    cacheWrite,
    reasoning: openai
      ? num(u.completion_tokens_details?.reasoning_tokens)
      : num(u.thinking_tokens),
    firstPrompt: uncached + cacheRead + cacheWrite,
  };
}

// Droid's tool ids → the bench's normalized tool names (the ones report.mjs
// aggregates into grepCalls/bashCalls/editCalls/writeCalls).
const TOOL_NAME = {
  read: "read",
  ls: "ls",
  glob: "glob",
  grep: "grep",
  execute: "bash",
  edit: "edit",
  create: "write",
  applypatch: "applypatch",
};

export async function round(opts) {
  const { repo, prompt, modelCfg, turnTimeoutMs, settingsFile, workdir } = opts;
  const thinking = opts.thinking || modelCfg.thinking || "";
  const promptFile = path.join(workdir, `droid-prompt-${Date.now()}.txt`);
  fs.writeFileSync(promptFile, prompt);

  const args = [
    "exec",
    "-o",
    "stream-json",
    "-f",
    promptFile,
    "-m",
    modelCfg.droidModelId || modelCfg.model,
    "--skip-permissions-unsafe",
    "--cwd",
    repo,
  ];
  if (settingsFile) args.push("--settings", settingsFile);
  if (thinking) args.push("-r", thinking);
  if (opts.sessionId) args.push("-s", opts.sessionId);

  const res = await run(modelCfg.bin || "droid", args, {
    cwd: repo,
    timeoutMs: turnTimeoutMs,
    env: { DROID_DISABLE_SOUNDS: "1" },
  });

  const events = parseJsonLines(res.stdout);
  let sessionId = opts.sessionId || null;
  let cliError = null;
  let reply = "";
  const roundShape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0 };
  let frameUsage = zeroUsage();
  let firstPrompt = null;
  let usageSeen = false;

  for (const e of events) {
    if (e?.type === "system" && e.subtype === "init") {
      sessionId = e.session_id || sessionId;
      continue;
    }
    if (e?.type === "error") {
      cliError = String(e.message || e.error || "droid error");
      continue;
    }
    // Any frame carrying a usage object counts; assistant/tool frames are
    // also where the tool mix is inferable.
    const u = usageOf(e?.usage || e?.message?.usage || e?.result?.usage);
    if (u) {
      usageSeen = true;
      if (firstPrompt === null) firstPrompt = u.firstPrompt;
      frameUsage.input += u.input;
      frameUsage.output += u.output;
      frameUsage.cacheRead += u.cacheRead;
      frameUsage.cacheWrite += u.cacheWrite;
      frameUsage.reasoning += u.reasoning || 0;
    }
    // `message` frames carry both roles; only the assistant's are turns.
    if (e?.type === "message" && e.role === "assistant") roundShape.turns += 1;
    // tool_call frames: {toolName, parameters}. Read is single-file per call
    // in Droid (path + offset/limit), so it keeps the readSingle column.
    if (e?.type === "tool_call") {
      const raw = String(e.toolName || "?").toLowerCase();
      const n = TOOL_NAME[raw] || raw;
      roundShape.tools[n] = (roundShape.tools[n] || 0) + 1;
      roundShape.toolCalls += 1;
      if (n === "read") roundShape.readSingle += 1;
    }
    if (typeof e?.result === "string") reply = e.result;
    else if (typeof e?.text === "string") reply = e.text;
  }
  if (!reply) {
    // Fall back to the last assistant text block seen in the stream.
    for (const e of events) {
      const blocks = e?.message?.content || e?.content;
      if (!Array.isArray(blocks)) continue;
      for (const b of blocks) if (b?.type === "text" && b.text) reply = b.text;
    }
  }

  const roundUsage = frameUsage;
  const price = PRICE[modelCfg.model];
  if (price && usageSeen) {
    roundUsage.cost =
      (roundUsage.input * price.input +
        roundUsage.output * price.output +
        roundUsage.cacheRead * price.cacheRead +
        roundUsage.cacheWrite * (price.cacheWrite || 0)) /
      1_000_000;
  }
  if (firstPrompt !== null) roundUsage.firstPrompt = firstPrompt;

  let error = null;
  if (res.timedOut) {
    error = `droid round timed out after ${turnTimeoutMs}ms`;
  } else if (cliError) {
    // Auth refusals are fatal for the run, not retryable: tag them so
    // run.mjs stops the cell instead of burning feedback rounds.
    error = /auth|login|credential|FACTORY_API_KEY/i.test(cliError)
      ? `[E_AUTH] droid: ${cliError}`
      : cliError;
  } else if (!events.length && res.code !== 0) {
    error = `droid exited ${res.code}: ${(res.stderr || res.stdout || "").slice(-400)}`;
  }
  if (!usageSeen && !error) {
    if (!round._warnedUsage) {
      console.warn(
        "[droid] no usage frames in the stream — token columns will read 0; " +
          "re-check the frame schema against a logged-in run",
      );
      round._warnedUsage = true;
    }
  }

  return { reply: String(reply || "").trim(), error, sessionId, roundUsage, roundShape, raw: res };
}

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

export const name = "droid";
