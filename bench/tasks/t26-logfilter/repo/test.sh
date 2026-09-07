#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
python3 -m unittest test_logfilter -v 2>&1
