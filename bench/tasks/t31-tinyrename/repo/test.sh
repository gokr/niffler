#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
go test ./...
if ! grep -q 'DrainAll' README.md; then echo "README does not document the renamed call"; exit 1; fi
if grep -q 'Drain()' README.md; then echo "README still shows the old call"; exit 1; fi
if ! grep -q '`Drain`' CHANGELOG.md; then echo "CHANGELOG history was rewritten"; exit 1; fi
echo "ALL TINYRENAME CHECKS PASSED"
