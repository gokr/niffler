#!/usr/bin/env python3
"""Fixture for the "disposed servers are reaped" regression in t_lsp.nim.

Models the nimtortoise -> nimsuggest process pair, whose orphan was the bug:

- Like nimtortoise it ignores SIGTERM, so the component's 50ms grace period
  lapses and it has to escalate to SIGKILL. A SIGKILLed-but-unreaped child is
  a zombie, and a zombie still holds its pid slot.
- Like nimtortoise it spawns a grandchild carrying its own pid as
  `--clientProcessId`, and that grandchild reproduces nimsuggest's watchdog
  (nimsuggest/procmonitor.nim) exactly: poll kill(clientPid, 0) once a second,
  SIGTERM self once that fails. Because kill(pid, 0) SUCCEEDS on a zombie, an
  unreaped server keeps its grandchild recompiling forever at 100% CPU.

Env:
  ZOMBIE_PID_DIR      directory receiving one file per (server pid -> grandchild pid)
  ZOMBIE_GRANDCHILD   path to the grandchild program (defaults to a sibling file)

Speaks just enough LSP to answer initialize and hover.
"""
import json
import os
import signal
import subprocess
import sys
import time

# nimtortoise does not exit inside the component's 50ms SIGTERM window.
signal.signal(signal.SIGTERM, signal.SIG_IGN)

here = os.path.dirname(os.path.abspath(__file__))
grandchild = os.environ.get("ZOMBIE_GRANDCHILD", os.path.join(here, "lsp_zombie_grandchild.py"))
piddir = os.environ.get("ZOMBIE_PID_DIR", "/tmp")

my_pid = os.getpid()
pidfile = os.path.join(piddir, str(my_pid))
subprocess.Popen([sys.executable, grandchild, str(my_pid), pidfile],
                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def send(obj):
    body = json.dumps(obj).encode()
    sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    sys.stdout.buffer.flush()


def read_msg(stream):
    length = None
    while True:
        line = stream.readline()
        if not line:
            return None
        line = line.strip()
        if length is None and line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
        elif line == b"" and length is not None:
            return json.loads(stream.read(length))


while True:
    msg = read_msg(sys.stdin.buffer)
    if msg is None:
        time.sleep(0.2)
        continue
    method, mid = msg.get("method"), msg.get("id")
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"capabilities": {
            "hoverProvider": True,
            "textDocumentSync": {"openClose": True, "change": 1}}}})
    elif method == "textDocument/hover":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "contents": {"kind": "plaintext", "value": "hover ok"}}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": None})
