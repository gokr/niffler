#!/usr/bin/env python3
"""Deterministic line emitter fixture for t_processes.nim.

Usage: line_emitter.py <count> [interval_ms] [tag]

Prints "<tag> line <i>" to stdout (flushed) for i in 0..<count, one every
interval_ms (default 100), then exits 0. With --fail <n>: after <n> lines,
print "FATAL boom" to stderr and exit 7. Unbuffered (-u) so lines reach the
spool file as they are printed.
"""
import sys
import time

def main():
    argv = sys.argv[1:]
    count = int(argv[0]) if argv else 5
    interval = int(argv[1]) / 1000.0 if len(argv) > 1 else 0.1
    tag = argv[2] if len(argv) > 2 else "tick"
    fail_at = int(argv[3]) if len(argv) > 3 and argv[3] != "-" else -1
    for i in range(count):
        print(f"{tag} line {i}", flush=True)
        if fail_at >= 0 and i == fail_at:
            print("FATAL boom", file=sys.stderr, flush=True)
            sys.exit(7)
        time.sleep(interval)

if __name__ == "__main__":
    main()
