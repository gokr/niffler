import test from "node:test";
import assert from "node:assert/strict";
import { summarizeEvents } from "../adapters/maki.mjs";

// Canned stream-json frames, the shape `maki --print --output-format
// stream-json` emits (Claude-Code-compatible): system/init, assistant
// messages with DeepSeek usage splits, a terminal result.
const assistant = (content, usage) => ({
  type: "assistant",
  message: { model: "deepseek-v4-flash", role: "assistant", content, usage },
});
const text = (t) => ({ type: "text", text: t });
const call = (id, name) => ({ type: "tool_use", id, name });

test("firstPrompt is the first request's TOTAL prompt, cache fields included", () => {
  const r = summarizeEvents([
    { type: "system", subtype: "init", session_id: "s1", tools: ["bash", "read"] },
    // First request: 7036 uncached + 512 implicit-cache read = 7548 total.
    assistant([call("a", "bash")], {
      input_tokens: 7036, output_tokens: 10,
      cache_read_input_tokens: 512, cache_creation_input_tokens: 0,
    }),
    assistant([text("done")], {
      input_tokens: 100, output_tokens: 2,
      cache_read_input_tokens: 7400, cache_creation_input_tokens: 0,
    }),
    { type: "result", subtype: "success", is_error: false, result: "done" },
  ]);
  // input_tokens alone would under-report by the cached prefix.
  assert.equal(r.roundUsage.firstPrompt, 7548);
  assert.equal(r.roundUsage.input, 7136);
  assert.equal(r.roundUsage.cacheRead, 7912);
  assert.equal(r.roundUsage.output, 12);
  assert.equal(r.reply, "done");
  assert.equal(r.error, null);
  assert.equal(r.sessionId, "s1");
});

test("cache creation counts into firstPrompt and repeated ids dedupe", () => {
  const r = summarizeEvents([
    assistant([call("x", "read"), call("x", "read"), call("y", "edit")], {
      input_tokens: 500, cache_read_input_tokens: 0, cache_creation_input_tokens: 6000,
    }),
    { type: "result", subtype: "success", is_error: false, result: "ok" },
  ]);
  assert.equal(r.roundUsage.firstPrompt, 6500);
  assert.equal(r.roundUsage.cacheWrite, 6000);
  assert.equal(r.roundShape.toolCalls, 2);
  assert.deepEqual(r.roundShape.tools, { read: 1, edit: 1 });
});

test("error paths: timeout preError, is_error result, no usage frames", () => {
  const r1 = summarizeEvents([], { preError: "maki round timed out after 100ms" });
  assert.equal(r1.error, "maki round timed out after 100ms");
  assert.equal(r1.roundUsage.firstPrompt, undefined);

  const r2 = summarizeEvents([
    { type: "result", subtype: "error", is_error: true, result: "boom" },
  ]);
  assert.equal(r2.error, "boom");
});
