#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
nim c -r --hints:off --warnings:off --path:src tests/test_iniparse.nim 2>&1
