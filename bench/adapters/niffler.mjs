// bench/adapters/niffler.mjs — drive a Niffler harness over its NATS bus.
//
// Lifecycle per (harness,model) combo: start() boots an isolated stack —
//   own nats-server on a free port + own NIF_ROOT (symlink farm over the
//   bench worktree, real var/ dir) + NIF_OPENAI_* env for the gateway —
// then each round is a blocking `cli call session` (the session tool runs
// the whole turn and returns the final reply). Usage is summed from the
// persisted transcript (assistant messages carry `usage`).
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { run, zeroUsage } from "../lib/util.mjs";

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
    srv.on("error", reject);
  });
}

export class NifflerHarness {
  constructor(opts) {
    // benchRoot: the bench git worktree (has manifest.yaml, core/, ...).
    // runRoot: per-combo scratch dir (gets niffler-root/ + logs).
    this.benchRoot = opts.benchRoot;
    this.runRoot = opts.runRoot;
    this.baseUrl = opts.baseUrl;
    this.apiKey = opts.apiKey;
    this.model = opts.model;
    this.binDir = opts.binDir || path.join(this.benchRoot, "var", "bin");
    this.root = path.join(this.runRoot, "niffler-root");
    this.natsProc = null;
    this.harnessProc = null;
    this.natsPort = 0;
    this.stopped = false;
    this.expertEnabled = opts.expertEnabled || false;
    // Optional judgment provider for niffler-expert runs:
    // {provider, model, baseUrl, apiKey}. Routed via NIF_LLM_PROVIDERS so
    // the shared llm component can reach a second provider (e.g. Synthetic)
    // without touching the provider store; the worker keeps its own model.
    this.expertJudge = opts.expertJudge || null;
    this.expertBaselines = new Map();
  }

  cliEnv() {
    return { NIF_NATS_URL: `nats://127.0.0.1:${this.natsPort}`, NIF_ROOT: this.root };
  }

  async start() {
    fs.mkdirSync(this.root, { recursive: true });
    // Symlink farm: everything from the worktree except git/, runtime state,
    // bench outputs and secrets; then a real var/ and a real .env.
    const skip = new Set([".git", "var", "bench", "results", ".env", ".niffler-build.lock"]);
    for (const entry of fs.readdirSync(this.benchRoot)) {
      if (skip.has(entry)) continue;
      const target = path.join(this.benchRoot, entry);
      const link = path.join(this.root, entry);
      try {
        fs.symlinkSync(target, link);
      } catch (e) {
        if (e.code !== "EEXIST") throw e;
      }
    }
    fs.mkdirSync(path.join(this.root, "var"), { recursive: true });
    // Component binaries live in the bench worktree's var/bin.
    try {
      fs.symlinkSync(path.join(this.binDir), path.join(this.root, "var", "bin"));
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
    }
    fs.copyFileSync(path.join(this.benchRoot, ".env"), path.join(this.root, ".env"));

    // 1. Private NATS bus on a free port (never the developer's 4222 bus).
    this.natsPort = await freePort();
    this.natsProc = spawn(
      "nats-server",
      ["-a", "127.0.0.1", "-p", String(this.natsPort), "-m", "-1"],
      {
        cwd: this.runRoot,
        stdio: ["ignore", "ignore", "pipe"],
      },
    );
    this.natsProc.stderr.on("data", () => {});
    await new Promise((r) => setTimeout(r, 500));

    // 2. Harness in service mode, pinned to this bus + gateway env.
    //    Shell env wins over .env, so NIF_OPENAI_* steers the llm component.
    const env = {
      ...process.env,
      NIF_ROOT: this.root,
      NIF_NATS_URL: `nats://127.0.0.1:${this.natsPort}`,
      NIF_OPENAI_BASE_URL: this.baseUrl,
      NIF_OPENAI_API_KEY: this.apiKey,
      NIF_OPENAI_MODEL: this.model,
      // Headless bench: no human to approve gated tools (edit/write).
      // This is the documented automation bypass; it only affects this
      // private bench harness (isolated NIF_ROOT + bus), never the dev's.
      NIF_AUTO_APPROVE: "1",
    };
    if (this.expertEnabled && this.expertJudge) {
      env.NIF_LLM_PROVIDERS = JSON.stringify({
        [this.expertJudge.provider]: {
          baseUrl: this.expertJudge.baseUrl,
          apiKey: this.expertJudge.apiKey,
          model: this.expertJudge.model,
          catalog: this.expertJudge.provider,
        },
      });
    }
    this.harnessProc = spawn(path.join(this.binDir, "niffler"), {
      cwd: this.root,
      env,
      detached: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.harnessLog = fs.openSync(path.join(this.runRoot, "harness.log"), "a");
    this.harnessProc.stdout.on("data", (d) => fs.writeSync(this.harnessLog, d));
    this.harnessProc.stderr.on("data", (d) => fs.writeSync(this.harnessLog, d));

    // 3. Wait for the bus contract: store first, then llm. Expert-assisted
    // runs also wait for the advisory peer so follow happens before turn start.
    const cli = path.join(this.binDir, "cli");
    const required = ["store", "llm", ...(this.expertEnabled ? ["expert"] : [])];
    for (const comp of required) {
      const res = await run(cli, ["wait", comp, "120"], {
        cwd: this.root,
        env: this.cliEnv(),
        timeoutMs: 140_000,
      });
      if (res.code !== 0) {
        await this.stop();
        throw new Error(`bench niffler: component '${comp}' never registered`);
      }
    }
    // Session runner binary must exist (make build).
    if (!fs.existsSync(path.join(this.binDir, "session"))) {
      await this.stop();
      throw new Error("bench niffler: var/bin/session missing — run `make build`");
    }
  }

  // One round = one blocking session tool call. Returns {reply, error}.
  async round(opts) {
    const { sessionId, prompt, turnTimeoutMs } = opts;
    const cli = path.join(this.binDir, "cli");
    const res = await run(
      cli,
      [
        `--timeout:${Math.ceil(turnTimeoutMs / 1000) + 30}`,
        "call",
        "session",
        JSON.stringify({ sessionId, content: prompt }),
      ],
      { cwd: this.root, env: this.cliEnv(), timeoutMs: turnTimeoutMs + 60_000 },
    );
    if (res.timedOut) {
      return { reply: "", error: `niffler round timed out after ${turnTimeoutMs}ms` };
    }
    let parsed = null;
    try {
      parsed = JSON.parse(res.stdout.trim().split("\n").at(-1));
    } catch {}
    if (res.code !== 0 || !parsed) {
      return {
        reply: "",
        error: `niffler session call failed (exit ${res.code}): ${(
          res.stderr || res.stdout
        ).slice(-400)}`,
      };
    }
    let reply = parsed.reply ?? "";
    if (typeof reply === "object" && reply !== null) reply = reply.content ?? JSON.stringify(reply);
    const error = parsed.error ? String(parsed.error) : null;
    return { reply: String(reply), error };
  }

  async callTool(tool, args, timeoutMs = 30_000) {
    const cli = path.join(this.binDir, "cli");
    const res = await run(
      cli,
      [
        `--timeout:${Math.ceil(timeoutMs / 1000)}`,
        "call",
        tool,
        JSON.stringify(args),
      ],
      { cwd: this.root, env: this.cliEnv(), timeoutMs: timeoutMs + 30_000 },
    );
    let parsed = null;
    try {
      parsed = JSON.parse(res.stdout.trim().split("\n").at(-1));
    } catch {}
    if (res.code !== 0 || !parsed || parsed.error) {
      throw new Error(
        `niffler ${tool} failed (exit ${res.code}): ${(
          parsed?.error || res.stderr || res.stdout
        ).toString().slice(-400)}`,
      );
    }
    return parsed;
  }

  async beginTask(sessionId) {
    if (!this.expertEnabled) return;
    const followArgs = { session_id: sessionId };
    // A cheaper/faster judgment model than the worker's (expert_follow's
    // optional overrides); absent = the harness's own model/provider.
    if (this.expertJudge?.model) followArgs.model = this.expertJudge.model;
    if (this.expertJudge?.provider) {
      followArgs.provider = this.expertJudge.provider;
    }
    const follow = await this.callTool("expert_follow", followArgs, 30_000);
    if (!follow.ok || follow.target !== sessionId) {
      throw new Error(`expert_follow did not target ${sessionId}: ${JSON.stringify(follow)}`);
    }
    // Counters are component-lifetime totals, so snapshot after follow and
    // subtract at task end. Follow itself performs no judgment.
    const status = await this.callTool("expert_status", {}, 30_000);
    this.expertBaselines.set(sessionId, status);
  }

  async expertMetricsSince(sessionId) {
    if (!this.expertEnabled) return null;
    // A status request queued behind an in-flight judgment can take as long
    // as the expert's chat timeout; waiting also makes token accounting final.
    const status = await this.callTool("expert_status", {}, 150_000);
    const base = this.expertBaselines.get(sessionId) || {};
    const delta = (key) => Math.max(0, (status[key] || 0) - (base[key] || 0));
    const tokenDelta = (key) =>
      Math.max(0, (status.tokens?.[key] || 0) - (base.tokens?.[key] || 0));
    return {
      active: status.target === sessionId && delta("judgments") > 0,
      target: status.target || "",
      knowledgeVersion: status.knowledgeVersion || "",
      judgments: delta("judgments"),
      silences: delta("silences"),
      steers: delta("steers"),
      accepted: delta("accepted"),
      rejected: delta("rejected"),
      staleDrops: delta("staleDrops"),
      errors: delta("errors"),
      tokens: {
        prompt: tokenDelta("prompt"),
        cached: tokenDelta("cached"),
        completion: tokenDelta("completion"),
      },
    };
  }

  // Sum token usage over the conversation transcript in the store.
  async usageFromTranscript(sessionId) {
    const cli = path.join(this.binDir, "cli");
    const res = await run(
      cli,
      [
        `--timeout:60`,
        "call",
        "list",
        JSON.stringify({ kind: "message", idPrefix: `${sessionId}:`, limit: 1000 }),
      ],
      { cwd: this.root, env: this.cliEnv(), timeoutMs: 90_000 },
    );
    const usage = zeroUsage();
    let items = [];
    try {
      items = JSON.parse(res.stdout.trim().split("\n").at(-1))?.items || [];
    } catch {
      return usage;
    }
    for (const it of items) {
      const v = it.value || {};
      if (v.role !== "assistant" || !v.usage) continue;
      usage.input += v.usage.prompt_tokens || 0;
      usage.output += v.usage.completion_tokens || 0;
      usage.cacheRead += v.usage.prompt_cache_hit_tokens || 0;
      usage.cacheWrite += v.usage.prompt_cache_miss_tokens || 0;
      usage.cost += 0; // pricing not configured for bench gateways
    }
    return usage;
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    if (this.harnessProc?.pid) {
      try {
        process.kill(-this.harnessProc.pid, "SIGTERM");
      } catch {}
    }
    if (this.natsProc?.pid) {
      try {
        this.natsProc.kill("SIGTERM");
      } catch {}
    }
    // Give the supervisor a moment to reap children, then hard-stop strays.
    await new Promise((r) => setTimeout(r, 1500));
    if (this.harnessProc?.pid) {
      try {
        process.kill(-this.harnessProc.pid, "SIGKILL");
      } catch {}
    }
  }
}

export const name = "niffler";
