#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
PYTHONPATH=src python3 -m unittest discover -s tests -p 'test_*.py' -v 2>&1
