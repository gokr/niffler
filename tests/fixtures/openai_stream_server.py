#!/usr/bin/env python3
"""Deterministic OpenAI-compatible SSE fixture for session/LLM bus tests."""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        request = json.loads(self.rfile.read(length))
        model = request.get("model", "")
        with open(self.server.request_path, "a", encoding="utf-8") as output:
            output.write(
                json.dumps(
                    {
                        "path": self.path,
                        "model": model,
                        "stream": request.get("stream", False),
                    }
                )
                + "\n"
            )

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
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
