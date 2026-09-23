// bench/adapters/dsh.mjs — drive DeepSeek Harness over its SDK JSON-RPC profile.
//
// One runtime is kept per benchmark task so the process cwd (and dsh's
// workspace policy) stays pinned to that task checkout. Rounds reuse the same
// session id and durable dsh home, so feedback rounds are genuine continuations
// rather than fresh conversations. Missing SDK profiles fail explicitly: a
// headless one-shot cannot report comparable usage or continue a session.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import { zeroUsage, addUsage } from "../lib/util.mjs";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const DEFAULT_DSH_ROOT = path.resolve(REPO_ROOT, "../harnesses/deepseek-harness");
const DEFAULT_PROFILE = "sdk-minimal";
const JSON_RPC_INIT_TIMEOUT_MS = 30_000;
const JSON_RPC_SHUTDOWN_TIMEOUT_MS = 1_500;
const JSON_RPC_CLOSE_GRACE_MS = 2_000;

function dshExecutable(explicit) {
  const value = explicit || process.env.DEEPSEEK_HARNESS_BIN || process.env.DSH_BIN;
  if (value) return value;
  const candidates = [
    path.join(DEFAULT_DSH_ROOT, "apps", "cli", "lib", "bin.js"),
    path.join(DEFAULT_DSH_ROOT, "apps", "cli", "bin", "dsh"),
  ];
  return candidates.find((candidate) => fs.existsSync(candidate)) || "dsh";
}

function launchFor(bin) {
  // An explicit JS entry is a Node program; installed `dsh` remains argv[0].
  if (/\.(?:c?m?js)$/i.test(bin) || path.basename(bin) === "bin.js") {
    return { command: process.execPath, args: [path.resolve(bin)] };
  }
  return { command: bin, args: [] };
}

function jsonRpcError(value) {
  const message = value?.message || "DeepSeek Harness JSON-RPC error";
  const error = new Error(String(message));
  error.code = value?.code;
  error.data = value?.data;
  return error;
}

function numeric(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

function reasonError(reason) {
  if (!reason || typeof reason !== "object") return null;
  if (reason.kind === "error") {
    const failure = reason.error || {};
    return `${failure.code || "UNKNOWN"}: ${failure.message || "DeepSeek Harness turn failed"}`;
  }
  if (reason.kind === "aborted") return "DeepSeek Harness turn aborted";
  if (reason.kind === "interrupted") return "DeepSeek Harness turn interrupted";
  if (reason.kind !== "completed") return `DeepSeek Harness stopped: ${reason.kind}`;
  return null;
}

function isInboxReceipt(event, messageId) {
  if (!event || event.type !== "agent/inbox/spliced") return false;
  const inserted = event.data?.inserted;
  return Array.isArray(inserted) && inserted.some((item) => item?.id === messageId);
}

function assistantText(event) {
  return (event?.data?.message?.content || [])
    .filter((block) => block?.type === "text")
    .map((block) => block.text || "")
    .join("");
}

function eventUsage(event) {
  const usage = event?.data?.usage;
  if (!usage) return zeroUsage();
  return {
    input: numeric(usage.inputTokens),
    output: numeric(usage.outputTokens),
    reasoning: numeric(usage.reasoningTokens),
    cacheRead: numeric(usage.cacheReadTokens),
    cacheWrite: numeric(usage.cacheWriteTokens),
    cost: 0,
  };
}

function collectLeakUrls(shape, name, rawArgs) {
  let args = rawArgs;
  if (typeof args === "string") {
    try { args = JSON.parse(args); } catch { args = {}; }
  }
  if (!args || typeof args !== "object") args = {};
  const probes = name === "fetch"
    ? [JSON.stringify(args)]
    : name === "bash" && /\b(curl|wget)\b|\bgit +(clone|fetch)\b/.test(String(args.command || ""))
      ? [String(args.command || "")]
      : [];
  for (const probe of probes) {
    for (const match of probe.matchAll(/https?:\/\/[^\s"'`)>]+/g)) {
      const url = match[0];
      if (/^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])/.test(url)) continue;
      if (!shape.leakUrls.includes(url)) shape.leakUrls.push(url);
    }
  }
}

export function summarizeEvents(events) {
  const usage = zeroUsage();
  const shape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0, leakUrls: [] };
  let reply = "";
  let firstPrompt = null;
  let reason = null;
  const seenToolCalls = new Set();
  for (const event of events) {
    if (event.type === "assistant/message") {
      shape.turns += 1;
      const text = assistantText(event);
      if (text) reply = text;
      const current = eventUsage(event);
      addUsage(usage, current);
      if (firstPrompt === null) {
        firstPrompt = current.input + current.cacheRead + current.cacheWrite;
      }
      for (const block of event.data?.message?.content || []) {
        if (block?.type !== "tool-call") continue;
        const id = block.id || `${block.name || "?"}:${shape.toolCalls}`;
        if (seenToolCalls.has(id)) continue;
        seenToolCalls.add(id);
        const name = block.name || "?";
        shape.tools[name] = (shape.tools[name] || 0) + 1;
        shape.toolCalls += 1;
        if (name === "read") {
          let args = {};
          try { args = JSON.parse(block.arguments || "{}"); } catch {}
          const reads = Array.isArray(args.reads) ? args.reads : Array.isArray(args.windows) ? args.windows : [];
          if (reads.length > 1) shape.readBatch += 1;
          else shape.readSingle += 1;
        }
        collectLeakUrls(shape, name, block.arguments);
      }
    }
    if (event.type === "tool/call" || event.type === "tool/ptc-dispatch") {
      const name = event.data?.name || "?";
      const id = event.data?.callId || event.data?.subCallId || `${name}:${event.seq}`;
      if (!seenToolCalls.has(id)) {
        seenToolCalls.add(id);
        shape.tools[name] = (shape.tools[name] || 0) + 1;
        shape.toolCalls += 1;
        if (name === "read") {
          let args = event.data?.arguments || {};
          if (typeof args === "string") {
            try { args = JSON.parse(args); } catch { args = {}; }
          }
          const reads = Array.isArray(args.reads) ? args.reads : Array.isArray(args.windows) ? args.windows : [];
          if (reads.length > 1) shape.readBatch += 1;
          else shape.readSingle += 1;
        }
        collectLeakUrls(shape, name, event.data?.arguments);
      }
    }
    if (event.type === "turn/end") reason = event.data?.reason || null;
  }
  shape.leaked = shape.leakUrls.length > 0;
  if (!reason) return { reply: reply.trim(), error: "DeepSeek Harness turn has no completion event", reason,
    roundUsage: { ...usage, firstPrompt }, roundShape: shape };
  return { reply: reply.trim(), error: reasonError(reason), reason, roundUsage: { ...usage, firstPrompt }, roundShape: shape };
}

class DshRuntime {
  constructor(opts) {
    Object.assign(this, opts);
    this.child = null;
    this.buffer = "";
    this.nextId = 1;
    this.pending = new Map();
    this.notifications = [];
    this.notificationWaiters = [];
    this.stderr = "";
    this.closed = false;
    this.initialized = false;
  }

  environment() {
    const env = {
      ...process.env,
      DSH_HOME: this.home,
      DSH_AGENTS_HOME: path.join(this.home, "agents"),
      DSH_TELEMETRY_DISABLED: "1",
      DSH_PERMISSION_MODE: "danger-full-access",
      DSH_TOOLS_MODE: "both",
      DEEPSEEK_API_KEY: this.apiKey || "missing",
    };
    if (this.baseUrl) env.DEEPSEEK_BASE_URL = this.baseUrl;
    return env;
  }

  onStdout(chunk) {
    this.buffer += chunk;
    for (;;) {
      const newline = this.buffer.indexOf("\n");
      if (newline < 0) return;
      const line = this.buffer.slice(0, newline).trim();
      this.buffer = this.buffer.slice(newline + 1);
      if (!line) continue;
      let message;
      try { message = JSON.parse(line); } catch { continue; }
      if (message.id !== undefined && message.id !== null) {
        const waiter = this.pending.get(String(message.id));
        if (!waiter) continue;
        this.pending.delete(String(message.id));
        if (message.error) waiter.reject(jsonRpcError(message.error));
        else waiter.resolve(message.result);
      } else if (message.method) {
        this.notifications.push(message);
        for (const waiter of this.notificationWaiters.splice(0)) waiter(message);
      }
    }
  }

  async start() {
    if (this.initialized) return;
    fs.mkdirSync(this.home, { recursive: true });
    const launch = launchFor(this.bin);
    this.child = spawn(launch.command, [...launch.args, "--profile", this.profile], {
      cwd: this.repo,
      env: this.environment(),
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child.stdout.setEncoding("utf8");
    this.child.stderr.setEncoding("utf8");
    this.child.stdout.on("data", (chunk) => this.onStdout(chunk));
    this.child.stderr.on("data", (chunk) => { this.stderr += String(chunk); });
    this.child.on("exit", (code, signal) => {
      const detail = `DeepSeek Harness exited (code=${code} signal=${signal})`;
      for (const waiter of this.pending.values()) waiter.reject(new Error(`${detail}: ${this.stderr.slice(-800)}`));
      this.pending.clear();
      for (const waiter of this.notificationWaiters.splice(0)) waiter({ method: "__closed", params: { detail } });
    });
    this.child.on("error", (error) => {
      for (const waiter of this.pending.values()) waiter.reject(error);
      this.pending.clear();
    });
    try {
      // DSH exposes low as a first-party effort level; pass it through as-is.
      const reasoningEffort = this.thinking === "medium" ? "high" : this.thinking;
      await this.request("initialize", {
        cwd: this.repo,
        provider: this.provider,
        model: this.model,
        ...(reasoningEffort ? { reasoningEffort } : {}),
        ...(this.maxTokens ? { maxTokens: this.maxTokens } : {}),
      }, JSON_RPC_INIT_TIMEOUT_MS);
      this.initialized = true;
    } catch (error) {
      await this.close();
      throw error;
    }
  }

  request(method, params = {}, timeoutMs = 0) {
    if (!this.child || this.child.exitCode !== null) return Promise.reject(new Error("DeepSeek Harness is not running"));
    const id = String(this.nextId++);
    return new Promise((resolve, reject) => {
      let timer = null;
      const finish = (fn, value) => {
        if (timer) clearTimeout(timer);
        fn(value);
      };
      this.pending.set(id, {
        resolve: (value) => finish(resolve, value),
        reject: (error) => finish(reject, error),
      });
      if (timeoutMs > 0) timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      try {
        this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: Number(id), method, params })}\n`);
      } catch (error) {
        this.pending.delete(id);
        finish(reject, error);
      }
    });
  }

  nextNotification() {
    return new Promise((resolve) => this.notificationWaiters.push(resolve));
  }

  async round(sessionId, prompt, timeoutMs) {
    if (!this.initialized) await this.start();
    const deadline = Date.now() + timeoutMs;
    let cursor = this.notifications.length;
    const events = [];
    let received = false;
    let idleSeen = false;
    const buffered = [];
    let messageId = null;
    const acceptNotifications = () => {
      if (messageId === null) return;
      while (cursor < this.notifications.length) {
        const notification = this.notifications[cursor++];
        if (notification.params?.sessionId !== sessionId) continue;
        if (notification.method === "session.event") {
          const event = notification.params.event;
          if (isInboxReceipt(event, messageId)) {
            received = true;
            events.push(...buffered.splice(0));
            events.push(event);
          } else if (received) {
            events.push(event);
          } else {
            // A fast agent can finish before the prompt RPC response reaches
            // stdout. Buffer events until the accepted message id arrives.
            buffered.push(event);
          }
        } else if (notification.method === "session.status" && notification.params.status === "idle") {
          idleSeen = true;
        }
      }
    };
    const promptRequest = this.request("session/prompt", {
      sessionId,
      contentBlocks: [{ type: "text", text: prompt }],
    }, Math.min(timeoutMs, 30_000));
    const messageWait = promptRequest.then((result) => {
      messageId = result.messageId;
      acceptNotifications();
      return result;
    });
    const messageDeadline = Date.now() + Math.min(timeoutMs, 30_000);
    while (messageId === null) {
      acceptNotifications();
      if (messageId !== null) break;
      const remaining = messageDeadline - Date.now();
      if (remaining <= 0) throw new Error(`session/prompt timed out after ${Math.min(timeoutMs, 30_000)}ms`);
      let timer;
      try {
        await Promise.race([
          messageWait,
          this.nextNotification(),
          new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error(`session/prompt timed out after ${Math.min(timeoutMs, 30_000)}ms`)), remaining);
          }),
        ]);
      } finally {
        clearTimeout(timer);
      }
    }
    acceptNotifications();
    for (;;) {
      if (received && idleSeen) {
        this.notifications.length = 0;
        return summarizeEvents(events);
      }
      const remaining = deadline - Date.now();
      if (remaining <= 0) throw new Error(`dsh round timed out after ${timeoutMs}ms`);
      let timer;
      const timeout = new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`dsh round timed out after ${timeoutMs}ms`)), remaining);
      });
      try {
        const notification = await Promise.race([this.nextNotification(), timeout]);
        if (notification?.method === "__closed") throw new Error(notification.params?.detail || "DeepSeek Harness closed");
        acceptNotifications();
      } finally {
        clearTimeout(timer);
      }
    }
  }

  async close() {
    if (this.closed) return;
    this.closed = true;
    const child = this.child;
    if (!child) return;
    if (child.exitCode === null && this.initialized) {
      try { await this.request("shutdown", {}, JSON_RPC_SHUTDOWN_TIMEOUT_MS); } catch {}
    }
    try { child.stdin.end(); } catch {}
    await new Promise((resolve) => {
      if (child.exitCode !== null) return resolve();
      const timer = setTimeout(() => {
        try { child.kill("SIGTERM"); } catch {}
        setTimeout(() => {
          try { child.kill("SIGKILL"); } catch {}
          resolve();
        }, JSON_RPC_CLOSE_GRACE_MS);
      }, JSON_RPC_CLOSE_GRACE_MS);
      child.once("exit", () => { clearTimeout(timer); resolve(); });
    });
  }
}

export class DshHarness {
  constructor(opts) {
    this.apiKey = opts.apiKey || "";
    this.model = opts.model;
    this.provider = opts.provider || "deepseek-official";
    this.baseUrl = opts.baseUrl;
    this.profile = opts.profile || DEFAULT_PROFILE;
    this.thinking = opts.thinking || "";
    this.maxTokens = opts.maxTokens || 256_000;
    this.bin = opts.bin || dshExecutable();
    this.runtimes = new Map();
  }

  async round({ repo, prompt, sessionId, turnTimeoutMs }) {
    let runtime = this.runtimes.get(repo);
    if (!runtime) {
      runtime = new DshRuntime({
        repo,
        home: path.join(path.dirname(repo), "dsh-home"),
        bin: this.bin,
        profile: this.profile,
        provider: this.provider,
        model: this.model,
        thinking: this.thinking,
        maxTokens: this.maxTokens,
        apiKey: this.apiKey,
        baseUrl: this.baseUrl,
      });
      this.runtimes.set(repo, runtime);
    }
    try {
      const result = await runtime.round(sessionId, prompt, turnTimeoutMs);
      return { ...result, raw: { stdout: "", stderr: runtime.stderr } };
    } catch (error) {
      // An interrupted SDK turn has no trustworthy summary. Never silently
      // switch to one-shot headless: it loses history and fabricates usage.
      try { await runtime.close(); } catch {}
      this.runtimes.delete(repo);
      return { reply: "", error: String(error?.message || error), roundUsage: zeroUsage(), roundShape: null,
        raw: { stdout: "", stderr: runtime.stderr } };
    }
  }

  async close() {
    await Promise.all([...this.runtimes.values()].map((runtime) => runtime.close()));
    this.runtimes.clear();
  }
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
    for (const url of value.leakUrls || []) {
      if (!shape.leakUrls.includes(url)) shape.leakUrls.push(url);
    }
    for (const [name, count] of Object.entries(value.tools || {})) {
      shape.tools[name] = (shape.tools[name] || 0) + count;
    }
  }
  shape.leaked = shape.leakUrls.length > 0;
  return shape;
}

export const name = "dsh";
