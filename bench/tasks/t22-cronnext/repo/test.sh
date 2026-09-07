#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
python3 -m unittest test_cron -v 2>&1
