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
  // variant). Only required when config.json's expertJudge is used.
  keys.SYNTHETIC_API_KEY = env.SYNTHETIC_API_KEY || "";
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
  // LLMGATEWAY (glm-5.3-flash) is optional: only required when a selected
  // lane actually uses it (deepseek-only runs must not fail without it).
  if (!keys.DEEPSEEK_API_KEY) missing.push("DEEPSEEK_API_KEY");
  if (want.has("glm-5.3-flash") && !keys.LLMGATEWAY_API_KEY)
    missing.push("LLMGATEWAY_API_KEY");
  return { keys, missing };
}
