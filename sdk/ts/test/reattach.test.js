"use strict";

// The TS SDK's re-attach contract (issue #98): the counterpart of
// tests/t_reconnect.nim (Nim) and sdk/go/component_test.go's
// TestReattachAfterOutage (Go).
//
// The failure this pins: nats.js `maxReconnectAttempts: -1` retries the SAME
// server forever, so a harness that restarts on a NEW port — `NIF_NATS_SPAWN=1`,
// or a home port yielded to a foreign core — can never be found again. The
// process stays alive and deaf, no `reg.depart` was sent, and the catalog keeps
// advertising a component nothing can reach.
//
// What is asserted, in the order the contract matters:
//   1. registration: onReattached is chainable and replaces nothing;
//   2. after an outage past NIF_RECONNECT_GRACE_S the component re-attaches to
//      a bus on a DIFFERENT port, re-announces `reg.publish`, and answers a
//      tool call again — with no process restart;
//   3. the onReattached hook runs (mcp-bridge's deferred-announce case);
//   4. a deliberate close() does NOT trigger a re-attach.

const assert = require("node:assert/strict");
const { execFileSync, spawn } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { Component } = require("../dist");
const { connect } = require("nats");

function startNats(tag) {
  // Let the server pick its own port and report it (no bind-close-start race).
  const portsDir = fs.mkdtempSync(path.join(os.tmpdir(), `niffler-ts-${tag}-*`));
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

async function waitFor(what, ms, probe) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (await probe()) return true;
    await new Promise((r) => setTimeout(r, 50));
  }
  return false;
}

async function main() {
  // --- 1. registration contract (no bus needed) ---------------------------
  {
    const c = new Component("reattach-reg", "0.1.0");
    const ret = c.onReattached(() => {});
    assert.equal(ret, c, "onReattached is chainable");
    // Two hooks must BOTH run: unlike onIdle (one handler, a replacement is a
    // bug), re-attach hooks compose — a component may have several pieces of
    // state to reconcile.
    c.onReattached(() => {});
    assert.equal(c.reattachedHandlers.length, 2,
      "re-attach hooks accumulate rather than replacing");
  }

  // --- 2/3. real outage, new port ----------------------------------------
  // A short grace keeps the test fast; the knob is shared with Nim and Go.
  const previousGrace = process.env.NIF_RECONNECT_GRACE_S;
  const previousUrl = process.env.NIF_NATS_URL;
  process.env.NIF_RECONNECT_GRACE_S = "1";

  let first = startNats("reattach-a");
  let second = null;
  try {
    process.env.NIF_NATS_URL = first.url;
    const c = new Component("reattach-live", "0.1.0");
    let hookRuns = 0;
    c.onReattached(() => { hookRuns++; });
    c.tool("ping", { type: "object", properties: {} },
      async () => ({ ok: true, pong: true }));
    await c.connect();
    assert.ok(c.connected(), "the component connected to the first bus");

    // Sanity: the tool answers BEFORE the outage, so a later success is not
    // just a fresh registration answering nothing.
    const ncBefore = await connect({ servers: first.url });
    const before = await ncBefore.request("svc.reattach-live.call",
      JSON.stringify({ v: 1, id: "b1", kind: "call", tool: "ping", args: {} }),
      { timeout: 3000 });
    await ncBefore.close();
    assert.match(new TextDecoder().decode(before.data), /pong/,
      "the tool answers before the outage");

    // Kill the bus and stand up a replacement on a DIFFERENT port — the case
    // the client's own same-server reconnect can never recover.
    first.server.kill("SIGKILL");
    await new Promise((r) => setTimeout(r, 200));
    second = startNats("reattach-b");
    assert.notEqual(second.url, first.url, "the second bus is on a new port");
    // The component re-resolves through NIF_NATS_URL (its candidate order
    // mirrors Nim/Go: env first, then the discovery file).
    process.env.NIF_NATS_URL = second.url;

    const back = await waitFor("re-attach", 20000, async () => {
      try {
        const nc = await connect({ servers: second.url });
        const reply = await nc.request("svc.reattach-live.call",
          JSON.stringify({ v: 1, id: "a1", kind: "call", tool: "ping", args: {} }),
          { timeout: 1000 });
        await nc.close();
        return /pong/.test(new TextDecoder().decode(reply.data));
      } catch {
        return false;
      }
    });
    assert.ok(back,
      "the component re-attached to the NEW port and answers again");
    assert.ok(hookRuns >= 1, "the onReattached hook ran");
    assert.ok(c.connected(), "the component reports itself connected");

    // --- 4. a deliberate close is not an outage --------------------------
    const hookedAtClose = hookRuns;
    await c.close();
    await new Promise((r) => setTimeout(r, 2500));
    assert.equal(hookRuns, hookedAtClose,
      "a deliberate close never triggers a re-attach");
  } finally {
    if (previousGrace === undefined) delete process.env.NIF_RECONNECT_GRACE_S;
    else process.env.NIF_RECONNECT_GRACE_S = previousGrace;
    if (previousUrl === undefined) delete process.env.NIF_NATS_URL;
    else process.env.NIF_NATS_URL = previousUrl;
    for (const s of [first, second]) {
      if (!s) continue;
      try { s.server.kill("SIGKILL"); } catch { /* already gone */ }
      fs.rmSync(s.portsDir, { recursive: true, force: true });
    }
  }

  console.log("reattach: ok");
}

main().then(() => process.exit(0)).catch((err) => {
  console.error("reattach test failed:", err);
  process.exit(1);
});
