// Small stdio SDK server: deliberate notification-before-prompt-reply ordering.
import readline from "node:readline";
let turn = 0;
const send = (message) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
for await (const line of readline.createInterface({ input: process.stdin })) {
  const { id, method, params } = JSON.parse(line);
  if (method === "initialize") {
    send({ id, result: { serverInfo: { name: "mock-dsh" } } });
  } else if (method === "session/prompt") {
    ++turn;
    const sessionId = params.sessionId;
    const messageId = `mock-msg-${turn}`;
    const event = (type, data) => send({ method: "session.event", params: {
      sessionId, event: { type, data },
    } });
    event("agent/inbox/spliced", { inserted: [{ id: messageId }] });
    event("turn/start", { turn });
    event("assistant/message", {
      message: { content: [
        { type: "tool-call", id: `call-${turn}`, name: "bash", arguments: '{"command":"echo ok"}' },
        { type: "text", text: `reply-${turn}` },
      ] },
      usage: { inputTokens: 10 + turn, outputTokens: 5, cacheReadTokens: turn },
    });
    event("tool/call", { callId: `call-${turn}`, name: "bash", arguments: '{"command":"echo ok"}' });
    event("turn/end", { reason: { kind: "completed" } });
    send({ method: "session.status", params: { sessionId, status: "idle" } });
    send({ id, result: { messageId } });
  } else if (method === "shutdown") {
    send({ id, result: {} });
    process.exit(0);
  }
}
