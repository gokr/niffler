// bench/adapters/pi.mjs — drive pi headless in JSON mode.
//
// One round = one `pi --mode json -p <prompt>` invocation. Round 2+ continue
// the same session file via `--session`. Tokens come from the session JSONL
// (authoritative; stdout events are only used for error detection).
import fs from "node:fs";
import path from "node:path";
import { run, parseJsonLines } from "../lib/util.mjs";

// Isolated pi config dir (PI_CODING_AGENT_DIR): own models.json so the bench
// never touches ~/.pi/agent. Keys are injected via env-var interpolation.
export function setupPiConfig(runRoot, defaults) {
  const dir = path.join(runRoot, "pi-config");
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(
    path.join(dir, "models.json"),
    JSON.stringify(
      {
        providers: {
          deepseek: {
            baseUrl: "https://api.deepseek.com/v1",
            api: "openai-completions",
            apiKey: "$DEEPSEEK_API_KEY",
            models: [
              {
                id: "deepseek-v4-flash",
                name: "DeepSeek V4 Flash",
                reasoning: true,
                input: ["text"],
                contextWindow: 1000000,
                maxTokens: 384000,
                cost: { input: 0.283, output: 1.14, cacheRead: 0.028, cacheWrite: 0 },
              },
            ],
          },
          llmgateway: {
            baseUrl: "https://api.llmgateway.io/v1",
            api: "openai-completions",
            apiKey: "$LLMGATEWAY_API_KEY",
            models: [
              {
                id: "glm-5.3-flash",
                name: "GLM-5.3-Flash",
                reasoning: true,
                input: ["text"],
                contextWindow: 200000,
                maxTokens: 131072,
                cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
              },
            ],
          },
        },
      },
      null,
      2,
    ) + "\n",
  );
  return dir;
}

function newestSessionFile(sessionsDir) {
  const files = fs
    .readdirSync(sessionsDir)
    .filter((f) => f.endsWith(".jsonl"))
    .map((f) => path.join(sessionsDir, f));
  files.sort((a, b) => fs.statSync(a).mtimeMs - fs.statSync(b).mtimeMs);
  return files.at(-1) || null;
}

// Runs one round. Returns {reply, error, sessionFile, stderrTail}.
export async function round(opts) {
  const { repo, prompt, modelCfg, keys, sessionsDir, sessionFile, turnTimeoutMs, cfgDir } =
    opts;
  const args = [
    "--mode",
    "json",
    "--no-extensions",
    "--no-skills",
    "--no-prompt-templates",
    "--no-context-files",
    "--provider",
    modelCfg.provider,
    "--model",
    modelCfg.model,
    "--session-dir",
    sessionsDir,
  ];
  if (sessionFile) args.push("--session", sessionFile);
  if (modelCfg.thinking) args.push("--thinking", modelCfg.thinking);
  args.push("-p", prompt);

  const env = {
    PI_CODING_AGENT_DIR: cfgDir,
    DEEPSEEK_API_KEY: keys.DEEPSEEK_API_KEY || "missing",
    LLMGATEWAY_API_KEY: keys.LLMGATEWAY_API_KEY || "missing",
  };
  const res = await run("pi", args, {
    cwd: repo,
    env,
    timeoutMs: turnTimeoutMs,
  });
  const file = newestSessionFile(sessionsDir);

  // Detect errors from the final assistant message in stdout events.
  let reply = "";
  let error = null;
  const events = parseJsonLines(res.stdout);
  for (const e of events) {
    if (e.type === "message_end" && e.message?.role === "assistant") {
      const m = e.message;
      reply = (m.content || [])
        .filter((c) => c.type === "text")
        .map((c) => c.text)
        .join("")
        .trim();
      if (m.stopReason === "error") {
        error = m.errorMessage || "pi assistant message ended with stopReason=error";
      }
    }
  }
  if (res.timedOut) error = error || `pi round timed out after ${turnTimeoutMs}ms`;
  if (res.code !== 0 && !error) {
    error = `pi exited ${res.code}: ${(res.stderr || res.stdout || "").slice(-400)}`;
  }
  return { reply, error, sessionFile: file, raw: res };
}

// Sum usage across all assistant messages of the session file.
export function usageFromSession(sessionFile) {
  const usage = {
    input: 0,
    output: 0,
    reasoning: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cost: 0,
  };
  if (!sessionFile || !fs.existsSync(sessionFile)) return usage;
  for (const line of fs.readFileSync(sessionFile, "utf8").split("\n")) {
    if (!line.trim()) continue;
    let e;
    try {
      e = JSON.parse(line);
    } catch {
      continue;
    }
    const m = e?.message;
    if (e.type === "message" && m?.role === "assistant" && m.usage) {
      const u = m.usage;
      usage.input += u.input || 0;
      usage.output += u.output || 0;
      usage.reasoning += u.reasoning || 0;
      usage.cacheRead += u.cacheRead || 0;
      usage.cacheWrite += u.cacheWrite || 0;
      usage.cost += u.cost?.total || 0;
    }
  }
  return usage;
}

export const name = "pi";
