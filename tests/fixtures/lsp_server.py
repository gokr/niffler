#!/usr/bin/env python3
"""Minimal deterministic LSP server fixture for t_lsp.nim.

Speaks the LSP wire protocol (Content-Length framing) over stdio and
implements just enough for the component tests:

- initialize/initialized handshake, plus a workspace/configuration
  server->client request right after `initialized` (exercises the
  component's polite-response path).
- textDocument/hover        -> echoes the received ZERO-BASED position in the
  hover text ("hover at line L char C") so tests can assert the
  one-based(wire)->zero-based conversion exactly.
- textDocument/definition   -> a fixed Location in sibling.nx (line 4,
  character 2, zero-based -> rendered as sibling.nx:5:3).
- textDocument/references   -> declaration location + one more iff
  context.includeDeclaration is true (proves the component always sends it).
- textDocument/didOpen      -> pushes two publishDiagnostics notifications
  for the opened document (an error and a warning), then a third one a
  moment later (exercises the settle logic).
- textDocument/implementation, etc. -> not advertised (capability refusal).

Optional env: LSP_FIXTURE_LOG=<path> appends one line per initialize,
recording the rootUri it was given, so tests can assert instance reuse (a
second query must not re-initialize) and root derivation (which directory
the component chose without being told).
"""

import json
import os
import sys
import time

LOG = os.environ.get("LSP_FIXTURE_LOG")


def log(msg):
    if LOG:
        with open(LOG, "a") as f:
            f.write(msg + "\n")


def read_frame():
    headers = {}
    while True:
        line = b""
        while not line.endswith(b"\r\n"):
            c = sys.stdin.buffer.read(1)
            if not c:
                sys.exit(0)
            line += c
        line = line.strip()
        if not line:
            break
        k, _, v = line.partition(b":")
        headers[k.strip().lower()] = v.strip()
    n = int(headers[b"content-length"])
    body = b""
    while len(body) < n:
        chunk = sys.stdin.buffer.read(n - len(body))
        if not chunk:
            sys.exit(0)
        body += chunk
    return json.loads(body)


def write_frame(obj):
    data = json.dumps(obj).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n%s" % (len(data), data))
    sys.stdout.buffer.flush()


def main():
    initialized = False
    while True:
        msg = read_frame()
        method = msg.get("method")
        if method == "initialize":
            log("initialize " + str(msg.get("params", {}).get("rootUri", "")))
            write_frame({"jsonrpc": "2.0", "id": msg["id"], "result": {
                "capabilities": {
                    "positionEncoding": "utf-16",
                    "textDocumentSync": {"openClose": True, "change": 2},
                    "hoverProvider": True,
                    "definitionProvider": True,
                    "referencesProvider": True,
                    # implementationProvider deliberately ABSENT:
                    # t_lsp asserts the component refuses with E_LSP_UNSUPPORTED.
                }}})
        elif method == "initialized":
            initialized = True
            # server->client request the component must answer politely
            write_frame({"jsonrpc": "2.0", "id": 9001,
                         "method": "workspace/configuration",
                         "params": {"items": [{"section": "nx"}]}})
        elif method == "textDocument/didOpen":
            uri = msg["params"]["textDocument"]["uri"]
            if "wobbly" not in uri:
                write_frame({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                             "params": {"uri": uri, "diagnostics": []}})
                continue
            write_frame({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                         "params": {"uri": uri, "diagnostics": [
                             {"range": {"start": {"line": 2, "character": 4},
                                        "end": {"line": 2, "character": 7}},
                              "severity": 1, "message": "undefined: wobble",
                              "source": "nx-check"},
                             {"range": {"start": {"line": 5, "character": 0},
                                        "end": {"line": 5, "character": 3}},
                              "severity": 2, "message": "unused variable"}]}})
            time.sleep(0.05)
            write_frame({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                         "params": {"uri": uri, "diagnostics": [
                             {"range": {"start": {"line": 2, "character": 4},
                                        "end": {"line": 2, "character": 7}},
                              "severity": 1, "message": "undefined: wobble",
                              "source": "nx-check", "code": "E1027"}]}})
        elif method == "textDocument/didClose":
            pass
        elif method == "textDocument/hover":
            pos = msg["params"]["position"]
            write_frame({"jsonrpc": "2.0", "id": msg["id"], "result": {
                "contents": {"kind": "markdown",
                             "value": "hover at line %d char %d" % (pos["line"], pos["character"])}}})
        elif method == "textDocument/definition":
            docdir = os.path.dirname(msg["params"]["textDocument"]["uri"].replace("file://", ""))
            target = os.path.join(docdir, "sibling.nx")
            write_frame({"jsonrpc": "2.0", "id": msg["id"], "result": {
                "uri": "file://" + target,
                "range": {"start": {"line": 4, "character": 2},
                          "end": {"line": 4, "character": 8}}}})
        elif method == "textDocument/references":
            ctx = msg["params"].get("context", {})
            locs = [{"uri": msg["params"]["textDocument"]["uri"],
                     "range": {"start": {"line": 9, "character": 0},
                               "end": {"line": 9, "character": 3}}}]
            if ctx.get("includeDeclaration"):
                locs.append({"uri": msg["params"]["textDocument"]["uri"],
                             "range": {"start": {"line": 1, "character": 0},
                                       "end": {"line": 1, "character": 3}}})
            write_frame({"jsonrpc": "2.0", "id": msg["id"], "result": locs})
        elif "id" in msg and "method" in msg:
            # any other server->client request: answer empty
            write_frame({"jsonrpc": "2.0", "id": msg["id"], "result": None})
        elif "id" in msg:
            # unknown client request (e.g. implementation): protocol error
            write_frame({"jsonrpc": "2.0", "id": msg["id"],
                         "error": {"code": -32601, "message": "not implemented"}})
        else:
            pass  # notification we don't care about


if __name__ == "__main__":
    main()
