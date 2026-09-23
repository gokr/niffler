import test from "node:test";
import assert from "node:assert/strict";
import { summarizeEvents, usageFromRounds, shapeFromRounds } from "../adapters/dsh.mjs";

const assistant = (seq, content, usage) => ({
  type: "assistant/message", seq,
  data: { message: { content }, usage },
});
const call = (seq, id, name, args = {}) => ({
  type: "tool/call", seq, data: { callId: id, name, arguments: JSON.stringify(args) },
});

test("usage and repeated tool calls use model events, not call-name presence", () => {
  const events = [
    assistant(1, [{ type: "tool-call", id: "a", name: "bash", arguments: "{}" }],
      { inputTokens: 42, cacheReadTokens: 10, outputTokens: 3, reasoningTokens: 2 }),
    call(2, "a", "bash"),
    assistant(3, [{ type: "tool-call", id: "b", name: "bash", arguments: "{}" }],
      { inputTokens: 12, cacheReadTokens: 30, outputTokens: 5, reasoningTokens: 1 }),
    call(4, "b", "bash"),
    assistant(5, [{ type: "text", text: "done" }],
      { inputTokens: 4, cacheReadTokens: 35, outputTokens: 2 }),
    { type: "turn/end", data: { reason: { kind: "completed" } } },
  ];
  const result = summarizeEvents(events);
  assert.equal(result.reply, "done");
  assert.equal(result.error, null);
  assert.deepEqual(result.roundUsage, {
    input: 58, output: 10, reasoning: 3, cacheRead: 75, cacheWrite: 0, cost: 0, firstPrompt: 52,
  });
  assert.equal(result.roundShape.toolCalls, 2);
  assert.deepEqual(result.roundShape.tools, { bash: 2 });
  assert.equal(result.roundShape.turns, 3);
});

test("nested PTC dispatches count, and external fetches are flagged", () => {
  const events = [
    assistant(1, [{ type: "tool-call", id: "root", name: "run_code", arguments: "{}" }],
      { inputTokens: 8, outputTokens: 7 }),
    call(2, "root", "run_code"),
    { type: "tool/ptc-dispatch", seq: 3, data: {
      subCallId: "root:ptc:1", name: "bash", arguments: { command: "curl https://example.com/issue" },
    } },
    { type: "tool/ptc-dispatch", seq: 4, data: {
      subCallId: "root:ptc:2", name: "bash", arguments: { command: "echo ok" },
    } },
    { type: "turn/end", data: { reason: { kind: "completed" } } },
  ];
  const result = summarizeEvents(events);
  assert.equal(result.roundShape.toolCalls, 3);
  assert.deepEqual(result.roundShape.tools, { run_code: 1, bash: 2 });
  assert.deepEqual(result.roundShape.leakUrls, ["https://example.com/issue"]);
  assert.equal(result.roundShape.leaked, true);
});

test("incomplete and errored turns do not look completed", () => {
  assert.match(summarizeEvents([]).error, /no completion event/);
  assert.match(summarizeEvents([{ type: "turn/end", data: {
    reason: { kind: "error", error: { code: "AUTH", message: "bad key" } },
  } }]).error, /AUTH: bad key/);
});

test("feedback rounds combine usage, tools, and leak status", () => {
  const rounds = [
    { input: 10, output: 2, cacheRead: 4, roundShape: {
      turns: 2, toolCalls: 2, tools: { bash: 2 }, leakUrls: ["https://example.com"] } },
    { input: 5, output: 1, cacheRead: 6, roundShape: {
      turns: 1, toolCalls: 1, tools: { bash: 1 }, leakUrls: ["https://example.com"] } },
  ];
  assert.deepEqual(usageFromRounds(rounds), {
    input: 15, output: 3, reasoning: 0, cacheRead: 10, cacheWrite: 0, cost: 0,
  });
  assert.deepEqual(shapeFromRounds(rounds), {
    turns: 3, toolCalls: 3, tools: { bash: 3 }, readSingle: 0, readBatch: 0,
    leakUrls: ["https://example.com"], leaked: true,
  });
});

test("SDK correlation handles pre-receipt completion and feedback continuation", async () => {
  const { DshHarness } = await import("../adapters/dsh.mjs");
  const { mkdtempSync, rmSync, mkdirSync } = await import("node:fs");
  const path = await import("node:path");
  const root = mkdtempSync(path.join(process.cwd(), "var", "dsh-mock-"));
  const repo = path.join(root, "repo");
  mkdirSync(repo);
  const h = new DshHarness({
    bin: path.join(import.meta.dirname, "fixtures", "mock-dsh.mjs"),
    provider: "deepseek-official", model: "deepseek-v4-flash", thinking: "low",
  });
  try {
    for (let i = 1; i <= 2; i++) {
      const r = await h.round({ repo, sessionId: "same-session", prompt: `turn ${i}`, turnTimeoutMs: 3000 });
      assert.equal(r.error, null);
      assert.equal(r.reply, `reply-${i}`);
      assert.equal(r.roundUsage.input, 10 + i);
      assert.equal(r.roundUsage.cacheRead, i);
      assert.equal(r.roundShape.toolCalls, 1);
      assert.deepEqual(r.roundShape.tools, { bash: 1 });
    }
  } finally {
    await h.close();
    rmSync(root, { recursive: true, force: true });
  }
});
