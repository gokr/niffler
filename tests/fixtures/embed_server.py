#!/usr/bin/env python3
"""Deterministic OpenAI-compatible /embeddings fixture with real semantics.

Why not a hash: a hash embedding has no notion of similarity, so a test built
on it could only prove that vectors round-trip, never that *semantic* search
works. The question memory validation has to answer is "does a query phrased in
different words find the right fact", and that needs a space where meaning
sits next to meaning.

So this fixture embeds text as a CONCEPT vector: each dimension is one concept,
and a token contributes to a concept when it appears in that concept's word
list. "install"/"dependency"/"depend"/"package" all light the same dimension,
so "how do we install dependencies" and "deps.package_manager: pnpm" land
close together with no shared tokens beyond the stem.

Consequences worth stating, because they bound what the test proves:

- Similarity is exact and repeatable: no model download, no network, no
  tolerance tuning. A failing assertion is a real bug in the caller's ranking,
  not embedding noise.
- It is NOT a proxy for nomic's quality. It proves the plumbing (provider
  record -> llm.embed -> embedding document -> vec0 kNN -> distance ordering)
  and the scope question; retrieval quality on a real model is a separate,
  human-run measurement (docs/research/LOCAL-EMBEDDINGS.md).

Endpoint shape (what components/llm's embedHandler sends):
  POST /v1/embeddings  {"model": "...", "input": ["...", ...]}
  -> {"data": [{"index": i, "embedding": [...]}], "usage": {...}}

Every request is appended to the log file (argv[2]) as one JSON line so a test
can assert the model id and input count that actually crossed the wire.
"""

import json
import math
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# One dimension per concept. Order defines the vector layout; keep it stable —
# a test asserting a distance depends on it.
CONCEPTS = {
    "package_manager": ["install", "instal", "depend", "dependency", "dependencies",
                        "package", "packages", "npm", "pnpm", "yarn", "venv", "pip"],
    "build": ["build", "compile", "make", "job", "jobs", "parallel", "compilation"],
    "test": ["test", "tests", "pytest", "spec", "assert", "suite"],
    "database": ["database", "db", "sqlite", "tidb", "postgres", "store", "storage"],
    "queue": ["queue", "worker", "job", "async", "retry", "backlog"],
    "network": ["network", "http", "socket", "port", "nats", "request", "endpoint"],
}

DIM = len(CONCEPTS)


def embed(text):
    """A concept vector for one string, L2-normalized.

    Normalizing matters: vec0 reports cosine distance, and an unnormalized
    vector would rank long texts above short on magnitude alone. A per-concept
    log-ish weight stops one repeated word from dominating a sentence.
    """
    lowered = "".join(ch.lower() if ch.isalnum() else " " for ch in text)
    words = set(lowered.split())
    vector = []
    for concept, vocabulary in CONCEPTS.items():
        hits = sum(1 for word in words if word in vocabulary)
        # sublinear: the same signal repeated is not linearly more meaning
        vector.append(float(hits) if hits == 0 else 1.0 + math.log(1.0 + hits))
    norm = math.sqrt(sum(v * v for v in vector))
    if norm == 0.0:
        # An empty or off-vocabulary input still needs a usable, deterministic
        # vector: one basis dimension would fake a topic, so use a constant
        # direction that is equidistant from every concept.
        return [1.0 / math.sqrt(DIM)] * DIM
    return [v / norm for v in vector]


class Handler(BaseHTTPRequestHandler):
    log_path = None

    def log_message(self, *args):
        pass  # keep stdout clean; the JSONL log is the record

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            request = json.loads(raw)
        except Exception:
            self.send_error(400, "bad json")
            return
        inputs = request.get("input", [])
        if isinstance(inputs, str):
            inputs = [inputs]
        model = request.get("model", "")
        if self.log_path:
            with open(self.log_path, "a") as handle:
                handle.write(json.dumps({
                    "path": self.path,
                    "model": model,
                    "input": inputs,
                    "auth": self.headers.get("Authorization", ""),
                }) + "\n")
        data = [{"object": "embedding", "index": i, "embedding": embed(text)}
                for i, text in enumerate(inputs)]
        body = json.dumps({
            "object": "list",
            "data": data,
            "model": model,
            "usage": {"prompt_tokens": sum(len(t.split()) for t in inputs),
                      "total_tokens": sum(len(t.split()) for t in inputs)},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    port = int(sys.argv[1])
    Handler.log_path = sys.argv[2] if len(sys.argv) > 2 else None
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
