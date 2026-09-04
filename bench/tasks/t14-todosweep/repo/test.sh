#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
python3 check.py 2>&1
