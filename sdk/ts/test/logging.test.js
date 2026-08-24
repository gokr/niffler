"use strict";

const assert = require("node:assert/strict");
const { Component } = require("../dist");

async function main() {
  const published = [];
  const component = new Component("ts-test", "0.1.0");
  component.nc = {
    publish(subject, data) {
      published.push({ subject, envelope: JSON.parse(new TextDecoder().decode(data)) });
    },
  };

  process.env.NIF_LOG_LEVEL = "warn";
  component.log("debug", "hidden");
  component.log("warn", "shown", { source: "test" });
  assert.equal(published.length, 1);
  assert.equal(published[0].subject, "ev.log.ts-test");
  assert.equal(published[0].envelope.payload.msg, "shown");
  assert.deepEqual(published[0].envelope.payload.ctx, { source: "test" });

  process.env.NIF_LOG_LEVEL = "invalid";
  component.log("info", "fallback-info");
  assert.equal(published.length, 2);
  assert.throws(() => component.log("notice", "bad"), /invalid log level/);

  delete process.env.NIF_LOG_LEVEL;

  const lifecycle = new Component("ts-lifecycle", "0.1.0");
  let handlerFinished = false;
  let connectionClosed = false;
  lifecycle.nc = {
    publish() {},
    async flush() {},
    async close() { connectionClosed = true; },
  };
  lifecycle.subs = [{ async drain() {} }];
  lifecycle.enqueue(async () => {
    await new Promise((resolve) => setTimeout(resolve, 50));
    handlerFinished = true;
  });
  await lifecycle.close();
  assert.equal(handlerFinished, true, "close waits for serialized handlers");
  assert.equal(connectionClosed, true, "close closes after handlers finish");

  const inHandler = new Component("ts-in-handler", "0.1.0");
  let inHandlerClosed = false;
  const handlerReplies = [];
  inHandler.nc = {
    publish(subject, data) {
      if (subject === "_INBOX.reply") {
        handlerReplies.push(JSON.parse(new TextDecoder().decode(data)));
      }
    },
    async flush() {},
    async close() { inHandlerClosed = true; },
  };
  inHandler.subs = [{ async drain() {} }];
  inHandler.tool("close", { type: "object", properties: {} }, async (c) => {
    await c.close();
    return { ok: true };
  });
  const closeCall = new TextEncoder().encode(JSON.stringify({
    v: 1, id: "close-call", kind: "call", tool: "close", args: {},
  }));
  inHandler.enqueue(() => inHandler.handleCall(
    "svc.ts-in-handler.call", "_INBOX.reply", closeCall));
  await Promise.race([
    inHandler.chain,
    new Promise((_, reject) => setTimeout(
      () => reject(new Error("close deadlocked inside a serialized handler")), 1000)),
  ]);
  for (let i = 0; i < 20 && !inHandlerClosed; i++) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(handlerReplies.length, 1, "in-handler close preserves the reply");
  assert.equal(handlerReplies[0].args.ok, true);
  assert.equal(inHandlerClosed, true, "close works inside a serialized handler");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
