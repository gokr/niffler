#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
node --test tests/jsonpatch.test.mjs 2>&1
