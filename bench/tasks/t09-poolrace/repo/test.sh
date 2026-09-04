#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
go test -race ./... 2>&1
