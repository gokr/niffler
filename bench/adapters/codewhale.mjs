// bench/adapters/codewhale.mjs — drive CodeWhale headless via `codewhale exec`.
//
// One round = one `codewhale --provider <p> --model <m> exec --auto
// --output-format stream-json <prompt>` in the repo dir. Round 2+ add
// `--continue`, which resumes the most recent session for that workspace —
// session ids are redacted in stream output, so the workspace-scoped
// continue flag is the supported continuation path. Provider/model are
// global flags and must precede the subcommand. Tokens are summed from the
// stream's `turn_usage` events (provider-reported; includes reasoning and
// cache hit/miss/write). Exit code 75 is CodeWhale's EX_TEMPFAIL: a
// retryable infrastructure failure (network/timeout), not a task failure.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { run, parseJsonLines, zeroUsage, addUsage } from "../lib/util.mjs";

// One CODEWHALE_HOME per bench process: isolates the bench from the
// developer's real ~/.codewhale and hosts the custom-provider tables
// (llmgateway is not a native provider; deepseek is). Sessions are
// workspace-scoped, so sharing the home across combos is safe. The config
// is the UNION of every combo's codewhale.providers seen so far: the first
// combo to boot must not freeze an empty config for the others (that bug
// cost a whole glm codewhale column — deepseek booted first, wrote an
// empty config.toml, and every llmgateway cell then failed provider
// resolution in 1s × 6 rounds).
let homePromise = null;
const providerTables = new Map();
// reasoning_effort written at the top of the bench's own config.toml (run
// profile; null = leave CodeWhale's default "auto"). One profile per run, so
// a plain rewrite on change is enough.
let writtenEffort = null;
function writeConfig(home) {
  const lines = [];
  if (writtenEffort) {
    lines.push(`reasoning_effort = ${JSON.stringify(writtenEffort)}`, "");
  }
  for (const [id, table] of providerTables) {
    lines.push(`[providers.${id}]`);
    for (const [k, v] of Object.entries(table)) {
      lines.push(`${k} = ${JSON.stringify(v)}`);
    }
    lines.push("");
  }
  fs.writeFileSync(path.join(home, "config.toml"), lines.join("\n"));
}
function cwHome(modelCfg, effort) {
  if (effort && effort !== writtenEffort) {
    writtenEffort = effort;
    if (homePromise) homePromise.then((home) => writeConfig(home));
  }
  if (!homePromise) {
    homePromise = new Promise((resolve) => {
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), "niffler-bench-cw-"));
      writeConfig(dir);
      resolve(dir);
    });
  }
  let changed = false;
  for (const [id, table] of Object.entries(modelCfg.providers || {})) {
    if (JSON.stringify(providerTables.get(id)) !== JSON.stringify(table)) {
      providerTables.set(id, table);
      changed = true;
    }
  }
  if (changed) {
    homePromise.then((home) => writeConfig(home));
  }
  return homePromise;
}

// Repos this process has already run a round in: round 2+ continues the
// workspace's most recent session. Cells own their repo workdir, so the
// scope is exactly one cell's feedback loop.
const continuedRepos = new Set();

export async function round(opts) {
  const { repo, prompt, modelCfg, keys = {}, turnTimeoutMs, thinking } = opts;
  const home = await cwHome(modelCfg, thinking);

  const args = ["--provider", modelCfg.provider, "--model", modelCfg.model];
  if (continuedRepos.has(repo)) args.push("--continue");
  args.push(
    "exec",
    "--auto",
    "--output-format",
    "stream-json",
    prompt,
  );

  const env = { CODEWHALE_HOME: home };
  if (modelCfg.apiKeyEnv) env[modelCfg.apiKeyEnv] = keys[modelCfg.apiKeyEnv] || "";

  const res = await run("codewhale", args, { cwd: repo, timeoutMs: turnTimeoutMs, env });
  continuedRepos.add(repo);

  // CodeWhale drops coordination state into <workspace>/.codewhale/ even when
  // no sub-agent ran (the startup lock is unconditional). Sessions live in
  // CODEWHALE_HOME, so removing the workspace state dir between rounds keeps
  // the cell's diff clean and clears stale locks after a killed round.
  try {
    fs.rmSync(path.join(repo, ".codewhale"), { recursive: true, force: true });
  } catch {}

  const events = parseJsonLines(res.stdout);
  let reply = "";
  let streamError = null;
  let meta = null;
  const roundUsage = zeroUsage();
  for (const e of events) {
    if (e.type === "content" && typeof e.content === "string") reply += e.content;
    if (e.type === "turn_usage") {
      addUsage(roundUsage, {
        input: e.input_tokens || 0,
        output: e.output_tokens || 0,
        reasoning: e.reasoning_tokens || 0,
        cacheRead: e.prompt_cache_hit_tokens || 0,
        cacheWrite: e.prompt_cache_write_tokens || 0,
      });
    }
    if (e.type === "error") streamError = e.error || streamError;
    if (e.type === "metadata" && e.meta) meta = e.meta;
  }
  reply = reply.trim();

  let error = null;
  if (res.timedOut) {
    error = `codewhale round timed out after ${turnTimeoutMs}ms`;
  } else if (res.code === 75) {
    // EX_TEMPFAIL — retryable infra; wording matches the runner's
    // isTransportError patterns so the feedback loop retries.
    error =
      `codewhale transport failure (network, exit 75): ` +
      `${streamError || meta?.error_category || "provider connection dropped"}`;
  } else if (streamError) {
    error = streamError;
  } else if (res.code !== 0) {
    error = `codewhale exited ${res.code}: ${(res.stderr || res.stdout || "").slice(-400)}`;
  }

  return { reply, error, sessionId: meta?.session_id || null, roundUsage, raw: res };
}

// Usage is accumulated per round by round(); total = sum of the given
// per-round usage objects (or round records carrying .roundUsage).
export function usageFromRounds(rounds) {
  const usage = zeroUsage();
  for (const r of rounds) addUsage(usage, r.roundUsage || r);
  return usage;
}

export const name = "codewhale";
