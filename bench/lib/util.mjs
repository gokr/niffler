// bench/lib/util.mjs — small spawn/json helpers for the bench harness.
import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

export function readJson(p, dflt = null) {
  try {
    return JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {
    return dflt;
  }
}

export function writeJson(p, obj) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, JSON.stringify(obj, null, 2) + "\n");
}

// Minimal .env loader — returns an object, never touches process.env.
export function loadDotEnv(p) {
  const out = {};
  try {
    for (const line of fs.readFileSync(p, "utf8").split("\n")) {
      const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m) out[m[1]] = m[2].replace(/^["']|["']$/g, "");
    }
  } catch {}
  return out;
}

export function tail(s, n = 4000) {
  if (s == null) return "";
  s = String(s);
  return s.length <= n ? s : "…\n" + s.slice(-n);
}

export function nowIso() {
  return new Date().toISOString();
}

// Run a command (no shell), capture output, kill on timeout.
// opts: {cwd, env, timeoutMs, stdin}
export function run(cmd, args, opts = {}) {
  return new Promise((resolve) => {
    const child = spawn(cmd, args, {
      cwd: opts.cwd,
      env: { ...process.env, ...(opts.env || {}) },
      stdio: ["ignore", "pipe", "pipe"],
      detached: true, // own process group, so we can kill grandchildren too
    });
    let stdout = "";
    let stderr = "";
    let timedOut = false;
    const timer =
      opts.timeoutMs > 0
        ? setTimeout(() => {
            timedOut = true;
            try {
              // Kill the whole group: children that survive the parent keep
              // the stdio pipes open and would delay 'close' indefinitely.
              if (child.pid) process.kill(-child.pid, "SIGKILL");
            } catch {}
            try {
              child.kill("SIGKILL");
            } catch {}
            // Belt and braces: force EOF on the pipes in our process.
            try {
              child.stdout.destroy();
              child.stderr.destroy();
            } catch {}
          }, opts.timeoutMs)
        : null;
    child.stdout.on("data", (d) => (stdout += d));
    child.stderr.on("data", (d) => (stderr += d));
    child.on("error", (err) => {
      if (timer) clearTimeout(timer);
      resolve({ code: -1, stdout, stderr: stderr + String(err), timedOut });
    });
    child.on("close", (code) => {
      if (timer) clearTimeout(timer);
      resolve({ code: code ?? -1, stdout, stderr, timedOut });
    });
  });
}

// Parse newline-delimited JSON, skipping junk lines (plugin banners etc).
export function parseJsonLines(text) {
  const out = [];
  for (const line of String(text).split("\n")) {
    const t = line.trim();
    if (!t.startsWith("{")) continue;
    try {
      out.push(JSON.parse(t));
    } catch {}
  }
  return out;
}

export function zeroUsage() {
  return {
    input: 0,
    output: 0,
    reasoning: 0,
    cacheRead: 0,
    cacheWrite: 0,
    cost: 0,
  };
}

export function addUsage(a, b) {
  for (const k of Object.keys(zeroUsage())) a[k] += b[k] || 0;
  return a;
}
