#!/usr/bin/env python3
"""Grandchild fixture standing in for nimsuggest.

Reproduces nimsuggest/procmonitor.nim verbatim in behaviour: once a second,
send the equivalent of `kill(clientPid, 0)`, and SIGTERM self when that fails.

The whole point of the surrounding test is that a zombie client keeps that
probe succeeding, so the grandchild never exits -- an orphan that would burn a
core forever. It records its own pid so the test can observe it.

argv: <clientPid> <pidfile>
"""
import os
import signal
import sys
import time

client = int(sys.argv[1])
pidfile = sys.argv[2]
with open(pidfile + ".new", "w") as f:
    f.write(str(os.getpid()))
os.replace(pidfile + ".new", pidfile)

while True:
    time.sleep(1)
    try:
        os.kill(client, 0)
    except ProcessLookupError:
        os.kill(os.getpid(), signal.SIGTERM)
        sys.exit(0)
