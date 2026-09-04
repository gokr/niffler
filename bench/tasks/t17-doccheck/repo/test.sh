#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
go build ./... 2>&1
out=$(./check.sh)
status=$?
if [ $status -ne 0 ]; then
  echo "check.sh failed: $out"
  exit 1
fi
if [ "$out" != "clean" ]; then
  echo "check.sh did not print 'clean': $out"
  exit 1
fi
echo "OK: invariant holds"
