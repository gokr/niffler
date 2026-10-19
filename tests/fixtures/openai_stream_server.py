#!/usr/bin/env python3
"""Deterministic OpenAI-compatible SSE fixture for session/LLM bus tests."""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def scripted_tool_call(request):
    """A tool call scripted by the user message, or None.

    Test harnesses need the model to CALL a tool (the tool result is what is
    under test), but this fixture is a fixed SSE stream. `TOOLCALL:<tool>
    {json args}` anywhere in the newest user message makes the first round
    emit that call; once the transcript carries its result the next round
    answers normally. Marker-driven on purpose: every existing test's prompts
    lack the marker and keep their plain "OK" behavior byte for byte.
    """
    marker = "TOOLCALL:"
    last_user = None
    for message in request.get("messages", []):
        if message.get("role") == "user":
            last_user = message
    if last_user is None:
        return None
    content = last_user.get("content")
    if isinstance(content, list):
        content = "\n".join(
            part.get("text", "")
            for part in content
            if isinstance(part, dict) and part.get("type") == "text"
        )
    if not isinstance(content, str) or marker not in content:
        return None
    # The tool result is the message AFTER the call; its presence means the
    # call already happened and this round is the final answer.
    seen_result = False
    for message in request.get("messages", []):
        if message.get("role") == "tool":
            seen_result = True
    if seen_result:
        return None
    spec = content.split(marker, 1)[1].strip().splitlines()[0].strip()
    name, _, raw_args = spec.partition(" ")
    args = {}
    if raw_args.strip():
        try:
            args = json.loads(raw_args)
        except ValueError:
            # Prose after the arguments is allowed (`TOOLCALL:read {"path":...}
            # please describe it`): take the first balanced {...} object and
            # leave the rest as the message's own text. Without this the call
            # silently arrives with empty arguments, which reads as the tool
            # being broken rather than the marker being mis-parsed.
            depth = 0
            for index, char in enumerate(raw_args):
                if char == "{":
                    depth += 1
                elif char == "}":
                    depth -= 1
                    if depth == 0:
                        try:
                            args = json.loads(raw_args[: index + 1])
                        except ValueError:
                            args = {}
                        break
    call_id = "fixture-call-1"
    for message in request.get("messages", []):
        for call in message.get("tool_calls") or []:
            if isinstance(call, dict) and call.get("id"):
                call_id = str(call["id"])
    return {"id": call_id, "name": name, "arguments": json.dumps(args)}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        model = request.get("model", "")
        # The request body is recorded in full: those JSON lines are the
        # only place a test can see what the provider actually received
        # (the messages array as sent, tool definitions and all).
        with open(self.server.request_path, "a", encoding="utf-8") as output:
            output.write(
                json.dumps(
                    {
                        "path": self.path,
                        "model": model,
                        "stream": request.get("stream", False),
                        "messages": request.get("messages", []),
                    }
                )
                + "\n"
            )

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        call = scripted_tool_call(request)
        if call is not None:
            chunks = [
                {
                    "id": "chatcmpl-fixture",
                    "object": "chat.completion.chunk",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "delta": {
                                "role": "assistant",
                                "tool_calls": [
                                    {
                                        "index": 0,
                                        "id": call["id"],
                                        "type": "function",
                                        "function": {
                                            "name": call["name"],
                                            "arguments": call["arguments"],
                                        },
                                    }
                                ],
                            },
                            "finish_reason": None,
                        }
                    ],
                },
                {
                    "id": "chatcmpl-fixture",
                    "object": "chat.completion.chunk",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [
                        {"index": 0, "delta": {}, "finish_reason": "tool_calls"}
                    ],
                    "usage": {
                        "prompt_tokens": 123,
                        "completion_tokens": 1,
                        "total_tokens": 124,
                    },
                },
            ]
        else:
            chunks = [
                {
                    "id": "chatcmpl-fixture",
                    "object": "chat.completion.chunk",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"role": "assistant", "content": "OK"},
                            "finish_reason": None,
                        }
                    ],
                },
                {
                    "id": "chatcmpl-fixture",
                    "object": "chat.completion.chunk",
                    "created": int(time.time()),
                    "model": model,
                    "choices": [
                        {"index": 0, "delta": {}, "finish_reason": "stop"}
                    ],
                    "usage": {
                        "prompt_tokens": 123,
                        "completion_tokens": 1,
                        "total_tokens": 124,
                    },
                },
            ]
        for chunk in chunks:
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
            self.wfile.flush()
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: openai_stream_server.py PORT_FILE REQUEST_FILE")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.request_path = sys.argv[2]
    with open(sys.argv[1], "w", encoding="utf-8") as port_file:
        port_file.write(str(server.server_port))
    server.serve_forever()


if __name__ == "__main__":
    main()
