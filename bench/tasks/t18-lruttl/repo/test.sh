#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
go test ./... 2>&1
