"""Serve a fixed JSON dataset on /data.json."""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

DATASET = [
    {"id": 1, "value": 10},
    {"id": 2, "value": 25},
    {"id": 3, "value": 40},
    {"id": 4, "value": 55},
    {"id": 5, "value": 70},
    {"id": 6, "value": 85},
]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/data.json":
            body = json.dumps(DATASET).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
