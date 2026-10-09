// bench/adapters/openhands.mjs — drive OpenHands (Agent Canvas + the
// openhands-agent-server it launches via uvx) over its documented REST API.
//
// One agent-server stack per combo (isService); each cell gets one
// conversation created against its task repo as the working directory and
// driven by initial_message (round 1) or an event follow-up (later rounds).
// Completion is the conversation's `execution_status`; usage comes from
// TokenEvent prompt/response token-id arrays (exact), tool calls from
// ActionEvent records, and the final answer from `agent_final_response`.
import fs from "node:fs";
import path from "node:path";
import net from "node:net";
import { spawn } from "node:child_process";
import { run as runCmd, zeroUsage, addUsage } from "../lib/util.mjs";

const OPENHANDS_ROOT = process.env.OPENHANDS_ROOT || "/home/gokr/git/harnesses/OpenHands";

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
    srv.on("error", reject);
  });
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export class OpenhandsHarness {
  constructor(opts) {
    this.model = opts.model;
    this.apiKey = opts.apiKey || "";
    this.baseUrl = opts.baseUrl || "https://api.deepseek.com/v1";
    this.port = 0;
    this.key = "bench-" + Math.random().toString(36).slice(2, 10);
    this.child = null;
    this.stderr = "";
    this.authName = "Authorization"; // probed at start
    this.conversations = new Map(); // task repo path -> conversation id (repo is the per-cell unique key; the bench session id is null on round 1 and shared across concurrent cells)
  }

  get base() { return `http://127.0.0.1:${this.port}`; }
  headers(extra = {}) {
    const value = this.authName === "Authorization" ? `Bearer ${this.key}` : this.key;
    return { "content-type": "application/json", [this.authName]: value, ...extra };
  }

  async start() {
    try {
      await this.startInner();
    } catch (e) {
      // Never leak a half-started stack: its agent-server owns a fixed port
      // that blocks every later launch.
      await this.stop();
      throw e;
    }
  }

  async startInner() {
    this.port = await freePort();
    // The product launcher fronts the agent-server with an ingress for the UI;
    // the documented REST API lives on the agent-server itself, so the bench
    // runs that directly (same PyPI pin and packages the launcher uses) on a
    // free port. `OH_SESSION_API_KEYS_0` is the session API key the launcher
    // wires from LOCAL_BACKEND_API_KEY.
    this.child = spawn("uvx", [
      "--from", "openhands-agent-server==1.50.1",
      "--with", "openhands-sdk==1.50.1",
      "--with", "openhands-tools==1.50.1",
      "--with", "openhands-workspace==1.50.1",
      "--with", "posthog",
      "agent-server",
      "--import-modules", "canvas_ui_tool",
      "--host", "127.0.0.1",
      "--port", String(this.port),
    ], {
      cwd: OPENHANDS_ROOT,
      detached: true,
      env: {
        ...process.env,
        OPENHANDS_SUPPRESS_BANNER: "1",
        // The launcher puts the clone's tools/ on sys.path before preloading
        // canvas_ui_tool; keep the product's tool surface exactly.
        PYTHONPATH: path.join(OPENHANDS_ROOT, "tools"),
        OH_SESSION_API_KEYS_0: this.key,
        OH_SECRET_KEY: "bench-secret",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.child.stdout.on("data", (d) => { this.stderr += String(d); });
    this.child.stderr.on("data", (d) => { this.stderr += String(d); });
    // Warm uvx cache boots in ~11s; allow cold-cache boots too.
    const deadline = Date.now() + 300_000;
    const seen = [];
    const authCandidates = [
      // The official client authenticates with X-Session-API-Key.
      ["X-Session-API-Key", this.key],
      ["Authorization", `Bearer ${this.key}`],
    ];
    while (Date.now() < deadline) {
      if (this.child.exitCode !== null) {
        throw new Error(`agent-server exited ${this.child.exitCode}: ${this.stderr.slice(-800)}`);
      }
      let sawHttp = false;
      for (const [name, value] of authCandidates) {
        try {
          const res = await fetch(`${this.base}/api/llm/providers`, {
            headers: { "content-type": "application/json", [name]: value },
            signal: AbortSignal.timeout(5_000),
          });
          sawHttp = sawHttp || res.status < 500;
          seen.push(`${name}=${res.status}`);
          if (res.ok) {
            this.authName = name;
            return;
          }
        } catch (e) { seen.push(`${name}=ERR:${e.name}`); }
      }
      if (sawHttp) {
        this.authName = "X-Session-API-Key";
      }
      await sleep(1000);
    }
    throw new Error(`agent-server did not become ready (probes ${seen.slice(-8).join(" ")}): ${this.stderr.slice(-1200)}`);
  }

  async stop() {
    const child = this.child;
    if (!child) return;
    const group = -child.pid; // detached: the launcher + its uvx children
    if (child.exitCode === null) {
      try { process.kill(group, "SIGTERM"); } catch {}
      await sleep(750);
      try { process.kill(group, "SIGKILL"); } catch {}
    }
    // Grandchildren keep the captured pipes open; destroy them so the bench
    // process can exit instead of lingering on live streams.
    try { child.stdout.destroy(); child.stderr.destroy(); } catch {}
    child.unref();
  }

  llm() {
    // The conversation pins its own provider/model — no shared global state to
    // bleed across cells.
    // The SDK routes through litellm, which wants provider-prefixed model ids;
    // `openai/<id>` rides the OpenAI-compatible path against base_url (which
    // must keep its /v1 — litellm appends /chat/completions verbatim).
    const model = this.model.includes("/") ? this.model : `openai/${this.model}`;
    return {
      api_key: this.apiKey,
      // litellm appends /chat/completions to base_url verbatim, so the base
      // must be the endpoint prefix WITH /v1 (stripping it 404s on /chat).
      base_url: this.baseUrl, model,
      api_mode: "chat", auth_type: "api_key",
      max_output_tokens: 4096, drop_params: true,
    };
  }

  async api(method, route, body) {
    const res = await fetch(`${this.base}${route}`, {
      method,
      headers: this.headers(),
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${route} -> ${res.status}: ${text.slice(0, 1200)}`);
    return text ? JSON.parse(text) : {};
  }

  async round({ repo, prompt, keys, model, sessionId, turnTimeoutMs }) {
    if (model) this.model = model;
    if (keys?.DEEPSEEK_API_KEY) this.apiKey = keys.DEEPSEEK_API_KEY;
    const usage = zeroUsage();
    const shape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0, leakUrls: [] };
    const cellKey = repo; // per-cell unique: concurrent cells must never share a conversation
    let convId = this.conversations.get(cellKey);
    try {
      if (!convId) {
        // Exactly the payload shape validated end-to-end against a live
        // agent-server (no conversation_id — the bench session id is not a
        // UUID and the server replaces null/absent with its own id).
        const created = await this.api("POST", "/api/conversations", {
          // `agent_settings` (not `agent`) is the product-faithful shape: the
          // server builds its default agent with the real toolset
          // (terminal/file_editor/task_tracker + think/finish). An explicit
          // `agent` block initializes NO tools.
          agent_settings: { agent_kind: "openhands", llm: this.llm() },
          workspace: { kind: "LocalWorkspace", working_dir: repo },
          initial_message: {
            role: "user",
            content: [{ type: "text", text: prompt }],
            run: true,
          },
          confirmation_policy: { kind: "NeverConfirm" },
        });
        convId = created.id || created.conversation_id;
        this.conversations.set(cellKey, convId);
      } else {
        await this.api("POST", `/api/conversations/${convId}/events`, {
          kind: "MessageEvent", source: "user",
          llm_message: { role: "user", content: [{ type: "text", text: prompt }] },
          run: true,
        });
      }
      const deadline = Date.now() + turnTimeoutMs;
      let status = "running";
      let lastInfo = {};
      let sawRunning = false;
      let polls = 0;
      while (Date.now() < deadline) {
        const info = await this.api("GET", `/api/conversations/${convId}`);
        lastInfo = info;
        status = info.execution_status;
        if (status === "running" || status === "waiting_for_confirmation") sawRunning = true;
        polls += 1;
        // `idle` before the run has started is a freshly created conversation,
        // not a finished turn — only a settled state after the run counts.
        if (["error", "stuck", "finished"].includes(status)) break;
        if (status === "idle" && (sawRunning || polls > 15)) break;
        await sleep(1000);
      }
      // Usage: TokenEvents are vLLM-only; the conversation's stats carry the
      // exact provider-reported aggregates across its usage records.
      const um = (lastInfo.stats && lastInfo.stats.usage_to_metrics) || {};
      for (const rec of Object.values(um)) {
        const t = (rec && rec.accumulated_token_usage) || {};
        usage.input += (t.prompt_tokens || 0) - (t.cache_read_tokens || 0) - (t.cache_write_tokens || 0);
        usage.output += (t.completion_tokens || 0);
        usage.reasoning += (t.reasoning_tokens || 0);
        usage.cacheRead += (t.cache_read_tokens || 0);
        usage.cacheWrite += (t.cache_write_tokens || 0);
      }
      // Collect usage/tool evidence from the event log (paginated).
      const rounds_debug = [];
      let page;
      let pages = 0;
      const seenPages = new Set();
      do {
        if (++pages > 50 || (page && (seenPages.has(page.next_page_id) || (page.items || []).length === 0))) break;
        if (page?.next_page_id) seenPages.add(page.next_page_id);
        page = await this.api("GET",
          `/api/conversations/${convId}/events/search${page ? `?page_id=${encodeURIComponent(page.next_page_id)}` : ""}`);
        for (const ev of page.items || []) {
          if (/Error|error/.test(String(ev.kind)) && ev.detail !== undefined) rounds_debug.push(`${ev.kind}:${ev.code || ""}:${String(ev.detail).slice(0, 300)}`);
          else if (/Error|error/.test(String(ev.kind)) || ev.observation?.error) rounds_debug.push(`${ev.kind}:${JSON.stringify(ev).slice(0, 300)}`);
          if (ev.kind === "TokenEvent" || ev.prompt_token_ids) {
            usage.input += (ev.prompt_token_ids || []).length;
            usage.output += (ev.response_token_ids || []).length;
          }
          if (ev.kind === "ActionEvent") {
            const name = ev.action?.action || ev.action?.name || ev.tool_call?.name || "?";
            const id = ev.id || `${name}:${shape.toolCalls}`;
            if (!shape.tools[`seen:${id}`]) {
              shape.tools[`seen:${id}`] = 1;
              shape.tools[name] = (shape.tools[name] || 0) + 1;
              shape.toolCalls += 1;
              if (name === "read") shape.readSingle += 1;
              const s = JSON.stringify(ev.action || {});
              for (const m of s.matchAll(/https?:\/\/[^\s"'`)>]+/g)) {
                const u = m[0];
                if (!/^https?:\/\/(127\.0\.0\.1|localhost|\[::1\])/.test(u) && !shape.leakUrls.includes(u)) shape.leakUrls.push(u);
              }
            }
          }
          if (ev.kind === "MessageEvent" && ev.source === "agent") shape.turns += 1;
        }
      } while (page.next_page_id);
      delete shape.tools["seen"];
      for (const k of Object.keys(shape.tools)) if (k.startsWith("seen:")) delete shape.tools[k];
      shape.leaked = shape.leakUrls.length > 0;
      const final = await this.api("GET", `/api/conversations/${convId}/agent_final_response`);
      const reply = String(final.response || "");
      // Surface whatever the server recorded about the failure (error events,
      // agent errors) instead of a bare status word.
      const details = [];
      for (const r of rounds_debug || []) details.push(r);
      let error = null;
      if (["error", "stuck"].includes(status)) {
        error = `OpenHands conversation ${status}` +
          (details.length ? `: ${details.join(" | ")}` : `: no error events recorded (tools ${JSON.stringify(shape.tools)})`) +
          ` | llm:${JSON.stringify({ ...this.llm(), api_key: this.apiKey ? "set" : "EMPTY" })} env:${["OPENAI_API_KEY","OPENAI_BASE_URL","OPENAI_API_BASE","DEEPSEEK_API_KEY","HTTPS_PROXY","HTTP_PROXY","NO_PROXY"].map((k) => `${k}=${process.env[k] ? "set" : "-"}`).join(",")}` +
          ` | server: ${this.stderr.slice(-500)}`;
      }
      if (!["finished", "idle", "error", "stuck"].includes(status)) error = `OpenHands turn timed out (${status})`;
      return { reply, error, sessionId, roundUsage: usage, roundShape: shape, raw: { stdout: "", stderr: this.stderr.slice(-2000) } };
    } catch (e) {
      return { reply: "", error: String(e.message || e), sessionId, roundUsage: usage,
        roundShape: shape, raw: { stdout: "", stderr: this.stderr.slice(-2000) } };
    }
  }
}

export async function round(opts) {
  if (!globalThis.__openhands) globalThis.__openhands = new OpenhandsHarness(opts);
  return globalThis.__openhands.round(opts);
}

export function usageFromRounds(rounds) {
  const usage = zeroUsage();
  for (const r of rounds) addUsage(usage, r.roundUsage || r);
  return usage;
}

export function shapeFromRounds(rounds) {
  const shape = { turns: 0, toolCalls: 0, tools: {}, readSingle: 0, readBatch: 0, leakUrls: [] };
  for (const r of rounds) {
    const v = r.roundShape;
    if (!v) continue;
    shape.turns += v.turns || 0;
    shape.toolCalls += v.toolCalls || 0;
    shape.readSingle += v.readSingle || 0;
    shape.readBatch += v.readBatch || 0;
    for (const u of v.leakUrls || []) if (!shape.leakUrls.includes(u)) shape.leakUrls.push(u);
    for (const [k, n] of Object.entries(v.tools || {})) {
      if (k.startsWith("seen:")) continue;
      shape.tools[k] = (shape.tools[k] || 0) + n;
    }
  }
  shape.leaked = shape.leakUrls.length > 0;
  return shape;
}

export const name = "openhands";
