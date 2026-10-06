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
import { run, tail, zeroUsage } from "../lib/util.mjs";

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

export const readinessDirectTools = Object.freeze([
  "bash", "read", "edit", "write", "replace_across", "grep", "discover", "invoke",
]);

// The shipped manifest uses block component entries, not inline YAML objects.
// Parse just name/autostart/required; reject an unrecognized required shape
// rather than silently reducing the readiness gate. No new YAML dependency.
export function requiredManifestComponents(text) {
  const entries = text.split(/^\s*- name:\s*/m).slice(1);
  if (!entries.length) throw new Error("bench niffler: no component entries in manifest");
  const required = [];
  for (const entry of entries) {
    const name = entry.split(/\r?\n/, 1)[0].replace(/\s+#.*$/, "").trim();
    if (!/^[a-z][a-z0-9-]*$/.test(name)) throw new Error("bench niffler: unsupported manifest component name");
    if (/^\s+required:\s*true\s*(?:#.*)?$/m.test(entry)) {
      if (!/^\s+autostart:\s*true\s*(?:#.*)?$/m.test(entry)) {
        throw new Error(`bench niffler: required manifest component ${name} is not autostarted`);
      }
      required.push(name);
    }
  }
  if (!required.length) throw new Error("bench niffler: manifest has no required components");
  return required;
}

export function readinessProblems(components, direct, required, root) {
  const problems = [];
  if (components?.root !== root || direct?.root !== root) problems.push("catalog root mismatch");
  const registered = components?.components;
  const absent = required.filter((name) => !Array.isArray(registered?.[name]));
  if (absent.length) problems.push(`missing components: ${absent.join(", ")}`);
  const tools = Array.isArray(direct?.tools) ? direct.tools : [];
  const missing = readinessDirectTools.filter((name) => !tools.some((tool) =>
    tool.name === name && tool.schema?.type === "object" &&
    !tool.schema?.["x-harness"]?.hidden && !tool.schema?.["x-harness"]?.onDemand));
  if (missing.length) problems.push(`missing direct tools: ${missing.join(", ")}`);
  if (!registered?.systemprompt?.includes("systemprompt")) problems.push("missing systemprompt.systemprompt");
  return problems;
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
    this.thinking = opts.thinking || "";
    this.maxTurnRounds = opts.maxTurnRounds || 1000;
    // LLM per-request ceiling: must exceed the longest legitimate thinking
    // stream, not the 5-min default (bench: a 19m41s high-effort thinking
    // call died at 300s and the retry re-did the whole turn). Sourced from
    // the turn budget + margin by run.mjs.
    this.llmTimeoutMs = opts.llmTimeoutMs || 0;
    // Optional judgment provider for niffler-expert runs:
    // {provider, model, baseUrl, apiKey}. Routed via NIF_LLM_PROVIDERS so
    // the shared llm component can reach a second provider (e.g. Synthetic)
    // without touching the provider store; the worker keeps its own model.
    this.expertJudge = opts.expertJudge || null;
  }

  cliEnv() {
    // Inherit the parent env (keys, NIF_LLM_TIMEOUT_MS, proxies) and pin the
    // private bus/root last so a stray NIF_NATS_URL in the shell can't
    // redirect the bench harness. XDG_CONFIG_HOME is the harness's own
    // edit-state dir (undo + seen digests) so a boot never inherits the
    // developer's store or a previous run's state for a reused session id.
    const env = {
      ...process.env,
      NIF_NATS_URL: `nats://127.0.0.1:${this.natsPort}`,
      NIF_ROOT: this.root,
    };
    if (this.xdgDir) env.XDG_CONFIG_HOME = this.xdgDir;
    return env;
  }

  async start() {
    fs.mkdirSync(this.root, { recursive: true });
    // Edit component state (undo history + per-session seen digests) lives
    // under XDG_CONFIG_HOME; defaulting to ~/.config/niffler-edit would let
    // one run leak into another (resume reuses session ids against
    // re-prepared repos, which makes the first edits of the fresh repo
    // E_STALE). Wipe a private dir per boot.
    this.xdgDir = path.join(this.root, "var", "edit-config");
    fs.rmSync(this.xdgDir, { recursive: true, force: true });
    fs.mkdirSync(this.xdgDir, { recursive: true });
    // Symlink farm: everything from the worktree except git/, runtime state,
    // bench outputs and secrets; then a real var/ and a real .env.
    // AGENTS.md is Niffler's own contributor guide — injecting it into bench
    // sessions would be prompt-context no other harness gets (fairness).
    const skip = new Set([
      ".git", "var", "bench", "results", ".env", ".niffler-build.lock",
      "AGENTS.md", "AGENTS.local.md",
    ]);
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
    // Task workdirs live under the bench worktree's var/bench (outside this
    // NIF_ROOT); mirroring the subtree here gives every task repo a path
    // that is lexically inside the harness root, so it can be handed to a
    // session as its immutable workspace (cwd) and pass core's confinement
    // check while the bytes stay shared with the results tree.
    try {
      fs.symlinkSync(
        path.join(this.benchRoot, "var", "bench"),
        path.join(this.root, "var", "bench"),
      );
    } catch (e) {
      if (e.code !== "EEXIST") throw e;
    }
    fs.copyFileSync(path.join(this.benchRoot, ".env"), path.join(this.root, ".env"));

    // 1. Private NATS bus on a free port (never the developer's 4222 bus).
    //    Prefer the in-repo component build (var/bin/nats-server); PATH
    //    fallback for machines that never ran `make build`.
    this.natsPort = await freePort();
    const natsBin = fs.existsSync(path.join(this.root, "var", "bin", "nats-server"))
      ? path.join(this.root, "var", "bin", "nats-server")
      : "nats-server";
    this.natsProc = spawn(
      natsBin,
      // --max_payload matches what core spawns for its own bus (8 MiB): the
      // default 1 MiB caps publishes, and a long SWE transcript with big tool
      // output fails to publish against it (core warns, then the turn dies).
      ["-a", "127.0.0.1", "-p", String(this.natsPort), "-m", "-1", "--max_payload", "8388608"],
      {
        cwd: this.runRoot,
        stdio: ["ignore", "ignore", "pipe"],
      },
    );
    // Persist the bus's stderr: when it dies mid-run everything cascades
    // (connection-closed publishes, PDEATHSIG) and without this log the
    // cause is pure guesswork (seen: silent death at 01:19, 2026-09-10).
    this.natsLog = fs.openSync(path.join(this.runRoot, "nats.log"), "a");
    this.natsProc.stderr.on("data", (d) => fs.writeSync(this.natsLog, d));
    this.natsProc.on("exit", (code, signal) =>
      fs.writeSync(
        this.natsLog,
        `bench: private nats exited (code=${code} signal=${signal})\n`,
      ),
    );
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
      // The bench harness is never UI-autostarted. When the bench itself is
      // driven from inside a Niffler session — the natural way to run it —
      // the caller's environment carries NIF_AUTOSTART=1, and the private
      // core then shuts itself down after the boot grace (60s) because no
      // interactive client registers: the run dies mid-cell with the cli
      // calls left waiting on a dead bus. Pin it off explicitly.
      NIF_AUTOSTART: "0",
      // Long-horizon tasks (DeepSWE) run far past an interactive turn's round
      // count; this only ever raises the ceiling for the bench harness.
      NIF_MAX_TURN_ROUNDS: String(this.maxTurnRounds),
      ...(this.llmTimeoutMs
        ? { NIF_LLM_TIMEOUT_MS: String(this.llmTimeoutMs) }
        : {}),
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

    // 3. Confirm the shipped shape before any conversation can freeze its
    // prompt/tools. Store + llm alone can register well before edit/grep.
    try {
      await this.waitUntilReady();
    } catch (error) {
      await this.stop();
      throw error;
    }
    // Session runner binary must exist (make build).
    if (!fs.existsSync(path.join(this.binDir, "session"))) {
      await this.stop();
      throw new Error("bench niffler: var/bin/session missing — run `make build`");
    }
  }

  // Ordinary catalog calls only: no session_prepare/export or model request.
  // Bound the CLI process too (its own catalog bootstrap has a separate wait).
  async readinessCatalog(op, timeoutMs) {
    const res = await run(path.join(this.binDir, "cli"),
      [`--timeout:${Math.max(1, Math.ceil(timeoutMs / 1000))}`,
        "call", "catalog", JSON.stringify({ op })],
      { cwd: this.root, env: this.cliEnv(), timeoutMs });
    if (res.code !== 0 || res.timedOut) {
      // Do not echo CLI/log output: it may contain provider credentials.
      throw new Error(`catalog ${op} unavailable (exit ${res.code}${res.timedOut ? ", timeout" : ""})`);
    }
    let value;
    try { value = JSON.parse(res.stdout.trim().split("\n").at(-1)); }
    catch { throw new Error(`catalog ${op} returned invalid JSON`); }
    if (!value || value.error) throw new Error(`catalog ${op} returned an error`);
    return value;
  }

  async waitUntilReady(timeoutMs = 120_000) {
    const required = requiredManifestComponents(
      fs.readFileSync(path.join(this.root, "manifest.yaml"), "utf8"));
    for (const name of ["store", "llm", "bash", "edit", "grep", "systemprompt",
      ...(this.expertEnabled ? ["expert"] : [])]) {
      if (!required.includes(name)) required.push(name);
    }
    const deadline = performance.now() + timeoutMs;
    let missing = "catalog not yet available";
    while (performance.now() < deadline) {
      for (const [name, child] of [["nats", this.natsProc], ["harness", this.harnessProc]]) {
        if (child && (child.exitCode != null || child.signalCode != null)) {
          throw new Error(`bench niffler: readiness failed: ${name} exited`);
        }
      }
      try {
        const budget = () => Math.max(1, Math.min(5000, deadline - performance.now()));
        const components = await this.readinessCatalog("components", budget());
        if (performance.now() >= deadline) break;
        const direct = await this.readinessCatalog("list", budget());
        const problems = readinessProblems(components, direct, required, this.root);
        missing = problems.join("; ");
        if (!problems.length && performance.now() < deadline) {
          this.readiness = { components: required.slice().sort(),
            directTools: direct.tools.map((t) => t.name).sort() };
          return this.readiness;
        }
      } catch (error) {
        missing = error.message;
      }
      const left = deadline - performance.now();
      if (left > 0) await new Promise((resolve) => setTimeout(resolve, Math.min(200, left)));
    }
    throw new Error(`bench niffler: readiness deadline ${timeoutMs}ms exceeded: ${missing}`);
  }

  // Map a path under <benchRoot>/var/bench to the same location inside the
  // harness root (via the var/bench mirror), so it can serve as a session
  // workspace. Returns null for paths outside the mirrored subtree.
  workspaceFor(workdir) {
    const benchVar = path.join(this.benchRoot, "var", "bench");
    const rel = path.relative(benchVar, workdir);
    if (!rel || rel.startsWith("..")) return null;
    return path.join(this.root, "var", "bench", rel);
  }

  // One round = one blocking session tool call. Returns {reply, error}.
  // Transport failures (the cli could not reach the bus / got no JSON) are
  // retried with backoff — they are the harness's problem, not the model's;
  // a parsed turnError or timeout is a genuine round result and never
  // retried.
  async round(opts) {
    await this.waitUntilReady();
    const { sessionId, prompt, turnTimeoutMs, cwd } = opts;
    const cli = path.join(this.binDir, "cli");
    const sessArgs = { sessionId, content: prompt, cwd };
    // Thinking effort from bench config (models.<m>.niffler.thinking) or the
    // run-level --thinking profile. The provider default for these hybrid
    // models is medium-ish thinking, which dominates output tokens; mirror
    // the other harnesses' effort for a symmetric comparison.
    if (this.thinking) sessArgs.thinking = this.thinking;
    const args = ["call", "session", JSON.stringify(sessArgs)];
    let res = null;
    let parsed = null;
    for (let attempt = 0; attempt <= 2; attempt++) {
      if (attempt > 0) await new Promise((r) => setTimeout(r, attempt * 3000));
      res = await run(
        cli,
        [`--timeout:${Math.ceil(turnTimeoutMs / 1000) + 30}`, ...args],
        { cwd: this.root, env: this.cliEnv(), timeoutMs: turnTimeoutMs + 60_000 },
      );
      try {
        parsed = JSON.parse(res.stdout.trim().split("\n").at(-1));
      } catch {}
      if (parsed) break; // got a session result (ok, turnError or error)
      if (res.timedOut) break; // genuine turn timeout — do not extend the budget
      if (attempt === 2) break;
    }
    if (res.timedOut) {
      return { reply: "", error: `niffler round timed out after ${turnTimeoutMs}ms` };
    }
    if (!parsed) {
      // Never fail a cell with an empty message. A cli killed by a signal
      // (exit -1, no stdout, no stderr) used to produce
      // "niffler session call failed (exit -1): " and nothing else, which cost
      // a full investigation of a cell that could not be explained from its own
      // artifacts. Fall back to the harness log, then to the process facts.
      let detail = (res.stderr || res.stdout || "").trim().slice(-400);
      if (!detail) {
        try {
          detail = tail(fs.readFileSync(path.join(this.runRoot, "harness.log"), "utf8"), 600).trim();
        } catch {}
        const facts = `exit ${res.code}${res.timedOut ? ", timed out" : ""}`;
        detail = detail
          ? `no cli output (${facts}); harness log tail: ${detail}`
          : `no cli output and no harness log (${facts})`;
      }
      return { reply: "", error: `niffler session call failed (exit ${res.code}): ${detail}` };
    }
    let reply = parsed.reply ?? "";
    if (typeof reply === "object" && reply !== null) reply = reply.content ?? JSON.stringify(reply);
    const error = parsed.error || parsed.turnError
      ? String(parsed.error || parsed.turnError)
      : null;
    return { reply: String(reply), error };
  }

  async callTool(tool, args, timeoutMs = 30_000) {
    const cli = path.join(this.binDir, "cli");
    let res = null;
    for (let attempt = 0; ; attempt++) {
      res = await run(
        cli,
        [
          `--timeout:${Math.ceil(timeoutMs / 1000)}`,
          "call",
          tool,
          JSON.stringify(args),
        ],
        { cwd: this.root, env: this.cliEnv(), timeoutMs: timeoutMs + 30_000 },
      );
      // A concurrent rebuild transiently unlinks var/bin/cli (nim c writes
      // the binary last) — one clean retry after a short wait.
      if (attempt > 0 || res.code >= 0 || !/ENOENT/.test(res.stderr || "")) break;
      await new Promise((r) => setTimeout(r, 3000));
    }
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
    await this.waitUntilReady();
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
  }

  async expertMetricsSince(sessionId) {
    if (!this.expertEnabled) return null;
    // Per-session counters (expert_status with session_id) — exact, no
    // baseline subtraction, immune to concurrent cells of the same combo.
    // A status request queued behind an in-flight judgment can take as long
    // as the expert's chat timeout; waiting also makes token accounting final.
    const status = await this.callTool("expert_status", { session_id: sessionId }, 150_000);
    if (!status || status.ok === false) return null;
    return {
      active: (status.judgments || 0) > 0,
      target: status.target || "",
      knowledgeVersion: status.knowledgeVersion || "",
      judgments: status.judgments || 0,
      silences: status.silences || 0,
      steers: status.steers || 0,
      accepted: status.accepted || 0,
      rejected: status.rejected || 0,
      staleDrops: status.staleDrops || 0,
      errors: status.errors || 0,
      tokens: {
        prompt: status.tokens?.prompt || 0,
        cached: status.tokens?.cached || 0,
        completion: status.tokens?.completion || 0,
      },
    };
  }

  // Export the full persisted conversation so a completed benchmark can be
  // audited after its private harness and store have stopped.
  async transcript(sessionId) {
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
    if (res.code !== 0) {
      throw new Error(`niffler transcript export failed (exit ${res.code})`);
    }
    const parsed = JSON.parse(res.stdout.trim().split("\n").at(-1));
    return parsed?.items || [];
  }

  // Sum token usage over the conversation transcript in the store.
  async usageFromTranscript(sessionId, items = null) {
    // $/MTok per model, same table as bench/adapters/pi.mjs — niffler cells
    // otherwise report cost 0 in reports while pi/opencode price the same
    // traffic.
    const PRICE = {
      "deepseek-v4-flash": { input: 0.283, output: 1.14, cacheRead: 0.028 },
      // LLM Gateway catalog pricing, same as the pi adapter entry.
      "deepseek-v4.1-flash": { input: 0.15, output: 0.6, cacheRead: 0.003 },
      "syn:large:text": { input: 0.15, output: 0.5, cacheRead: 0.04 },
      // DeepSeek V4.1 Flash on Synthetic (hf: id) — per Synthetic's published
      // model catalog (GET /openai/v1/models → pricing, $/M): prompt 0.8,
      // completion 1.2, input_cache_reads 0.16, input_cache_writes 0.
      "hf:deepseek-ai/DeepSeek-V4.1-Flash": { input: 0.8, output: 1.2, cacheRead: 0.16 },
      // Synthetic catalog (GET /openai/v1/models → pricing, $/M) for the two
      // frontier lanes: GLM-5.3 prompt 1.4 / completion 4.4 / cache read 0.26;
      // Kimi-K3 3.0 / 15.0 / 0.45.
      "hf:zai-org/GLM-5.3": { input: 1.4, output: 4.4, cacheRead: 0.26 },
      "hf:moonshotai/Kimi-K3": { input: 3.0, output: 15.0, cacheRead: 0.45 },
    };
    const usage = zeroUsage();
    if (!items) items = await this.transcript(sessionId);
    for (const it of items) {
      const v = it.value || {};
      if (v.role !== "assistant" || !v.usage) continue;
      // OpenAI prompt_tokens includes cached tokens; pi/opencode expose input
      // and cacheRead as disjoint counters. Normalize Niffler to the latter
      // so input + cacheRead + output is an honest cross-harness total.
      const prompt = v.usage.prompt_tokens || 0;
      const cached = Math.min(
        prompt,
        Math.max(
          v.usage.prompt_cache_hit_tokens || 0,
          v.usage.prompt_tokens_details?.cached_tokens || 0,
        ),
      );
      usage.input += prompt - cached;
      usage.output += v.usage.completion_tokens || 0;
      usage.cacheRead += cached;
      const price = PRICE[this.model] || null;
      if (price) {
        usage.cost +=
          ((prompt - cached) * price.input +
            (v.usage.completion_tokens || 0) * price.output +
            cached * price.cacheRead) /
          1_000_000;
      }
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

// Assistant turns + tool-call counts from a persisted transcript —
// turn-shape metrics next to usageFromTranscript (readSingle/readBatch
// split the read tool's single-file sugar from multi-file batches;
// a 1-item "reads" array returns plain content, so it counts as single).
// Compact argument telemetry for the shipped direct tools. Counts are fields
// explicitly emitted (including nested read selectors), not inferred defaults.
const argumentContracts = {
  bash: { required: ["command"], defaults: { cwd: "", run_in_background: false, timeoutMs: 120000 } },
  read: { required: [], defaults: { force: false, offset: 1, limit: 2000, word: false, context: 2, max: 8 } },
  edit: { required: ["path", "edits"], defaults: { replace_all: false } },
  write: { required: ["path", "content"], defaults: {} },
  replace_across: { required: ["replace"], defaults: { word: false, min_matches: 1 } },
  grep: { required: ["pattern"], defaults: { path: "", glob: "", case_insensitive: false, hidden: false, context: 0, max_results: 200, timeoutMs: 30000 } },
  discover: { required: [], defaults: { component: "", query: "" } },
  invoke: { required: ["tool", "arguments"], defaults: { sticky: false } },
};

export function transcriptShape(items) {
  const shape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0,
                  leakUrls: [], discoverCalls: 0, discoverRegistry: 0,
                  discoverComponent: 0, discoverToolSchemas: 0, discoverQuery: 0,
                  discoverAnswers: 0, discoverBytes: 0, invokeCalls: 0,
                  multiCallMessages: 0, multiCallCalls: 0, maxCallsPerMessage: 0,
                  pipelineCalls: 0, pipelineMessages: 0, saveAsCalls: 0, resolveVarsCalls: 0,
                  readSelectors: { calls: 0, items: 0, glob: 0, pattern: 0, inventory: 0 },
                  arguments: {}, resultChars: {}, resultAnswers: {} };
  for (const it of items || []) {
    const v = it.value || {};
    if (v.role !== "assistant") continue;
    shape.turns += 1;
    const calls = Array.isArray(v.tool_calls) ? v.tool_calls : [];
    shape.maxCallsPerMessage = Math.max(shape.maxCallsPerMessage, calls.length);
    if (calls.length > 1) {
      shape.multiCallMessages += 1;
      shape.multiCallCalls += calls.length;
    }
    let pipelineMessage = false;
    for (const tc of calls) {
      const n = tc?.function?.name || "?";
      let a = {};
      let valid = true;
      const raw = tc?.function?.arguments || "{}";
      try {
        a = typeof raw === "string" ? JSON.parse(raw) : raw;
        if (!a || typeof a !== "object" || Array.isArray(a)) { a = {}; valid = false; }
      } catch { valid = false; }
      const metrics = shape.arguments[n] ||= { chars: 0, keys: 0, optional: 0, defaults: 0, invalid: 0 };
      metrics.chars += typeof raw === "string" ? raw.length : JSON.stringify(raw).length;
      metrics.keys += Object.keys(a).length;
      if (!valid) metrics.invalid += 1;
      const contract = argumentContracts[n];
      if (contract) {
        metrics.optional += Object.keys(a).filter((key) => !contract.required.includes(key)).length;
        const countDefaults = (obj) => {
          if (!obj || typeof obj !== "object") return;
          for (const [key, value] of Object.entries(obj)) {
            if (Object.hasOwn(contract.defaults, key) && value === contract.defaults[key]) metrics.defaults += 1;
          }
        };
        countDefaults(a);
        for (const key of ["reads", "windows", "edits", "replace"]) {
          if (Array.isArray(a[key])) for (const item of a[key]) countDefaults(item);
        }
      }
      const saved = Object.hasOwn(a, "save_as");
      const resolved = a.resolve_vars === true;
      if (saved) shape.saveAsCalls += 1;
      if (resolved) shape.resolveVarsCalls += 1;
      if (saved || resolved) { shape.pipelineCalls += 1; pipelineMessage = true; }

      shape.tools[n] = (shape.tools[n] || 0) + 1;
      shape.toolCalls += 1;
      if (n === "read") {
        const selectors = [a, ...(Array.isArray(a.reads) ? a.reads : [])]
          .filter((item) => item && typeof item === "object" &&
            (Object.hasOwn(item, "glob") || Object.hasOwn(item, "pattern")));
        if (selectors.length) shape.readSelectors.calls += 1;
        shape.readSelectors.items += selectors.length;
        for (const item of selectors) {
          if (item.glob) shape.readSelectors.glob += 1;
          if (item.pattern) shape.readSelectors.pattern += 1;
          else shape.readSelectors.inventory += 1;
        }
        // canonical "reads" array and the legacy "windows" alias both batch
        const batched =
          (Array.isArray(a.reads) && a.reads.length > 1) ||
          (Array.isArray(a.windows) && a.windows.length > 1);
        if (batched) shape.readBatch += 1;
        else shape.readSingle += 1;
      } else if (n === "discover") {
        // The roster moved out of the system prompt into discover's registry,
        // so the shape of discovery is now a result, not just an anecdote:
        // registry (no arguments), a component view, named tool schemas, or a
        // keyword query. "shopping" is a discover with no invoke after it.
        shape.discoverCalls += 1;
        if (Array.isArray(a.tools) && a.tools.length > 0) shape.discoverToolSchemas += 1;
        else if (typeof a.component === "string" && a.component.length > 0) shape.discoverComponent += 1;
        else if (typeof a.query === "string" && a.query.length > 0) shape.discoverQuery += 1;
        else shape.discoverRegistry += 1;
      } else if (n === "invoke" || n === "bash") {
        if (n === "invoke") shape.invokeCalls += 1;
        // Knowledge-isolation check. A SWE-bench instance is derived from a
        // real merged pull request, so fetching the upstream project (its
        // issues, PRs, patch) hands the model the graded answer. Prompt rules
        // are not enforcement — record what each cell actually reached for, so
        // a leak can never be read as a capability win. Conservative on
        // purpose: bash is only inspected when the command looks like network
        // access, and loopback URLs are ignored.
        const probes =
          n === "invoke"
            ? a.tool === "fetch"
              ? [JSON.stringify(a.arguments || a.args || {})]
              : []
            : /\b(curl|wget)\b|\bgit +(clone|fetch)\b/.test(String(a.command || ""))
              ? [String(a.command || "")]
              : [];
        for (const s of probes) {
          for (const m of s.matchAll(/https?:\/\/[^\s"'`)]+/g)) {
            const u = m[0];
            if (/^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])/.test(u)) continue;
            if (!shape.leakUrls.includes(u)) shape.leakUrls.push(u);
          }
        }
      }
    }
    if (pipelineMessage) shape.pipelineMessages += 1;
  }
  // Answer size, not just call count: the registry exists to make discovery
  // cheap, so a component dump that answers with kilobytes is a regression we
  // want to see per cell rather than argue about.
  for (const it of items || []) {
    const v = it.value || {};
    if (v.role !== "tool") continue;
    const n = v.name || "?";
    const chars = typeof v.content === "string" ? v.content.length
      : v.content == null ? 0 : JSON.stringify(v.content).length;
    shape.resultChars[n] = (shape.resultChars[n] || 0) + chars;
    shape.resultAnswers[n] = (shape.resultAnswers[n] || 0) + 1;
    if (n === "discover") {
      shape.discoverAnswers += 1;
      shape.discoverBytes += chars;
    }
  }
  shape.shopping = shape.discoverCalls > 0 && shape.invokeCalls === 0;
  shape.leaked = shape.leakUrls.length > 0;
  return shape;
}

export const name = "niffler";
