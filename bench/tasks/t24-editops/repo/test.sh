#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
node --test tests/editops.test.mjs 2>&1
