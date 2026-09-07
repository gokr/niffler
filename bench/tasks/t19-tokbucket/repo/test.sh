#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
python3 -m unittest test_tokbucket -v 2>&1
