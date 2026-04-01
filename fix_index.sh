#!/bin/bash
# Replace createIndexIfNotExists with createIndex wrapped in try/except

file="src/core/database.nim"

# Use perl for multiline replacement
perl -i -pe '
  s/(\s+)db\.createIndexIfNotExists\(([^)]+)\)/$1try:\n$1  db.createIndex($2)\n$1except:\n$1  discard/g
' "$file"

echo "Fixed $file"
