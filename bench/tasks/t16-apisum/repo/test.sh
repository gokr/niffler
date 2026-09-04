#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
python3 server.py 8765 &
SRV=$!
trap 'kill $SRV 2>/dev/null || true' EXIT
sleep 1
python3 solution.py
python3 check.py 2>&1
