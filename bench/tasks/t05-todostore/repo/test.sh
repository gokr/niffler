#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
node --test tests/todos.test.mjs
