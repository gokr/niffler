"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");
const { Component } = require("../dist");
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitFor(read) {
  for (let i = 0; i < 250; i++) {
    const value = read();
    if (value) return value;
    await pause(20);
  }
  throw new Error("fixture did not become ready");
}
async function stop(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  const exited = new Promise((resolve) => child.once("exit", resolve));
  child.kill("SIGKILL");
  await exited;
}
async function main() {
  const root = path.resolve(__dirname, "../../..");
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "niffler-ts-admission-"));
  let server, router, accepted;
  try {
    server = spawn(path.join(root, "var/bin/nats-server"),
      ["-a", "127.0.0.1", "-p", "-1", "--ports_file_dir", tmp], { stdio: "ignore" });
    const url = await waitFor(() => {
      const file = fs.readdirSync(tmp).find((f) => f.endsWith(".ports"));
      if (!file) return null;
      try { return JSON.parse(fs.readFileSync(path.join(tmp, file), "utf8")).nats[0]; }
      catch { return null; }
    });
    const ready = path.join(tmp, "ready");
    router = spawn(path.join(root, "var/bin/test_catalog_router"), [url, ready], { stdio: "ignore" });
    await waitFor(() => fs.existsSync(ready));
    process.env.NIF_NATS_URL = url;
    const schema = { type: "object", properties: {} };
    accepted = new Component("ts-admission", "1");
    accepted.tool("ts_admission_ping", schema, () => ({ accepted: true }));
    await accepted.connect();
    const rejected = new Component("ts-admission", "1");
    rejected.tool("ts_admission_ping", schema, () => { throw new Error("rejected handler ran"); });
    rejected.tool("ts_admission_extra", schema, () => ({}));
    await assert.rejects(rejected.connect(), /registration rejected/);
    assert.equal(rejected.connected(), false);
    await rejected.close();
    for (let i = 0; i < 20; i++) {
      const result = await accepted.request("ts-admission", "ts_admission_ping", {}, 1000);
      assert.equal(result.accepted, true);
    }
    console.log("TS ADMISSION TEST PASSED");
  } finally {
    if (accepted) await accepted.close();
    await stop(router);
    await stop(server);
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
