// bench/lib/keys.mjs — resolve API keys from local stores at run time.
// Keys are never written to disk by the bench, never logged, and never
// land in results. Order: process env > niffler .env > opencode auth.json.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadDotEnv } from "./util.mjs";

// want: set of model ids whose keys must resolve (llmgateway stays optional
// otherwise); deepseek falls back to NIF_OPENAI_* in niffler's .env.
export function resolveKeys(benchRoot, want = new Set(["deepseek-v4-flash", "glm-5.3-flash"])) {
  const env = process.env;
  const dot = loadDotEnv(path.join(benchRoot, ".env"));
  const keys = {};

  keys.DEEPSEEK_API_KEY =
    env.DEEPSEEK_API_KEY ||
    env.NIF_OPENAI_API_KEY ||
    dot.NIF_OPENAI_API_KEY ||
    "";

  if (!keys.LLMGATEWAY_API_KEY) {
    try {
      const auth = JSON.parse(
        fs.readFileSync(
          path.join(os.homedir(), ".local/share/opencode/auth.json"),
          "utf8",
        ),
      );
      keys.LLMGATEWAY_API_KEY = auth?.llmgateway?.key || "";
    } catch {}
  }

  // Optional: Synthetic (expert judge provider for the niffler-expert
  // variant, and the syn-* worker models). env > niffler .env > opencode
  // auth.json.
  keys.SYNTHETIC_API_KEY = env.SYNTHETIC_API_KEY || dot.SYNTHETIC_API_KEY || "";
  if (!keys.SYNTHETIC_API_KEY) {
    try {
      const auth = JSON.parse(
        fs.readFileSync(
          path.join(os.homedir(), ".local/share/opencode/auth.json"),
          "utf8",
        ),
      );
      keys.SYNTHETIC_API_KEY = auth?.synthetic?.key || "";
    } catch {}
  }

  const missing = [];
  // Generic requirement check driven by config.json: every harness entry of
  // a wanted model names its apiKeyEnv, and each must resolve (keys above
  // already apply the model-specific fallbacks, e.g. deepseek → NIF_OPENAI_*).
  // So a syn-large run demands SYNTHETIC_API_KEY while a deepseek-only run
  // still passes without llmgateway/synthetic keys.
  let cfgModels = {};
  try {
    cfgModels =
      JSON.parse(fs.readFileSync(path.join(benchRoot, "bench", "config.json"), "utf8"))
        .models || {};
  } catch {}
  const missingSet = new Set();
  for (const model of want) {
    for (const harness of Object.values(cfgModels[model] || {})) {
      if (harness && typeof harness === "object" && harness.apiKeyEnv && !keys[harness.apiKeyEnv])
        missingSet.add(harness.apiKeyEnv);
    }
  }
  missing.push(...missingSet);
  return { keys, missing };
}
