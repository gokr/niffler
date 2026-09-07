#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
nim c --hints:off --warnings:off -r test_tarpeek.nim
