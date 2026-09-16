"use strict";

// The TS SDK's idle seam (onIdle): the counterpart of the Nim SDK's onIdle and
// the Go SDK's OnIdle. A component needs work that has no request to ride on —
// components/processes uses exactly this to notice a background child's exit
// without anyone polling.
//
// Two things are pinned here: the registration contract (chainable, one
// handler, interval floored) and, with a real NATS server, that the handler
// actually fires while connected and stops at close.

const assert = require("node:assert/strict");
const { execFileSync, spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Component } = require("../dist");

function startNats() {
  // Let the server pick its own port and report it (no bind-close-start race).
  const portsDir = fs.mkdtempSync(path.join(os.tmpdir(), "niffler-ts-idle-*"));
  const server = spawn("nats-server", ["-a", "127.0.0.1", "-p", "-1",
    "--ports_file_dir", portsDir], { stdio: "ignore" });
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    for (const name of fs.readdirSync(portsDir)) {
      if (!name.endsWith(".ports")) continue;
      const published = JSON.parse(
        fs.readFileSync(path.join(portsDir, name), "utf8"));
      if (published.nats && published.nats.length > 0) {
        return { server, portsDir, url: published.nats[0] };
      }
    }
    execFileSync("sleep", ["0.02"]);
  }
  server.kill();
  throw new Error("nats-server did not publish a client port");
}

async function main() {
  // --- registration contract (no bus needed) -------------------------------
  {
    const c = new Component("idle-reg", "0.1.0");
    let called = 0;
    const ret = c.onIdle(1, () => { called++; });
    assert.equal(ret, c, "onIdle is chainable");
    assert.equal(c.idleEveryMs, 10, "interval is floored at 10ms");
    const first = c.idleHandler;
    c.onIdle(250, () => {});
    assert.notEqual(c.idleHandler, first,
      "a second registration replaces the first");
    assert.equal(c.idleEveryMs, 250, "the replacement interval wins");
    assert.equal(called, 0, "registering alone never runs the handler");
  }

  // --- fires while connected, stops at close -------------------------------
  const { server, portsDir, url } = startNats();
  // Point the component at THIS server: without it connect() falls back to
  // NIF_NATS_URL/nats://127.0.0.1:4222 and the test would register a phantom
  // component on whatever harness happens to be running there.
  const previousUrl = process.env.NIF_NATS_URL;
  process.env.NIF_NATS_URL = url;
  try {
    const c = new Component("idle-live", "0.1.0");
    let runs = 0;
    let maxDepth = 0;
    let depth = 0;
    c.onIdle(20, async () => {
      depth++;
      maxDepth = Math.max(maxDepth, depth);
      runs++;
      await new Promise((resolve) => setTimeout(resolve, 5));
      depth--;
    });
    await c.connect();
    const deadline = Date.now() + 3000;
    while (runs < 2 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    assert.ok(runs >= 2, `idle handler ran ${runs} times while connected`);
    assert.equal(maxDepth, 1, "idle work is serialized, never overlapping");
    await c.close();
    const after = runs;
    await new Promise((resolve) => setTimeout(resolve, 150));
    assert.equal(runs, after, `idle handler kept running after close (${after} -> ${runs})`);
  } finally {
    if (previousUrl === undefined) delete process.env.NIF_NATS_URL;
    else process.env.NIF_NATS_URL = previousUrl;
    server.kill();
    fs.rmSync(portsDir, { recursive: true, force: true });
  }

  console.log("idle: ok");
}

main().then(() => process.exit(0)).catch((err) => {
  console.error("idle test failed:", err);
  process.exit(1);
});
